using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public delegate double ValueGetter();
    public delegate void ValueSetter(double v);
    public delegate string ValueFormat(double v);
    public delegate void EditAction();

    public class SliderBinding : Object {
        public Scale scale;
        public Label value_label;
        public ValueGetter getter;
        public ValueFormat format;
        public double display_scale;
    }

    public class DevelopControls : Object {
        public signal void begin_change(string label, bool coalesce);
        public signal void changed();

        public Gee.ArrayList<SliderBinding> sliders = new Gee.ArrayList<SliderBinding>();
        public Gee.ArrayList<Object> syncers = new Gee.ArrayList<Object>();
        public bool syncing = false;

        public static string percent(double v) {
            return "%d".printf((int) Math.round(v * 100));
        }

        public static string signed(double v) {
            int n = (int) Math.round(v);
            return n > 0 ? "+%d".printf(n) : n.to_string();
        }

        public static string signed_percent(double v) {
            int n = (int) Math.round(v * 100);
            return n > 0 ? "+%d".printf(n) : n.to_string();
        }

        public PreferencesRow slider(string title, double min, double max, double reset_value, double display_scale,
                                     owned ValueGetter getter, owned ValueSetter setter, owned ValueFormat? format = null, double step = 0) {
            var row = new PreferencesRow();
            row.activatable = false;
            row.add_css_class("photo-edit-slider-row");
            var content = new Box(Orientation.VERTICAL, 2);
            content.margin_start = 12;
            content.margin_end = 12;
            content.margin_top = 6;
            content.margin_bottom = 4;
            var head = new Box(Orientation.HORIZONTAL, 6);
            var name = new Label(title);
            name.halign = Align.START;
            name.hexpand = true;
            name.xalign = 0;
            var value = new Label("0");
            value.add_css_class("dim-label");
            value.add_css_class("numeric");
            head.append(name);
            head.append(value);
            content.append(head);
            double st = step > 0 ? step : (max - min) / 200.0;
            var scale = new Scale.with_range(Orientation.HORIZONTAL, min * display_scale, max * display_scale, st * display_scale);
            scale.draw_value = false;
            scale.hexpand = true;
            if (min < 0 && max > 0) {
                scale.has_origin = false;
                scale.add_mark(0, PositionType.BOTTOM, null);
            }
            var binding = new SliderBinding();
            binding.scale = scale;
            binding.value_label = value;
            binding.getter = (owned) getter;
            binding.display_scale = display_scale;
            if (format != null) binding.format = (owned) format;
            else binding.format = (v) => "%d".printf((int) Math.round(v));
            unowned SliderBinding b = binding;
            scale.value_changed.connect(() => {
                double v = scale.get_value() / display_scale;
                value.label = b.format(scale.get_value());
                if (syncing) return;
                begin_change(title, true);
                setter(v);
                changed();
            });
            var reset_click = new GestureClick();
            reset_click.pressed.connect((n) => {
                if (n == 2) scale.set_value(reset_value * display_scale);
            });
            head.add_controller(reset_click);
            content.append(scale);
            row.child = content;
            row.tooltip_text = _("Double-click the name to reset");
            sliders.add(binding);
            return row;
        }

        public void sync() {
            syncing = true;
            foreach (var b in sliders) {
                double v = b.getter() * b.display_scale;
                b.scale.set_value(v);
                b.value_label.label = b.format(b.scale.get_value());
            }
            syncing = false;
        }

        public static PreferencesRow static_row(Widget child) {
            var row = new PreferencesRow();
            row.activatable = false;
            row.add_css_class("photo-edit-static-row");
            child.margin_start = 10;
            child.margin_end = 10;
            child.margin_top = 8;
            child.margin_bottom = 8;
            row.child = child;
            return row;
        }

        public static Button pill(string label, owned EditAction action) {
            var b = new Button.with_label(label);
            b.add_css_class("pill");
            b.halign = Align.CENTER;
            b.clicked.connect(() => action());
            return b;
        }

        public static ActionRow action_row(string title, string icon, owned EditAction action) {
            var row = new ActionRow(title, null, icon);
            row.activated.connect(() => action());
            return row;
        }

        public static Button header_button(string icon, string tooltip, owned EditAction action) {
            var b = new Button.from_icon_name(icon);
            b.tooltip_text = tooltip;
            b.add_css_class("circular");
            b.valign = Align.CENTER;
            b.clicked.connect(() => action());
            return b;
        }
    }

    public class ChoiceRow : SelectionRow {
        private Gee.ArrayList<string> keys = new Gee.ArrayList<string>();
        private Gee.ArrayList<string> labels = new Gee.ArrayList<string>();

        public signal void chosen(string name);

        public string active_key { get; private set; default = ""; }

        public ChoiceRow(string title) {
            base(title, {}, "");
            selected.connect((item) => {
                int i = labels.index_of(item);
                if (i >= 0) {
                    active_key = keys[i];
                    chosen(keys[i]);
                }
            });
        }

        public void add_option(string name, string label) {
            keys.add(name);
            labels.add(label);
            set_items(labels.to_array());
            if (keys.size == 1) {
                current_value = label;
                active_key = name;
            }
        }

        public void set_active(string name) {
            int i = keys.index_of(name);
            if (i >= 0) {
                current_value = labels[i];
                active_key = name;
            }
        }
    }

    public class HintRow : EntryRow {
        public HintRow(string title, string hint) {
            base(title);
            if (hint != "") entry.placeholder_text = hint;
        }
    }

    public class IndexChoiceRow : SelectionRow {
        private string[] labels = {};
        private uint _selected_index = 0;

        public uint selected_index {
            get { return _selected_index; }
            set {
                _selected_index = value;
                if (value < labels.length) current_value = labels[value];
            }
        }

        public IndexChoiceRow(string title, string[] labels, uint active = 0) {
            base(title, labels, active < labels.length ? labels[active] : "");
            this.labels = labels;
            _selected_index = active;
            selected.connect((item) => {
                for (uint i = 0; i < this.labels.length; i++) {
                    if (this.labels[i] == item) {
                        selected_index = i;
                        return;
                    }
                }
            });
        }

        public void set_labels(string[] new_labels) {
            labels = new_labels;
            set_items(new_labels);
            if (_selected_index >= new_labels.length) _selected_index = 0;
            current_value = new_labels.length > 0 ? new_labels[_selected_index] : "";
        }
    }

    public class DevelopSection : Object {
        public PreferencesGroup group;
        public string id;
        private Button toggle;
        private bool _expanded = true;
        public signal void expanded_changed(bool expanded);

        public bool expanded {
            get { return _expanded; }
            set {
                _expanded = value;
                foreach (var r in group.get_rows()) r.visible = value;
                for (var child = group.get_first_child(); child != null; child = child.get_next_sibling()) {
                    if (child is ListBox) child.visible = value;
                }
                toggle.icon_name = value ? "go-up-symbolic" : "go-down-symbolic";
                toggle.tooltip_text = value ? _("Collapse") : _("Expand");
            }
        }

        public DevelopSection(string id, string title, bool collapsible, bool expanded) {
            this.id = id;
            group = new PreferencesGroup(title);
            toggle = new Button.from_icon_name("go-down-symbolic");
            toggle.add_css_class("circular");
            toggle.valign = Align.CENTER;
            toggle.visible = collapsible;
            toggle.clicked.connect(() => {
                this.expanded = !_expanded;
                expanded_changed(_expanded);
            });
            group.add_header_suffix(toggle);
            group.row_added.connect((r) => r.visible = _expanded);
            this.expanded = expanded;
        }

        public void add(Widget row) {
            group.add_row(row);
            row.visible = _expanded;
        }
    }
}
