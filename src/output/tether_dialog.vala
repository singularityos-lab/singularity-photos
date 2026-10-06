using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public class TetherDialog : AppDialog {
        private File folder;
        private Stack stack;
        private IndexChoiceRow camera_dd;
        private IndexChoiceRow preset_dd;
        private ActionRow folder_row;
        private SwitchRow watch_row;
        private SwitchRow live_row;
        private uint live_id = 0;
        private bool live_busy = false;
        private Picture last_shot;
        private Label status;
        private Button capture_button;
        private Gee.List<TetherCamera> cameras = new Gee.ArrayList<TetherCamera>();
        private Gee.List<DevelopPreset> presets;
        private TetherSession? session = null;
        private bool busy = false;
        private bool watching = false;
        private int captured = 0;

        public TetherDialog(Gtk.Window parent, File folder) {
            base(parent.application, true, false);
            this.folder = folder;
            transient_for = parent;
            set_title(_("Tethered Capture"));
            set_default_size(720, 560);
            presets = DevelopPresets.all();
            build();
            refresh();
            close_request.connect(() => {
                watching = false;
                set_live(false);
                return false;
            });
        }

        private void build() {
            stack = new Stack();
            stack.vexpand = true;
            var empty = new StatusPage();
            empty.icon_name = "camera-photo";
            empty.title = _("No Camera Connected");
            empty.description = _("Connect a camera with a USB cable, switch it on and set it to PC or PTP mode");
            var retry = new Button.with_label(_("Look Again"));
            retry.halign = Align.CENTER;
            retry.add_css_class("pill");
            retry.clicked.connect(() => refresh());
            empty.child = retry;
            stack.add_named(empty, "empty");

            var page = new Box(Gtk.Orientation.HORIZONTAL, 18);
            page.margin_start = page.margin_end = 18;
            page.margin_top = 6;
            var left = new Box(Gtk.Orientation.VERTICAL, 8);
            left.hexpand = true;
            last_shot = new Picture();
            last_shot.content_fit = ContentFit.CONTAIN;
            last_shot.vexpand = true;
            left.append(last_shot);
            status = new Label(_("Ready"));
            status.add_css_class("dim-label");
            status.wrap = true;
            left.append(status);
            page.append(left);
            var group = new PreferencesGroup(_("Session"));
            group.width_request = 300;
            group.add_row(OutputRows.choice(_("Camera"), { "" }, 0, out camera_dd));
            camera_dd.notify["selected-index"].connect(() => {
                set_live(false);
                if (session != null) session.close();
                session = null;
                probe();
            });
            folder_row = new ActionRow(_("Save To"), folder.get_path());
            var choose = new Button.with_label(_("Choose…"));
            choose.valign = Align.CENTER;
            choose.clicked.connect(() => choose_folder());
            folder_row.add_suffix(choose);
            group.add_row(folder_row);
            string[] names = { _("None") };
            foreach (var p in presets) names += p.name;
            group.add_row(OutputRows.choice(_("Develop Preset"), names, 0, out preset_dd));
            watch_row = new SwitchRow(_("Import Shots Taken on the Camera"));
            watch_row.switch_btn.notify["active"].connect(() => set_watch(watch_row.active));
            group.add_row(watch_row);
            live_row = new SwitchRow(_("Live View"));
            live_row.switch_btn.notify["active"].connect(() => set_live(live_row.active));
            group.add_row(live_row);
            var import_row = new ActionRow(_("Photos on the Camera"), _("Copy the shots that are not in Photos yet"));
            var import_button = new Button.with_label(_("Import"));
            import_button.valign = Align.CENTER;
            import_button.clicked.connect(() => import_card());
            import_row.add_suffix(import_button);
            group.add_row(import_row);
            page.append(group);
            stack.add_named(page, "session");
            content_box.append(stack);

            var bar = new Box(Gtk.Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 18;
            bar.margin_bottom = 16;
            bar.margin_top = 8;
            var spacer = new Box(Gtk.Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            bar.append(spacer);
            bar.append(add_cancel_button(_("Close")));
            capture_button = new Button.with_label(_("Take Photo"));
            capture_button.add_css_class("suggested-action");
            capture_button.clicked.connect(() => capture());
            bar.append(capture_button);
            content_box.append(bar);
        }

        private void refresh() {
            status.label = _("Looking for cameras…");
            new Thread<void>("photos-tether-detect", () => {
                var found = TetherSession.detect();
                Idle.add(() => {
                    cameras = found;
                    string[] names = {};
                    foreach (var c in cameras) names += c.model;
                    camera_dd.set_labels(names);
                    stack.visible_child_name = cameras.size > 0 ? "session" : "empty";
                    capture_button.visible = cameras.size > 0;
                    status.label = _("Ready");
                    if (cameras.size > 0) probe();
                    return Source.REMOVE;
                });
            });
        }

        private TetherSession current_session() {
            if (session == null) session = new TetherSession(cameras[((int) camera_dd.selected_index).clamp(0, cameras.size - 1)]);
            return session;
        }

        private void probe() {
            if (cameras.size == 0) return;
            var s = current_session();
            new Thread<void>("photos-tether-probe", () => {
                bool capture = false, preview = false;
                string? error = null;
                try {
                    capture = s.can_capture();
                    preview = s.can_preview();
                } catch (Error e) {
                    error = e.message;
                }
                Idle.add(() => {
                    capture_button.visible = capture;
                    live_row.visible = preview;
                    if (error != null) status.label = error;
                    else if (!capture) status.label = _("This camera cannot be triggered from the computer; its photos can still be imported");
                    return Source.REMOVE;
                });
            });
        }

        private void set_live(bool on) {
            if (!on) {
                if (live_id != 0) Source.remove(live_id);
                live_id = 0;
                return;
            }
            if (live_id != 0 || cameras.size == 0) return;
            var s = current_session();
            live_id = Timeout.add(125, () => {
                if (live_busy || busy) return Source.CONTINUE;
                live_busy = true;
                new Thread<void>("photos-tether-live", () => {
                    Gdk.Texture? frame = null;
                    string? error = null;
                    try {
                        frame = Gdk.Texture.from_bytes(s.preview());
                    } catch (Error e) {
                        error = e.message;
                    }
                    Idle.add(() => {
                        live_busy = false;
                        if (frame != null) last_shot.paintable = frame;
                        else if (error != null) {
                            status.label = error;
                            live_row.active = false;
                        }
                        return Source.REMOVE;
                    });
                });
                return Source.CONTINUE;
            });
        }

        private void import_card() {
            if (busy || cameras.size == 0) return;
            busy = true;
            status.label = _("Copying photos from the camera…");
            var s = current_session();
            var dir = folder;
            string preset = preset_id();
            new Thread<void>("photos-tether-import", () => {
                Gee.List<File>? got = null;
                string? error = null;
                try {
                    got = TetherImport.import_new(s, dir, preset);
                } catch (Error e) {
                    error = e.message;
                }
                Idle.add(() => {
                    busy = false;
                    if (error != null) {
                        status.label = error;
                    } else if (got.size == 0) {
                        status.label = _("Every photo on the camera is already in Photos");
                    } else {
                        foreach (var f in got) imported(f);
                    }
                    return Source.REMOVE;
                });
            });
        }

        private string preset_id() {
            int i = (int) preset_dd.selected_index;
            return i <= 0 || i > presets.size ? "" : presets[i - 1].id;
        }

        private void choose_folder() {
            var chooser = new FileDialog();
            chooser.title = _("Save Captures To");
            chooser.select_folder.begin(this, null, (o, res) => {
                try {
                    var f = chooser.select_folder.end(res);
                    if (f == null) return;
                    folder = f;
                    folder_row.subtitle = f.get_path();
                } catch (Error e) {
                }
            });
        }

        private void imported(File file) {
            captured++;
            status.label = ngettext("%d photo captured, last %s", "%d photos captured, last %s", captured).printf(captured, file.get_basename());
            new Thread<void>("photos-tether-thumb", () => {
                Gdk.Texture? tex = null;
                try {
                    tex = OutputRender.thumbnail(file, 900);
                } catch (Error e) {
                }
                Idle.add(() => {
                    if (tex != null) last_shot.paintable = tex;
                    return Source.REMOVE;
                });
            });
        }

        private void capture() {
            if (busy || cameras.size == 0) return;
            busy = true;
            capture_button.sensitive = false;
            status.label = _("Taking a photo…");
            var s = current_session();
            var dir = folder;
            string preset = preset_id();
            new Thread<void>("photos-tether-capture", () => {
                File? shot = null;
                string? error = null;
                try {
                    shot = s.capture(dir);
                    TetherImport.apply_preset(shot, preset);
                } catch (Error e) {
                    error = e.message;
                }
                Idle.add(() => {
                    busy = false;
                    capture_button.sensitive = true;
                    if (error != null) status.label = error;
                    else imported(shot);
                    return Source.REMOVE;
                });
            });
        }

        private void set_watch(bool on) {
            if (on == watching) return;
            watching = on;
            if (!on || cameras.size == 0) return;
            var s = current_session();
            var dir = folder;
            string preset = preset_id();
            new Thread<void>("photos-tether-watch", () => {
                while (watching) {
                    if (busy) {
                        Thread.usleep(200000);
                        continue;
                    }
                    try {
                        var shot = s.wait(dir, 1000);
                        if (shot != null) {
                            TetherImport.apply_preset(shot, preset);
                            Idle.add(() => {
                                imported(shot);
                                return Source.REMOVE;
                            });
                        }
                    } catch (Error e) {
                        string msg = e.message;
                        Idle.add(() => {
                            status.label = msg;
                            watch_row.active = false;
                            return Source.REMOVE;
                        });
                        break;
                    }
                }
            });
        }
    }
}
