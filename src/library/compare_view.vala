using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public class ComparePane : Box {
        public PhotoRecord record { get; construct; }
        public ScrolledWindow scroll;
        public Picture picture;
        private Label name_label;
        private RatingBar rating;
        private FlagBar flag;
        public signal void chosen();
        public signal void marked();
        public signal void dismissed();

        public ComparePane(PhotoRecord record, Catalog catalog, bool closable) {
            Object(record: record, orientation: Orientation.VERTICAL, spacing: 6);
            add_css_class("photos-compare-pane");
            hexpand = true;
            vexpand = true;
            scroll = new ScrolledWindow();
            scroll.hexpand = true;
            scroll.vexpand = true;
            picture = new Picture();
            picture.content_fit = ContentFit.CONTAIN;
            picture.can_shrink = true;
            picture.hexpand = true;
            picture.vexpand = true;
            scroll.child = picture;
            append(scroll);
            var click = new GestureClick();
            click.pressed.connect(() => chosen());
            scroll.add_controller(click);
            name_label = new Label(record.is_virtual_copy() ? "%s (%s)".printf(record.name(), record.copy_name) : record.name());
            name_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            name_label.margin_start = 12;
            name_label.xalign = 0;
            append(name_label);
            var bar = new Box(Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 8;
            bar.margin_bottom = 8;
            bar.halign = Align.CENTER;
            rating = new RatingBar();
            rating.set_value(record.rating);
            rating.rated.connect((n) => {
                catalog.set_rating(record, n);
                rating.set_value(n);
                marked();
            });
            bar.append(rating);
            flag = new FlagBar();
            flag.set_value(record.flag);
            flag.flagged.connect((f) => {
                catalog.set_flag(record, f);
                marked();
            });
            bar.append(flag);
            if (closable) {
                var close = new Button.from_icon_name("window-close-symbolic");
                close.add_css_class("flat");
                close.add_css_class("circular");
                close.tooltip_text = _("Remove from Survey");
                close.clicked.connect(() => dismissed());
                bar.append(close);
            }
            append(bar);
            var file = record.file();
            new Thread<void>("photos-compare-load", () => {
                Gdk.Texture? tex = null;
                try {
                    tex = EditImageIO.load_display_texture(file);
                } catch (Error e) {
                }
                Idle.add(() => {
                    picture.paintable = tex;
                    return Source.REMOVE;
                });
            });
        }

        public void refresh_marks() {
            rating.set_value(record.rating);
            flag.set_value(record.flag);
        }

        public void set_zoom(double zoom) {
            if (zoom <= 1.0) {
                picture.set_size_request(-1, -1);
                scroll.hscrollbar_policy = PolicyType.NEVER;
                scroll.vscrollbar_policy = PolicyType.NEVER;
                return;
            }
            scroll.hscrollbar_policy = PolicyType.AUTOMATIC;
            scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            picture.set_size_request((int) (scroll.get_width() * zoom), (int) (scroll.get_height() * zoom));
        }
    }

    public class CompareView : Box {
        public signal void finished();
        public signal void records_changed();

        private Catalog catalog;
        private Gee.ArrayList<PhotoRecord> records = new Gee.ArrayList<PhotoRecord>();
        private bool survey;
        private Box stage;
        private Scale zoom;
        private int select_index = 0;
        private int candidate_index = 1;
        private Gee.ArrayList<ComparePane> panes = new Gee.ArrayList<ComparePane>();
        private Label hint;

        public CompareView(Catalog catalog, Gee.List<PhotoRecord> selection, bool survey) {
            Object(orientation: Orientation.VERTICAL, spacing: 8);
            this.catalog = catalog;
            this.survey = survey;
            records.add_all(selection);
            add_css_class("photos-compare-host");
            hexpand = true;
            vexpand = true;
            focusable = true;
            var top = new Box(Orientation.HORIZONTAL, 12);
            apply_bubble_inset(top, 60, 8);
            top.margin_start = top.margin_end = 12;
            hint = new Label("");
            hint.add_css_class("dim-label");
            hint.hexpand = true;
            hint.xalign = 0;
            hint.wrap = true;
            top.append(hint);
            if (!survey) {
                var zl = new Label(_("Zoom"));
                top.append(zl);
                zoom = new Scale.with_range(Orientation.HORIZONTAL, 1.0, 4.0, 0.1);
                zoom.width_request = 180;
                zoom.draw_value = false;
                zoom.value_changed.connect(() => {
                    foreach (var p in panes) p.set_zoom(zoom.get_value());
                });
                top.append(zoom);
                var swap = new Button.with_label(_("Swap"));
                swap.clicked.connect(() => {
                    int t = select_index;
                    select_index = candidate_index;
                    candidate_index = t;
                    build();
                });
                top.append(swap);
                var promote = new Button.with_label(_("Make Select"));
                promote.tooltip_text = _("The candidate becomes the select");
                promote.clicked.connect(() => {
                    select_index = candidate_index;
                    next_candidate(1);
                });
                top.append(promote);
            }
            var done = new Button.with_label(_("Done"));
            done.add_css_class("suggested-action");
            done.clicked.connect(() => finished());
            top.append(done);
            append(top);
            stage = new Box(Orientation.HORIZONTAL, 12);
            stage.vexpand = true;
            stage.homogeneous = true;
            stage.margin_start = stage.margin_end = 12;
            stage.margin_bottom = 12;
            append(stage);
            var keys = new EventControllerKey();
            keys.key_pressed.connect(on_key);
            add_controller(keys);
            build();
        }

        private bool on_key(uint keyval, uint code, Gdk.ModifierType state) {
            if (keyval == Gdk.Key.Escape) {
                finished();
                return true;
            }
            if (!survey && (keyval == Gdk.Key.Right || keyval == Gdk.Key.Left)) {
                next_candidate(keyval == Gdk.Key.Right ? 1 : -1);
                return true;
            }
            return false;
        }

        private void next_candidate(int delta) {
            if (records.size < 2) return;
            int n = records.size;
            int c = candidate_index;
            for (int i = 0; i < n; i++) {
                c = ((c + delta) % n + n) % n;
                if (c != select_index) break;
            }
            candidate_index = c;
            build();
        }

        private void build() {
            Widget? w;
            while ((w = stage.get_first_child()) != null) stage.remove(w);
            panes.clear();
            if (records.size == 0) {
                finished();
                return;
            }
            if (survey) {
                hint.label = _("Click a photo to focus it, rate or flag it, remove the ones you do not want");
                var grid = new Grid();
                grid.row_spacing = grid.column_spacing = 12;
                grid.row_homogeneous = grid.column_homogeneous = true;
                grid.hexpand = grid.vexpand = true;
                int cols = (int) Math.ceil(Math.sqrt(records.size));
                for (int i = 0; i < records.size; i++) {
                    var pane = new ComparePane(records[i], catalog, true);
                    var rec = records[i];
                    pane.marked.connect(() => records_changed());
                    pane.dismissed.connect(() => {
                        records.remove(rec);
                        build();
                    });
                    pane.chosen.connect(() => {
                        foreach (var p in panes) p.remove_css_class("selected");
                        pane.add_css_class("selected");
                    });
                    panes.add(pane);
                    grid.attach(pane, i % cols, i / cols);
                }
                stage.append(grid);
                return;
            }
            if (records.size == 1) candidate_index = 0;
            hint.label = _("Select on the left, candidate on the right. Use the arrow keys to change the candidate");
            foreach (int idx in new int[] { select_index, candidate_index }) {
                var pane = new ComparePane(records[idx.clamp(0, records.size - 1)], catalog, false);
                pane.marked.connect(() => records_changed());
                panes.add(pane);
                stage.append(pane);
            }
            if (panes.size == 2) {
                panes[0].add_css_class("selected");
                panes[1].scroll.hadjustment = panes[0].scroll.hadjustment;
                panes[1].scroll.vadjustment = panes[0].scroll.vadjustment;
                if (zoom != null && zoom.get_value() > 1.0) {
                    Idle.add(() => {
                        foreach (var p in panes) p.set_zoom(zoom.get_value());
                        return Source.REMOVE;
                    });
                }
            }
        }
    }
}
