using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public class ImportDialog : Object {
        public signal void imported(ImportResult result);

        private Gtk.Window parent;
        private Catalog catalog;
        private File library;
        private AppDialog dlg;
        private DropDown source_dd;
        private Gee.ArrayList<File> sources = new Gee.ArrayList<File>();
        private FlowBox tiles;
        private Label count_label;
        private Spinner spinner;
        private Gee.ArrayList<ImportCandidate> candidates = new Gee.ArrayList<ImportCandidate>();
        private Gee.HashMap<ImportCandidate, CheckButton> checks = new Gee.HashMap<ImportCandidate, CheckButton>();
        private ChoiceRow mode_switch;
        private ActionRow dest_row;
        private File destination;
        private IndexChoiceRow structure_dd;
        private EntryRow rename_row;
        private ActionRow rename_preview;
        private EntryRow keywords_row;
        private EntryRow creator_row;
        private EntryRow copyright_row;
        private IndexChoiceRow preset_dd;
        private Gee.List<DevelopPreset> preset_list;
        private SwitchRow dup_row;
        private Button import_btn;
        private uint scan_serial = 0;
        private bool running = false;

        private const string[] STRUCTURES = { "date", "month", "flat" };

        public ImportDialog(Gtk.Window parent, Catalog catalog, File library) {
            this.parent = parent;
            this.catalog = catalog;
            this.library = library;
            destination = library;
        }

        public void present(File? initial = null) {
            dlg = LibraryDialogs.make(parent, _("Import Photos"), 900);
            dlg.set_default_size(900, 720);
            var paned = new Box(Orientation.HORIZONTAL, 16);
            paned.margin_start = paned.margin_end = 18;
            paned.margin_top = 6;
            paned.vexpand = true;
            dlg.content_box.append(paned);

            var left = new Box(Orientation.VERTICAL, 10);
            left.hexpand = true;
            paned.append(left);
            var source_bar = new Box(Orientation.HORIZONTAL, 8);
            source_dd = new DropDown(new StringList(null), null);
            source_dd.hexpand = true;
            source_dd.notify["selected"].connect(() => {
                if (source_dd.selected < sources.size) scan(sources[(int) source_dd.selected]);
            });
            source_bar.append(source_dd);
            var choose = new Button.with_label(_("Choose Folder…"));
            choose.clicked.connect(() => pick_source());
            source_bar.append(choose);
            left.append(source_bar);

            var sel_bar = new Box(Orientation.HORIZONTAL, 8);
            count_label = new Label("");
            count_label.add_css_class("dim-label");
            count_label.hexpand = true;
            count_label.xalign = 0;
            sel_bar.append(count_label);
            spinner = new Spinner();
            sel_bar.append(spinner);
            var all = new Button.with_label(_("Select All"));
            all.add_css_class("flat");
            all.clicked.connect(() => select_all(true));
            sel_bar.append(all);
            var none = new Button.with_label(_("Select None"));
            none.add_css_class("flat");
            none.clicked.connect(() => select_all(false));
            sel_bar.append(none);
            left.append(sel_bar);

            tiles = new FlowBox();
            tiles.selection_mode = SelectionMode.NONE;
            tiles.homogeneous = true;
            tiles.min_children_per_line = 3;
            tiles.max_children_per_line = 8;
            tiles.column_spacing = 8;
            tiles.row_spacing = 8;
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = tiles;
            left.append(scroll);

            var right = new Box(Orientation.VERTICAL, 10);
            right.width_request = 330;
            var rscroll = new ScrolledWindow();
            rscroll.hscrollbar_policy = PolicyType.NEVER;
            rscroll.child = right;
            rscroll.width_request = 340;
            paned.append(rscroll);

            var how = new PreferencesGroup(_("Import As"));
            mode_switch = new ChoiceRow(_("Mode"));
            mode_switch.add_option("copy", _("Copy"));
            mode_switch.add_option("move", _("Move"));
            mode_switch.add_option("add", _("Add in Place"));
            mode_switch.set_active("copy");
            mode_switch.chosen.connect(() => update_mode());
            var mode_row = mode_switch;
            how.add_row(mode_row);
            dup_row = new SwitchRow(_("Skip Duplicates"), _("Photos already in the library are left out"), true);
            how.add_row(dup_row);
            right.append(how);

            var dest = new PreferencesGroup(_("Destination"));
            dest_row = new ActionRow(_("Folder"), destination.get_path());
            var dest_btn = new Button.with_label(_("Change…"));
            dest_btn.valign = Align.CENTER;
            dest_btn.clicked.connect(() => pick_destination());
            dest_row.add_suffix(dest_btn);
            dest.add_row(dest_row);
            structure_dd = new IndexChoiceRow(_("Organize"), { _("By Date"), _("By Month"), _("Into One Folder") });
            var struct_row = structure_dd;
            dest.add_row(struct_row);
            rename_row = new EntryRow(_("File Name"));
            rename_row.text = "{original}";
            rename_row.tooltip_text = _("Tokens: {original} {date} {time} {year} {month} {day} {camera} {seq}");
            rename_row.entry_changed.connect(() => update_preview());
            dest.add_row(rename_row);
            rename_preview = new ActionRow(_("Example"), "");
            dest.add_row(rename_preview);
            right.append(dest);

            var apply = new PreferencesGroup(_("Apply During Import"));
            preset_list = DevelopPresets.all();
            string[] names = { _("None") };
            foreach (var p in preset_list) names += p.name;
            preset_dd = new IndexChoiceRow(_("Develop Preset"), names);
            var preset_row = preset_dd;
            apply.add_row(preset_row);
            keywords_row = new EntryRow(_("Keywords"));
            keywords_row.tooltip_text = _("Separate with commas, use | for a hierarchy");
            apply.add_row(keywords_row);
            creator_row = new EntryRow(_("Creator"));
            apply.add_row(creator_row);
            copyright_row = new EntryRow(_("Copyright"));
            apply.add_row(copyright_row);
            right.append(apply);

            import_btn = LibraryDialogs.footer(dlg, _("Import"), () => start_import(), false, false);
            load_sources(initial);
            update_preview();
            dlg.open_dialog();
        }

        private void load_sources(File? initial) {
            sources.clear();
            var labels = new StringList(null);
            foreach (var f in PhotoImporter.removable_sources()) {
                sources.add(f);
                var parent_dir = f.get_parent();
                string name = f.get_basename() == "DCIM" && parent_dir != null ? parent_dir.get_basename() : f.get_basename();
                labels.append(_("Card or Camera: %s").printf(name));
            }
            if (initial != null) {
                sources.insert(0, initial);
                labels.splice(0, 0, { initial.get_basename() });
            }
            if (sources.size == 0) {
                var home = File.new_for_path(Environment.get_home_dir());
                var dl = Environment.get_user_special_dir(UserDirectory.DOWNLOAD);
                var f = dl != null ? File.new_for_path(dl) : home;
                sources.add(f);
                labels.append(f.get_basename());
            }
            source_dd.model = labels;
            source_dd.selected = 0;
            scan(sources[0]);
        }

        private void pick_source() {
            var fd = new FileDialog();
            fd.title = _("Import From");
            fd.select_folder.begin(dlg, null, (obj, res) => {
                try {
                    var f = fd.select_folder.end(res);
                    if (f == null) return;
                    sources.insert(0, f);
                    var labels = source_dd.model as StringList;
                    labels.splice(0, 0, { f.get_basename() });
                    source_dd.selected = 0;
                    scan(f);
                } catch (Error e) {
                }
            });
        }

        private void pick_destination() {
            var fd = new FileDialog();
            fd.title = _("Import Into");
            fd.initial_folder = destination;
            fd.select_folder.begin(dlg, null, (obj, res) => {
                try {
                    var f = fd.select_folder.end(res);
                    if (f == null) return;
                    destination = f;
                    dest_row.subtitle = f.get_path();
                } catch (Error e) {
                }
            });
        }

        private void update_mode() {
            bool add = mode_switch.active_key == "add";
            dest_row.sensitive = !add;
            structure_dd.sensitive = !add;
            rename_row.sensitive = !add;
        }

        private void update_preview() {
            var sample = candidates.size > 0 ? candidates[0] : null;
            string n = PhotoImporter.render_name(rename_row.text, sample != null ? sample.file : File.new_for_path("IMG_0001.JPG"),
                sample != null ? sample.captured : new DateTime.now_local(), sample != null ? sample.camera : "Camera", 1);
            rename_preview.subtitle = n;
        }

        private void update_count() {
            int sel = 0, dup = 0;
            foreach (var c in candidates) {
                if (c.selected) sel++;
                if (c.duplicate) dup++;
            }
            string text = ngettext("%d of %d photo selected", "%d of %d photos selected", candidates.size).printf(sel, candidates.size);
            if (dup > 0) text += ", " + ngettext("%d already imported", "%d already imported", dup).printf(dup);
            count_label.label = text;
            import_btn.sensitive = sel > 0 && !running;
            import_btn.label = sel > 0 ? ngettext("Import %d Photo", "Import %d Photos", sel).printf(sel) : _("Import");
        }

        private void select_all(bool on) {
            foreach (var e in checks.entries) e.value.active = on;
        }

        private void scan(File source) {
            uint serial = ++scan_serial;
            candidates.clear();
            checks.clear();
            Widget? c;
            while ((c = tiles.get_first_child()) != null) tiles.remove(c);
            spinner.spinning = true;
            count_label.label = _("Looking for photos…");
            import_btn.sensitive = false;
            new Thread<void>("photos-import-scan", () => {
                var found = PhotoImporter.scan_source(source);
                foreach (var cand in found) cand.hash = Catalog.file_hash(cand.file.get_path()) ?? "";
                Idle.add(() => {
                    if (serial != scan_serial || dlg == null) return Source.REMOVE;
                    spinner.spinning = false;
                    foreach (var cand in found) {
                        cand.duplicate = cand.hash != "" && catalog.find_duplicate(cand.hash, cand.size) != null;
                        cand.selected = !cand.duplicate;
                        candidates.add(cand);
                        tiles.append(tile_for(cand));
                    }
                    update_count();
                    update_preview();
                    return Source.REMOVE;
                });
            });
        }

        private Widget tile_for(ImportCandidate cand) {
            var box = new Box(Orientation.VERTICAL, 4);
            var overlay = new Overlay();
            var pic = new Picture();
            pic.content_fit = ContentFit.COVER;
            pic.width_request = 120;
            pic.height_request = 90;
            pic.add_css_class("photo-thumb");
            pic.overflow = Overflow.HIDDEN;
            overlay.child = pic;
            var check = new CheckButton();
            check.active = cand.selected;
            check.halign = Align.START;
            check.valign = Align.START;
            check.margin_start = check.margin_top = 4;
            check.toggled.connect(() => {
                cand.selected = check.active;
                update_count();
            });
            checks[cand] = check;
            overlay.add_overlay(check);
            if (cand.duplicate) {
                var dup = new Label(_("Imported"));
                dup.add_css_class("photos-badge");
                dup.halign = Align.END;
                dup.valign = Align.END;
                dup.margin_end = dup.margin_bottom = 4;
                overlay.add_overlay(dup);
                pic.opacity = 0.5;
            }
            box.append(overlay);
            var name = new Label(cand.file.get_basename());
            name.add_css_class("caption");
            name.ellipsize = Pango.EllipsizeMode.MIDDLE;
            name.max_width_chars = 14;
            box.append(name);
            string path = cand.file.get_path();
            new Thread<void>("photos-import-thumb", () => {
                Gdk.Texture? tex = null;
                try {
                    var pb = new Gdk.Pixbuf.from_file_at_scale(path, 240, 180, true);
                    pb = pb.apply_embedded_orientation() ?? pb;
                    tex = Gdk.Texture.for_pixbuf(pb);
                } catch (Error e) {
                }
                Idle.add(() => {
                    if (tex != null) pic.paintable = tex;
                    return Source.REMOVE;
                });
            });
            return box;
        }

        private void start_import() {
            if (running) return;
            running = true;
            var importer = new PhotoImporter(catalog);
            var o = new ImportOptions();
            switch (mode_switch.active_key) {
                case "move": o.mode = ImportMode.MOVE; break;
                case "add": o.mode = ImportMode.ADD; break;
                default: o.mode = ImportMode.COPY; break;
            }
            o.destination = destination;
            o.structure = STRUCTURES[structure_dd.selected_index.clamp(0, STRUCTURES.length - 1)];
            o.rename_template = rename_row.text.strip() != "" ? rename_row.text.strip() : "{original}";
            o.skip_duplicates = dup_row.active;
            o.keywords = keywords_row.text.split(",");
            o.creator = creator_row.text.strip();
            o.copyright = copyright_row.text.strip();
            if (preset_dd.selected_index > 0 && preset_dd.selected_index <= preset_list.size) o.preset_id = preset_list[(int) preset_dd.selected_index - 1].id;
            var todo = new Gee.ArrayList<ImportCandidate>();
            foreach (var c in candidates) if (c.selected) todo.add(c);
            var total = new ImportResult();
            int index = 0;
            spinner.spinning = true;
            import_btn.sensitive = false;
            catalog.begin();
            Idle.add(() => {
                if (index >= todo.size) {
                    catalog.commit();
                    running = false;
                    spinner.spinning = false;
                    dlg.close_dialog();
                    imported(total);
                    return Source.REMOVE;
                }
                var one = new Gee.ArrayList<ImportCandidate>();
                one.add(todo[index]);
                o.start_sequence = 1 + total.imported;
                var r = importer.run(one, o);
                total.imported += r.imported;
                total.skipped_duplicates += r.skipped_duplicates;
                total.failed += r.failed;
                total.records.add_all(r.records);
                total.errors.add_all(r.errors);
                index++;
                count_label.label = _("Importing %d of %d…").printf(index, todo.size);
                return Source.CONTINUE;
            });
        }
    }
}
