using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public delegate void GroupsChosen(string[] groups);

    namespace EditSync {

        public void choose_groups(Gtk.Window parent, string title, string action_label, owned GroupsChosen done) {
            var dlg = LibraryDialogs.make(parent, title, 420);
            var box = LibraryDialogs.body(dlg);
            var group = new PreferencesGroup(_("Settings to Include"));
            var rows = new Gee.HashMap<string, SwitchRow>();
            foreach (var g in SettingsClipboard.GROUPS) {
                bool on = g != "crop" && g != "spots" && g != "masks";
                var row = new SwitchRow(SettingsClipboard.label(g), null, on);
                rows[g] = row;
                group.add_row(row);
            }
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.max_content_height = 460;
            scroll.child = group;
            box.append(scroll);
            var all = new Button.with_label(_("All"));
            all.valign = Align.CENTER;
            all.tooltip_text = _("Check All");
            all.clicked.connect(() => { foreach (var r in rows.values) r.active = true; });
            var none = new Button.with_label(_("None"));
            none.valign = Align.CENTER;
            none.tooltip_text = _("Check None");
            none.clicked.connect(() => { foreach (var r in rows.values) r.active = false; });
            group.add_header_suffix(all);
            group.add_header_suffix(none);
            LibraryDialogs.footer(dlg, action_label, () => {
                string[] chosen = {};
                foreach (var g in SettingsClipboard.GROUPS) if (rows[g].active) chosen += g;
                if (chosen.length > 0) done(chosen);
            });
            dlg.open_dialog();
        }

        public EditParams load(PhotoRecord r) {
            return EditStore.load(r.file(), r.variant()) ?? new EditParams();
        }

        public bool store(PhotoRecord r, EditParams p, Catalog catalog) {
            try {
                if (p.is_identity()) EditStore.revert(r.file(), r.variant());
                else EditStore.save(r.file(), p, r.variant());
            } catch (Error e) {
                warning("Photos: cannot save edits for %s: %s", r.path, e.message);
                return false;
            }
            r.edited = !p.is_identity();
            catalog.save(r);
            return true;
        }

        public int apply(Gee.List<PhotoRecord> targets, EditParams source, string[] groups, Catalog catalog) {
            int n = 0;
            catalog.begin();
            foreach (var r in targets) {
                if (r.missing) continue;
                var p = load(r);
                EditParamsGroups.transfer(source, p, groups);
                if (store(r, p, catalog)) n++;
            }
            catalog.commit();
            return n;
        }

        public int apply_preset(Gee.List<PhotoRecord> targets, DevelopPreset preset, Catalog catalog) {
            int n = 0;
            catalog.begin();
            foreach (var r in targets) {
                if (r.missing) continue;
                var p = load(r);
                DevelopPresets.apply(p, preset);
                if (store(r, p, catalog)) n++;
            }
            catalog.commit();
            return n;
        }

        public int reset(Gee.List<PhotoRecord> targets, Catalog catalog) {
            catalog.begin();
            foreach (var r in targets) {
                EditStore.revert(r.file(), r.variant());
                r.edited = false;
                catalog.save(r);
            }
            catalog.commit();
            return targets.size;
        }

        public void rotate(Gee.List<PhotoRecord> targets, int turns, Catalog catalog) {
            catalog.begin();
            foreach (var r in targets) {
                if (r.missing) continue;
                var p = load(r);
                p.rotate(turns);
                store(r, p, catalog);
            }
            catalog.commit();
        }
    }
}
