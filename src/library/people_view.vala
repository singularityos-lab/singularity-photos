using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public class FaceScanResult {
        public int64 photo_id;
        public FaceBox[] boxes = {};
        public Gee.ArrayList<FloatBox> descriptors = new Gee.ArrayList<FloatBox>();
    }

    public class FloatBox {
        public float[] values;
    }

    public class PeopleView : Box {
        public const double CLUSTER_THRESHOLD = 0.6;

        public Catalog catalog { get; construct; }
        public signal void person_activated(PersonRecord person);
        public signal void message(string text);
        public signal void collection_created(CollectionRecord collection);

        private FlowBox flow;
        private Label status;
        private Button scan_btn;
        private Spinner spinner;
        private WelcomePage empty;
        private Box bar;
        private bool scanning = false;
        private Cancellable? cancel = null;

        public PeopleView(Catalog catalog) {
            Object(catalog: catalog, orientation: Orientation.VERTICAL, spacing: 8);
        }

        construct {
            hexpand = true;
            vexpand = true;
            bar = new Box(Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 16;
            apply_bubble_inset(bar, 56, 8);
            status = new Label("");
            status.add_css_class("dim-label");
            status.hexpand = true;
            status.xalign = 0;
            status.wrap = true;
            bar.append(status);
            spinner = new Spinner();
            bar.append(spinner);
            scan_btn = new Button.with_label(_("Find People"));
            scan_btn.add_css_class("suggested-action");
            scan_btn.tooltip_text = _("Faces are found and grouped on this computer, nothing is sent over the network");
            scan_btn.clicked.connect(() => toggle_scan());
            bar.append(scan_btn);
            append(bar);
            var overlay = new Overlay();
            overlay.vexpand = true;
            flow = new FlowBox();
            flow.selection_mode = SelectionMode.NONE;
            flow.homogeneous = true;
            flow.min_children_per_line = 2;
            flow.max_children_per_line = 10;
            flow.halign = Align.START;
            flow.column_spacing = 12;
            flow.row_spacing = 12;
            flow.margin_start = flow.margin_end = 16;
            flow.valign = Align.START;
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = flow;
            overlay.child = scroll;
            empty = new WelcomePage();
            empty.is_section = true;
            empty.app_icon_name = "avatar-default";
            empty.title = _("People");
            empty.subtitle = _("No people found yet. Faces are found and grouped on this computer, nothing is sent over the network.");
            empty.add_action("edit-find", _("Find People"), _("Look for faces in your photos and group them"), () => toggle_scan());
            empty.vexpand = true;
            overlay.add_overlay(empty);
            append(overlay);
            refresh();
        }

        private void toggle_scan() {
            if (scanning) {
                stop();
                return;
            }
            catalog.set_meta("ui.people-enabled", "1");
            scan();
        }

        public void refresh() {
            Widget? c;
            while ((c = flow.get_first_child()) != null) flow.remove(c);
            var counts = new Gee.HashMap<int64?, int>(id_hash, id_equal);
            var sample = new Gee.HashMap<int64?, FaceRecord>(id_hash, id_equal);
            foreach (var f in catalog.faces.values) {
                if (f.person_id == 0) continue;
                counts[f.person_id] = (counts.has_key(f.person_id) ? counts[f.person_id] : 0) + 1;
                if (!sample.has_key(f.person_id)) sample[f.person_id] = f;
            }
            var people = new Gee.ArrayList<PersonRecord>();
            foreach (var p in catalog.people.values) if (counts.has_key(p.id)) people.add(p);
            people.sort((a, b) => {
                if ((a.name == "") != (b.name == "")) return a.name == "" ? 1 : -1;
                return counts[b.id] - counts[a.id];
            });
            foreach (var p in people) flow.append(tile(p, counts[p.id], sample[p.id]));
            empty.visible = people.size == 0 && !scanning;
            bar.visible = !empty.visible;
            int scanned = 0, total = 0;
            foreach (var r in catalog.photos.values) {
                if (r.master_id != 0 || r.kind == "video") continue;
                total++;
                if (catalog.faces_scanned(r)) scanned++;
            }
            if (!scanning) status.label = ngettext("%d person", "%d people", people.size).printf(people.size) + ", " +
                _("%d of %d photos scanned").printf(scanned, total);
        }

        private Widget tile(PersonRecord person, int count, FaceRecord face) {
            var btn = new Button();
            btn.add_css_class("flat");
            var box = new Box(Orientation.VERTICAL, 6);
            var pic = new Image();
            pic.pixel_size = 96;
            pic.add_css_class("photos-face");
            pic.overflow = Overflow.HIDDEN;
            pic.halign = Align.CENTER;
            box.append(pic);
            var name = new Label(person.name != "" ? person.name : _("Add Name"));
            if (person.name == "") name.add_css_class("dim-label");
            name.ellipsize = Pango.EllipsizeMode.END;
            name.max_width_chars = 14;
            box.append(name);
            var n = new Label(ngettext("%d photo", "%d photos", count).printf(count));
            n.add_css_class("caption");
            n.add_css_class("dim-label");
            box.append(n);
            btn.child = box;
            btn.clicked.connect(() => person_activated(person));
            var ctx = new GestureClick();
            ctx.button = 3;
            ctx.pressed.connect((np, x, y) => show_menu(btn, person, x, y));
            btn.add_controller(ctx);
            load_face(pic, face);
            return btn;
        }

        public bool enabled() {
            return catalog.get_meta("ui.people-enabled") == "1";
        }

        public void auto_scan() {
            if (!enabled() || scanning) return;
            foreach (var r in catalog.photos.values) {
                if (r.master_id != 0 || r.missing || r.kind == "video") continue;
                if (!catalog.faces_scanned(r)) {
                    scan(true);
                    return;
                }
            }
        }

        private void create_person_collection(PersonRecord person) {
            var rules = new SmartRules();
            rules.rules.add(new SmartRule("person", "is", person.name));
            var c = catalog.create_collection(person.name, "smart", 0, rules.to_json());
            collection_created(c);
        }

        private void show_menu(Widget w, PersonRecord person, double x, double y) {
            var menu = new ContextMenu(w);
            var r = Gdk.Rectangle();
            r.x = (int) x;
            r.y = (int) y;
            r.width = r.height = 1;
            menu.pointing_to = r;
            menu.add_item(_("Rename…"), "document-edit-symbolic", () => {
                var win = get_root() as Gtk.Window;
                if (win == null) return;
                LibraryDialogs.ask_text(win, _("Name This Person"), _("Name"), person.name, _("Save"), (name) => {
                    PersonRecord? same = null;
                    foreach (var p in catalog.people.values) if (p != person && p.name.down() == name.down()) same = p;
                    if (same != null) catalog.merge_people(same, person);
                    else catalog.rename_person(person, name);
                    refresh();
                });
            });
            menu.add_item(_("Review Faces…"), "system-users-symbolic", () => {
                var win = get_root() as Gtk.Window;
                if (win != null) new FacesDialog(win, catalog, person, () => refresh()).present();
            });
            menu.add_item(_("Show Photos"), "image-x-generic-symbolic", () => person_activated(person));
            if (person.name != "") {
                menu.add_item(_("Create Smart Collection"), "edit-find-symbolic", () => create_person_collection(person));
            }
            menu.add_item(_("Not a Person"), "action-unavailable-symbolic", () => {
                catalog.begin();
                foreach (var f in catalog.person_faces(person.id)) catalog.set_face_state(f, -1);
                catalog.prune_people();
                catalog.commit();
                refresh();
            });
            var merge = menu.add_submenu(_("Merge Into"), null);
            foreach (var p in catalog.people.values) {
                if (p == person || p.name == "") continue;
                var target = p;
                merge.add_item(p.name, null, () => {
                    catalog.merge_people(target, person);
                    refresh();
                });
            }
            menu.popup();
        }

        private void load_face(Image pic, FaceRecord face) {
            var r = catalog.photos[face.photo_id];
            if (r == null) return;
            string path = r.path;
            double fx = face.x, fy = face.y, fw = face.width, fh = face.height;
            new Thread<void>("photos-face-thumb", () => {
                Gdk.Texture? tex = null;
                try {
                    var pb = new Gdk.Pixbuf.from_file_at_scale(path, 900, 900, true);
                    pb = pb.apply_embedded_orientation() ?? pb;
                    double pad = 0.25;
                    int x = (int) ((fx - fw * pad) * pb.width).clamp(0, pb.width - 1);
                    int y = (int) ((fy - fh * pad) * pb.height).clamp(0, pb.height - 1);
                    int w = (int) (fw * (1 + pad * 2) * pb.width).clamp(1, pb.width - x);
                    int h = (int) (fh * (1 + pad * 2) * pb.height).clamp(1, pb.height - y);
                    int side = int.min(w, h);
                    tex = Gdk.Texture.for_pixbuf(new Gdk.Pixbuf.subpixbuf(pb, x + (w - side) / 2, y + (h - side) / 2, side, side).scale_simple(192, 192, Gdk.InterpType.BILINEAR));
                } catch (Error e) {
                }
                Idle.add(() => {
                    pic.set_from_paintable(tex);
                    return Source.REMOVE;
                });
            });
        }

        public void stop() {
            if (cancel != null) cancel.cancel();
        }

        public void scan(bool quiet = false) {
            if (scanning) return;
            var todo = new Gee.ArrayList<PhotoRecord>();
            foreach (var r in catalog.photos.values) {
                if (r.master_id != 0 || r.missing || r.kind == "video") continue;
                if (!catalog.faces_scanned(r)) todo.add(r);
            }
            if (todo.size == 0) {
                PeopleClustering.cluster(catalog, CLUSTER_THRESHOLD);
                refresh();
                if (!quiet) message(_("Every photo has already been scanned"));
                return;
            }
            scanning = true;
            empty.visible = false;
            bar.visible = true;
            cancel = new Cancellable();
            var c = cancel;
            scan_btn.label = _("Stop");
            spinner.spinning = true;
            int total = todo.size;
            int64[] ids = new int64[total];
            string[] paths = new string[total];
            for (int i = 0; i < total; i++) {
                ids[i] = todo[i].id;
                paths[i] = todo[i].path;
            }
            new Thread<void>("photos-faces", () => {
                int found = 0;
                for (int i = 0; i < total && !c.is_cancelled(); i++) {
                    var res = new FaceScanResult();
                    res.photo_id = ids[i];
                    try {
                        var photo = Codecs.load(File.new_for_path(paths[i]), 1024);
                        res.boxes = Faces.detect(photo.image);
                        foreach (var b in res.boxes) {
                            var fb = new FloatBox();
                            fb.values = Faces.descriptor(photo.image, b);
                            res.descriptors.add(fb);
                        }
                    } catch (Error e) {
                    }
                    found += res.boxes.length;
                    int done = i + 1;
                    int so_far = found;
                    Idle.add(() => {
                        var r = catalog.photos[res.photo_id];
                        if (r != null) {
                            for (int k = 0; k < res.boxes.length; k++) catalog.add_face(r, res.boxes[k], res.descriptors[k].values);
                            catalog.mark_faces_scanned(r);
                        }
                        status.label = _("Scanning %d of %d photos, %d faces found").printf(done, total, so_far);
                        return Source.REMOVE;
                    });
                }
                Idle.add(() => {
                    scanning = false;
                    scan_btn.label = _("Find People");
                    spinner.spinning = false;
                    PeopleClustering.cluster(catalog, CLUSTER_THRESHOLD);
                    refresh();
                    if (catalog.faces.size == 0 && !quiet) message(_("No faces were found"));
                    return Source.REMOVE;
                });
            });
        }
    }
}

