using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    namespace LibraryDialogs {

        public delegate void Action();
        public delegate void TextAction(string text);

        public AppDialog make(Gtk.Window parent, string title, int width) {
            var dlg = new AppDialog(parent.application, true);
            dlg.set_title(title);
            dlg.transient_for = parent;
            dlg.set_default_size(width, -1);
            return dlg;
        }

        public Button footer(AppDialog dlg, string label, owned Action action, bool destructive = false, bool close_on_ok = true) {
            var bar = new Box(Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 18;
            bar.margin_bottom = 16;
            bar.margin_top = 4;
            bar.halign = Align.END;
            var cancel = new Button.with_label(_("Cancel"));
            cancel.clicked.connect(() => dlg.close_dialog());
            dlg.set_cancel_button(cancel);
            var ok = new Button.with_label(label);
            ok.add_css_class(destructive ? "destructive-action" : "suggested-action");
            ok.clicked.connect(() => {
                if (close_on_ok) dlg.close_dialog();
                action();
            });
            bar.append(cancel);
            bar.append(ok);
            dlg.content_box.append(bar);
            dlg.default_widget = ok;
            return ok;
        }

        public Box body(AppDialog dlg) {
            var box = new Box(Orientation.VERTICAL, 12);
            box.margin_start = box.margin_end = 18;
            box.margin_top = 6;
            box.margin_bottom = 8;
            dlg.content_box.append(box);
            return box;
        }

        public void ask_text(Gtk.Window parent, string title, string row_title, string initial, string action_label, owned TextAction action) {
            var dlg = make(parent, title, 380);
            var box = body(dlg);
            var group = new PreferencesGroup();
            var row = new EntryRow(row_title);
            row.text = initial;
            group.add_row(row);
            box.append(group);
            footer(dlg, action_label, () => {
                string t = row.text.strip();
                if (t != "") action(t);
            });
            dlg.open_dialog();
        }

        public void confirm(Gtk.Window parent, string title, string message, string action_label, owned Action action) {
            var dlg = make(parent, title, 380);
            var box = body(dlg);
            var label = new Label(message);
            label.wrap = true;
            label.xalign = 0;
            label.max_width_chars = 44;
            box.append(label);
            footer(dlg, action_label, (owned) action, true);
            dlg.open_dialog();
        }

        public DropDown string_dropdown(string[] labels, int selected = 0) {
            var model = new StringList(labels);
            var dd = new DropDown(model, null);
            dd.selected = selected.clamp(0, int.max(0, labels.length - 1));
            dd.valign = Align.CENTER;
            return dd;
        }
    }

    public class RatingBar : Box {
        public signal void rated(int stars);
        private Button[] stars = {};
        private int value = 0;

        public RatingBar() {
            Object(orientation: Orientation.HORIZONTAL, spacing: 0);
            add_css_class("photos-rating-bar");
            for (int i = 1; i <= 5; i++) {
                var b = new Button.from_icon_name("non-starred-symbolic");
                b.add_css_class("flat");
                b.tooltip_text = ngettext("%d star (%d)", "%d stars (%d)", i).printf(i, i);
                int n = i;
                b.clicked.connect(() => rated(value == n ? 0 : n));
                stars += b;
                append(b);
            }
        }

        public void set_value(int v) {
            value = v;
            for (int i = 0; i < stars.length; i++) stars[i].icon_name = i < v ? "starred-symbolic" : "non-starred-symbolic";
        }
    }

    public class FlagBar : Box {
        public signal void flagged(int flag);
        private ToggleButton pick;
        private ToggleButton reject;
        private bool syncing = false;

        public FlagBar() {
            Object(orientation: Orientation.HORIZONTAL, spacing: 2);
            pick = new ToggleButton();
            pick.icon_name = "object-select-symbolic";
            pick.tooltip_text = _("Pick (P)");
            pick.add_css_class("flat");
            reject = new ToggleButton();
            reject.icon_name = "action-unavailable-symbolic";
            reject.tooltip_text = _("Reject (X)");
            reject.add_css_class("flat");
            pick.toggled.connect(() => {
                if (syncing) return;
                flagged(pick.active ? PickFlag.PICK : PickFlag.NONE);
            });
            reject.toggled.connect(() => {
                if (syncing) return;
                flagged(reject.active ? PickFlag.REJECT : PickFlag.NONE);
            });
            append(pick);
            append(reject);
        }

        public void set_value(int flag) {
            syncing = true;
            pick.active = flag == PickFlag.PICK;
            reject.active = flag == PickFlag.REJECT;
            syncing = false;
        }
    }

    public class LabelBar : Box {
        public signal void labeled(string label);
        private Gee.HashMap<string, ToggleButton> buttons = new Gee.HashMap<string, ToggleButton>();
        private bool syncing = false;

        public LabelBar() {
            Object(orientation: Orientation.HORIZONTAL, spacing: 4);
            int key = 6;
            foreach (var l in COLOR_LABELS) {
                var b = new ToggleButton();
                b.add_css_class("photos-label-dot");
                b.add_css_class("photos-label-" + l);
                b.tooltip_text = key <= 9 ? "%s (%d)".printf(color_label_title(l), key) : color_label_title(l);
                key++;
                string id = l;
                b.toggled.connect(() => {
                    if (syncing) return;
                    labeled(id);
                });
                buttons[l] = b;
                append(b);
            }
        }

        public void set_value(string label) {
            syncing = true;
            foreach (var e in buttons.entries) e.value.active = e.key == label;
            syncing = false;
        }
    }

    namespace LibraryStyle {

        private bool installed = false;

        public void install() {
            if (installed) return;
            installed = true;
            var sb = new StringBuilder();
            sb.append("""
.photos-badges { margin: 4px; }
.photos-badge label { margin: 0; padding: 0; }
.photos-badge { background-color: alpha(black, 0.55); color: white; border-radius: 99px; padding: 1px 6px; font-size: 10px; font-weight: bold; }
.photos-badge image { color: white; -gtk-icon-size: 12px; }
.photos-badge.reject { background-color: alpha(#e5484d, 0.85); }
.photos-badge.pick { background-color: alpha(#30a46c, 0.85); }
.photos-rating-bar button { min-width: 24px; min-height: 24px; padding: 3px; }
.photos-label-strip { min-height: 4px; border-radius: 2px; margin: 0 8px; }
.photo-grid-item.rejected image { opacity: 0.45; }
.photo-grid-item.missing image { opacity: 0.35; }
button.photos-label-dot { min-width: 18px; min-height: 18px; padding: 0; border-radius: 99px; border: 2px solid transparent; }
button.photos-label-dot:checked { border-color: @window_fg_color; }
.photos-filter-bar { border-bottom: 1px solid alpha(@window_fg_color, 0.08); }
.photos-keyword-chip { border-radius: 99px; padding: 2px 4px 2px 10px; background-color: alpha(@accent_color, 0.15); }
.photos-keyword-chip button { min-width: 18px; min-height: 18px; padding: 0; }
.photos-compare-host { background-color: @window_bg_color; }
.photos-compare-pane { background-color: alpha(black, 0.04); border-radius: 12px; }
.photos-compare-pane.selected { box-shadow: inset 0 0 0 2px @accent_color; }
.photos-face { border-radius: 99px; }
gridview > child:selected .photo-grid-item { background-color: alpha(@accent_color, 0.3); }
.photos-sidebar-add { min-width: 22px; min-height: 22px; padding: 0; }
""");
            foreach (var l in COLOR_LABELS) {
                sb.append("button.photos-label-%s, .photos-label-strip.photos-label-%s { background-color: %s; }\n".printf(l, l, color_label_css(l)));
            }
            Singularity.Application.add_app_css(sb.str);
        }
    }
}
