using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public delegate void KeywordChosen(KeywordRecord keyword);

    public class KeywordManager : Object {
        private Gtk.Window parent;
        private Catalog catalog;
        private AppDialog dlg;
        private Box list;
        private KeywordChosen on_show;

        public KeywordManager(Gtk.Window parent, Catalog catalog, owned KeywordChosen on_show) {
            this.parent = parent;
            this.catalog = catalog;
            this.on_show = (owned) on_show;
        }

        public void present() {
            dlg = LibraryDialogs.make(parent, _("Keywords"), 480);
            dlg.set_default_size(480, 560);
            var box = LibraryDialogs.body(dlg);
            var add_group = new PreferencesGroup(_("New Keyword"));
            var entry = new EntryRow(_("Keyword"));
            entry.tooltip_text = _("Use | for a hierarchy, for example Places|Italy|Rome");
            entry.entry_activated.connect(() => {
                string t = entry.text.strip();
                if (t == "") return;
                catalog.ensure_keyword_path(t);
                entry.text = "";
                rebuild();
            });
            add_group.add_row(entry);
            box.append(add_group);
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            list = new Box(Orientation.VERTICAL, 0);
            scroll.child = list;
            box.append(scroll);
            var close_bar = new Box(Orientation.HORIZONTAL, 8);
            close_bar.halign = Align.END;
            close_bar.margin_start = close_bar.margin_end = 18;
            close_bar.margin_bottom = 16;
            var close = new Button.with_label(_("Close"));
            close.clicked.connect(() => dlg.close_dialog());
            dlg.set_cancel_button(close);
            close_bar.append(close);
            dlg.content_box.append(close_bar);
            rebuild();
            dlg.open_dialog();
        }

        private int count_for(int64 id) {
            int n = 0;
            foreach (var r in catalog.photos.values) {
                foreach (var k in r.keywords) {
                    if (catalog.keyword_under(k, id)) {
                        n++;
                        break;
                    }
                }
            }
            return n;
        }

        private void rebuild() {
            Widget? c;
            while ((c = list.get_first_child()) != null) list.remove(c);
            var group = new PreferencesGroup(_("Keyword List"));
            add_rows(group, 0, 0);
            if (catalog.keywords.size == 0) group.description = _("No keywords yet");
            list.append(group);
        }

        private void add_rows(PreferencesGroup group, int64 parent_id, int depth) {
            foreach (var k in catalog.child_keywords(parent_id)) {
                int n = count_for(k.id);
                var row = new ActionRow(k.name, ngettext("%d photo", "%d photos", n).printf(n) + (k.synonyms != "" ? ", " + k.synonyms : ""));
                row.margin_start = 16 * depth;
                var kw = k;
                var show = new Button.from_icon_name("image-x-generic-symbolic");
                show.add_css_class("flat");
                show.valign = Align.CENTER;
                show.tooltip_text = _("Show Photos");
                show.clicked.connect(() => {
                    dlg.close_dialog();
                    on_show(kw);
                });
                row.add_suffix(show);
                var edit = new Button.from_icon_name("document-edit-symbolic");
                edit.add_css_class("flat");
                edit.valign = Align.CENTER;
                edit.tooltip_text = _("Rename");
                edit.clicked.connect(() => {
                    LibraryDialogs.ask_text(dlg, _("Rename Keyword"), _("Name"), kw.name, _("Rename"), (name) => {
                        catalog.rename_keyword(kw, name);
                        rebuild();
                    });
                });
                row.add_suffix(edit);
                var syn = new Button.from_icon_name("edit-find-symbolic");
                syn.add_css_class("flat");
                syn.valign = Align.CENTER;
                syn.tooltip_text = _("Synonyms");
                syn.clicked.connect(() => {
                    LibraryDialogs.ask_text(dlg, _("Synonyms"), _("Separate with commas"), kw.synonyms, _("Save"), (text) => {
                        catalog.set_synonyms(kw, text);
                        rebuild();
                    });
                });
                row.add_suffix(syn);
                var del = new Button.from_icon_name("user-trash-symbolic");
                del.add_css_class("flat");
                del.valign = Align.CENTER;
                del.tooltip_text = _("Delete");
                del.clicked.connect(() => {
                    LibraryDialogs.confirm(dlg, _("Delete Keyword?"), _("\"%s\" and the keywords inside it are removed from every photo.").printf(kw.name), _("Delete"), () => {
                        catalog.delete_keyword(kw);
                        rebuild();
                    });
                });
                row.add_suffix(del);
                group.add_row(row);
                add_rows(group, k.id, depth + 1);
            }
        }
    }
}