namespace Singularity.Apps.Photos {

    public delegate void FacesChanged();

    public class FacesDialog : Object {
        private Gtk.Window parent;
        private Catalog catalog;
        private PersonRecord person;
        private FacesChanged changed;
        private AppDialog dlg;
        private FlowBox flow;

        public FacesDialog(Gtk.Window parent, Catalog catalog, PersonRecord person, owned FacesChanged changed) {
            this.parent = parent;
            this.catalog = catalog;
            this.person = person;
            this.changed = (owned) changed;
        }

        public void present() {
            dlg = LibraryDialogs.make(parent, person.name != "" ? person.name : _("Unnamed Person"), 640);
            dlg.set_default_size(640, 560);
            var box = LibraryDialogs.body(dlg);
            var hint = new Label(_("Confirm the faces that are this person, move the others to the right person or mark them as not this person. Confirmed faces guide the next grouping."));
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class("dim-label");
            box.append(hint);
            flow = new FlowBox();
            flow.selection_mode = SelectionMode.NONE;
            flow.homogeneous = true;
            flow.min_children_per_line = 3;
            flow.max_children_per_line = 5;
            flow.column_spacing = flow.row_spacing = 12;
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = flow;
            box.append(scroll);
            var bar = new Box(Orientation.HORIZONTAL, 8);
            bar.halign = Align.END;
            bar.margin_start = bar.margin_end = 18;
            bar.margin_bottom = 16;
            var close = new Button.with_label(_("Close"));
            close.clicked.connect(() => dlg.close_dialog());
            dlg.set_cancel_button(close);
            bar.append(close);
            dlg.content_box.append(bar);
            rebuild();
            dlg.open_dialog();
        }

