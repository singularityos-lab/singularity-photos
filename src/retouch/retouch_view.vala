using Gtk;
using Singularity.Widgets;
using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class RetouchView : Box {
        public File file { get; construct; }
        public bool busy { get; private set; default = false; }
        public RetouchDocument? document { get; private set; default = null; }
        public File? saved_file { get; private set; default = null; }

        public signal void finished(bool saved);
        public signal void message(string text);

        private RetouchCanvas canvas;
        private RetouchController controller;
        private Spinner spinner;
        private Box toolbar;
        private Singularity.Widgets.ToolPalette palette;
        private Singularity.Widgets.InspectorPanel panel;
        private Singularity.Animation.MotionBin panel_bin;
        private Singularity.Animation.MotionBin toolbar_bin;
        private Gee.HashMap<string, ToggleButton> tool_buttons = new Gee.HashMap<string, ToggleButton>();
        private Button undo_button;
        private Button redo_button;
        private Label zoom_label;
        private PreferencesGroup layers_group;
        private PreferencesGroup properties_group;
        private PreferencesGroup content_group;
        private PreferencesGroup tool_group;
        private PreferencesGroup selection_group;
        private PreferencesGroup actions_group;
        private int saved_modifications = 0;
        private bool syncing = false;
        private string select_kind = "rect";
        private string brush_kind = "paint";
        private RetouchExternal? external = null;
        private uint prop_timeout = 0;

        private static bool styled = false;

        private const string RETOUCH_CSS = """
.photo-retouch-view {
    background-color: @window_bg_color;
}

.photo-retouch-view .photo-edit-panel {
    border-left: 1px solid alpha(@borders, 0.6);
    background-color: alpha(@card_bg_color, 0.6);
}

button.photo-retouch-chip {
    border-radius: 99px;
    padding: 4px 12px;
    min-height: 26px;
}

button.photo-retouch-chip:checked {
    background-color: @accent_color;
    color: @accent_fg;
}

row.photo-retouch-layer-active {
    background-color: alpha(@accent_color, 0.18);
}

row.photo-retouch-static-row,
row.photo-retouch-static-row:hover,
row.photo-retouch-slider-row:hover {
    background: none;
}

label.photo-retouch-zoom {
    min-width: 48px;
}
""";

        private static void install_style() {
            if (styled) return;
            styled = true;
            Gtk.IconTheme.get_for_display(Gdk.Display.get_default()).add_resource_path("/dev/sinty/photos/retouch/icons");
            Singularity.Application.add_app_css(RETOUCH_CSS);
        }

        public RetouchView(File file) {
            Object(file: file, orientation: Gtk.Orientation.HORIZONTAL, spacing: 0);
        }

        construct {
            install_style();
            add_css_class("photo-retouch-view");
            add_css_class("photo-edit-view");
            hexpand = true;
            vexpand = true;
            focusable = true;

            var stage = new Overlay();
            stage.hexpand = true;
            stage.vexpand = true;
            canvas = new RetouchCanvas();
            stage.child = canvas;
            controller = new RetouchController(canvas);
            controller.message.connect((t) => message(t));
            controller.state_changed.connect(() => {
                update_history();
                rebuild_tool_options();
            });
            controller.layer_created.connect((l) => {
                controller.active = l;
                rebuild_layers();
                rebuild_properties();
            });

            spinner = new Spinner();
            spinner.halign = Align.CENTER;
            spinner.valign = Align.CENTER;
            spinner.width_request = 32;
            spinner.height_request = 32;
            stage.add_overlay(spinner);

            build_toolbar();
            stage.add_overlay(palette);
            toolbar_bin = new Singularity.Animation.MotionBin(toolbar);
            var stage_column = new Box(Gtk.Orientation.VERTICAL, 0);
            stage_column.hexpand = true;
            stage_column.vexpand = true;
            stage.vexpand = true;
            stage_column.append(stage);
            stage_column.append(toolbar_bin);
            append(stage_column);

            panel = new Singularity.Widgets.InspectorPanel(340);
            panel.page_chosen.connect((name) => panel.page = name);
            layers_group = new PreferencesGroup(_("Layers"));
            properties_group = new PreferencesGroup(_("Properties"));
            content_group = new PreferencesGroup();
            tool_group = new PreferencesGroup(_("Tool"));
            selection_group = new PreferencesGroup(_("Selection"));
            actions_group = new PreferencesGroup(_("Actions"));
            var layers_box = inspector_page("layers", _("Layers"), "singularity-retouch-layer-symbolic");
            layers_box.append(layers_group);
            layers_box.append(properties_group);
            layers_box.append(content_group);
            var tool_box = inspector_page("tool", _("Tool"), "singularity-retouch-transform-symbolic");
            tool_box.append(tool_group);
            tool_box.append(selection_group);
            var actions_box = inspector_page("actions", _("Actions"), "singularity-photos-adjust-symbolic");
            actions_box.append(actions_group);
            panel.page = "layers";
            panel_bin = new Singularity.Animation.MotionBin(panel);
            append(panel_bin);


            canvas.zoom_changed.connect(() => zoom_label.label = "%d%%".printf((int) Math.round(canvas.zoom * 100)));
            load_document();
        }

        public override void map() {
            base.map();
            Singularity.Motion.reveal(panel_bin, Singularity.Motion.Preset.FADE_SLIDE);
            Singularity.Motion.reveal(toolbar_bin, Singularity.Motion.Preset.FADE_SLIDE, Singularity.Motion.stagger_delay(1));
            install_window_actions();
        }

        public override void unmap() {
            remove_window_actions();
            base.unmap();
        }

        private const string[] WINDOW_ACTIONS = { "retouch-tool", "retouch-select-subject", "retouch-select-sky", "retouch-select-all", "retouch-deselect", "retouch-invert-selection", "retouch-content-aware-fill", "retouch-generative-fill", "retouch-fill-variant", "retouch-apply-fill", "retouch-edit-in-draw", "retouch-new-adjustment", "retouch-frequency-separation", "retouch-save-psd", "retouch-undo", "retouch-redo" };

        private void window_action(Gtk.ApplicationWindow win, string name, VariantType? type, owned WindowActionFunc func) {
            var act = new SimpleAction(name, type);
            act.activate.connect((p) => func(p));
            win.add_action(act);
        }

        private delegate void WindowActionFunc(Variant? p);

        private EventControllerKey? window_keys = null;

        private void install_window_actions() {
            var win = get_root() as Gtk.ApplicationWindow;
            if (win == null) return;
            if (window_keys == null) {
                window_keys = new EventControllerKey();
                window_keys.propagation_phase = PropagationPhase.CAPTURE;
                window_keys.key_pressed.connect(on_key);
                ((Gtk.Widget) win).add_controller(window_keys);
            }
            window_action(win, "retouch-tool", VariantType.STRING, (p) => {
                string id = p.get_string();
                if (id.has_prefix("select-")) {
                    select_kind = id.substring(7);
                    id = "select";
                } else if (id == "erase" || id == "mask" || id == "paint") {
                    brush_kind = id;
                    id = "brush";
                }
                select_tool(id);
            });
            window_action(win, "retouch-select-subject", null, (p) => select_segment(false));
            window_action(win, "retouch-select-sky", null, (p) => select_segment(true));
            window_action(win, "retouch-select-all", null, (p) => select_all());
            window_action(win, "retouch-deselect", null, (p) => deselect());
            window_action(win, "retouch-invert-selection", null, (p) => invert_selection());
            window_action(win, "retouch-content-aware-fill", null, (p) => content_aware_fill());
            window_action(win, "retouch-generative-fill", null, (p) => generative_fill());
            window_action(win, "retouch-fill-variant", VariantType.INT32, (p) => show_variant(p.get_int32()));
            window_action(win, "retouch-apply-fill", null, (p) => apply_generative());
            window_action(win, "retouch-edit-in-draw", null, (p) => send_to(RetouchExternal.DRAW_ID));
            window_action(win, "retouch-new-adjustment", VariantType.STRING, (p) => new_adjustment(p.get_string()));
            window_action(win, "retouch-frequency-separation", null, (p) => frequency_separation());
            window_action(win, "retouch-save-psd", null, (p) => save_as_psd());
            window_action(win, "retouch-undo", null, (p) => undo());
            window_action(win, "retouch-redo", null, (p) => redo());
        }

        private void remove_window_actions() {
            var win = get_root() as Gtk.ApplicationWindow;
            if (win == null) return;
            if (window_keys != null) {
                ((Gtk.Widget) win).remove_controller(window_keys);
                window_keys = null;
            }
            foreach (unowned string name in WINDOW_ACTIONS) win.remove_action(name);
        }

        private Box inspector_page(string name, string title, string icon) {
            var box = new Box(Gtk.Orientation.VERTICAL, 12);
            box.margin_start = 14;
            box.margin_end = 14;
            box.margin_top = 2;
            box.margin_bottom = 14;
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_width = false;
            scroll.vexpand = true;
            scroll.child = box;
            panel.add_page(name, title, icon, scroll, true);
            return box;
        }

        private ToggleButton tool_toggle(string id, string icon, string tooltip) {
            var b = palette.add_tool(icon, tooltip);
            if (tool_buttons.size > 0) b.group = tool_buttons.values.to_array()[0];
            tool_buttons[id] = b;
            b.toggled.connect(() => {
                if (b.active && !syncing) {
                    select_tool(id);
                    if (panel != null) panel.page = "tool";
                }
            });
            return b;
        }

        private Button tool_button(string icon, string tooltip) {
            return ((Singularity.Widgets.ControlStrip) toolbar).add_icon_button(icon, tooltip);
        }

        private void separator() {
            palette.add_separator();
        }

        private void build_toolbar() {
            palette = new Singularity.Widgets.ToolPalette();
            palette.margin_start = 10;
            palette.margin_top = palette.margin_bottom = 6;
            var strip = new Singularity.Widgets.ControlStrip(6, 6);
            strip.add_css_class("photo-edit-strip");
            toolbar = strip;
            tool_toggle("move", RetouchTool.MOVE.icon(), RetouchTool.MOVE.label()).active = true;
            tool_toggle("select", RetouchTool.MARQUEE_RECT.icon(), _("Selection (M)"));
            tool_toggle("brush", RetouchTool.BRUSH.icon(), _("Brush and Mask (B)"));
            tool_toggle("clone", RetouchTool.CLONE.icon(), RetouchTool.CLONE.label());
            tool_toggle("heal", RetouchTool.HEAL.icon(), RetouchTool.HEAL.label());
            tool_toggle("patch", RetouchTool.PATCH.icon(), RetouchTool.PATCH.label());
            separator();
            tool_toggle("liquify", RetouchTool.LIQUIFY.icon(), RetouchTool.LIQUIFY.label());
            tool_toggle("transform", RetouchTool.TRANSFORM.icon(), RetouchTool.TRANSFORM.label());
            tool_toggle("text", RetouchTool.TEXT.icon(), RetouchTool.TEXT.label());
            tool_toggle("eyedropper", RetouchTool.EYEDROPPER.icon(), RetouchTool.EYEDROPPER.label());
            var fit = tool_button("zoom-fit-best-symbolic", _("Fit (Ctrl+0)"));
            fit.clicked.connect(() => canvas.fit());
            zoom_label = new Label("100%");
            zoom_label.add_css_class("numeric");
            zoom_label.add_css_class("caption");
            zoom_label.add_css_class("photo-retouch-zoom");
            toolbar.append(zoom_label);
            var actual = tool_button("zoom-original-symbolic", _("Actual Size (Ctrl+1)"));
            actual.clicked.connect(() => canvas.apply_zoom(1.0));
            strip.add_spacer();
            undo_button = tool_button("edit-undo-symbolic", _("Undo (Ctrl+Z)"));
            undo_button.clicked.connect(() => undo());
            redo_button = tool_button("edit-redo-symbolic", _("Redo (Shift+Ctrl+Z)"));
            redo_button.clicked.connect(() => redo());
        }

        public void select_tool(string id) {
            var b = tool_buttons[id];
            if (b != null && !b.active) {
                syncing = true;
                b.active = true;
                syncing = false;
            }
            switch (id) {
                case "select": controller.tool = select_tool_for(select_kind); break;
                case "brush": controller.tool = brush_kind == "erase" ? RetouchTool.ERASER : brush_kind == "mask" ? RetouchTool.MASK_BRUSH : RetouchTool.BRUSH; break;
                case "clone": controller.tool = RetouchTool.CLONE; break;
                case "heal": controller.tool = RetouchTool.HEAL; break;
                case "patch": controller.tool = RetouchTool.PATCH; break;
                case "liquify": controller.tool = RetouchTool.LIQUIFY; break;
                case "transform": controller.tool = RetouchTool.TRANSFORM; break;
                case "text": controller.tool = RetouchTool.TEXT; break;
                case "eyedropper": controller.tool = RetouchTool.EYEDROPPER; break;
                default: controller.tool = RetouchTool.MOVE; break;
            }
            canvas.show_overlay_mask = controller.tool == RetouchTool.MASK_BRUSH;
            canvas.overlay_mask = controller.active != null ? controller.active.mask : null;
            canvas.invalidate();
            rebuild_tool_options();
        }

        private RetouchTool select_tool_for(string kind) {
            switch (kind) {
                case "ellipse": return RetouchTool.MARQUEE_ELLIPSE;
                case "lasso": return RetouchTool.LASSO;
                case "polygon": return RetouchTool.POLYGON;
                case "wand": return RetouchTool.MAGIC_WAND;
                case "quick": return RetouchTool.QUICK_SELECT;
                default: return RetouchTool.MARQUEE_RECT;
            }
        }

        private void load_document() {
            busy = true;
            spinner.spinning = true;
            var f = file;
            new Thread<void>("photo-retouch-load", () => {
                RetouchDocument? doc = null;
                string? error = null;
                try {
                    doc = open_document(f);
                } catch (Error e) {
                    error = e.message;
                }
                Idle.add(() => {
                    busy = false;
                    spinner.spinning = false;
                    if (doc == null) {
                        message(_("This photo cannot be retouched: %s").printf(error ?? ""));
                        finished(false);
                        return Source.REMOVE;
                    }
                    install_document(doc);
                    return Source.REMOVE;
                });
            });
        }

        public static RetouchDocument open_document(File f) throws Error {
            return RetouchDocument.open(f);
        }

        private void install_document(RetouchDocument doc) {
            document = doc;
            controller.doc = doc;
            controller.active = doc.layers.size > 0 ? doc.layers[doc.layers.size - 1] : null;
            canvas.set_document(doc);
            saved_modifications = doc.modifications;
            doc.structure_changed.connect(() => {
                if (controller.active == null || doc.find(controller.active.id) == null)
                    controller.active = doc.layers.size > 0 ? doc.layers[doc.layers.size - 1] : null;
                rebuild_layers();
                rebuild_properties();
            });
            doc.changed.connect(() => update_history());
            rebuild_layers();
            rebuild_properties();
            rebuild_tool_options();
            rebuild_selection();
            rebuild_actions();
            update_history();
            zoom_label.label = "%d%%".printf((int) Math.round(canvas.zoom * 100));
            canvas.grab_focus();
        }

        private void update_history() {
            undo_button.sensitive = document != null && document.can_undo();
            redo_button.sensitive = document != null && document.can_redo();
        }

        public void undo() {
            if (document == null || controller.transforming || controller.liquify != null || gen_layer != null) return;
            document.undo();
            if (controller.active == null || document.find(controller.active.id) == null)
                controller.active = document.layers.size > 0 ? document.layers[document.layers.size - 1] : null;
            rebuild_layers();
            rebuild_properties();
            update_history();
        }

        public void redo() {
            if (document == null || controller.transforming || controller.liquify != null || gen_layer != null) return;
            document.redo();
            if (controller.active == null || document.find(controller.active.id) == null)
                controller.active = document.layers.size > 0 ? document.layers[document.layers.size - 1] : null;
            rebuild_layers();
            rebuild_properties();
            update_history();
        }

        private string kind_icon(RetouchLayer layer) {
            switch (layer.kind) {
                case RetouchLayerKind.GROUP: return layer.expanded ? "folder-open-symbolic" : "folder-symbolic";
                case RetouchLayerKind.ADJUSTMENT: return "singularity-photos-adjust-symbolic";
                case RetouchLayerKind.TEXT: return "singularity-markup-text-symbolic";
                case RetouchLayerKind.EMBEDDED: return "image-x-generic-symbolic";
                default: return "singularity-retouch-layer-symbolic";
            }
        }

        private void rebuild_layers() {
            layers_group.clear();
            if (document == null) return;
            var flat = new Gee.ArrayList<RetouchLayer>();
            var depths = new Gee.ArrayList<int>();
            document.flatten_list(flat, 0, depths);
            for (int i = 0; i < flat.size; i++) {
                var layer = flat[i];
                var row = new ActionRow(layer.name, null, kind_icon(layer));
                row.activatable = true;
                row.margin_start = depths[i] * 16;
                if (layer == controller.active) row.add_css_class("photo-retouch-layer-active");
                if (layer.mask != null) {
                    var mask_icon = new Image.from_icon_name("singularity-retouch-mask-symbolic");
                    mask_icon.tooltip_text = layer.mask_enabled ? _("Has a layer mask") : _("Layer mask disabled");
                    mask_icon.opacity = layer.mask_enabled ? 1.0 : 0.4;
                    row.add_suffix(mask_icon);
                }
                if (layer.locked) row.add_suffix(new Image.from_icon_name("system-lock-screen-symbolic"));
                var eye = new Button.from_icon_name(layer.visible ? "view-reveal-symbolic" : "view-conceal-symbolic");
                eye.add_css_class("flat");
                eye.valign = Align.CENTER;
                eye.tooltip_text = layer.visible ? _("Hide Layer") : _("Show Layer");
                eye.clicked.connect(() => {
                    document.record_structure(_("Visibility"));
                    layer.visible = !layer.visible;
                    document.recomposite();
                    rebuild_layers();
                });
                row.add_suffix(eye);
                row.activated.connect(() => {
                    if (controller.active == layer && layer.kind == RetouchLayerKind.GROUP) layer.expanded = !layer.expanded;
                    set_active(layer);
                });
                layers_group.add_row(row);
            }
            var top = new Box(Gtk.Orientation.HORIZONTAL, 2);
            top.homogeneous = true;
            top.append(icon_action("list-add-symbolic", _("New Layer"), () => new_layer()));
            top.append(icon_action("singularity-retouch-mask-symbolic", _("Add Layer Mask"), () => add_mask(document.selection != null)));
            top.append(icon_action("folder-new-symbolic", _("New Group"), () => new_group()));
            top.append(adjustment_menu_button());
            top.append(icon_action("image-x-generic-symbolic", _("Place Photo as Embedded Layer"), () => place_photo()));
            var bottom = new Box(Gtk.Orientation.HORIZONTAL, 2);
            bottom.homogeneous = true;
            bottom.append(icon_action("edit-copy-symbolic", _("Duplicate Layer (Ctrl+J)"), () => duplicate_layer()));
            bottom.append(icon_action("go-up-symbolic", _("Move Up"), () => move_layer(1)));
            bottom.append(icon_action("go-down-symbolic", _("Move Down"), () => move_layer(-1)));
            bottom.append(icon_action("user-trash-symbolic", _("Delete Layer"), () => delete_layer()));
            var buttons = new Box(Gtk.Orientation.VERTICAL, 2);
            buttons.margin_start = 6;
            buttons.margin_end = 6;
            buttons.margin_top = 4;
            buttons.margin_bottom = 4;
            buttons.append(top);
            buttons.append(bottom);
            var holder = new PreferencesRow();
            holder.activatable = false;
            holder.add_css_class("photo-retouch-static-row");
            holder.child = buttons;
            layers_group.add_row(holder);
        }

        private Button icon_action(string icon, string tooltip, owned Singularity.Widgets.Window.BubbleAction action) {
            var b = new Button.from_icon_name(icon);
            b.add_css_class("flat");
            b.tooltip_text = tooltip;
            b.clicked.connect(() => action());
            return b;
        }

        private Button adjustment_menu_button() {
            var mb = new Button.from_icon_name("singularity-photos-adjust-symbolic");
            mb.tooltip_text = _("New Adjustment Layer");
            mb.add_css_class("flat");
            mb.clicked.connect(() => {
                var menu = new ContextMenu(mb);
                foreach (unowned string kind in RetouchAdjustment.KINDS) {
                    string k = kind;
                    menu.add_item(RetouchAdjustment.label_for(k), null, () => new_adjustment(k));
                }
                menu.closed.connect(() => Idle.add(() => {
                    menu.unparent();
                    return Source.REMOVE;
                }));
                menu.popup();
            });
            return mb;
        }

        private void set_active(RetouchLayer layer) {
            controller.active = layer;
            canvas.overlay_mask = layer.mask;
            canvas.invalidate();
            rebuild_layers();
            rebuild_properties();
            rebuild_tool_options();
        }

        private void after_structure(RetouchLayer? select = null) {
            if (select != null) controller.active = select;
            document.recomposite();
            rebuild_layers();
            rebuild_properties();
            update_history();
        }

        public void new_layer() {
            if (document == null) return;
            document.record_structure(_("New Layer"));
            var layer = new RetouchLayer(_("Layer %d").printf(count_layers() + 1), RetouchLayerKind.RASTER);
            layer.pixels = new FloatImage.filled(document.width, document.height, 0, 0, 0, 0);
            document.add_layer(layer, controller.active);
            after_structure(layer);
        }

        private int count_layers() {
            var flat = new Gee.ArrayList<RetouchLayer>();
            var depths = new Gee.ArrayList<int>();
            document.flatten_list(flat, 0, depths);
            return flat.size;
        }

        public void new_group() {
            if (document == null) return;
            document.record_structure(_("New Group"));
            var group = new RetouchLayer(_("Group"), RetouchLayerKind.GROUP);
            var active = controller.active;
            if (active != null) {
                var list = document.parent_list(active);
                int index = list.index_of(active);
                list.remove_at(index);
                group.children.add(active);
                list.insert(index, group);
            } else {
                document.layers.add(group);
            }
            after_structure(group);
        }

        public void new_adjustment(string kind) {
            if (document == null) return;
            document.record_structure(_("New Adjustment Layer"));
            var layer = new RetouchLayer(RetouchAdjustment.label_for(kind), RetouchLayerKind.ADJUSTMENT);
            layer.adjustment = new RetouchAdjustment(kind);
            if (document.selection != null) layer.mask = document.selection.copy();
            document.add_layer(layer, controller.active);
            after_structure(layer);
        }

        public void duplicate_layer() {
            if (document == null || controller.active == null) return;
            document.record_structure(_("Duplicate Layer"));
            var copy = controller.active.deep_copy();
            document.add_layer(copy, controller.active);
            after_structure(copy);
        }

        public void delete_layer() {
            if (document == null || controller.active == null) return;
            if (document.layers.size <= 1 && document.layers.contains(controller.active)) {
                message(_("A document needs at least one layer"));
                return;
            }
            document.record_structure(_("Delete Layer"));
            var below = document.layer_below(controller.active);
            document.remove_layer(controller.active);
            after_structure(below ?? (document.layers.size > 0 ? document.layers[document.layers.size - 1] : null));
        }

        public void move_layer(int delta) {
            if (document == null || controller.active == null) return;
            document.record_structure(_("Move Layer"));
            if (!document.move_layer(controller.active, delta)) return;
            after_structure();
        }

        public void merge_down() {
            if (document == null || controller.active == null) return;
            document.record_structure(_("Merge Down"));
            var merged = document.merge_down(controller.active);
            if (merged == null) {
                message(_("The layer below must be a pixel layer"));
                return;
            }
            after_structure(merged);
        }

        public void place_photo() {
            var dialog = new FileDialog();
            dialog.title = _("Place Photo");
            var filter = new FileFilter();
            filter.name = _("Images");
            filter.add_mime_type("image/*");
            var filters = new GLib.ListStore(typeof(FileFilter));
            filters.append(filter);
            dialog.filters = filters;
            dialog.open.begin(get_root() as Gtk.Window, null, (obj, res) => {
                try {
                    var picked = dialog.open.end(res);
                    if (picked != null) place_file(picked);
                } catch (Error e) {
                }
            });
        }

        public void place_file(File source) {
            if (document == null) return;
            busy = true;
            spinner.spinning = true;
            new Thread<void>("photo-retouch-place", () => {
                FloatImage? img = null;
                string edit = "";
                try {
                    var photo = Codecs.load(source, 0);
                    var p = EditStore.load(source);
                    if (p != null && p.is_identity()) p = null;
                    if (p != null) edit = p.to_json();
                    img = RetouchDevelop.render(photo, p);
                } catch (Error e) {
                    warning("Retouch: %s", e.message);
                }
                Idle.add(() => {
                    busy = false;
                    spinner.spinning = false;
                    if (img == null) {
                        message(_("This photo cannot be placed"));
                        return Source.REMOVE;
                    }
                    document.record_structure(_("Place Photo"));
                    var layer = new RetouchLayer(source.get_basename() ?? _("Photo"), RetouchLayerKind.EMBEDDED);
                    layer.source_uri = source.get_uri();
                    layer.source_edit = edit;
                    double fit_scale = double.min(1.0, double.min((double) document.width / img.width, (double) document.height / img.height));
                    layer.embed_scale = fit_scale;
                    layer.pixels = fit_scale < 1 ? img.resized(int.max(1, (int) (img.width * fit_scale)), int.max(1, (int) (img.height * fit_scale))) : img;
                    layer.x = (document.width - layer.pixels.width) / 2;
                    layer.y = (document.height - layer.pixels.height) / 2;
                    document.add_layer(layer, controller.active);
                    after_structure(layer);
                    return Source.REMOVE;
                });
            });
        }

        private Widget slider_row(string title, double min, double max, double step, double value, int digits, owned SliderChanged changed) {
            var row = new PreferencesRow();
            row.activatable = false;
            row.add_css_class("photo-retouch-slider-row");
            var content = new Box(Gtk.Orientation.VERTICAL, 2);
            content.margin_start = 12;
            content.margin_end = 12;
            content.margin_top = 6;
            content.margin_bottom = 4;
            var head = new Box(Gtk.Orientation.HORIZONTAL, 6);
            var name = new Label(title);
            name.halign = Align.START;
            name.hexpand = true;
            var val = new Label("");
            val.add_css_class("dim-label");
            val.add_css_class("numeric");
            head.append(name);
            head.append(val);
            content.append(head);
            var scale = new Scale.with_range(Gtk.Orientation.HORIZONTAL, min, max, step);
            scale.draw_value = false;
            scale.hexpand = true;
            scale.set_value(value);
            string fmt = "%." + digits.to_string() + "f";
            val.label = fmt.printf(value);
            scale.value_changed.connect(() => {
                val.label = fmt.printf(scale.get_value());
                changed(scale.get_value());
            });
            content.append(scale);
            row.child = content;
            return row;
        }

        private delegate void SliderChanged(double v);

        private Widget chips(string[] ids, string[] labels, string active, owned ChipSelected selected) {
            var flow = new FlowBox();
            flow.selection_mode = SelectionMode.NONE;
            flow.max_children_per_line = 4;
            flow.column_spacing = 6;
            flow.row_spacing = 6;
            flow.margin_start = 10;
            flow.margin_end = 10;
            flow.margin_top = 10;
            flow.margin_bottom = 10;
            ToggleButton? first = null;
            for (int i = 0; i < ids.length; i++) {
                string id = ids[i];
                var chip = new ToggleButton.with_label(labels[i]);
                chip.add_css_class("photo-retouch-chip");
                if (first == null) first = chip;
                else chip.group = first;
                chip.active = id == active;
                chip.toggled.connect(() => {
                    if (chip.active) selected(id);
                });
                flow.append(chip);
            }
            var row = new PreferencesRow();
            row.activatable = false;
            row.add_css_class("photo-retouch-static-row");
            row.child = flow;
            return row;
        }

        private delegate void ChipSelected(string id);

        private ActionRow action_row(string title, string icon, owned Singularity.Widgets.Window.BubbleAction action) {
            var row = new ActionRow(title, null, icon);
            row.activatable = true;
            row.activated.connect(() => action());
            return row;
        }

        private SwitchRow switch_row(string title, bool active, owned SwitchChanged changed) {
            var row = new SwitchRow(title, null, active);
            row.notify["active"].connect(() => changed(row.active));
            return row;
        }

        private delegate void SwitchChanged(bool v);

        private void schedule_recomposite() {
            if (prop_timeout != 0) return;
            prop_timeout = Timeout.add(40, () => {
                prop_timeout = 0;
                if (document != null) document.recomposite();
                return Source.REMOVE;
            });
        }

        private void rebuild_properties() {
            properties_group.clear();
            content_group.clear();
            content_group.description = "";
            content_group.visible = false;
            if (gen_layer != null) {
                properties_group.visible = false;
                rebuild_generative();
                return;
            }
            var layer = controller.active;
            if (document == null || layer == null) {
                properties_group.visible = false;
                return;
            }
            properties_group.visible = true;
            var name_row = new EntryRow(_("Name"));
            name_row.text = layer.name;
            name_row.notify["text"].connect(() => {
                if (name_row.text.strip() == "" || name_row.text == layer.name) return;
                layer.name = name_row.text;
                document.mark_modified();
            });
            properties_group.add_row(name_row);
            bool recorded = false;
            properties_group.add_row(slider_row(_("Opacity"), 0, 100, 1, layer.opacity * 100, 0, (v) => {
                if (!recorded) {
                    document.record_structure(_("Opacity"));
                    recorded = true;
                }
                layer.opacity = (float) (v / 100);
                schedule_recomposite();
            }));
            string[] modes = {};
            for (int i = 0; i < BlendMode.COUNT; i++) modes += ((BlendMode) i).label();
            var mode_row = new IndexChoiceRow(_("Blend Mode"), modes, (uint) layer.mode);
            mode_row.notify["selected-index"].connect(() => {
                document.record_structure(_("Blend Mode"));
                layer.mode = (BlendMode) mode_row.selected_index;
                document.recomposite();
            });
            properties_group.add_row(mode_row);
            properties_group.add_row(switch_row(_("Lock"), layer.locked, (v) => {
                layer.locked = v;
                document.mark_modified();
                rebuild_layers();
            }));
            if (layer.mask == null) {
                properties_group.add_row(action_row(_("Add Layer Mask"), "singularity-retouch-mask-symbolic", () => add_mask(false)));
                if (document.selection != null) properties_group.add_row(action_row(_("Mask from Selection"), "singularity-retouch-mask-symbolic", () => add_mask(true)));
            } else {
                properties_group.add_row(switch_row(_("Mask Enabled"), layer.mask_enabled, (v) => {
                    document.record_structure(_("Mask"));
                    layer.mask_enabled = v;
                    document.recomposite();
                    rebuild_layers();
                }));
                properties_group.add_row(action_row(_("Paint Mask"), "singularity-markup-pen-symbolic", () => {
                    brush_kind = "mask";
                    select_tool("brush");
                }));
                properties_group.add_row(action_row(_("Invert Mask"), "object-flip-horizontal-symbolic", () => {
                    document.record_structure(_("Invert Mask"));
                    layer.mask = RetouchSelection.invert(layer.mask, document.width, document.height);
                    canvas.overlay_mask = layer.mask;
                    document.recomposite();
                }));
                properties_group.add_row(action_row(_("Mask from Luminance"), "display-brightness-symbolic", () => {
                    document.record_structure(_("Luminance Mask"));
                    layer.mask = RetouchSelection.luminance_range(document.composite, 0.5, 1.0, 0.25);
                    canvas.overlay_mask = layer.mask;
                    document.recomposite();
                }));
                properties_group.add_row(action_row(_("Load Mask as Selection"), "edit-select-all-symbolic", () => {
                    document.record_selection(_("Selection"));
                    document.selection = layer.mask.copy();
                    canvas.invalidate();
                }));
                properties_group.add_row(action_row(_("Delete Mask"), "user-trash-symbolic", () => {
                    document.record_structure(_("Delete Mask"));
                    layer.mask = null;
                    canvas.overlay_mask = null;
                    after_structure();
                }));
            }
            if (layer.kind == RetouchLayerKind.RASTER && document.layer_below(layer) != null)
                properties_group.add_row(action_row(_("Merge Down"), "go-down-symbolic", () => merge_down()));
            if (layer.kind == RetouchLayerKind.TEXT || layer.kind == RetouchLayerKind.EMBEDDED)
                properties_group.add_row(action_row(_("Rasterize Layer"), "singularity-retouch-layer-symbolic", () => rasterize_active()));
            switch (layer.kind) {
                case RetouchLayerKind.ADJUSTMENT: build_adjustment_controls(layer); break;
                case RetouchLayerKind.TEXT: build_text_controls(layer); break;
                case RetouchLayerKind.EMBEDDED: build_embedded_controls(layer); break;
                default: break;
            }
        }

        private void add_mask(bool from_selection) {
            var layer = controller.active;
            if (layer == null) return;
            document.record_structure(_("Add Mask"));
            layer.mask = from_selection && document.selection != null ? document.selection.copy() : document.full_plane(1.0f);
            layer.mask_enabled = true;
            canvas.overlay_mask = layer.mask;
            after_structure();
        }

        private void rasterize_active() {
            var layer = controller.active;
            if (layer == null) return;
            document.record_structure(_("Rasterize"));
            var pixels = document.render_layer_pixels(layer);
            layer.kind = RetouchLayerKind.RASTER;
            layer.pixels = pixels;
            layer.x = 0;
            layer.y = 0;
            layer.text = null;
            layer.source_uri = "";
            document.invalidate_layer(layer);
            after_structure();
        }

        private void build_adjustment_controls(RetouchLayer layer) {
            var adj = layer.adjustment;
            if (adj == null) return;
            content_group.visible = true;
            content_group.title = RetouchAdjustment.label_for(adj.kind);
            bool recorded = false;
            if (adj.kind == "curves") {
                var editor = new RetouchCurveEditor(adj.curves[0]);
                editor.changed.connect(() => {
                    if (!recorded) {
                        document.record_structure(_("Curves"));
                        recorded = true;
                    }
                    layer.adjustment = adj;
                    schedule_recomposite();
                });
                var row = new PreferencesRow();
                row.activatable = false;
                row.add_css_class("photo-retouch-static-row");
                row.child = editor;
                content_group.add_row(row);
                content_group.add_row(chips({ "0", "1", "2", "3" }, { _("RGB"), _("Red"), _("Green"), _("Blue") }, "0", (id) => {
                    editor.curve = adj.curves[int.parse(id)];
                }));
                return;
            }
            if (adj.kind == "develop") {
                for (int i = 0; i < Adjustment.COUNT; i++) {
                    var a = (Adjustment) i;
                    content_group.add_row(slider_row(a.label(), a.min_value() * 100, a.max_value() * 100, 1, adj.develop.get_value(a) * 100, 0, (v) => {
                        if (!recorded) {
                            document.record_structure(_("Develop"));
                            recorded = true;
                        }
                        adj.develop.set_value(a, v / 100);
                        schedule_recomposite();
                    }));
                }
                return;
            }
            foreach (unowned string key in RetouchAdjustment.keys_for(adj.kind)) {
                string k = key;
                double min, max, def;
                RetouchAdjustment.range_for(k, out min, out max, out def);
                if (k == "colorize") {
                    content_group.add_row(switch_row(RetouchAdjustment.key_label(k), adj.value_of(k) > 0.5, (v) => {
                        document.record_structure(_("Adjustment"));
                        adj.put(k, v ? 1 : 0);
                        document.recomposite();
                    }));
                    continue;
                }
                double step = (max - min) / 200;
                int digits = max - min > 50 ? 0 : 2;
                content_group.add_row(slider_row(RetouchAdjustment.key_label(k), min, max, step, adj.value_of(k), digits, (v) => {
                    if (!recorded) {
                        document.record_structure(_("Adjustment"));
                        recorded = true;
                    }
                    adj.put(k, v);
                    schedule_recomposite();
                }));
            }
        }

        private void build_text_controls(RetouchLayer layer) {
            if (layer.text == null) return;
            content_group.visible = true;
            content_group.title = _("Text");
            var view = new TextView();
            view.wrap_mode = WrapMode.WORD_CHAR;
            view.buffer.text = layer.text.text;
            view.top_margin = 8;
            view.bottom_margin = 8;
            view.left_margin = 8;
            view.right_margin = 8;
            view.height_request = 72;
            bool recorded = false;
            view.buffer.changed.connect(() => {
                if (!recorded) {
                    document.record_structure(_("Edit Text"));
                    recorded = true;
                }
                var t = layer.text.copy();
                t.text = view.buffer.text;
                layer.text = t;
                schedule_recomposite();
            });
            var holder = new PreferencesRow();
            holder.activatable = false;
            holder.add_css_class("photo-retouch-static-row");
            holder.child = view;
            content_group.add_row(holder);
            var font_button = new FontDialogButton(new FontDialog());
            font_button.font_desc = Pango.FontDescription.from_string(layer.text.font);
            font_button.valign = Align.CENTER;
            font_button.notify["font-desc"].connect(() => {
                document.record_structure(_("Font"));
                var t = layer.text.copy();
                t.font = font_button.font_desc.to_string();
                layer.text = t;
                document.recomposite();
            });
            var font_row = new ActionRow(_("Font"));
            font_row.add_suffix(font_button);
            content_group.add_row(font_row);
            var rgba = Gdk.RGBA();
            rgba.red = layer.text.r;
            rgba.green = layer.text.g;
            rgba.blue = layer.text.b;
            rgba.alpha = layer.text.a;
            var color_button = new ColorPickerButton(rgba);
            color_button.valign = Align.CENTER;
            color_button.color_changed.connect((c) => {
                document.record_structure(_("Text Color"));
                var t = layer.text.copy();
                t.r = c.red;
                t.g = c.green;
                t.b = c.blue;
                t.a = c.alpha;
                layer.text = t;
                document.recomposite();
            });
            var color_row = new ActionRow(_("Color"));
            color_row.add_suffix(color_button);
            content_group.add_row(color_row);
            content_group.add_row(chips({ "left", "center", "right" }, { _("Left"), _("Center"), _("Right") }, layer.text.align, (id) => {
                document.record_structure(_("Alignment"));
                var t = layer.text.copy();
                t.align = id;
                layer.text = t;
                document.recomposite();
            }));
            content_group.add_row(switch_row(_("Shadow"), layer.text.shadow, (v) => {
                document.record_structure(_("Shadow"));
                var t = layer.text.copy();
                t.shadow = v;
                layer.text = t;
                document.recomposite();
            }));
        }

        private void build_embedded_controls(RetouchLayer layer) {
            content_group.visible = true;
            content_group.title = _("Embedded Photo");
            string label = layer.source_uri != "" ? (File.new_for_uri(layer.source_uri).get_basename() ?? "") : _("Missing");
            var info = new ActionRow(label, layer.source_edit != "" ? _("Edited in Photos") : _("Original"), "image-x-generic-symbolic");
            content_group.add_row(info);
            content_group.add_row(action_row(_("Update from Source"), "view-refresh-symbolic", () => {
                document.record_structure(_("Update Embedded Photo"));
                var src = File.new_for_uri(layer.source_uri);
                var p = EditStore.load(src);
                layer.source_edit = p != null ? p.to_json() : "";
                int w0 = layer.pixels != null ? layer.pixels.width : 0;
                document.invalidate_layer(layer);
                document.layer_source(layer);
                if (w0 > 0 && layer.pixels != null && layer.pixels.width != w0) layer.embed_scale *= (double) w0 / layer.pixels.width;
                document.invalidate_layer(layer);
                document.recomposite();
            }));
        }

        private void rebuild_tool_options() {
            if (tool_group == null) return;
            tool_group.clear();
            tool_group.description = "";
            var tool = controller.tool;
            string id = "";
            foreach (var e in tool_buttons.entries) if (e.value.active) id = e.key;
            tool_group.title = _("Tool");
            switch (id) {
                case "select":
                    tool_group.add_row(chips({ "rect", "ellipse", "lasso", "polygon", "wand", "quick" },
                        { _("Rectangle"), _("Ellipse"), _("Lasso"), _("Polygon"), _("Magic Wand"), _("Quick") }, select_kind, (k) => {
                            select_kind = k;
                            controller.tool = select_tool_for(k);
                            rebuild_tool_options();
                        }));
                    tool_group.add_row(chips({ "new", "add", "subtract", "intersect" }, { _("New"), _("Add"), _("Subtract"), _("Intersect") },
                        controller.selection_op == SelectionOp.ADD ? "add" : controller.selection_op == SelectionOp.SUBTRACT ? "subtract" : controller.selection_op == SelectionOp.INTERSECT ? "intersect" : "new", (k) => {
                            controller.selection_op = k == "add" ? SelectionOp.ADD : k == "subtract" ? SelectionOp.SUBTRACT : k == "intersect" ? SelectionOp.INTERSECT : SelectionOp.REPLACE;
                        }));
                    if (tool == RetouchTool.MAGIC_WAND) {
                        tool_group.add_row(slider_row(_("Tolerance"), 0, 100, 1, controller.tolerance * 100, 0, (v) => controller.tolerance = v / 100));
                        tool_group.add_row(switch_row(_("Contiguous"), controller.contiguous, (v) => controller.contiguous = v));
                        tool_group.add_row(switch_row(_("Sample All Layers"), controller.sample_all, (v) => controller.sample_all = v));
                    } else if (tool == RetouchTool.QUICK_SELECT) {
                        tool_group.add_row(slider_row(_("Size"), 2, 500, 1, controller.brush_size, 0, (v) => { controller.brush_size = v; canvas.queue_draw(); }));
                    } else if (tool == RetouchTool.POLYGON) {
                        tool_group.add_row(action_row(_("Close Polygon (Enter)"), "object-select-symbolic", () => controller.close_polygon()));
                    }
                    break;
                case "brush":
                    tool_group.add_row(chips({ "paint", "erase", "mask" }, { _("Paint"), _("Erase"), _("Mask") }, brush_kind, (k) => {
                        brush_kind = k;
                        select_tool("brush");
                    }));
                    add_brush_options(true);
                    if (brush_kind == "paint") add_color_row();
                    if (brush_kind == "mask") {
                        tool_group.add_row(chips({ "hide", "reveal" }, { _("Hide"), _("Reveal") }, controller.mask_reveal ? "reveal" : "hide", (k) => controller.mask_reveal = k == "reveal"));
                    }
                    break;
                case "clone":
                case "heal":
                    add_brush_options(true);
                    tool_group.add_row(switch_row(_("Sample All Layers"), controller.sample_all, (v) => controller.sample_all = v));
                    tool_group.description = id == "clone" ? _("Ctrl+click to set the source, then paint") : _("Paint over a blemish to repair it, or Ctrl+click to choose a source first");
                    break;
                case "patch":
                    tool_group.description = _("Select an area, then drag toward the texture to use");
                    break;
                case "liquify":
                    tool_group.add_row(chips({ "forward", "pucker", "bloat", "twirl", "reconstruct", "smooth", "freeze", "thaw" },
                        { _("Push"), _("Pucker"), _("Bloat"), _("Twirl"), _("Restore"), _("Smooth"), _("Freeze"), _("Thaw") }, liquify_id(), (k) => {
                            controller.liquify_brush = liquify_from(k);
                        }));
                    add_brush_options(false);
                    if (controller.liquify != null) {
                        tool_group.add_row(action_row(_("Apply Liquify"), "object-select-symbolic", () => {
                            controller.apply_liquify();
                            select_tool("move");
                        }));
                        tool_group.add_row(action_row(_("Restore All"), "view-refresh-symbolic", () => controller.reset_liquify()));
                        tool_group.add_row(action_row(_("Cancel"), "window-close-symbolic", () => {
                            controller.cancel_liquify();
                            select_tool("move");
                        }));
                    }
                    break;
                case "transform":
                    tool_group.add_row(chips({ "free", "perspective", "warp" }, { _("Free"), _("Perspective"), _("Warp") },
                        controller.transform_mode == TransformMode.WARP ? "warp" : controller.transform_mode == TransformMode.PERSPECTIVE ? "perspective" : "free", (k) => {
                            controller.transform_mode = k == "warp" ? TransformMode.WARP : k == "perspective" ? TransformMode.PERSPECTIVE : TransformMode.FREE;
                            controller.setup_grid();
                            controller.preview_transform();
                        }));
                    if (controller.transforming) {
                        tool_group.add_row(action_row(_("Apply Transform (Enter)"), "object-select-symbolic", () => {
                            controller.apply_transform();
                            select_tool("move");
                        }));
                        tool_group.add_row(action_row(_("Cancel"), "window-close-symbolic", () => {
                            controller.cancel_transform();
                            select_tool("move");
                        }));
                    }
                    break;
                case "text":
                    tool_group.description = _("Click on the photo to add a caption");
                    add_color_row();
                    break;
                case "eyedropper":
                    add_color_row();
                    break;
                default:
                    tool_group.description = _("Drag to move the selected layer; Space or the middle button pans");
                    break;
            }
        }

        private string liquify_id() {
            switch (controller.liquify_brush) {
                case LiquifyBrush.PUCKER: return "pucker";
                case LiquifyBrush.BLOAT: return "bloat";
                case LiquifyBrush.TWIRL_CLOCKWISE: return "twirl";
                case LiquifyBrush.RECONSTRUCT: return "reconstruct";
                case LiquifyBrush.SMOOTH: return "smooth";
                case LiquifyBrush.FREEZE: return "freeze";
                case LiquifyBrush.THAW: return "thaw";
                default: return "forward";
            }
        }

        private LiquifyBrush liquify_from(string k) {
            switch (k) {
                case "pucker": return LiquifyBrush.PUCKER;
                case "bloat": return LiquifyBrush.BLOAT;
                case "twirl": return LiquifyBrush.TWIRL_CLOCKWISE;
                case "reconstruct": return LiquifyBrush.RECONSTRUCT;
                case "smooth": return LiquifyBrush.SMOOTH;
                case "freeze": return LiquifyBrush.FREEZE;
                case "thaw": return LiquifyBrush.THAW;
                default: return LiquifyBrush.FORWARD;
            }
        }

        private void add_brush_options(bool hardness) {
            tool_group.add_row(slider_row(_("Size"), 1, 800, 1, controller.brush_size, 0, (v) => {
                controller.brush_size = v;
                canvas.queue_draw();
            }));
            if (hardness) tool_group.add_row(slider_row(_("Hardness"), 0, 100, 1, controller.hardness * 100, 0, (v) => controller.hardness = v / 100));
            tool_group.add_row(slider_row(hardness ? _("Opacity") : _("Pressure"), 1, 100, 1, controller.brush_opacity * 100, 0, (v) => controller.brush_opacity = v / 100));
        }

        private ColorPickerButton? color_button = null;

        private void add_color_row() {
            var rgba = Gdk.RGBA();
            rgba.red = controller.fg_r;
            rgba.green = controller.fg_g;
            rgba.blue = controller.fg_b;
            rgba.alpha = 1;
            color_button = new ColorPickerButton(rgba);
            color_button.valign = Align.CENTER;
            color_button.color_changed.connect((c) => controller.set_color(c.red, c.green, c.blue));
            controller.color_picked.connect(() => {
                if (color_button == null) return;
                var c = Gdk.RGBA();
                c.red = controller.fg_r;
                c.green = controller.fg_g;
                c.blue = controller.fg_b;
                c.alpha = 1;
                color_button.color = c;
            });
            var row = new ActionRow(_("Color"));
            row.add_suffix(color_button);
            tool_group.add_row(row);
        }

        private double feather_radius = 8;
        private double expand_amount = 4;

        private void rebuild_selection() {
            selection_group.clear();
            selection_group.add_row(action_row(_("Select All (Ctrl+A)"), "edit-select-all-symbolic", () => select_all()));
            selection_group.add_row(action_row(_("Deselect (Ctrl+D)"), "edit-clear-symbolic", () => deselect()));
            selection_group.add_row(action_row(_("Invert Selection"), "object-flip-horizontal-symbolic", () => invert_selection()));
            selection_group.add_row(action_row(_("Select Subject"), "avatar-default-symbolic", () => select_segment(false)));
            selection_group.add_row(action_row(_("Select Sky"), "weather-clear-symbolic", () => select_segment(true)));
            selection_group.add_row(slider_row(_("Feather and Refine Radius"), 0, 200, 1, feather_radius, 0, (v) => feather_radius = v));
            selection_group.add_row(action_row(_("Feather"), "singularity-photos-filters-symbolic", () => modify_selection("feather")));
            selection_group.add_row(action_row(_("Refine Edge"), "singularity-photos-enhance-symbolic", () => modify_selection("refine")));
            selection_group.add_row(action_row(_("Smooth"), "singularity-markup-ellipse-symbolic", () => modify_selection("smooth")));
            selection_group.add_row(slider_row(_("Expand or Contract"), -100, 100, 1, expand_amount, 0, (v) => expand_amount = v));
            selection_group.add_row(action_row(_("Apply Expand or Contract"), "zoom-in-symbolic", () => modify_selection("expand")));
            selection_group.add_row(action_row(_("Content-Aware Fill"), "singularity-photos-enhance-symbolic", () => content_aware_fill()));
            var gen = action_row(_("Generative Fill"), "singularity-retouch-patch-symbolic", () => generative_fill());
            gen.subtitle = _("Several fills to choose from, made on this device");
            selection_group.add_row(gen);
            selection_group.add_row(action_row(_("Fill with Color"), "color-select-symbolic", () => fill_selection()));
            selection_group.add_row(action_row(_("Delete Pixels"), "edit-delete-symbolic", () => clear_selection_pixels()));
            selection_group.add_row(action_row(_("Layer via Copy"), "edit-copy-symbolic", () => layer_via(false)));
            selection_group.add_row(action_row(_("Layer via Cut"), "edit-cut-symbolic", () => layer_via(true)));
        }

        private double freq_radius = 6;

        private void rebuild_actions() {
            actions_group.clear();
            actions_group.add_row(slider_row(_("Frequency Separation Radius"), 1, 60, 0.5, freq_radius, 1, (v) => freq_radius = v));
            actions_group.add_row(action_row(_("Frequency Separation"), "singularity-photos-filters-symbolic", () => frequency_separation()));
            actions_group.add_row(action_row(_("Stamp Visible"), "edit-paste-symbolic", () => stamp_visible()));
            actions_group.add_row(action_row(_("Flatten Image"), "view-paged-symbolic", () => flatten()));
            var draw = action_row(_("Edit in Draw"), "dev.sinty.draw", () => send_to(RetouchExternal.DRAW_ID));
            draw.sensitive = RetouchExternal.available(RetouchExternal.DRAW_ID);
            actions_group.add_row(draw);
            actions_group.add_row(action_row(_("Save Layers as PSD…"), "document-save-as-symbolic", () => save_as_psd()));
            actions_group.add_row(action_row(_("Export Flattened Copy"), "document-save-symbolic", () => export_flattened()));
        }

        private bool need_selection() {
            if (document == null) return false;
            if (document.selection == null) {
                message(_("Make a selection first"));
                return false;
            }
            return true;
        }

        public void select_all() {
            if (document == null) return;
            document.record_selection(_("Select All"));
            document.selection = document.full_plane(1.0f);
            canvas.invalidate();
        }

        public void deselect() {
            if (document == null || document.selection == null) return;
            document.record_selection(_("Deselect"));
            document.selection = null;
            canvas.invalidate();
        }

        public void invert_selection() {
            if (document == null) return;
            document.record_selection(_("Invert Selection"));
            document.selection = RetouchSelection.invert(document.selection, document.width, document.height);
            if (RetouchSelection.is_empty(document.selection)) document.selection = null;
            canvas.invalidate();
        }

        private void run_busy(string label, owned ThreadWork work, owned Singularity.Widgets.Window.BubbleAction done) {
            if (busy) return;
            busy = true;
            spinner.spinning = true;
            new Thread<void>("photo-retouch-" + label, () => {
                work();
                Idle.add(() => {
                    busy = false;
                    spinner.spinning = false;
                    done();
                    return Source.REMOVE;
                });
            });
        }

        private delegate void ThreadWork();

        public void select_segment(bool sky) {
            if (document == null) return;
            float[]? result = null;
            var comp = document.composite;
            run_busy("segment", () => {
                result = RetouchSelection.from_segmentation(comp, sky);
            }, () => {
                if (RetouchSelection.is_empty(result)) {
                    message(sky ? _("No sky was found in this photo") : _("No clear subject was found in this photo"));
                    return;
                }
                document.record_selection(sky ? _("Select Sky") : _("Select Subject"));
                controller.apply_selection(result, controller.selection_op);
            });
        }

        public void modify_selection(string op) {
            if (!need_selection()) return;
            var sel = document.selection;
            int w = document.width, h = document.height;
            var comp = document.composite;
            double radius = feather_radius, amount = expand_amount;
            float[]? result = null;
            run_busy("select", () => {
                switch (op) {
                    case "feather": result = RetouchSelection.feather(sel, w, h, radius / 2); break;
                    case "refine": result = RetouchSelection.refine_edge(comp, sel, double.max(1, radius), 0.3); break;
                    case "smooth": result = RetouchSelection.smooth(sel, w, h, double.max(1, radius / 2)); break;
                    default: result = RetouchSelection.expand(sel, w, h, amount); break;
                }
            }, () => {
                document.record_selection(_("Modify Selection"));
                document.selection = RetouchSelection.is_empty(result) ? null : result;
                canvas.invalidate();
            });
        }

        private RetouchLayer? editable_pixels() {
            var layer = controller.active;
            if (layer == null || layer.locked || layer.kind != RetouchLayerKind.RASTER || layer.pixels == null) {
                message(_("Select an unlocked pixel layer"));
                return null;
            }
            return layer;
        }

        public void content_aware_fill() {
            if (!need_selection()) return;
            var layer = editable_pixels();
            if (layer == null) return;
            var before = layer.pixels.copy();
            var sel = document.selection;
            run_busy("fill", () => {
                RetouchOps.content_aware_fill(document, layer, sel);
            }, () => {
                var after = layer.pixels;
                layer.pixels = before;
                document.record_structure(_("Content-Aware Fill"));
                layer.pixels = after;
                document.recomposite();
                update_history();
            });
        }

        private Gee.ArrayList<FloatImage> gen_pieces = new Gee.ArrayList<FloatImage>();
        private int[] gen_offsets = {};
        private float[]? gen_mask = null;
        private RetouchLayer? gen_layer = null;
        private FloatImage? gen_original = null;
        private int gen_current = 0;

        public bool generating {
            get { return gen_layer != null; }
        }

        private float[] fill_mask(RetouchLayer layer) {
            var mask = RetouchOps.selection_in_layer(document, layer, document.selection);
            var hard = new float[mask.length];
            for (size_t i = 0; i < mask.length; i++) hard[i] = mask[i] > 0.02f ? 1 : 0;
            return RetouchSelection.expand(hard, layer.pixels.width, layer.pixels.height, 2);
        }

        public void generative_fill() {
            if (!need_selection()) return;
            var layer = editable_pixels();
            if (layer == null) return;
            if (gen_layer != null) cancel_generative();
            gen_layer = layer;
            gen_original = layer.pixels;
            gen_mask = fill_mask(layer);
            gen_pieces.clear();
            gen_offsets = {};
            more_variants(3);
        }

        public void more_variants(int count) {
            if (gen_layer == null) return;
            var original = gen_original;
            var mask = gen_mask;
            int start = gen_pieces.size;
            var made = new Gee.ArrayList<FloatImage>();
            int[] offsets = {};
            run_busy("generate", () => {
                for (int i = 0; i < count; i++) {
                    int ox, oy;
                    made.add(RetouchOps.fill_variant(original, mask, start + i, out ox, out oy));
                    offsets += ox;
                    offsets += oy;
                }
            }, () => {
                if (gen_layer == null) return;
                gen_pieces.add_all(made);
                int[] all = gen_offsets;
                foreach (int v in offsets) all += v;
                gen_offsets = all;
                show_variant(start);
                message(_("%d fills ready").printf(gen_pieces.size));
            });
        }

        public int variant_count() {
            return gen_pieces.size;
        }

        public void show_variant(int index) {
            if (gen_layer == null || index < 0 || index >= gen_pieces.size) return;
            gen_current = index;
            var copy = gen_original.copy();
            RetouchOps.apply_variant(copy, gen_mask, gen_pieces[index], gen_offsets[index * 2], gen_offsets[index * 2 + 1]);
            gen_layer.pixels = copy;
            document.recomposite();
            rebuild_generative();
        }

        public void apply_generative() {
            if (gen_layer == null) return;
            var chosen = gen_layer.pixels;
            gen_layer.pixels = gen_original;
            document.record_structure(_("Generative Fill"));
            gen_layer.pixels = chosen;
            finish_generative();
            document.recomposite();
            update_history();
        }

        public void cancel_generative() {
            if (gen_layer == null) return;
            gen_layer.pixels = gen_original;
            finish_generative();
            document.recomposite();
        }

        private void finish_generative() {
            gen_layer = null;
            gen_original = null;
            gen_mask = null;
            gen_pieces.clear();
            gen_offsets = {};
            rebuild_properties();
        }

        private void rebuild_generative() {
            if (gen_layer == null) return;
            content_group.clear();
            content_group.visible = true;
            content_group.title = _("Generative Fill");
            content_group.description = _("Each fill is rebuilt from different parts of the photo. No data leaves this device.");
            string[] ids = {};
            string[] labels = {};
            for (int i = 0; i < gen_pieces.size; i++) {
                ids += i.to_string();
                labels += _("Fill %d").printf(i + 1);
            }
            content_group.add_row(chips(ids, labels, gen_current.to_string(), (id) => show_variant(int.parse(id))));
            content_group.add_row(action_row(_("More Fills"), "view-refresh-symbolic", () => more_variants(3)));
            content_group.add_row(action_row(_("Apply"), "object-select-symbolic", () => apply_generative()));
            content_group.add_row(action_row(_("Cancel"), "window-close-symbolic", () => cancel_generative()));
        }

        public void fill_selection() {
            if (!need_selection()) return;
            var layer = editable_pixels();
            if (layer == null) return;
            float r, g, b;
            RetouchColor.pixel_to_working(controller.fg_r, controller.fg_g, controller.fg_b, out r, out g, out b);
            var copy = layer.pixels.copy();
            var old = layer.pixels;
            document.record_structure(_("Fill"));
            layer.pixels = copy;
            RetouchOps.fill_selection(layer, document, document.selection, r, g, b, 1);
            if (layer.pixels == old) return;
            document.recomposite();
            update_history();
        }

        public void clear_selection_pixels() {
            if (!need_selection()) return;
            var layer = editable_pixels();
            if (layer == null) return;
            document.record_structure(_("Delete Pixels"));
            layer.pixels = layer.pixels.copy();
            RetouchOps.clear_selection(layer, document, document.selection);
            document.recomposite();
            update_history();
        }

        public void layer_via(bool cut) {
            if (!need_selection()) return;
            var layer = editable_pixels();
            if (layer == null) return;
            document.record_structure(cut ? _("Layer via Cut") : _("Layer via Copy"));
            if (cut) layer.pixels = layer.pixels.copy();
            var nl = RetouchOps.layer_from_selection(document, layer, document.selection, cut);
            document.add_layer(nl, layer);
            after_structure(nl);
        }

        public void frequency_separation() {
            var layer = controller.active;
            if (document == null || layer == null || layer.kind == RetouchLayerKind.GROUP || layer.kind == RetouchLayerKind.ADJUSTMENT) {
                message(_("Select a pixel layer"));
                return;
            }
            RetouchLayer[]? made = null;
            double radius = freq_radius;
            run_busy("frequency", () => {
                made = RetouchOps.frequency_separation(document, layer, radius);
            }, () => {
                document.record_structure(_("Frequency Separation"));
                var group = new RetouchLayer(_("Frequency Separation"), RetouchLayerKind.GROUP);
                group.children.add(made[0]);
                group.children.add(made[1]);
                document.add_layer(group, layer);
                layer.visible = false;
                after_structure(made[1]);
            });
        }

        public void stamp_visible() {
            if (document == null) return;
            document.record_structure(_("Stamp Visible"));
            var layer = document.stamp_visible();
            document.add_layer(layer, null);
            after_structure(layer);
        }

        public void flatten() {
            if (document == null) return;
            document.record_structure(_("Flatten Image"));
            var layer = document.flatten_to_layer();
            document.layers.clear();
            document.layers.add(layer);
            after_structure(layer);
        }

        public void send_to(string app_id) {
            if (document == null) return;
            if (external != null) external.stop();
            external = new RetouchExternal();
            string stem = stem_of(file);
            external.returned.connect((img) => {
                document.record_structure(_("Returned from %s").printf(external.app_name));
                var layer = new RetouchLayer(_("From %s").printf(external.app_name), RetouchLayerKind.RASTER);
                layer.pixels = img.width == document.width && img.height == document.height ? img : img.resized(document.width, document.height);
                var existing = find_returned(external.app_name);
                if (existing != null) {
                    existing.pixels = layer.pixels;
                    after_structure(existing);
                } else {
                    document.add_layer(layer, null);
                    after_structure(layer);
                }
                message(_("Updated from %s").printf(external.app_name));
            });
            try {
                external.send(document, app_id, stem);
                message(_("Opened in %s. Save there to bring the changes back.").printf(external.app_name));
            } catch (Error e) {
                message(e.message);
            }
        }

        private RetouchLayer? find_returned(string app_name) {
            string wanted = _("From %s").printf(app_name);
            foreach (var l in document.layers) if (l.name == wanted && l.kind == RetouchLayerKind.RASTER) return l;
            return null;
        }

        private static string stem_of(File f) {
            string name = f.get_basename() ?? "photo";
            int dot = name.last_index_of_char('.');
            string stem = dot > 0 ? name.substring(0, dot) : name;
            string suffix = _(" (Retouched)");
            if (stem.has_suffix(suffix)) stem = stem.substring(0, stem.length - suffix.length);
            return stem;
        }

        public static File version_target(File original, string extension) {
            var parent = original.get_parent() ?? File.new_for_path(Environment.get_home_dir());
            string stem = stem_of(original);
            var candidate = parent.get_child(_("%s (Retouched)").printf(stem) + extension);
            int n = 2;
            while (candidate.query_exists()) {
                candidate = parent.get_child(_("%s (Retouched %d)").printf(stem, n) + extension);
                n++;
            }
            return candidate;
        }

        public bool is_modified() {
            return document != null && document.modifications != saved_modifications;
        }

        private File save_target() {
            if (saved_file != null) return saved_file;
            string name = (file.get_basename() ?? "").down();
            if (name.has_suffix(".ora")) return file;
            return version_target(file, ".ora");
        }

        public void save() {
            if (busy || document == null) return;
            if (controller.transforming) controller.apply_transform();
            if (controller.liquify != null) controller.apply_liquify();
            if (gen_layer != null) apply_generative();
            if (!is_modified() && saved_file == null) {
                finished(false);
                return;
            }
            var target = save_target();
            string? error = null;
            var doc = document;
            run_busy("save", () => {
                try {
                    var data = RetouchOra.save(doc);
                    string partial = "%s.%u.part".printf(target.get_path(), Random.next_int());
                    FileUtils.set_data(partial, data);
                    if (FileUtils.rename(partial, target.get_path()) != 0) {
                        FileUtils.remove(partial);
                        error = _("Could not write the file");
                    }
                } catch (Error e) {
                    error = e.message;
                }
            }, () => {
                if (error != null) {
                    message(_("Could not save: %s").printf(error));
                    return;
                }
                saved_file = target;
                saved_modifications = doc.modifications;
                message(_("Saved as %s").printf(target.get_basename()));
                finished(true);
            });
        }

        public void save_as_psd() {
            if (document == null) return;
            var target = version_target(file, ".psd");
            var doc = document;
            string? error = null;
            run_busy("psd", () => {
                try {
                    FileUtils.set_data(target.get_path(), RetouchPsd.write(doc));
                } catch (Error e) {
                    error = e.message;
                }
            }, () => {
                message(error != null ? _("Could not save: %s").printf(error) : _("Saved as %s").printf(target.get_basename()));
            });
        }

        public void export_flattened() {
            if (document == null) return;
            bool jpeg = !document.composite.is_opaque() ? false : true;
            var target = version_target(file, jpeg ? ".jpg" : ".png");
            var comp = document.composite.copy();
            string? error = null;
            run_busy("export", () => {
                try {
                    var tex = RetouchColor.to_texture8(comp);
                    if (jpeg) {
                        var bytes = tex.save_to_png_bytes();
                        var loader = new Gdk.PixbufLoader();
                        loader.write(bytes.get_data());
                        loader.close();
                        var pb = loader.get_pixbuf();
                        if (pb.has_alpha) pb = pb.add_alpha(false, 0, 0, 0);
                        var flat = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, pb.width, pb.height);
                        pb.copy_area(0, 0, pb.width, pb.height, flat, 0, 0);
                        flat.savev(target.get_path(), "jpeg", { "quality" }, { "95" });
                    } else {
                        tex.save_to_png(target.get_path());
                    }
                } catch (Error e) {
                    error = e.message;
                }
            }, () => {
                message(error != null ? _("Could not save: %s").printf(error) : _("Saved as %s").printf(target.get_basename()));
            });
        }

        public void cancel() {
            if (controller.transforming) controller.cancel_transform();
            if (controller.liquify != null) controller.cancel_liquify();
            if (external != null) external.stop();
            finished(saved_file != null);
        }

        private bool on_key(uint keyval, uint keycode, Gdk.ModifierType state) {
            if (document == null) return false;
            var focus = get_root() != null ? ((Gtk.Window) get_root()).get_focus() : null;
            if (focus is Gtk.Text || focus is Gtk.TextView) return false;
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            if (ctrl) {
                switch (keyval) {
                    case Gdk.Key.z:
                    case Gdk.Key.Z:
                        if (shift) redo(); else undo();
                        return true;
                    case Gdk.Key.y:
                        redo();
                        return true;
                    case Gdk.Key.a:
                        select_all();
                        return true;
                    case Gdk.Key.d:
                        deselect();
                        return true;
                    case Gdk.Key.i:
                    case Gdk.Key.I:
                        if (shift) {
                            invert_selection();
                            return true;
                        }
                        return false;
                    case Gdk.Key.j:
                        duplicate_layer();
                        return true;
                    case Gdk.Key.s:
                        save();
                        return true;
                    case Gdk.Key.@0:
                        canvas.fit();
                        return true;
                    case Gdk.Key.@1:
                        canvas.apply_zoom(1.0);
                        return true;
                    case Gdk.Key.plus:
                    case Gdk.Key.equal:
                        canvas.apply_zoom(canvas.zoom * 1.25);
                        return true;
                    case Gdk.Key.minus:
                        canvas.apply_zoom(canvas.zoom / 1.25);
                        return true;
                    default:
                        return false;
                }
            }
            switch (keyval) {
                case Gdk.Key.Return:
                case Gdk.Key.KP_Enter:
                    if (controller.transforming) {
                        controller.apply_transform();
                        select_tool("move");
                        return true;
                    }
                    if (controller.tool == RetouchTool.POLYGON) {
                        controller.close_polygon(state);
                        return true;
                    }
                    return false;
                case Gdk.Key.Escape:
                    if (controller.transforming) {
                        controller.cancel_transform();
                        select_tool("move");
                        return true;
                    }
                    if (controller.tool == RetouchTool.POLYGON) {
                        controller.cancel_polygon();
                        return true;
                    }
                    return false;
                case Gdk.Key.Delete:
                case Gdk.Key.BackSpace:
                    if (document.selection != null) clear_selection_pixels();
                    return true;
                case Gdk.Key.bracketleft:
                    controller.brush_size = double.max(1, controller.brush_size / 1.2);
                    rebuild_tool_options();
                    canvas.queue_draw();
                    return true;
                case Gdk.Key.bracketright:
                    controller.brush_size = double.min(800, controller.brush_size * 1.2);
                    rebuild_tool_options();
                    canvas.queue_draw();
                    return true;
                case Gdk.Key.v: select_tool("move"); return true;
                case Gdk.Key.m: select_kind = "rect"; select_tool("select"); return true;
                case Gdk.Key.l: select_kind = "lasso"; select_tool("select"); return true;
                case Gdk.Key.w: select_kind = "wand"; select_tool("select"); return true;
                case Gdk.Key.b: brush_kind = "paint"; select_tool("brush"); return true;
                case Gdk.Key.e: brush_kind = "erase"; select_tool("brush"); return true;
                case Gdk.Key.s: select_tool("clone"); return true;
                case Gdk.Key.j: select_tool("heal"); return true;
                case Gdk.Key.t: select_tool("transform"); return true;
                case Gdk.Key.i: select_tool("eyedropper"); return true;
                default: return false;
            }
        }
    }

    public class RetouchCurveEditor : Widget {
        private CurvePoints _curve;
        public CurvePoints curve {
            get { return _curve; }
            set {
                _curve = value;
                queue_draw();
            }
        }

        public signal void changed();

        private int dragging = -1;

        public RetouchCurveEditor(CurvePoints curve) {
            _curve = curve;
            height_request = 240;
            hexpand = true;
            margin_start = 12;
            margin_end = 12;
            margin_top = 12;
            margin_bottom = 12;
            var drag = new GestureDrag();
            drag.drag_begin.connect((x, y) => {
                double cx = (x / get_width()).clamp(0, 1), cy = (1 - y / get_height()).clamp(0, 1);
                dragging = nearest(cx, cy);
                if (dragging < 0) {
                    ensure_endpoints();
                    _curve.add(cx, cy);
                    dragging = nearest(cx, cy);
                    changed();
                }
                queue_draw();
            });
            drag.drag_update.connect((ox, oy) => {
                if (dragging < 0) return;
                double sx, sy;
                drag.get_start_point(out sx, out sy);
                double cx = ((sx + ox) / get_width()).clamp(0, 1), cy = (1 - (sy + oy) / get_height()).clamp(0, 1);
                double[] xs = _curve.xs, ys = _curve.ys;
                double lo = dragging > 0 ? xs[dragging - 1] + 0.01 : 0;
                double hi = dragging < xs.length - 1 ? xs[dragging + 1] - 0.01 : 1;
                xs[dragging] = cx.clamp(lo, hi);
                ys[dragging] = cy;
                _curve.xs = xs;
                _curve.ys = ys;
                changed();
                queue_draw();
            });
            drag.drag_end.connect(() => dragging = -1);
            add_controller(drag);
            var click = new GestureClick();
            click.pressed.connect((n, x, y) => {
                if (n != 2) return;
                int i = nearest((x / get_width()).clamp(0, 1), (1 - y / get_height()).clamp(0, 1));
                if (i > 0 && i < _curve.xs.length - 1) {
                    _curve.remove_at(i);
                    changed();
                    queue_draw();
                }
            });
            add_controller(click);
        }

        private void ensure_endpoints() {
            if (_curve.xs.length == 0) {
                _curve.add(0, 0);
                _curve.add(1, 1);
            }
        }

        private int nearest(double x, double y) {
            for (int i = 0; i < _curve.xs.length; i++) {
                if ((_curve.xs[i] - x).abs() < 0.04 && (_curve.ys[i] - y).abs() < 0.06) return i;
            }
            return -1;
        }

        public override void snapshot(Snapshot snapshot) {
            float w = get_width(), h = get_height();
            var bounds = Graphene.Rect();
            bounds.init(0, 0, w, h);
            var cr = snapshot.append_cairo(bounds);
            var fg = get_color();
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.08);
            cr.rectangle(0, 0, w, h);
            cr.fill();
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.18);
            cr.set_line_width(1);
            for (int i = 1; i < 4; i++) {
                cr.move_to(w * i / 4, 0);
                cr.line_to(w * i / 4, h);
                cr.move_to(0, h * i / 4);
                cr.line_to(w, h * i / 4);
            }
            cr.stroke();
            var lut = _curve.lut(256);
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.9);
            cr.set_line_width(2);
            for (int i = 0; i < 256; i++) {
                double x = w * i / 255.0, y = h * (1 - lut[i]);
                if (i == 0) cr.move_to(x, y);
                else cr.line_to(x, y);
            }
            cr.stroke();
            for (int i = 0; i < _curve.xs.length; i++) {
                cr.arc(w * _curve.xs[i], h * (1 - _curve.ys[i]), 5, 0, 2 * Math.PI);
                cr.fill();
            }
        }
    }
}
