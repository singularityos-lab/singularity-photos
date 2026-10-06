using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public class LibraryFilterBar : Box {
        public LibraryFilter filter { get; construct; }
        public Catalog catalog { get; construct; }

        public signal void changed();

        private DropDown rating_dd;
        private DropDown flag_dd;
        private DropDown kind_dd;
        private DropDown edited_dd;
        private DropDown camera_dd;
        private DropDown lens_dd;
        private DropDown year_dd;
        private DropDown keyword_dd;
        private DropDown sort_dd;
        private ToggleButton order_btn;
        private Gee.HashMap<string, ToggleButton> label_buttons = new Gee.HashMap<string, ToggleButton>();
        private string[] cameras = {};
        private string[] lenses = {};
        private string[] years = {};
        private int64[] keyword_ids = {};
        private bool syncing = false;

        private const string[] FLAG_KEYS = { "any", "pick", "not-rejected", "unflagged", "reject" };
        private const string[] KIND_KEYS = { "any", "photo", "raw", "video", "virtual" };
        private const string[] EDITED_KEYS = { "any", "edited", "unedited" };
        private const string[] SORT_KEYS = { "captured", "added", "name", "rating" };

        public LibraryFilterBar(LibraryFilter filter, Catalog catalog) {
            Object(filter: filter, catalog: catalog, orientation: Orientation.VERTICAL, spacing: 6);
        }

        construct {
            add_css_class("photos-filter-bar");
            var strip = new Singularity.Widgets.ControlStrip(6, 6);
            append(strip);
            var row1 = new Box(Orientation.HORIZONTAL, 6);
            var filters_scroll = new ScrolledWindow();
            filters_scroll.hscrollbar_policy = PolicyType.AUTOMATIC;
            filters_scroll.vscrollbar_policy = PolicyType.NEVER;
            filters_scroll.propagate_natural_height = true;
            filters_scroll.hexpand = true;
            filters_scroll.child = row1;
            strip.append(filters_scroll);
            var row2 = row1;

            rating_dd = LibraryDialogs.string_dropdown({ _("Any Rating"), "★ " + _("or more"), "★★ " + _("or more"), "★★★ " + _("or more"), "★★★★ " + _("or more"), "★★★★★", _("Unrated") });
            rating_dd.tooltip_text = _("Rating");
            rating_dd.notify["selected"].connect(() => {
                if (syncing) return;
                uint s = rating_dd.selected;
                if (s == 6) {
                    filter.rating = 0;
                    filter.rating_op = "==";
                } else {
                    filter.rating = (int) s;
                    filter.rating_op = s == 5 ? "==" : ">=";
                }
                changed();
            });
            row1.append(rating_dd);

            flag_dd = LibraryDialogs.string_dropdown({ _("Any Flag"), _("Picked"), _("Not Rejected"), _("Unflagged"), _("Rejected") });
            flag_dd.tooltip_text = _("Flag");
            flag_dd.notify["selected"].connect(() => {
                if (syncing) return;
                filter.flag = FLAG_KEYS[flag_dd.selected];
                changed();
            });
            row1.append(flag_dd);

            var labels = new Box(Orientation.HORIZONTAL, 4);
            labels.valign = Align.CENTER;
            labels.tooltip_text = _("Color Label");
            foreach (var l in COLOR_LABELS) {
                var b = new ToggleButton();
                b.add_css_class("photos-label-dot");
                b.add_css_class("photos-label-" + l);
                b.tooltip_text = color_label_title(l);
                b.toggled.connect(() => {
                    if (syncing) return;
                    update_labels();
                });
                label_buttons[l] = b;
                labels.append(b);
            }
            row1.append(labels);


            kind_dd = LibraryDialogs.string_dropdown({ _("All Kinds"), _("Photos"), _("RAW"), _("Videos"), _("Virtual Copies") });
            kind_dd.notify["selected"].connect(() => {
                if (syncing) return;
                filter.kind = KIND_KEYS[kind_dd.selected];
                changed();
            });
            row2.append(kind_dd);

            edited_dd = LibraryDialogs.string_dropdown({ _("Edited or Not"), _("Edited"), _("Unedited") });
            edited_dd.notify["selected"].connect(() => {
                if (syncing) return;
                filter.edited = EDITED_KEYS[edited_dd.selected];
                changed();
            });
            row2.append(edited_dd);

            year_dd = new DropDown(new StringList(null), null);
            year_dd.notify["selected"].connect(() => {
                if (syncing) return;
                filter.year = year_dd.selected == 0 || year_dd.selected > years.length ? 0 : int.parse(years[year_dd.selected - 1]);
                changed();
            });
            row2.append(year_dd);

            camera_dd = new DropDown(new StringList(null), null);
            camera_dd.notify["selected"].connect(() => {
                if (syncing) return;
                filter.camera = camera_dd.selected == 0 || camera_dd.selected > cameras.length ? "" : cameras[camera_dd.selected - 1];
                changed();
            });
            row2.append(camera_dd);

            lens_dd = new DropDown(new StringList(null), null);
            lens_dd.notify["selected"].connect(() => {
                if (syncing) return;
                filter.lens = lens_dd.selected == 0 || lens_dd.selected > lenses.length ? "" : lenses[lens_dd.selected - 1];
                changed();
            });
            row2.append(lens_dd);

            keyword_dd = new DropDown(new StringList(null), null);
            keyword_dd.notify["selected"].connect(() => {
                if (syncing) return;
                filter.keyword_id = keyword_dd.selected == 0 || keyword_dd.selected > keyword_ids.length ? 0 : keyword_ids[keyword_dd.selected - 1];
                changed();
            });
            row2.append(keyword_dd);


            sort_dd = LibraryDialogs.string_dropdown({ _("Capture Time"), _("Added"), _("File Name"), _("Rating") });
            sort_dd.tooltip_text = _("Sort");
            sort_dd.notify["selected"].connect(() => {
                if (syncing) return;
                filter.sort_key = SORT_KEYS[sort_dd.selected];
                changed();
            });
            strip.append(sort_dd);
            order_btn = new ToggleButton();
            order_btn.icon_name = "view-sort-ascending-symbolic";
            order_btn.tooltip_text = _("Ascending Order");
            order_btn.add_css_class("flat");
            order_btn.toggled.connect(() => {
                if (syncing) return;
                filter.ascending = order_btn.active;
                changed();
            });
            strip.append(order_btn);
            var reset = strip.add_text_button(_("Clear"), _("Clear All Filters"));
            reset.clicked.connect(() => {
                filter.reset_attributes();
                sync();
                changed();
            });

            refresh_values();
            sync();
        }

        private void update_labels() {
            string[] ls = {};
            foreach (var e in label_buttons.entries) if (e.value.active) ls += e.key;
            filter.labels = ls;
            changed();
        }

        private static StringList with_all(string all, string[] values) {
            var list = new StringList(null);
            list.append(all);
            foreach (var v in values) list.append(v);
            return list;
        }

        public void refresh_values() {
            syncing = true;
            cameras = catalog.distinct_values("camera");
            lenses = catalog.distinct_values("lens");
            var ys = catalog.distinct_values("year");
            string[] rev = {};
            for (int i = ys.length - 1; i >= 0; i--) rev += ys[i];
            years = rev;
            camera_dd.model = with_all(_("All Cameras"), cameras);
            lens_dd.model = with_all(_("All Lenses"), lenses);
            year_dd.model = with_all(_("All Dates"), years);
            var kw_names = new Gee.ArrayList<string>();
            int64[] ids = {};
            var all = new Gee.ArrayList<int64?>();
            foreach (var k in catalog.keywords.values) all.add(k.id);
            all.sort((a, b) => catalog.keyword_path(a).collate(catalog.keyword_path(b)));
            foreach (var id in all) {
                ids += id;
                kw_names.add(catalog.keyword_path(id).replace("|", " / "));
            }
            keyword_ids = ids;
            keyword_dd.model = with_all(_("All Keywords"), kw_names.to_array());
            camera_dd.visible = cameras.length > 0;
            lens_dd.visible = lenses.length > 0;
            keyword_dd.visible = keyword_ids.length > 0;
            year_dd.visible = years.length > 0;
            syncing = false;
            sync();
        }

        private static uint index_of(string[] arr, string v) {
            for (int i = 0; i < arr.length; i++) if (arr[i] == v) return i + 1;
            return 0;
        }

        public void sync() {
            syncing = true;
            rating_dd.selected = filter.rating_op == "==" && filter.rating == 0 ? 6 : (uint) filter.rating.clamp(0, 5);
            for (int i = 0; i < FLAG_KEYS.length; i++) if (FLAG_KEYS[i] == filter.flag) flag_dd.selected = i;
            for (int i = 0; i < KIND_KEYS.length; i++) if (KIND_KEYS[i] == filter.kind) kind_dd.selected = i;
            for (int i = 0; i < EDITED_KEYS.length; i++) if (EDITED_KEYS[i] == filter.edited) edited_dd.selected = i;
            for (int i = 0; i < SORT_KEYS.length; i++) if (SORT_KEYS[i] == filter.sort_key) sort_dd.selected = i;
            order_btn.active = filter.ascending;
            foreach (var e in label_buttons.entries) {
                bool on = false;
                foreach (var l in filter.labels) if (l == e.key) on = true;
                e.value.active = on;
            }
            camera_dd.selected = index_of(cameras, filter.camera);
            lens_dd.selected = index_of(lenses, filter.lens);
            year_dd.selected = filter.year == 0 ? 0 : index_of(years, filter.year.to_string());
            uint kw = 0;
            for (int i = 0; i < keyword_ids.length; i++) if (keyword_ids[i] == filter.keyword_id) kw = i + 1;
            keyword_dd.selected = kw;
            syncing = false;
        }

        public void focus_text() {
            rating_dd.grab_focus();
        }
    }
}
