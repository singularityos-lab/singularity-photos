using Gtk;
using Singularity.Widgets;
using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public delegate void PickHandler(double nx, double ny, float r, float g, float b);

    public class EditView : Box {
        public const int PREVIEW_SIDE = 1600;
        public const int THUMB_SIDE = 132;
        public const int HISTORY_LIMIT = 60;

        public File file { get; construct; }
        public string variant { get; construct; default = ""; }
        public EditParams params { get; private set; }
        public bool busy { get; private set; default = false; }
        public bool can_revert { get; private set; default = false; }
        public DecodedPhoto? photo { get; private set; default = null; }
        public RenderResult? last_result { get; private set; default = null; }
        public GLib.Settings? settings { get; private set; default = null; }
        public EditCanvas canvas { get; private set; }
        public HistogramView histogram { get; private set; }

        public signal void finished(bool saved);
        public signal void message(string text);
        public signal void params_changed();
        public signal void rendered();

        private EditParams saved_params;
        private Singularity.Widgets.InspectorPanel pages;
        private Spinner spinner;
        private Box toolbar;
        private Singularity.Widgets.InspectorPanel panel;
        private Singularity.Animation.MotionBin panel_bin;
        private Singularity.Animation.MotionBin toolbar_bin;
        private ToggleButton compare_button;
        private Button undo_button;
        private Button redo_button;
        private Gee.HashMap<string, ToggleButton> filter_buttons = new Gee.HashMap<string, ToggleButton>();
        private Gee.HashMap<string, Picture> filter_pictures = new Gee.HashMap<string, Picture>();
        private ChoiceRow aspect_row;
        private Gee.ArrayList<EditParams> undo_stack = new Gee.ArrayList<EditParams>();
        private Gee.ArrayList<string> undo_labels = new Gee.ArrayList<string>();
        private Gee.ArrayList<EditParams> redo_stack = new Gee.ArrayList<EditParams>();
        private Gee.ArrayList<string> redo_labels = new Gee.ArrayList<string>();
        private uint coalesce_id = 0;
        private string coalesce_label = "";
        private bool syncing = false;
        private bool display_changed = false;
        private bool rendering = false;
        private bool render_pending = false;
        private uint render_generation = 0;
        private DevelopCache cache = new DevelopCache();
        private DevelopCache before_cache = new DevelopCache();
        private DevelopControls crop_controls = new DevelopControls();
        private DevelopPanel develop_panel;
        private MasksPanel masks_panel;
        private HealPanel heal_panel;
        private HistoryPanel history_panel;
        private PresetsPanel presets_panel;
        private PickHandler? pick_handler = null;
        private string previous_tool = "";
        public string proof_profile_id = "";
        public string proof_intent = "perceptual";
        public bool proof_enabled = false;
        public bool gamut_warning = false;
        private ColorTransform? display_transform = null;
        private string display_transform_key = "";

        private static bool styled = false;

        private static void install_style() {
            if (styled) return;
            styled = true;
            IconTheme.get_for_display(Gdk.Display.get_default()).add_resource_path("/dev/sinty/photos/icons");
            Singularity.Application.add_app_css(EDIT_CSS);
        }

        private const string EDIT_CSS = """
.photo-edit-host {
    background-color: @window_bg_color;
}

.photo-edit-strip {
    min-height: 36px;
}

.photo-edit-canvas {
    background-color: alpha(black, 0.04);
}

button.photo-filter-button {
    padding: 4px;
    border-radius: 12px;
}

row.photo-edit-static-row button.photo-filter-button:checked {
    background-color: alpha(@accent_color, 0.18);
    box-shadow: inset 0 0 0 2px @accent_color;
}

.photo-filter-thumb {
    border-radius: 8px;
}

button.photo-edit-chip {
    border-radius: 99px;
    padding: 4px 12px;
    min-height: 26px;
}

row.photo-edit-static-row button.photo-edit-chip:checked {
    background-color: @accent_color;
    color: @accent_fg;
}

row.photo-edit-static-row,
row.photo-edit-static-row:hover,
row.photo-edit-slider-row:hover {
    background: none;
}

.photo-edit-exif {
    font-size: 0.9em;
}

row.photo-edit-list-row.selected-mask {
    background-color: alpha(@accent_color, 0.16);
}
""";

        public EditView(File file, string variant = "") {
            Object(file: file, variant: variant, orientation: Orientation.HORIZONTAL, spacing: 0);
        }

        construct {
            install_style();
            add_css_class("photo-edit-view");
            hexpand = true;
            vexpand = true;
            var source = SettingsSchemaSource.get_default();
            if (source != null && source.lookup("dev.sinty.photos", true) != null) settings = new GLib.Settings("dev.sinty.photos");
            params = EditStore.load(file, variant) ?? new EditParams();
            saved_params = params.copy();
            can_revert = EditStore.has_edits(file, variant);
            foreach (var h in params.history) {
                var restored = h.restore();
                if (restored == null) continue;
                undo_stack.add(restored);
                undo_labels.add(h.name);
            }

            var stage = new Overlay();
            stage.hexpand = true;
            stage.vexpand = true;
            canvas = new EditCanvas();
            canvas.crop_changed.connect(on_crop_changed);
            canvas.edit_begin.connect(() => record(_("Mask Edit")));
            canvas.picked.connect(on_picked);
            canvas.guides_changed.connect((finished) => { if (finished) solve_guides(); });
            stage.child = canvas;

            spinner = new Spinner();
            spinner.halign = Align.CENTER;
            spinner.valign = Align.CENTER;
            spinner.width_request = 32;
            spinner.height_request = 32;
            stage.add_overlay(spinner);

            build_toolbar();
            toolbar_bin = new Singularity.Animation.MotionBin(toolbar);
            var stage_column = new Box(Orientation.VERTICAL, 0);
            stage_column.hexpand = true;
            stage_column.vexpand = true;
            stage_column.append(stage);
            stage_column.append(toolbar_bin);
            append(stage_column);

            histogram = new HistogramView();

            panel = new Singularity.Widgets.InspectorPanel(340);
            panel.add_css_class("photo-edit-panel");
            pages = panel;
            develop_panel = new DevelopPanel(this);
            masks_panel = new MasksPanel(this);
            heal_panel = new HealPanel(this);
            history_panel = new HistoryPanel(this);
            presets_panel = new PresetsPanel(this);
            panel.add_page("adjust", _("Adjust"), "singularity-photos-adjust-symbolic", page_wrap(develop_panel), true);
            panel.add_page("filters", _("Filters"), "singularity-photos-filters-symbolic", page_wrap(build_filters_page()), true);
            panel.add_page("crop", _("Crop"), "singularity-markup-crop-symbolic", page_wrap(build_crop_page()), true);
            panel.add_page("masks", _("Masks"), "singularity-photos-mask-symbolic", page_wrap(masks_panel), true);
            panel.add_page("heal", _("Spot Removal"), "singularity-photos-heal-symbolic", page_wrap(heal_panel), false);
            panel.add_page("history", _("History and Snapshots"), "singularity-photos-history-symbolic", page_wrap(history_panel), false);
            panel.page = "adjust";
            panel.page_chosen.connect((name) => show_page(name));
            panel_bin = new Singularity.Animation.MotionBin(panel);
            append(panel_bin);

            crop_controls.begin_change.connect((label, coalesce) => record(label, coalesce));
            crop_controls.changed.connect(() => changed());

            var keys = new EventControllerKey();
            keys.key_pressed.connect(on_key);
            add_controller(keys);

            sync_controls();
            update_history_buttons();
            load_original();
        }

        private bool on_key(uint keyval, uint keycode, Gdk.ModifierType state) {
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            if (ctrl && (keyval == Gdk.Key.z || keyval == Gdk.Key.Z)) {
                if (shift) redo(); else undo();
                return true;
            }
            if (ctrl && shift && (keyval == Gdk.Key.c || keyval == Gdk.Key.C)) {
                presets_panel.copy_settings();
                return true;
            }
            if (ctrl && shift && (keyval == Gdk.Key.v || keyval == Gdk.Key.V)) {
                paste_settings();
                return true;
            }
            if (!ctrl && (keyval == Gdk.Key.backslash)) {
                compare_button.active = !compare_button.active;
                return true;
            }
            if (!ctrl && (keyval == Gdk.Key.Delete || keyval == Gdk.Key.BackSpace)) {
                if (canvas.tool == "heal") {
                    heal_panel.delete_selected();
                    return true;
                }
            }
            if (!ctrl && !shift && !(get_root() is Gtk.Window && ((Gtk.Window) get_root()).get_focus() is Gtk.Editable)) {
                switch (keyval) {
                    case Gdk.Key.d: show_page("adjust"); return true;
                    case Gdk.Key.r: show_page("crop"); return true;
                    case Gdk.Key.m: show_page("masks"); return true;
                    case Gdk.Key.q: show_page("heal"); return true;
                    case Gdk.Key.y: compare_button.active = !compare_button.active; return true;
                    default: break;
                }
            }
            if (!ctrl && keyval == Gdk.Key.o && canvas.tool != "") {
                canvas.show_overlay = !canvas.show_overlay;
                return true;
            }
            return false;
        }

        public override void map() {
            base.map();
            Singularity.Motion.reveal(panel_bin, Singularity.Motion.Preset.FADE_SLIDE);
            Singularity.Motion.reveal(toolbar_bin, Singularity.Motion.Preset.FADE_SLIDE, Singularity.Motion.stagger_delay(1));
        }

        private ScrolledWindow page_wrap(Widget child) {
            var box = new Box(Orientation.VERTICAL, 12);
            box.add_css_class("photo-edit-page");
            box.margin_start = 14;
            box.margin_end = 14;
            box.margin_top = 2;
            box.margin_bottom = 14;
            box.append(child);
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_width = false;
            scroll.vexpand = true;
            scroll.child = new Singularity.Animation.MotionBin(box);
            var wheel = new EventControllerScroll(EventControllerScrollFlags.VERTICAL);
            wheel.propagation_phase = PropagationPhase.CAPTURE;
            wheel.scroll.connect((dx, dy) => {
                var adj = scroll.vadjustment;
                double step = wheel.get_unit() == Gdk.ScrollUnit.WHEEL ? 60.0 : 1.0;
                adj.value = (adj.value + dy * step).clamp(adj.lower, adj.upper - adj.page_size);
                return true;
            });
            scroll.add_controller(wheel);
            return scroll;
        }

        private void build_toolbar() {
            var strip = new Singularity.Widgets.ControlStrip(6, 6);
            toolbar = strip;
            toolbar.add_css_class("photo-edit-strip");
            var auto = strip.add_icon_button("singularity-photos-enhance-symbolic", _("Auto Enhance"));
            auto.clicked.connect(() => auto_enhance());
            compare_button = strip.add_icon_toggle("singularity-photos-compare-symbolic", _("Compare with Original (\\)"));
            compare_button.toggled.connect(() => set_compare(compare_button.active));
            strip.add_spacer();
            undo_button = strip.add_icon_button("edit-undo-symbolic", _("Undo (Ctrl+Z)"));
            undo_button.clicked.connect(() => undo());
            redo_button = strip.add_icon_button("edit-redo-symbolic", _("Redo (Shift+Ctrl+Z)"));
            redo_button.clicked.connect(() => redo());
        }

        public void show_page(string name) {
            if (pages.stack.get_child_by_name(name) == null) return;
            if (pages.page == name && !(name == "crop" && canvas.mode != EditCanvas.Mode.CROP)) return;
            syncing = true;
            pages.page = name;
            syncing = false;
            var page_scroll = pages.stack.visible_child as ScrolledWindow;
            var viewport = page_scroll != null ? page_scroll.child as Viewport : null;
            var bin = viewport != null ? viewport.child as Singularity.Animation.MotionBin : null;
            if (bin != null) Singularity.Motion.reveal(bin, Singularity.Motion.Preset.FADE_SLIDE);
            if (name == "crop") {
                compare_button.active = false;
                canvas.crop_x = params.crop_x;
                canvas.crop_y = params.crop_y;
                canvas.crop_w = params.crop_w;
                canvas.crop_h = params.crop_h;
                canvas.mode = EditCanvas.Mode.CROP;
            } else if (canvas.mode == EditCanvas.Mode.CROP) {
                canvas.mode = compare_button.active ? EditCanvas.Mode.COMPARE : EditCanvas.Mode.VIEW;
            }
            compare_button.sensitive = name != "crop";
            canvas.tool = "";
            canvas.mask_overlay = null;
            canvas.component = null;
            canvas.spots = null;
            if (name == "masks") masks_panel.activate_tools();
            else if (name == "heal") heal_panel.activate_tools();
            else if (name == "history") history_panel.refresh();
            schedule_render();
        }

        public string current_page() {
            return pages.page ?? "adjust";
        }

        public void set_compare(bool on) {
            if (compare_button.active != on) {
                compare_button.active = on;
                return;
            }
            if (on && canvas.mode == EditCanvas.Mode.CROP) show_page("adjust");
            canvas.mode = on ? EditCanvas.Mode.COMPARE : EditCanvas.Mode.VIEW;
            if (on) canvas.divider = 0.5;
            schedule_render();
        }

        private Widget build_filters_page() {
            var box = new Box(Orientation.VERTICAL, 12);
            var group = new PreferencesGroup(_("Filters"));
            var flow = new FlowBox();
            flow.selection_mode = SelectionMode.NONE;
            flow.homogeneous = true;
            flow.min_children_per_line = 2;
            flow.max_children_per_line = 2;
            flow.column_spacing = 8;
            flow.row_spacing = 8;
            flow.margin_start = 8;
            flow.margin_end = 8;
            flow.margin_top = 8;
            flow.margin_bottom = 8;
            ToggleButton? first = null;
            foreach (unowned FilterPreset f in FilterPreset.all()) {
                var button = new ToggleButton();
                button.add_css_class("flat");
                button.add_css_class("photo-filter-button");
                var tile = new Box(Orientation.VERTICAL, 4);
                var pic = new Picture();
                pic.content_fit = ContentFit.COVER;
                pic.width_request = 120;
                pic.height_request = 90;
                pic.add_css_class("photo-filter-thumb");
                pic.overflow = Overflow.HIDDEN;
                var label = new Label(f.name);
                label.add_css_class("caption");
                tile.append(pic);
                tile.append(label);
                button.child = tile;
                button.tooltip_text = f.name;
                if (first == null) first = button;
                else button.group = first;
                string id = f.id;
                button.toggled.connect(() => {
                    if (!button.active || syncing) return;
                    set_filter(id);
                });
                filter_buttons[id] = button;
                filter_pictures[id] = pic;
                flow.append(button);
            }
            var holder = new PreferencesRow();
            holder.activatable = false;
            holder.add_css_class("photo-edit-static-row");
            holder.child = flow;
            group.add_row(holder);
            box.append(group);
            box.append(presets_panel);
            return box;
        }

        private Widget build_crop_page() {
            var box = new Box(Orientation.VERTICAL, 12);
            var aspect_group = new PreferencesGroup(_("Aspect Ratio"));
            aspect_row = new ChoiceRow(_("Shape"));
            for (int i = 0; i < AspectPreset.COUNT; i++) {
                string id = "aspect-%d".printf(i);
                string label = ((AspectPreset) i).label();
                aspect_row.add_option(id, label);
            }
            aspect_row.chosen.connect((name) => {
                if (syncing) return;
                apply_aspect(int.parse(name.substring(7)));
            });
            aspect_group.add_row(aspect_row);
            box.append(aspect_group);

            var orient = new PreferencesGroup(_("Orientation"));
            orient.add_row(action_row(_("Rotate Left"), "object-rotate-left-symbolic", () => rotate(-1)));
            orient.add_row(action_row(_("Rotate Right"), "object-rotate-right-symbolic", () => rotate(1)));
            orient.add_row(action_row(_("Flip Horizontally"), "singularity-photos-flip-symbolic", () => flip()));
            box.append(orient);

            var straighten = new PreferencesGroup(_("Straighten"));
            straighten.add_row(crop_controls.slider(_("Angle"), -EditParams.MAX_STRAIGHTEN, EditParams.MAX_STRAIGHTEN, 0, 1,
                () => params.straighten, (v) => params.straighten = v, (v) => "%.1f°".printf(v), 0.1));
            box.append(straighten);

            var upright = new PreferencesGroup(_("Upright"));
            var switcher = new ChoiceRow(_("Mode"));
            switcher.add_option("off", _("Off"));
            switcher.add_option("auto", _("Auto"));
            switcher.add_option("level", _("Level"));
            switcher.add_option("vertical", _("Vertical"));
            switcher.add_option("full", _("Full"));
            switcher.add_option("guided", _("Guided"));
            switcher.chosen.connect((name) => {
                if (syncing) return;
                apply_upright(name);
            });
            upright_switcher = switcher;
            upright.add_row(switcher);
            box.append(upright);

            var transform = new PreferencesGroup(_("Transform"));
            string[,] keys = {
                { "transform.vertical", _("Vertical") }, { "transform.horizontal", _("Horizontal") },
                { "transform.aspect", _("Aspect") }, { "transform.x", _("Horizontal Offset") }, { "transform.y", _("Vertical Offset") }
            };
            for (int i = 0; i < keys.length[0]; i++) {
                string key = keys[i, 0];
                transform.add_row(crop_controls.slider(keys[i, 1], -1, 1, 0, 100, () => params.develop.get(key), (v) => params.develop.set(key, v), DevelopControls.signed));
            }
            transform.add_row(crop_controls.slider(_("Rotate"), -10, 10, 0, 1, () => params.develop.get("transform.rotate"), (v) => params.develop.set("transform.rotate", v), (v) => "%.1f°".printf(v), 0.1));
            transform.add_row(crop_controls.slider(_("Scale"), 0.5, 1.5, 1, 100, () => params.develop.get("transform.scale"), (v) => params.develop.set("transform.scale", v), (v) => "%d%%".printf((int) Math.round(v))));
            box.append(transform);

            transform.add_row(DevelopControls.action_row(_("Reset Crop and Geometry"), "edit-undo-symbolic", () => {
                record(_("Reset Crop"));
                params.quarter_turns = 0;
                params.flip = false;
                params.straighten = 0;
                params.set_crop(0, 0, 1, 1);
                params.develop.reset_prefix("transform.");
                params.develop.set_string("upright", null);
                params.develop.set_string("upright.guides", null);
                canvas.guides = {};
                canvas.aspect = 0;
                changed();
            }));
            return box;
        }

        private ChoiceRow upright_switcher;

        private void solve_guides() {
            if (photo == null) return;
            var g = new GeometryMap(params, photo.full_width, photo.full_height, 0, false);
            double[] oriented = {};
            var src = canvas.guides;
            for (int i = 0; i + 3 < src.length; i += 4) {
                double ax, ay, bx, by;
                g.source_to_oriented(src[i] * photo.full_width, src[i + 1] * photo.full_height, out ax, out ay);
                g.source_to_oriented(src[i + 2] * photo.full_width, src[i + 3] * photo.full_height, out bx, out by);
                if (Math.hypot(bx - ax, by - ay) < 8) continue;
                oriented += ax;
                oriented += ay;
                oriented += bx;
                oriented += by;
            }
            params.develop.set_string("upright.guides", DevelopPipeline.format_guides(src));
            double v = 0, h = 0, r = 0;
            if (oriented.length >= 4) DevelopPipeline.solve_guided(oriented, g.oriented_width, g.oriented_height, out v, out h, out r);
            params.develop.set("transform.vertical", v);
            params.develop.set("transform.horizontal", h);
            params.develop.set("transform.rotate", r);
            changed();
        }

        private void apply_upright(string mode) {
            if (last_result == null || photo == null) return;
            if (mode == "guided") {
                record(_("Guided Upright"));
                params.develop.set_string("upright", "guided");
                canvas.guides = DevelopPipeline.parse_guides(params.develop.get_string("upright.guides"));
                canvas.mode = EditCanvas.Mode.VIEW;
                canvas.tool = "guide";
                message(_("Draw up to four lines along edges that should be straight"));
                schedule_render();
                return;
            }
            if (canvas.tool == "guide") {
                canvas.tool = "";
                if (current_page() == "crop") canvas.mode = EditCanvas.Mode.CROP;
            }
            record(_("Upright"));
            if (mode == "off") {
                params.develop.set_string("upright", null);
                params.develop.set("transform.vertical", 0);
                params.develop.set("transform.horizontal", 0);
                params.develop.set("transform.rotate", 0);
                changed();
                return;
            }
            params.develop.set_string("upright", mode);
            var p = params.copy();
            p.develop.reset_prefix("transform.");
            p.set_crop(0, 0, 1, 1);
            p.straighten = 0;
            var src = photo;
            busy = true;
            spinner.spinning = true;
            new Thread<void>("photo-upright", () => {
                var img = DevelopPipeline.render(src, p, new RenderOptions.preview(1024));
                double v, h, r;
                Upright.solve(img, mode, out v, out h, out r);
                Idle.add(() => {
                    busy = false;
                    spinner.spinning = false;
                    params.develop.set("transform.vertical", v);
                    params.develop.set("transform.horizontal", h);
                    params.develop.set("transform.rotate", r);
                    changed();
                    if (v.abs() < 1e-6 && h.abs() < 1e-6 && r.abs() < 1e-6) message(_("No lines to straighten were found"));
                    return Source.REMOVE;
                });
            });
        }

        private ActionRow action_row(string title, string icon, owned Singularity.Widgets.Window.BubbleAction action) {
            var row = new ActionRow(title, null, icon);
            row.activatable = true;
            row.activated.connect(() => action());
            return row;
        }

        public void rotated_size(out int w1, out int h1) {
            w1 = 1;
            h1 = 1;
            if (photo == null) return;
            EditPipeline.rotated_size(params, photo.full_width, photo.full_height, out w1, out h1);
        }

        public void record(string label = "", bool coalesce = false) {
            if (coalesce && coalesce_id != 0 && coalesce_label == label) {
                Source.remove(coalesce_id);
                coalesce_id = Timeout.add(600, () => { coalesce_id = 0; return Source.REMOVE; });
                return;
            }
            if (coalesce_id != 0) {
                Source.remove(coalesce_id);
                coalesce_id = 0;
            }
            undo_stack.add(params.copy());
            undo_labels.add(label == "" ? _("Edit") : label);
            if (undo_stack.size > 100) {
                undo_stack.remove_at(0);
                undo_labels.remove_at(0);
            }
            redo_stack.clear();
            redo_labels.clear();
            coalesce_label = label;
            if (coalesce) coalesce_id = Timeout.add(600, () => { coalesce_id = 0; return Source.REMOVE; });
            update_history_buttons();
        }

        public void undo() {
            if (undo_stack.size == 0) return;
            redo_stack.add(params.copy());
            redo_labels.add(undo_labels[undo_labels.size - 1]);
            params.assign(undo_stack.remove_at(undo_stack.size - 1));
            undo_labels.remove_at(undo_labels.size - 1);
            changed();
        }

        public void redo() {
            if (redo_stack.size == 0) return;
            undo_stack.add(params.copy());
            undo_labels.add(redo_labels.remove_at(redo_labels.size - 1));
            params.assign(redo_stack.remove_at(redo_stack.size - 1));
            changed();
        }

        public Gee.List<string> history_labels() {
            return undo_labels.read_only_view;
        }

        public void jump_to_history(int index) {
            if (index < 0 || index >= undo_stack.size) return;
            var target = undo_stack[index].copy();
            record(_("History"));
            params.assign(target);
            changed();
        }

        private void update_history_buttons() {
            undo_button.sensitive = undo_stack.size > 0;
            redo_button.sensitive = redo_stack.size > 0;
        }

        public void changed() {
            sync_controls();
            update_history_buttons();
            params_changed();
            schedule_render();
        }

        public void sync_controls() {
            syncing = true;
            crop_controls.sync();
            develop_panel.sync();
            masks_panel.sync();
            heal_panel.sync();
            presets_panel.sync();
            var fb = filter_buttons[params.filter];
            if (fb != null) fb.active = true;
            if (upright_switcher != null) upright_switcher.set_active(params.develop.get_string("upright", "off"));
            if (canvas.tool == "guide") canvas.guides = DevelopPipeline.parse_guides(params.develop.get_string("upright.guides"));
            if (canvas.mode == EditCanvas.Mode.CROP) {
                canvas.crop_x = params.crop_x;
                canvas.crop_y = params.crop_y;
                canvas.crop_w = params.crop_w;
                canvas.crop_h = params.crop_h;
                canvas.queue_draw();
            }
            syncing = false;
        }

        private void on_crop_changed() {
            record(_("Crop"));
            params.set_crop(canvas.crop_x, canvas.crop_y, canvas.crop_w, canvas.crop_h);
            update_history_buttons();
            schedule_render();
        }

        public void set_filter(string id) {
            if (FilterPreset.find(id) == null || params.filter == id) {
                sync_controls();
                return;
            }
            record(_("Filter"));
            params.filter = id;
            changed();
        }

        public void set_adjustment(string key, double value) {
            var a = Adjustment.from_key(key);
            if (a != null) {
                record(a.label());
                params.set_value(a, value);
                changed();
                return;
            }
            if (DevelopSettings.find_key(key) != null) {
                record(key);
                params.develop.set(key, value);
                changed();
            }
        }

        public void set_crop(double x, double y, double w, double h) {
            record(_("Crop"));
            params.set_crop(x, y, w, h);
            changed();
        }

        public void set_straighten(double degrees) {
            record(_("Straighten"));
            params.straighten = degrees.clamp(-EditParams.MAX_STRAIGHTEN, EditParams.MAX_STRAIGHTEN);
            changed();
        }

        public void select_aspect(int index) {
            if (index < 0 || index >= AspectPreset.COUNT) return;
            show_page("crop");
            aspect_row.set_active("aspect-%d".printf(index));
            apply_aspect(index);
        }

        private void apply_aspect(int index) {
            record(_("Aspect Ratio"));
            int w1, h1;
            rotated_size(out w1, out h1);
            canvas.apply_aspect(((AspectPreset) index).ratio((double) w1 / h1));
        }

        public void rotate(int turns) {
            record(_("Rotate"));
            params.rotate(turns);
            changed();
        }

        public void flip() {
            record(_("Flip"));
            params.toggle_flip();
            changed();
        }

        public void auto_enhance() {
            if (last_result == null) return;
            record(_("Auto Enhance"));
            var base_params = params.copy();
            base_params.reset_color();
            var src = photo;
            var img = DevelopPipeline.render(src, base_params, new RenderOptions.preview(512));
            var encoded = WorkingSpace.to_srgb_encoded(img);
            var small = new EditImage.from_rgba(encoded.width, encoded.height, encoded.to_rgba8(false), encoded.width * 4, true);
            var auto = EditPipeline.auto_enhance(small, params);
            params.black_point = auto.black_point;
            params.white_point = auto.white_point;
            params.set_value(Adjustment.SHADOWS, auto.get_value(Adjustment.SHADOWS));
            params.set_value(Adjustment.HIGHLIGHTS, auto.get_value(Adjustment.HIGHLIGHTS));
            params.set_value(Adjustment.VIBRANCE, auto.get_value(Adjustment.VIBRANCE));
            if (photo != null && photo.is_raw()) params.develop.set_string("wb.mode", "auto");
            changed();
        }

        public void paste_settings() {
            if (!SettingsClipboard.has_content()) {
                message(_("There are no copied settings"));
                return;
            }
            record(_("Paste Settings"));
            SettingsClipboard.paste(params);
            changed();
            message(_("Settings pasted"));
        }

        public void request_pick(string tool_label, owned PickHandler handler) {
            previous_tool = canvas.tool;
            pick_handler = (owned) handler;
            if (canvas.mode != EditCanvas.Mode.VIEW) {
                compare_button.active = false;
                canvas.mode = EditCanvas.Mode.VIEW;
            }
            canvas.tool = "pick";
            message(tool_label);
        }

        private void on_picked(double nx, double ny) {
            if (pick_handler == null || last_result == null) return;
            var res = last_result;
            double ox, oy;
            res.geometry.source_to_output(nx * res.geometry.source_width, ny * res.geometry.source_height, out ox, out oy);
            int x = ((int) ox).clamp(0, res.image.width - 1), y = ((int) oy).clamp(0, res.image.height - 1);
            float r = 0, g = 0, b = 0;
            int n = 0;
            for (int dy = -2; dy <= 2; dy++) {
                for (int dx = -2; dx <= 2; dx++) {
                    int px = (x + dx).clamp(0, res.image.width - 1), py = (y + dy).clamp(0, res.image.height - 1);
                    size_t i = res.image.offset(px, py);
                    r += res.image.data[i];
                    g += res.image.data[i + 1];
                    b += res.image.data[i + 2];
                    n++;
                }
            }
            var handler = (owned) pick_handler;
            pick_handler = null;
            canvas.tool = previous_tool;
            handler(nx, ny, r / n, g / n, b / n);
        }

        public bool sample_base(double nx, double ny, out float r, out float g, out float b) {
            r = g = b = 0;
            if (photo == null) return false;
            var o = new RenderOptions.preview(PREVIEW_SIDE);
            o.color = false;
            var res = DevelopPipeline.render_full(photo, params, o, before_cache);
            double ox, oy;
            res.geometry.source_to_output(nx * res.geometry.source_width, ny * res.geometry.source_height, out ox, out oy);
            int x = ((int) ox).clamp(0, res.image.width - 1), y = ((int) oy).clamp(0, res.image.height - 1);
            int n = 0;
            for (int dy = -2; dy <= 2; dy++) {
                for (int dx = -2; dx <= 2; dx++) {
                    size_t i = res.image.offset((x + dx).clamp(0, res.image.width - 1), (y + dy).clamp(0, res.image.height - 1));
                    r += res.image.data[i];
                    g += res.image.data[i + 1];
                    b += res.image.data[i + 2];
                    n++;
                }
            }
            r /= n;
            g /= n;
            b /= n;
            return true;
        }

        public void pick_white_balance(double nx, double ny) {
            float r, g, b;
            if (!sample_base(nx, ny, out r, out g, out b)) return;
            if (r <= 1e-6f || g <= 1e-6f || b <= 1e-6f) {
                message(_("Pick a brighter neutral area"));
                return;
            }
            record(_("White Balance"));
            if (photo.raw != null) {
                double cr, cg, cb;
                DevelopPipeline.white_balance_multipliers(photo, params, out cr, out cg, out cb);
                var to_working = Singularity.Imaging.Matrix3.multiply(Singularity.Imaging.Matrix3.invert(WorkingSpace.primaries().to_xyz()), photo.raw.camera_to_xyz);
                var inv = Singularity.Imaging.Matrix3.invert(to_working);
                float rr = r, gg = g, bb = b;
                Singularity.Imaging.Matrix3.apply(inv, ref rr, ref gg, ref bb);
                double camr = rr / cr, camg = gg / cg, camb = bb / cb;
                if (camr > 1e-9 && camb > 1e-9 && camg > 1e-9) {
                    double t, ti;
                    RawColor.temperature_for(photo.raw, camg / camr, 1.0, camg / camb, out t, out ti);
                    params.develop.set_string("wb.mode", "custom");
                    params.develop.set("wb.temperature", t);
                    params.develop.set("wb.tint", ti);
                }
            } else {
                double lr = Math.log2(r), lg = Math.log2(g), lb = Math.log2(b);
                double dw = (lb - lr) / 0.7;
                double dt = (lg - lr - 0.35 * dw) / 0.38;
                params.set_value(Adjustment.WARMTH, dw);
                params.set_value(Adjustment.TINT, dt);
            }
            changed();
        }

        private void load_original() {
            busy = true;
            spinner.spinning = true;
            var f = file;
            new Thread<void>("photo-edit-load", () => {
                DecodedPhoto? decoded = null;
                string? error = null;
                try {
                    decoded = Codecs.load(f, PREVIEW_SIDE);
                } catch (Error e) {
                    error = e.message;
                }
                Idle.add(() => {
                    busy = false;
                    spinner.spinning = false;
                    if (decoded == null) {
                        message(_("This photo cannot be edited: %s").printf(error ?? ""));
                        finished(false);
                        return Source.REMOVE;
                    }
                    photo = decoded;
                    if (photo.is_raw() && EditStore.find_sidecar(file, variant) == null && !EditStore.has_edits(file, variant)
                        && params.is_identity() && settings != null && settings.get_boolean("raw-sharpening")) {
                        params.set_value(Adjustment.SHARPNESS, 0.27);
                        params.develop.set("detail.color.amount", 0.25);
                        saved_params = params.copy();
                    }
                    develop_panel.photo_loaded();
                    sync_controls();
                    schedule_render();
                    render_filter_thumbnails();
                    return Source.REMOVE;
                });
            });
        }

        private void render_filter_thumbnails() {
            var base_params = params.copy();
            base_params.reset_color();
            base_params.filter = "none";
            var src = photo;
            new Thread<void>("photo-edit-filters", () => {
                var small_cache = new DevelopCache();
                var results = new Gee.HashMap<string, Gdk.Texture>();
                foreach (unowned FilterPreset f in FilterPreset.all()) {
                    var p = base_params.copy();
                    p.filter = f.id;
                    var img = DevelopPipeline.render(src, p, new RenderOptions.preview(THUMB_SIDE * 2), small_cache);
                    results[f.id] = WorkingSpace.to_display_texture(img);
                }
                Idle.add(() => {
                    foreach (var entry in results.entries) {
                        var pic = filter_pictures[entry.key];
                        if (pic != null) pic.paintable = entry.value;
                    }
                    return Source.REMOVE;
                });
            });
        }

        private ColorTransform? current_display_transform() {
            string display = settings != null ? settings.get_string("display-profile") : "auto";
            string key = "%s|%s|%s|%s|%s".printf(display, proof_enabled.to_string(), proof_profile_id, proof_intent, gamut_warning.to_string());
            if (key == display_transform_key) return display_transform;
            display_transform_key = key;
            display_transform = null;
            IccProfile? target = display == "auto" ? null : IccProfile.builtin(display);
            if (proof_enabled && proof_profile_id != "") {
                IccProfile? proof = null;
                if (proof_profile_id.has_prefix("/")) {
                    try {
                        proof = IccProfile.from_file(proof_profile_id);
                    } catch (Error e) {
                        message(_("Cannot read the proof profile: %s").printf(e.message));
                    }
                } else {
                    proof = IccProfile.builtin(proof_profile_id);
                }
                if (proof != null) {
                    var intent = proof_intent == "relative" ? RenderingIntent.RELATIVE_COLORIMETRIC : RenderingIntent.PERCEPTUAL;
                    display_transform = new ColorTransform.proofing(WorkingSpace.profile(), target ?? IccProfile.srgb(), proof, intent, gamut_warning);
                }
            } else if (target != null && target.id != "srgb") {
                display_transform = new ColorTransform(WorkingSpace.profile(), target, RenderingIntent.PERCEPTUAL, true);
            }
            return display_transform;
        }

        public void invalidate_display() {
            display_transform_key = "";
            schedule_render();
        }

        public void schedule_render() {
            if (photo == null) return;
            if (rendering) {
                render_pending = true;
                return;
            }
            rendering = true;
            render_pending = false;
            uint gen = ++render_generation;
            var p = params.copy();
            var src = photo;
            bool crop_mode = canvas.mode == EditCanvas.Mode.CROP;
            bool compare = canvas.mode == EditCanvas.Mode.COMPARE;
            var display = current_display_transform();
            LocalAdjustment? overlay_local = null;
            if (current_page() == "masks") overlay_local = masks_panel.active_local();
            var c = cache;
            var bc = before_cache;
            new Thread<void>("photo-edit-render", () => {
                var o = new RenderOptions.preview(PREVIEW_SIDE);
                o.crop = !crop_mode;
                var result = DevelopPipeline.render_full(src, p, o, c);
                Gdk.Texture? before = null;
                if (compare) {
                    var bo = new RenderOptions.preview(PREVIEW_SIDE);
                    bo.color = false;
                    before = WorkingSpace.to_display_texture(DevelopPipeline.render(src, p, bo, bc), display);
                }
                var shown = result.image.copy();
                if (display != null && display.valid()) display.apply(shown);
                else {
                    WorkingSpace.to_linear_srgb(shown);
                    WorkingSpace.encode_srgb(shown);
                }
                var px = shown.to_rgba8(false);
                var texture = new Gdk.MemoryTexture(shown.width, shown.height, Gdk.MemoryFormat.R8G8B8A8, new Bytes(px), shown.width * 4);
                Gdk.Texture? overlay = null;
                if (overlay_local != null && overlay_local.components.size > 0) {
                    var mask = Masks.evaluate(overlay_local, result.image, result.coords, result.geometry, c);
                    var ov = new uint8[mask.length * 4];
                    for (int i = 0; i < mask.length; i++) {
                        ov[i * 4] = 255;
                        ov[i * 4 + 1] = 40;
                        ov[i * 4 + 2] = 40;
                        ov[i * 4 + 3] = (uint8) (mask[i].clamp(0, 1) * 255);
                    }
                    overlay = new Gdk.MemoryTexture(result.image.width, result.image.height, Gdk.MemoryFormat.R8G8B8A8, new Bytes(ov), result.image.width * 4);
                }
                Idle.add(() => {
                    rendering = false;
                    if (gen == render_generation) {
                        last_result = result;
                        canvas.geometry = result.geometry;
                        if (crop_mode) canvas.uncropped = texture;
                        else canvas.edited = texture;
                        if (before != null) canvas.before = before;
                        canvas.mask_overlay = overlay;
                        histogram.update_from_rgba8(px);
                        rendered();
                    }
                    if (render_pending) schedule_render();
                    return Source.REMOVE;
                });
            });
        }

        public bool is_modified() {
            return !params.equals(saved_params);
        }

        private void store_history() {
            params.history.clear();
            int start = int.max(0, undo_stack.size - HISTORY_LIMIT);
            for (int i = start; i < undo_stack.size; i++) {
                var snap = new EditSnapshot(undo_labels[i], undo_stack[i]);
                params.history.add(snap);
            }
        }

        public void save() {
            if (busy) return;
            if (!is_modified()) {
                finished(display_changed);
                return;
            }
            store_history();
            try {
                if (params.is_identity() && params.snapshots.size == 0) EditStore.revert(file, variant);
                else EditStore.save(file, params, variant);
            } catch (Error e) {
                message(_("Could not save: %s").printf(e.message));
                return;
            }
            saved_params = params.copy();
            busy = true;
            spinner.spinning = true;
            var p = params.copy();
            var f = file;
            string v = variant;
            new Thread<void>("photo-edit-save", () => {
                if (!p.is_identity() || Codecs.is_raw_name(f.get_basename() ?? "")) EditImageIO.render_to_cache(f, p, v);
                Idle.add(() => {
                    busy = false;
                    spinner.spinning = false;
                    finished(true);
                    return Source.REMOVE;
                });
            });
        }

        public void save_copy() {
            if (busy) return;
            busy = true;
            spinner.spinning = true;
            var p = params.copy();
            var f = file;
            string name = (f.get_basename() ?? "").down();
            bool png = name.has_suffix(".png");
            var target = EditStore.copy_target(f, png ? ".png" : ".jpg");
            new Thread<void>("photo-edit-copy", () => {
                string? error = null;
                try {
                    var full = Codecs.load(f, 0);
                    var img = DevelopPipeline.render(full, p, new RenderOptions());
                    EditImageIO.save_working(img, target);
                } catch (Error e) {
                    error = e.message;
                }
                Idle.add(() => {
                    busy = false;
                    spinner.spinning = false;
                    if (error != null) message(_("Could not save: %s").printf(error));
                    else message(_("Saved as %s").printf(target.get_basename()));
                    return Source.REMOVE;
                });
            });
        }

        public void revert() {
            if (busy) return;
            record(_("Revert"));
            EditStore.revert(file, variant);
            var snaps = params.snapshots;
            params.assign(new EditParams());
            params.snapshots = snaps;
            saved_params = params.copy();
            can_revert = false;
            display_changed = true;
            canvas.aspect = 0;
            if (aspect_row != null) aspect_row.set_active("aspect-0");
            changed();
            message(_("Reverted to the original"));
        }

        public void cancel() {
            finished(display_changed);
        }
    }
}
