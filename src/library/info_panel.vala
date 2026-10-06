using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public class MetadataPreset : Object {
        public string name = "";
        public Gee.TreeMap<string, string> fields = new Gee.TreeMap<string, string>();
    }

    namespace MetadataPresets {

        public const string META_KEY = "metadata-presets";

        public Gee.ArrayList<MetadataPreset> load(Catalog catalog) {
            var list = new Gee.ArrayList<MetadataPreset>();
            string? json = catalog.get_meta(META_KEY);
            if (json == null || json == "") return list;
            try {
                var parser = new Json.Parser();
                parser.load_from_data(json);
                var root = parser.get_root();
                if (root.get_node_type() != Json.NodeType.ARRAY) return list;
                root.get_array().foreach_element((a, i, e) => {
                    if (e.get_node_type() != Json.NodeType.OBJECT) return;
                    var o = e.get_object();
                    var p = new MetadataPreset();
                    p.name = o.has_member("name") ? o.get_string_member("name") : "";
                    if (o.has_member("fields")) {
                        var f = o.get_object_member("fields");
                        foreach (var m in f.get_members()) p.fields[m] = f.get_string_member(m);
                    }
                    if (p.name != "") list.add(p);
                });
            } catch (Error e) {
            }
            return list;
        }

        public void save(Catalog catalog, Gee.List<MetadataPreset> presets) {
            var b = new Json.Builder();
            b.begin_array();
            foreach (var p in presets) {
                b.begin_object();
                b.set_member_name("name");
                b.add_string_value(p.name);
                b.set_member_name("fields");
                b.begin_object();
                foreach (var e in p.fields.entries) {
                    b.set_member_name(e.key);
                    b.add_string_value(e.value);
                }
                b.end_object();
                b.end_object();
            }
            b.end_array();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            catalog.set_meta(META_KEY, gen.to_data(null));
        }
    }

    public class LibraryInfoPanel : Singularity.Widgets.InspectorPanel {
        public const string[] TEXT_FIELDS = { "title", "caption", "creator", "copyright", "location", "city", "country" };

        public Catalog catalog { get; private set; }

        public signal void records_changed(Gee.List<PhotoRecord> records);

        private Gee.ArrayList<PhotoRecord> records = new Gee.ArrayList<PhotoRecord>();
        private Label name_label;
        private Label detail_label;
        private RatingBar rating_bar;
        private FlagBar flag_bar;
        private LabelBar label_bar;
        private PreferencesGroup camera_group;
        private Gee.HashMap<string, ActionRow> exif_rows = new Gee.HashMap<string, ActionRow>();
        private Gee.HashMap<string, EntryRow> text_rows = new Gee.HashMap<string, EntryRow>();
        private IndexChoiceRow preset_dd;
        private FlowBox keyword_flow;
        private FlowBox suggestion_flow;
        private FlowBox set_flow;
        private IndexChoiceRow set_dd;
        private Entry keyword_entry;
        private bool syncing = false;
        private Gee.HashSet<string> mixed_fields = new Gee.HashSet<string>();
        private Gee.ArrayList<MetadataPreset> presets;
        private Gee.ArrayList<KeywordSet> sets = new Gee.ArrayList<KeywordSet>();

        public LibraryInfoPanel(Catalog catalog) {
            base(340);
            this.catalog = catalog;
            build();
        }

        private Box info_page(string name, string title, string icon) {
            var box = new Box(Orientation.VERTICAL, 12);
            box.margin_start = box.margin_end = 14;
            box.margin_top = 2;
            box.margin_bottom = 14;
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_width = false;
            scroll.vexpand = true;
            scroll.child = box;
            add_page(name, title, icon, scroll, true);
            return box;
        }

        private void build() {
            add_css_class("photos-info-panel");
            page_chosen.connect((name) => page = name);
            var box = info_page("info", _("Info"), "dialog-information-symbolic");

            name_label = new Label("");
            name_label.add_css_class("title-4");
            name_label.xalign = 0;
            name_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            box.append(name_label);
            detail_label = new Label("");
            detail_label.add_css_class("dim-label");
            detail_label.xalign = 0;
            detail_label.wrap = true;
            box.append(detail_label);

            var marks = new PreferencesGroup(_("Rating and Labels"));
            rating_bar = new RatingBar();
            rating_bar.rated.connect((n) => {
                foreach (var r in records) catalog.set_rating(r, n);
                refresh_header();
                records_changed(records);
            });
            rating_bar.halign = Align.START;
            rating_bar.margin_start = 6;
            rating_bar.tooltip_text = _("Rating");
            var rating_row = new PreferencesRow();
            rating_row.activatable = false;
            rating_row.child = rating_bar;
            marks.add_row(rating_row);
            flag_bar = new FlagBar();
            flag_bar.flagged.connect((f) => {
                foreach (var r in records) catalog.set_flag(r, f);
                refresh_header();
                records_changed(records);
            });
            label_bar = new LabelBar();
            label_bar.valign = Align.CENTER;
            label_bar.labeled.connect((l) => {
                string target = records.size > 0 && records[0].label == l ? "" : l;
                foreach (var r in records) {
                    r.label = target;
                    catalog.save(r);
                }
                refresh_header();
                records_changed(records);
            });
            var flag_row = new ActionRow(_("Flag"));
            flag_row.activatable = false;
            flag_bar.valign = Align.CENTER;
            flag_row.add_suffix(flag_bar);
            marks.add_row(flag_row);
            var label_row = new ActionRow(_("Color Label"));
            label_row.activatable = false;
            label_row.add_suffix(label_bar);
            marks.add_row(label_row);
            box.append(marks);

            camera_group = new PreferencesGroup(_("Camera"));
            foreach (var pair in new string[] { "camera", "lens", "exposure", "date", "size", "gps" }) {
                var row = new ActionRow(exif_title(pair), "");
                exif_rows[pair] = row;
                camera_group.add_row(row);
            }
            box.append(camera_group);

            box = info_page("description", _("Description"), "document-edit-symbolic");
            var desc = new PreferencesGroup(_("Caption and Credits"));
            var place = new PreferencesGroup(_("Place"));
            foreach (var f in TEXT_FIELDS) {
                var row = new EntryRow(field_title(f));
                string field = f;
                row.entry_activated.connect(() => commit_field(field));
                var focus = new EventControllerFocus();
                focus.leave.connect(() => commit_field(field));
                row.add_controller(focus);
                text_rows[f] = row;
                if (f == "location" || f == "city" || f == "country") place.add_row(row);
                else desc.add_row(row);
            }
            box.append(desc);
            box.append(place);

            var preset_group = new PreferencesGroup(_("Metadata Preset"), _("Fills creator, copyright and place in one step."));
            presets = MetadataPresets.load(catalog);
            preset_dd = new IndexChoiceRow(_("Apply Preset"), { _("None") });
            reload_presets();
            preset_dd.notify["selected-index"].connect(() => {
                if (syncing || preset_dd.selected_index == 0 || preset_dd.selected_index > presets.size) return;
                apply_preset(presets[(int) preset_dd.selected_index - 1]);
                syncing = true;
                preset_dd.selected_index = 0;
                syncing = false;
            });
            preset_group.add_row(preset_dd);
            var save_preset = new Button.with_label(_("Save"));
            save_preset.valign = Align.CENTER;
            save_preset.tooltip_text = _("Save Current Description as Preset");
            save_preset.clicked.connect(() => {
                var win = get_root() as Gtk.Window;
                if (win == null) return;
                LibraryDialogs.ask_text(win, _("New Metadata Preset"), _("Name"), "", _("Save"), (name) => {
                    var p = new MetadataPreset();
                    p.name = name;
                    foreach (var e in text_rows.entries) {
                        string v = e.value.text.strip();
                        if (v != "" && e.key != "title" && e.key != "caption") p.fields[e.key] = v;
                    }
                    presets.add(p);
                    MetadataPresets.save(catalog, presets);
                    reload_presets();
                });
            });
            preset_group.add_header_suffix(save_preset);
            box.append(preset_group);

            box = info_page("keywords", _("Keywords"), "tag-symbolic");
            var kw_group = new PreferencesGroup(_("Keywords"), _("Use | for a hierarchy, for example Places|Italy|Rome."));
            var kw_box = new Box(Orientation.VERTICAL, 8);
            kw_box.margin_start = kw_box.margin_end = 12;
            kw_box.margin_top = kw_box.margin_bottom = 8;
            keyword_flow = chip_flow();
            kw_box.append(keyword_flow);
            keyword_entry = new Entry();
            keyword_entry.placeholder_text = _("Add keywords, separated by commas");
            keyword_entry.activate.connect(() => {
                foreach (var part in keyword_entry.text.split(",")) {
                    string w = part.strip();
                    if (w == "") continue;
                    var existing = w.contains("|") ? null : catalog.find_keyword(w);
                    var k = existing ?? catalog.ensure_keyword_path(w);
                    foreach (var r in records) catalog.assign_keyword(r, k.id);
                }
                keyword_entry.text = "";
                refresh_keywords();
                records_changed(records);
            });
            kw_box.append(keyword_entry);
            var sugg_label = new Label(_("Suggestions"));
            sugg_label.add_css_class("dim-label");
            sugg_label.add_css_class("caption");
            sugg_label.xalign = 0;
            kw_box.append(sugg_label);
            suggestion_flow = chip_flow();
            kw_box.append(suggestion_flow);
            var sets_group = new PreferencesGroup(_("Keyword Sets"), _("Click a keyword of the set to add it."));
            set_dd = new IndexChoiceRow(_("Set"), { _("None") });
            set_dd.notify["selected-index"].connect(() => refresh_set());
            sets_group.add_row(set_dd);
            var save_set = new Button.with_label(_("Save"));
            save_set.valign = Align.CENTER;
            save_set.tooltip_text = _("Save These Keywords as a Set");
            save_set.clicked.connect(() => {
                var win = get_root() as Gtk.Window;
                if (win == null || records.size == 0) return;
                LibraryDialogs.ask_text(win, _("New Keyword Set"), _("Name"), "", _("Save"), (name) => {
                    catalog.save_keyword_set(name, catalog.keyword_paths(records[0]));
                    reload_sets();
                });
            });
            sets_group.add_header_suffix(save_set);
            set_flow = chip_flow();
            var set_holder = new PreferencesRow();
            set_holder.activatable = false;
            set_flow.margin_start = set_flow.margin_end = 12;
            set_flow.margin_top = set_flow.margin_bottom = 8;
            set_holder.child = set_flow;
            sets_group.add_row(set_holder);
            var holder = new PreferencesRow();
            holder.activatable = false;
            holder.child = kw_box;
            kw_group.add_row(holder);
            box.append(kw_group);
            box.append(sets_group);
            reload_sets();
            page = "info";
            set_records(new Gee.ArrayList<PhotoRecord>());
        }

        private FlowBox chip_flow() {
            var flow = new FlowBox();
            flow.selection_mode = SelectionMode.NONE;
            flow.column_spacing = 6;
            flow.row_spacing = 6;
            flow.max_children_per_line = 8;
            return flow;
        }

        private static string exif_title(string key) {
            switch (key) {
                case "camera": return _("Camera");
                case "lens": return _("Lens");
                case "exposure": return _("Exposure");
                case "date": return _("Captured");
                case "size": return _("File");
                default: return _("Location");
            }
        }

        public static string field_title(string key) {
            switch (key) {
                case "title": return _("Title");
                case "caption": return _("Caption");
                case "creator": return _("Creator");
                case "copyright": return _("Copyright");
                case "location": return _("Sublocation");
                case "city": return _("City");
                default: return _("Country");
            }
        }

        private static string get_field(PhotoRecord r, string key) {
            switch (key) {
                case "title": return r.title;
                case "caption": return r.caption;
                case "creator": return r.creator;
                case "copyright": return r.copyright;
                case "location": return r.location;
                case "city": return r.city;
                default: return r.country;
            }
        }

        public static void set_field(PhotoRecord r, string key, string v) {
            switch (key) {
                case "title": r.title = v; break;
                case "caption": r.caption = v; break;
                case "creator": r.creator = v; break;
                case "copyright": r.copyright = v; break;
                case "location": r.location = v; break;
                case "city": r.city = v; break;
                default: r.country = v; break;
            }
        }

        private void commit_field(string key) {
            if (syncing || records.size == 0) return;
            var row = text_rows[key];
            string v = row.text.strip();
            if (mixed_fields.contains(key) && v == "") return;
            bool any = false;
            foreach (var r in records) {
                if (get_field(r, key) == v) continue;
                set_field(r, key, v);
                catalog.save(r);
                any = true;
            }
            if (any) records_changed(records);
        }

        private void apply_preset(MetadataPreset p) {
            foreach (var r in records) {
                foreach (var e in p.fields.entries) set_field(r, e.key, e.value);
                catalog.save(r);
            }
            set_records(records);
            records_changed(records);
        }

        private void reload_presets() {
            syncing = true;
            string[] list = { _("None") };
            foreach (var p in presets) list += p.name;
            preset_dd.set_labels(list);
            preset_dd.selected_index = 0;
            syncing = false;
        }

        private void reload_sets() {
            sets.clear();
            sets.add_all(catalog.keyword_sets.values);
            sets.sort((a, b) => a.name.collate(b.name));
            string[] list = { _("None") };
            foreach (var s in sets) list += s.name;
            set_dd.set_labels(list);
            set_dd.selected_index = sets.size > 0 ? 1 : 0;
            refresh_set();
        }

        private void clear_flow(FlowBox flow) {
            Widget? c;
            while ((c = flow.get_first_child()) != null) flow.remove(c);
        }

        private Widget add_chip(string label, owned LibraryDialogs.Action on_click) {
            var b = new Button.with_label(label);
            b.add_css_class("pill");
            b.add_css_class("flat");
            b.clicked.connect(() => on_click());
            return b;
        }

        private void refresh_set() {
            if (set_flow == null) return;
            clear_flow(set_flow);
            if (set_dd.selected_index == 0 || set_dd.selected_index > sets.size) return;
            foreach (var word in sets[(int) set_dd.selected_index - 1].keywords) {
                if (word.strip() == "") continue;
                string w = word;
                set_flow.append(add_chip(w.contains("|") ? w.substring(w.last_index_of_char('|') + 1) : w, () => {
                    var k = catalog.ensure_keyword_path(w);
                    foreach (var r in records) catalog.assign_keyword(r, k.id);
                    refresh_keywords();
                    records_changed(records);
                }));
            }
        }

        private void refresh_keywords() {
            clear_flow(keyword_flow);
            clear_flow(suggestion_flow);
            if (records.size == 0) return;
            var common = new Gee.HashSet<int64?>(id_hash, id_equal);
            common.add_all(records[0].keywords);
            foreach (var r in records) {
                var drop = new Gee.ArrayList<int64?>();
                foreach (var k in common) if (!r.keywords.contains(k)) drop.add(k);
                common.remove_all(drop);
            }
            var ids = new Gee.ArrayList<int64?>();
            ids.add_all(common);
            ids.sort((a, b) => catalog.keyword_path(a).collate(catalog.keyword_path(b)));
            foreach (var id in ids) {
                var k = catalog.keywords[id];
                if (k == null) continue;
                var chip = new Box(Orientation.HORIZONTAL, 2);
                chip.add_css_class("photos-keyword-chip");
                var l = new Label(k.name);
                l.tooltip_text = catalog.keyword_path(id).replace("|", " / ");
                chip.append(l);
                var x = new Button.from_icon_name("window-close-symbolic");
                x.add_css_class("flat");
                x.add_css_class("circular");
                x.tooltip_text = _("Remove Keyword");
                int64 kid = id;
                x.clicked.connect(() => {
                    foreach (var r in records) catalog.unassign_keyword(r, kid);
                    refresh_keywords();
                    records_changed(records);
                });
                chip.append(x);
                keyword_flow.append(chip);
            }
            foreach (var k in catalog.suggest_keywords(records[0], 8)) {
                int64 kid = k.id;
                suggestion_flow.append(add_chip(k.name, () => {
                    foreach (var r in records) catalog.assign_keyword(r, kid);
                    refresh_keywords();
                    records_changed(records);
                }));
            }
        }

        private void refresh_header() {
            if (records.size == 0) {
                name_label.label = _("No Photo Selected");
                detail_label.label = "";
                rating_bar.set_value(0);
                flag_bar.set_value(0);
                label_bar.set_value("");
                return;
            }
            var first = records[0];
            if (records.size == 1) {
                name_label.label = first.is_virtual_copy() ? "%s (%s)".printf(first.name(), first.copy_name) : first.name();
                detail_label.label = first.missing ? _("The original file is missing") : Path.get_dirname(first.path);
            } else {
                name_label.label = ngettext("%d Photo Selected", "%d Photos Selected", records.size).printf(records.size);
                detail_label.label = _("Changes apply to every selected photo");
            }
            rating_bar.set_value(first.rating);
            flag_bar.set_value(first.flag);
            label_bar.set_value(first.label);
        }

        public void set_records(Gee.List<PhotoRecord> list) {
            if (list != records) {
                records.clear();
                records.add_all(list);
            }
            syncing = true;
            refresh_header();
            var first = records.size > 0 ? records[0] : null;
            camera_group.visible = records.size == 1;
            if (first != null) {
                var m = first.metadata();
                exif_rows["camera"].subtitle = first.camera != "" ? first.camera : _("Unknown");
                exif_rows["lens"].subtitle = first.lens != "" ? first.lens : _("Unknown");
                string summary = m.summary();
                exif_rows["exposure"].subtitle = summary != "" ? summary : _("Unknown");
                var t = first.captured_time();
                exif_rows["date"].subtitle = t != null ? t.format("%x %X") : _("Unknown");
                string dims = m.width > 0 ? "%d × %d".printf(m.width, m.height) : "";
                string size = GLib.format_size((uint64) first.size);
                exif_rows["size"].subtitle = dims != "" ? "%s, %s".printf(dims, size) : size;
                exif_rows["gps"].subtitle = first.has_gps ? "%.5f, %.5f".printf(first.latitude, first.longitude) : _("Not set");
            }
            foreach (var e in text_rows.entries) {
                string v = first != null ? get_field(first, e.key) : "";
                bool mixed = false;
                foreach (var r in records) if (get_field(r, e.key) != v) mixed = true;
                e.value.text = mixed ? "" : v;
                e.value.tooltip_text = mixed ? _("The selected photos have different values") : null;
                if (mixed) mixed_fields.add(e.key);
                else mixed_fields.remove(e.key);
                e.value.sensitive = records.size > 0;
            }
            keyword_entry.sensitive = records.size > 0;
            syncing = false;
            refresh_keywords();
        }
    }
}
