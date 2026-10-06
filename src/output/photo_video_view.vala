using Gtk;

namespace Singularity.Apps.Photos {

    public class PhotoVideoView : Box {
        public Singularity.Widgets.MediaView view { get; private set; }
        public bool live { get; private set; default = false; }

        public signal void message(string text);
        public signal void saved(File trimmed);

        private File? current = null;
        private ToggleButton trim_toggle;
        private Revealer trim_revealer;
        private Scale start_scale;
        private Scale end_scale;
        private Label range_label;
        private Button save_button;
        private Spinner spinner;
        private bool busy = false;

        public PhotoVideoView() {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 8);
            hexpand = true;
            vexpand = true;
            VideoTools.ensure();
            view = new Singularity.Widgets.MediaView();
            view.hexpand = true;
            view.vexpand = true;
            append(view);

            var bar = new Box(Gtk.Orientation.HORIZONTAL, 8);
            bar.halign = Align.CENTER;
            trim_toggle = new ToggleButton.with_label(_("Trim"));
            trim_toggle.add_css_class("pill");
            trim_toggle.toggled.connect(() => trim_revealer.reveal_child = trim_toggle.active);
            bar.append(trim_toggle);
            append(bar);

            var trim_box = new Box(Gtk.Orientation.VERTICAL, 4);
            trim_box.add_css_class("photo-viewer-controls");
            trim_box.margin_start = trim_box.margin_end = 24;
            start_scale = new Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 1, 0.01);
            start_scale.draw_value = false;
            end_scale = new Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 1, 0.01);
            end_scale.draw_value = false;
            start_scale.value_changed.connect(() => {
                if (start_scale.get_value() > end_scale.get_value() - 0.1) start_scale.set_value(double.max(0, end_scale.get_value() - 0.1));
                view.playback.seek((int64) (start_scale.get_value() * Gst.SECOND));
                update_range();
            });
            end_scale.value_changed.connect(() => {
                if (end_scale.get_value() < start_scale.get_value() + 0.1) end_scale.set_value(start_scale.get_value() + 0.1);
                view.playback.seek((int64) (end_scale.get_value() * Gst.SECOND));
                update_range();
            });
            trim_box.append(scale_row(_("Start"), start_scale));
            trim_box.append(scale_row(_("End"), end_scale));
            var actions = new Box(Gtk.Orientation.HORIZONTAL, 8);
            range_label = new Label("");
            range_label.add_css_class("numeric");
            range_label.hexpand = true;
            range_label.xalign = 0;
            spinner = new Spinner();
            save_button = new Button.with_label(_("Save Trimmed Copy"));
            save_button.add_css_class("suggested-action");
            save_button.clicked.connect(() => save_trim());
            actions.append(range_label);
            actions.append(spinner);
            actions.append(save_button);
            trim_box.append(actions);
            trim_revealer = new Revealer();
            trim_revealer.child = trim_box;
            trim_revealer.transition_type = Singularity.Motion.reduced() ? RevealerTransitionType.NONE : RevealerTransitionType.SLIDE_UP;
            append(trim_revealer);

            view.playback.notify["duration"].connect(() => set_duration(view.playback.duration));
        }

        private Box scale_row(string title, Scale scale) {
            var row = new Box(Gtk.Orientation.HORIZONTAL, 8);
            var label = new Label(title);
            label.width_chars = 6;
            label.xalign = 0;
            scale.hexpand = true;
            row.append(label);
            row.append(scale);
            return row;
        }

        private void set_duration(int64 duration) {
            double seconds = duration / (double) Gst.SECOND;
            if (seconds <= 0) return;
            start_scale.set_range(0, seconds);
            end_scale.set_range(0, seconds);
            end_scale.set_value(seconds);
            start_scale.set_value(0);
            update_range();
        }

        private void update_range() {
            int64 a = (int64) (start_scale.get_value() * Gst.SECOND), b = (int64) (end_scale.get_value() * Gst.SECOND);
            range_label.label = _("%s to %s").printf(Singularity.Widgets.MediaPlayback.format_time(a), Singularity.Widgets.MediaPlayback.format_time(b));
            save_button.sensitive = !busy && !live && current != null;
        }

        public bool open(File photo_or_video) {
            var playable = LivePhoto.playable_for(photo_or_video);
            if (playable == null) return false;
            current = playable;
            live = !LivePhoto.is_video_name(photo_or_video.get_basename() ?? "");
            trim_toggle.visible = !live;
            trim_toggle.active = false;
            view.playback.loop = live;
            view.playback.muted = live;
            view.playback.open(playable.get_uri(), true);
            return true;
        }

        public void stop() {
            view.playback.stop();
            trim_toggle.active = false;
        }

        private void save_trim() {
            if (busy || current == null) return;
            busy = true;
            spinner.spinning = true;
            update_range();
            view.playback.pause();
            var source = current;
            int64 a = (int64) (start_scale.get_value() * Gst.SECOND), b = (int64) (end_scale.get_value() * Gst.SECOND);
            new Thread<void>("photos-video-trim", () => {
                File? result = null;
                string? error = null;
                try {
                    result = VideoTools.trim(source, a, b);
                } catch (Error e) {
                    error = e.message;
                }
                Idle.add(() => {
                    busy = false;
                    spinner.spinning = false;
                    update_range();
                    if (result != null) {
                        message(_("Saved as %s").printf(result.get_basename()));
                        saved(result);
                        trim_toggle.active = false;
                    } else {
                        message(_("Could not trim the video: %s").printf(error ?? ""));
                    }
                    return Source.REMOVE;
                });
            });
        }
    }
}
