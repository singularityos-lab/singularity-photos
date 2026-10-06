using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public delegate void CollectionDone(CollectionRecord collection);

    namespace CollectionDialogs {

        private IndexChoiceRow parent_dropdown(Catalog catalog, int64 selected, out Gee.ArrayList<CollectionRecord> sets) {
            sets = new Gee.ArrayList<CollectionRecord>();
            string[] labels = { _("Top Level") };
            uint index = 0;
            foreach (var c in catalog.collections.values) {
                if (!c.is_set()) continue;
                sets.add(c);
            }
            sets.sort((a, b) => a.name.collate(b.name));
            for (int i = 0; i < sets.size; i++) {
                labels += sets[i].name;
                if (sets[i].id == selected) index = i + 1;
            }
            return new IndexChoiceRow(_("Inside"), labels, index);
        }

        public void create(Gtk.Window parent, Catalog catalog, string kind, Gee.List<PhotoRecord> selection, owned CollectionDone done) {
            string title = kind == "set" ? _("New Collection Set") : _("New Collection");
            var dlg = LibraryDialogs.make(parent, title, 420);
            var box = LibraryDialogs.body(dlg);
            var group = new PreferencesGroup();
            var name_row = new EntryRow(_("Name"));
            group.add_row(name_row);
            Gee.ArrayList<CollectionRecord> sets;
            var parent_dd = parent_dropdown(catalog, 0, out sets);
            var parent_row = parent_dd;
            group.add_row(parent_row);
            SwitchRow? include = null;
            if (kind == "manual" && selection.size > 0) {
                include = new SwitchRow(_("Include Selected Photos"),
                    ngettext("%d photo", "%d photos", selection.size).printf(selection.size), true);
                group.add_row(include);
            }
            box.append(group);
            LibraryDialogs.footer(dlg, _("Create"), () => {
                string name = name_row.text.strip();
                if (name == "") name = kind == "set" ? _("Untitled Set") : _("Untitled Collection");
                int64 pid = parent_dd.selected_index > 0 ? sets[(int) parent_dd.selected_index - 1].id : 0;
                var c = catalog.create_collection(name, kind, pid);
                if (include != null && include.active) {
                    catalog.begin();
                    foreach (var r in selection) catalog.add_to_collection(c, r);
                    catalog.commit();
                }
                done(c);
            });
            dlg.open_dialog();
        }

        public void edit_smart(Gtk.Window parent, Catalog catalog, CollectionRecord? existing, owned CollectionDone done) {
            var dlg = LibraryDialogs.make(parent, existing != null ? _("Edit Smart Collection") : _("New Smart Collection"), 620);
            var box = LibraryDialogs.body(dlg);
            var head = new PreferencesGroup();
            var name_row = new EntryRow(_("Name"));
            name_row.text = existing != null ? existing.name : "";
            head.add_row(name_row);
            Gee.ArrayList<CollectionRecord> sets;
            var parent_dd = parent_dropdown(catalog, existing != null ? existing.parent_id : 0, out sets);
            var parent_row = parent_dd;
            head.add_row(parent_row);
            var rules = existing != null ? SmartRules.parse(existing.rules) : new SmartRules();
            if (rules.rules.size == 0) rules.rules.add(new SmartRule("rating", ">=", "3"));
            var match_dd = new IndexChoiceRow(_("Match"), { _("All Rules"), _("Any Rule") }, rules.match_all ? 0 : 1);
            var match_row = match_dd;
            head.add_row(match_row);
            box.append(head);

            var rules_box = new Box(Orientation.VERTICAL, 12);
            box.append(rules_box);
            var preview_group = new PreferencesGroup(_("Result"));
            var preview = new Label("");
            preview.xalign = 0;
            preview.margin_top = preview.margin_bottom = 12;
            preview.margin_start = preview.margin_end = 12;
            var preview_row = new PreferencesRow();
            preview_row.activatable = false;
            preview_row.child = preview;
            preview_group.add_row(preview_row);

            LibraryDialogs.Action refresh_preview = () => {
                rules.match_all = match_dd.selected_index == 0;
                int n = 0;
                foreach (var r in catalog.photos.values) if (rules.matches(r, catalog)) n++;
                preview.label = ngettext("%d photo matches", "%d photos match", n).printf(n);
            };

            LibraryDialogs.Action rebuild = () => {};
            rebuild = () => {
                Widget? c;
                while ((c = rules_box.get_first_child()) != null) rules_box.remove(c);
                int number = 0;
                foreach (var rule in rules.rules) {
                    number++;
                    string[] field_labels = {};
                    uint fsel = 0;
                    for (int i = 0; i < SmartRules.FIELDS.length; i++) {
                        field_labels += SmartRules.field_title(SmartRules.FIELDS[i]);
                        if (SmartRules.FIELDS[i] == rule.field) fsel = i;
                    }
                    var ops = SmartRules.ops_for(rule.field);
                    string[] op_labels = {};
                    uint osel = 0;
                    for (int i = 0; i < ops.length; i++) {
                        op_labels += SmartRules.op_title(ops[i]);
                        if (ops[i] == rule.op) osel = i;
                    }
                    var group = new PreferencesGroup(_("Rule %d").printf(number));
                    var field_dd = new IndexChoiceRow(_("Field"), field_labels, fsel);
                    var op_dd = new IndexChoiceRow(_("Condition"), op_labels, osel);
                    var value = new HintRow(_("Value"), placeholder_for(rule.field));
                    value.text = rule.value;
                    var remove = new Button.with_label(_("Remove"));
                    remove.valign = Align.CENTER;
                    remove.tooltip_text = _("Remove Rule");
                    var r = rule;
                    field_dd.notify["selected-index"].connect(() => {
                        r.field = SmartRules.FIELDS[field_dd.selected_index];
                        r.op = SmartRules.ops_for(r.field)[0];
                        r.value = default_value(r.field);
                        Idle.add(() => {
                            rebuild();
                            return Source.REMOVE;
                        });
                    });
                    op_dd.notify["selected-index"].connect(() => {
                        r.op = SmartRules.ops_for(r.field)[op_dd.selected_index];
                        refresh_preview();
                    });
                    value.entry_changed.connect(() => {
                        r.value = value.text.strip();
                        refresh_preview();
                    });
                    remove.clicked.connect(() => {
                        rules.rules.remove(r);
                        rebuild();
                    });
                    group.add_header_suffix(remove);
                    group.add_row(field_dd);
                    group.add_row(op_dd);
                    group.add_row(value);
                    rules_box.append(group);
                }
                var add_group = new PreferencesGroup(_("More Rules"));
                var add = new ActionRow(_("Add Rule"), null, "list-add-symbolic");
                add.activated.connect(() => {
                    rules.rules.add(new SmartRule("rating", ">=", "1"));
                    rebuild();
                });
                add_group.add_row(add);
                rules_box.append(add_group);
                if (preview_group.get_parent() != null) rules_box.remove(preview_group);
                rules_box.append(preview_group);
                refresh_preview();
            };
            match_dd.notify["selected-index"].connect(() => refresh_preview());
            rebuild();
            LibraryDialogs.footer(dlg, existing != null ? _("Save") : _("Create"), () => {
                rules.match_all = match_dd.selected_index == 0;
                string name = name_row.text.strip();
                if (name == "") name = _("Smart Collection");
                int64 pid = parent_dd.selected_index > 0 ? sets[(int) parent_dd.selected_index - 1].id : 0;
                CollectionRecord c;
                if (existing != null) {
                    existing.name = name;
                    existing.parent_id = pid;
                    existing.rules = rules.to_json();
                    catalog.update_collection(existing);
                    c = existing;
                } else {
                    c = catalog.create_collection(name, "smart", pid, rules.to_json());
                }
                done(c);
            });
            dlg.open_dialog();
        }

        private string placeholder_for(string field) {
            switch (field) {
                case "rating": return "0-5";
                case "flag": return "pick, reject, none";
                case "label": return "red, yellow, green, blue, purple, none";
                case "date": return _("days or YYYY-MM-DD");
                case "kind": return "photo, raw, video, virtual";
                case "edited":
                case "gps": return "true, false";
                default: return "";
            }
        }

        private string default_value(string field) {
            switch (field) {
                case "rating": return "3";
                case "flag": return "pick";
                case "label": return "red";
                case "date": return "30";
                case "kind": return "raw";
                case "edited":
                case "gps": return "true";
                default: return "";
            }
        }
    }
}