        private void rebuild() {
            Widget? c;
            while ((c = flow.get_first_child()) != null) flow.remove(c);
            var list = catalog.person_faces(person.id);
            if (list.size == 0) {
                dlg.close_dialog();
                changed();
                return;
            }
            foreach (var f in list) flow.append(tile(f));
        }

        private Widget tile(FaceRecord face) {
            var box = new Box(Orientation.VERTICAL, 6);
            var pic = new Image();
            pic.pixel_size = 96;
            pic.add_css_class("photos-face");
            pic.overflow = Overflow.HIDDEN;
            pic.halign = Align.CENTER;
            box.append(pic);
            var state = new Label(face.confirmed() ? _("Confirmed") : _("Suggested"));
            state.add_css_class("caption");
            if (!face.confirmed()) state.add_css_class("dim-label");
            box.append(state);
            var actions = new Box(Orientation.HORIZONTAL, 2);
            actions.halign = Align.CENTER;
            var ok = new Button.from_icon_name("object-select-symbolic");
            ok.add_css_class("flat");
            ok.tooltip_text = _("This Is the Person");
            ok.sensitive = !face.confirmed();
            ok.clicked.connect(() => {
                catalog.set_face_state(face, 1);
                rebuild();
                changed();
            });
            actions.append(ok);
            var no = new Button.from_icon_name("action-unavailable-symbolic");
            no.add_css_class("flat");
            no.tooltip_text = _("Not This Person");
            no.clicked.connect(() => {
                catalog.set_face_state(face, -1);
                catalog.prune_people();
                rebuild();
                changed();
            });
            actions.append(no);
            var move = new Button.from_icon_name("system-users-symbolic");
            move.add_css_class("flat");
            move.tooltip_text = _("Move to Another Person");
            move.clicked.connect(() => {
                var menu = new ContextMenu(move);
                menu.add_item(_("New Person…"), "list-add-symbolic", () => {
                    LibraryDialogs.ask_text(dlg, _("New Person"), _("Name"), "", _("Create"), (name) => {
                        var target = catalog.find_person(name) ?? catalog.create_person(name);
                        catalog.move_face(face, target.id);
                        rebuild();
                        changed();
                    });
                });
                foreach (var p in catalog.people.values) {
                    if (p == person || p.name == "") continue;
                    var target = p;
                    menu.add_item(p.name, null, () => {
                        catalog.move_face(face, target.id);
                        rebuild();
                        changed();
                    });
                }
                menu.popup();
            });
            actions.append(move);
            box.append(actions);
            var r = catalog.photos[face.photo_id];
            if (r != null) {
                string path = r.path;
                double fx = face.x, fy = face.y, fw = face.width, fh = face.height;
                new Thread<void>("photos-face-crop", () => {
                    Gdk.Texture? tex = null;
                    try {
                        var pb = new Gdk.Pixbuf.from_file_at_scale(path, 900, 900, true);
                        pb = pb.apply_embedded_orientation() ?? pb;
                        double pad = 0.25;
                        int x = (int) ((fx - fw * pad) * pb.width).clamp(0, pb.width - 1);
                        int y = (int) ((fy - fh * pad) * pb.height).clamp(0, pb.height - 1);
                        int w = (int) (fw * (1 + pad * 2) * pb.width).clamp(1, pb.width - x);
                        int h = (int) (fh * (1 + pad * 2) * pb.height).clamp(1, pb.height - y);
                        int side = int.min(w, h);
                    tex = Gdk.Texture.for_pixbuf(new Gdk.Pixbuf.subpixbuf(pb, x + (w - side) / 2, y + (h - side) / 2, side, side).scale_simple(192, 192, Gdk.InterpType.BILINEAR));
                    } catch (Error e) {
                    }
                    Idle.add(() => {
                        pic.set_from_paintable(tex);
                        return Source.REMOVE;
                    });
                });
            }
            return box;
        }
    }
}
