using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public class SlideStage : Widget {
        public SlideCompositor? compositor = null;
        public double time = 0;

        construct {
            hexpand = true;
            vexpand = true;
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            var rect = Graphene.Rect();
            rect.init(0, 0, get_width(), get_height());
            var cr = snapshot.append_cairo(rect);
            cr.set_source_rgb(0, 0, 0);
            cr.paint();
            if (compositor == null) return;
            double s = double.min(get_width() / (double) compositor.width, get_height() / (double) compositor.height);
            cr.translate((get_width() - compositor.width * s) / 2, (get_height() - compositor.height * s) / 2);
            cr.scale(s, s);
            cr.rectangle(0, 0, compositor.width, compositor.height);
            cr.clip();
            compositor.draw(cr, time);
        }
    }

    public class SlideshowWindow : Gtk.Window {
        private File[] files;
        private SlideshowSpec spec = new SlideshowSpec();
        private SlideStage stage;
        private Spinner spinner;
        private Box controls;
        private Button play_button;
        private DropDown transition_dd;
        private DropDown caption_dd;
        private SpinButton seconds_spin;
        private Button music_button;
        private ProgressBar export_progress;
        private Gst.Element? player = null;
        private bool playing = true;
        private int64 last_frame = 0;
        private uint tick_id = 0;
        private uint hide_id = 0;
        private uint load_serial = 0;
        private Gtk.Window parent_window;

        public SlideshowWindow(Gtk.Window parent, File[] files) {
            Object(application: parent.application, title: _("Slideshow"));
            this.files = files;
            parent_window = parent;
            transient_for = parent;
            set_default_size(1100, 700);
            add_css_class("photo-slideshow");
            if (Singularity.Motion.reduced()) spec.transition = "fade";
            var overlay = new Overlay();
            stage = new SlideStage();
            overlay.child = stage;
            spinner = new Spinner();
            spinner.halign = Align.CENTER;
            spinner.valign = Align.CENTER;
            spinner.width_request = 48;
            spinner.height_request = 48;
            overlay.add_overlay(spinner);
            controls = build_controls();
            overlay.add_overlay(controls);
            export_progress = new ProgressBar();
            export_progress.halign = Align.CENTER;
            export_progress.valign = Align.START;
            export_progress.margin_top = 16;
            export_progress.width_request = 320;
            export_progress.show_text = true;
            export_progress.visible = false;
            overlay.add_overlay(export_progress);
            child = overlay;
            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                switch (keyval) {
                    case Gdk.Key.Escape: close(); return true;
                    case Gdk.Key.space: toggle_play(); return true;
                    case Gdk.Key.Left: step(-1); return true;
                    case Gdk.Key.Right: step(1); return true;
                    case Gdk.Key.F11:
                    case Gdk.Key.f:
                        if (fullscreened) unfullscreen(); else fullscreen();
                        return true;
                    default: return false;
                }
            });
            ((Widget) this).add_controller(keys);
            var motion = new EventControllerMotion();
            motion.motion.connect(() => reveal_controls());
            ((Widget) this).add_controller(motion);
            close_request.connect(() => {
                stop_music();
                if (tick_id != 0) stage.remove_tick_callback(tick_id);
                tick_id = 0;
                return false;
            });
            reload();
            tick_id = stage.add_tick_callback((w, clock) => {
                int64 now = clock.get_frame_time();
                if (last_frame != 0 && playing) stage.time += (now - last_frame) / 1000000.0;
                last_frame = now;
                stage.queue_draw();
                return Source.CONTINUE;
            });
            reveal_controls();
        }

        private Button osd_button(string icon, string tooltip) {
            var b = new Button.from_icon_name(icon);
            b.add_css_class("flat");
            b.tooltip_text = tooltip;
            controls.append(b);
            return b;
        }

        private Box build_controls() {
            controls = new Box(Gtk.Orientation.HORIZONTAL, 8);
            controls.add_css_class("photo-viewer-controls");
            controls.halign = Align.CENTER;
            controls.valign = Align.END;
            controls.margin_bottom = 20;
            osd_button("go-previous-symbolic", _("Previous (Left)")).clicked.connect(() => step(-1));
            play_button = osd_button("media-playback-pause-symbolic", _("Pause (Space)"));
            play_button.clicked.connect(() => toggle_play());
            osd_button("go-next-symbolic", _("Next (Right)")).clicked.connect(() => step(1));
            transition_dd = OutputRows.dropdown({ _("No Transition"), _("Crossfade"), _("Slide"), _("Zoom") }, OutputRows.index_of(SlideshowSpec.TRANSITIONS, spec.transition));
            transition_dd.tooltip_text = _("Transition");
            transition_dd.notify["selected"].connect(() => {
                spec.transition = SlideshowSpec.TRANSITIONS[((int) transition_dd.selected).clamp(0, 3)];
                reload();
            });
            controls.append(transition_dd);
            seconds_spin = new SpinButton.with_range(1, 60, 1);
            seconds_spin.value = spec.slide_seconds;
            seconds_spin.tooltip_text = _("Seconds per Photo");
            seconds_spin.valign = Align.CENTER;
            seconds_spin.value_changed.connect(() => {
                double index = Math.floor(stage.time / spec.slide_seconds);
                spec.slide_seconds = seconds_spin.value;
                spec.transition_seconds = double.min(1.0, spec.slide_seconds / 3);
                stage.time = index * spec.slide_seconds;
            });
            controls.append(seconds_spin);
            caption_dd = OutputRows.dropdown({ _("No Captions"), _("File Name"), _("Title"), _("Caption") }, 0);
            caption_dd.tooltip_text = _("Captions");
            caption_dd.notify["selected"].connect(() => {
                string[] ids = { "none", "filename", "title", "caption" };
                spec.caption = ids[((int) caption_dd.selected).clamp(0, 3)];
                reload();
            });
            controls.append(caption_dd);
            music_button = osd_button("audio-x-generic-symbolic", _("Background Music"));
            music_button.clicked.connect(() => choose_music());
            osd_button("document-save-symbolic", _("Export as Video")).clicked.connect(() => choose_video_target());
            osd_button("view-fullscreen-symbolic", _("Full Screen (F11)")).clicked.connect(() => {
                if (fullscreened) unfullscreen(); else fullscreen();
            });
            osd_button("window-close-symbolic", _("Close (Esc)")).clicked.connect(() => close());
            return controls;
        }

        private void reveal_controls() {
            controls.opacity = 1;
            if (hide_id != 0) Source.remove(hide_id);
            hide_id = Timeout.add_seconds(3, () => {
                hide_id = 0;
                if (playing) Singularity.Motion.tween(controls, "opacity", 0.0, Singularity.Motion.Duration.LARGE, Singularity.Motion.Curve.EXIT);
                return Source.REMOVE;
            });
        }

        private void reload() {
            uint serial = ++load_serial;
            spinner.spinning = true;
            spinner.visible = true;
            var s = spec;
            var list = files;
            new Thread<void>("photos-slideshow", () => {
                var comp = new SlideCompositor(s, 1920, 1080);
                foreach (var f in list) {
                    try {
                        comp.add_file(f);
                    } catch (Error e) {
                        warning("Photos: slideshow skipped %s: %s", f.get_path(), e.message);
                    }
                }
                Idle.add(() => {
                    if (serial != load_serial) return Source.REMOVE;
                    spinner.spinning = false;
                    spinner.visible = false;
                    stage.compositor = comp;
                    stage.queue_draw();
                    return Source.REMOVE;
                });
            });
        }

        private void toggle_play() {
            playing = !playing;
            play_button.icon_name = playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
            play_button.tooltip_text = playing ? _("Pause (Space)") : _("Play (Space)");
            if (player != null) player.set_state(playing ? Gst.State.PLAYING : Gst.State.PAUSED);
            reveal_controls();
        }

        private void step(int delta) {
            double index = Math.floor(stage.time / spec.slide_seconds) + delta;
            if (index < 0) index = int.max(0, files.length - 1);
            stage.time = index * spec.slide_seconds;
            stage.queue_draw();
            reveal_controls();
        }

        private void choose_music() {
            var chooser = new FileDialog();
            chooser.title = _("Choose Music");
            var filter = new FileFilter();
            filter.name = _("Audio");
            filter.add_mime_type("audio/*");
            var filters = new GLib.ListStore(typeof(FileFilter));
            filters.append(filter);
            chooser.filters = filters;
            chooser.open.begin(this, null, (o, res) => {
                try {
                    var f = chooser.open.end(res);
                    if (f == null) return;
                    spec.music = f.get_path();
                    music_button.tooltip_text = f.get_basename();
                    start_music();
                } catch (Error e) {
                }
            });
        }

        private void start_music() {
            stop_music();
            if (spec.music == "") return;
            player = Gst.ElementFactory.make("playbin", "slideshow-music");
            if (player == null) return;
            player.set("uri", Filename.to_uri(spec.music));
            player.set("flags", 0x2);
            var bus = ((Gst.Pipeline) player).get_bus();
            bus.add_signal_watch();
            bus.message["eos"].connect(() => {
                if (player != null) player.seek_simple(Gst.Format.TIME, Gst.SeekFlags.FLUSH, 0);
            });
            player.set_state(playing ? Gst.State.PLAYING : Gst.State.PAUSED);
        }

        private void stop_music() {
            if (player == null) return;
            player.set_state(Gst.State.NULL);
            player = null;
        }

        private void choose_video_target() {
            var containers = SlideshowVideo.available_containers();
            if (containers.length == 0) {
                OutputRows.toast(parent_window, _("No video encoder is available on this system"));
                return;
            }
            var chooser = new FileDialog();
            chooser.title = _("Export Slideshow");
            chooser.initial_name = _("Slideshow") + "." + containers[0];
            chooser.save.begin(this, null, (o, res) => {
                try {
                    var f = chooser.save.end(res);
                    if (f == null) return;
                    string path = f.get_path();
                    string container = path.down().has_suffix(".webm") && "webm" in containers ? "webm" : containers[0];
                    if (!path.down().has_suffix("." + container)) path += "." + container;
                    export_video(path, container);
                } catch (Error e) {
                }
            });
        }

        private void export_video(string path, string container) {
            var copy = new SlideshowSpec();
            copy.slide_seconds = spec.slide_seconds;
            copy.transition_seconds = spec.transition_seconds;
            copy.transition = spec.transition;
            copy.caption = spec.caption;
            copy.music = spec.music;
            export_progress.visible = true;
            export_progress.fraction = 0;
            export_progress.text = _("Exporting video…");
            var list = files;
            new Thread<void>("photos-slideshow-video", () => {
                string? error = null;
                try {
                    SlideshowVideo.export(list, copy, 1920, 1080, 30, container, path, null, (f) => {
                        Idle.add(() => {
                            export_progress.fraction = f;
                            return Source.REMOVE;
                        });
                    });
                } catch (Error e) {
                    error = e.message;
                }
                Idle.add(() => {
                    export_progress.visible = false;
                    OutputRows.toast(parent_window, error == null ? _("Saved %s").printf(Path.get_basename(path)) : _("Could not export the video: %s").printf(error));
                    return Source.REMOVE;
                });
            });
        }
    }
}
