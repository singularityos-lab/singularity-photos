using Gtk;

namespace Singularity.Apps.Photos {

    public class EditCanvas : Widget {
        public enum Mode {
            VIEW,
            CROP,
            COMPARE
        }

        private enum Handle {
            NONE,
            MOVE,
            TOP_LEFT,
            TOP,
            TOP_RIGHT,
            RIGHT,
            BOTTOM_RIGHT,
            BOTTOM,
            BOTTOM_LEFT,
            LEFT,
            DIVIDER
        }

        private const double PADDING = 28.0;
        private const double TOP_INSET = 60.0;
        private const double BOTTOM_INSET = 84.0;
        private const double HANDLE_REACH = 18.0;

        public Gdk.Texture? edited { get; set; }
        public Gdk.Texture? before { get; set; }
        public Gdk.Texture? uncropped { get; set; }
        public double divider { get; set; default = 0.5; }
        public double aspect { get; set; default = 0.0; }

        private Mode _mode = Mode.VIEW;
        public Mode mode {
            get { return _mode; }
            set {
                _mode = value;
                update_cursor();
                queue_draw();
            }
        }

        public double crop_x = 0.0;
        public double crop_y = 0.0;
        public double crop_w = 1.0;
        public double crop_h = 1.0;

        public signal void crop_changed();
        public signal void edit_begin();
        public signal void picked(double nx, double ny);
        public signal void strokes_changed(bool finished);
        public signal void gradient_changed(bool finished);
        public signal void spots_changed(bool finished);
        public signal void spot_selected(int index);
        public signal void guides_changed(bool finished);
        public double[] guides = {};

        public GeometryMap? geometry { get; set; }
        public string tool { get; set; default = ""; }
        public MaskComponent? component { get; set; }
        public Gdk.Texture? mask_overlay { get; set; }
        public bool show_overlay { get; set; default = true; }
        public Gee.ArrayList<SpotEdit>? spots { get; set; }
        public int selected_spot { get; set; default = -1; }
        public double brush_radius { get; set; default = 0.03; }
        public double brush_feather { get; set; default = 0.5; }
        public double brush_flow { get; set; default = 1.0; }
        public bool brush_erase { get; set; default = false; }
        public string spot_mode { get; set; default = "heal"; }
        public double spot_radius { get; set; default = 0.02; }

        private BrushStroke? current_stroke = null;
        private string tool_handle = "";
        private double tool_start_x;
        private double tool_start_y;
        private double cursor_x = -1;
        private double cursor_y = -1;
        private Gee.HashMap<string, double?> tool_origin = new Gee.HashMap<string, double?>();

        private Handle drag_handle = Handle.NONE;
        private double drag_start_x;
        private double drag_start_y;
        private double start_cx;
        private double start_cy;
        private double start_cw;
        private double start_ch;

        construct {
            hexpand = true;
            vexpand = true;
            add_css_class("photo-edit-canvas");
            notify["edited"].connect(queue_draw);
            notify["before"].connect(queue_draw);
            notify["uncropped"].connect(queue_draw);
            notify["divider"].connect(queue_draw);
            notify["mask-overlay"].connect(queue_draw);
            notify["show-overlay"].connect(queue_draw);
            notify["component"].connect(queue_draw);
            notify["spots"].connect(queue_draw);
            notify["selected-spot"].connect(queue_draw);
            notify["tool"].connect(() => {
                set_cursor_from_name(tool == "" ? null : "crosshair");
                queue_draw();
            });

            var drag = new GestureDrag();
            drag.drag_begin.connect((x, y) => {
                if (tool != "" && _mode == Mode.VIEW) tool_begin(x, y);
                else on_drag_begin(x, y);
            });
            drag.drag_update.connect((dx, dy) => {
                if (tool_handle != "") tool_update(dx, dy);
                else on_drag_update(dx, dy);
            });
            drag.drag_end.connect((x, y) => {
                if (tool_handle != "") {
                    tool_end();
                    return;
                }
                if (drag_handle != Handle.NONE && drag_handle != Handle.DIVIDER) crop_changed();
                drag_handle = Handle.NONE;
            });
            add_controller(drag);

            var motion = new EventControllerMotion();
            motion.motion.connect((x, y) => {
                cursor_x = x;
                cursor_y = y;
                if (tool != "" && _mode == Mode.VIEW) {
                    if (tool == "brush") queue_draw();
                    return;
                }
                if (drag_handle != Handle.NONE) return;
                set_cursor_from_name(cursor_for(hit_test(x, y)));
            });
            motion.leave.connect(() => {
                cursor_x = -1;
                queue_draw();
            });
            add_controller(motion);
        }

        private Gdk.Texture? shown() {
            if (_mode == Mode.CROP && uncropped != null) return uncropped;
            return edited;
        }

        public bool image_rect(out Graphene.Rect rect) {
            rect = Graphene.Rect();
            var tex = shown();
            if (tex == null) return false;
            double aw = get_width() - PADDING * 2, ah = get_height() - TOP_INSET - BOTTOM_INSET;
            if (aw <= 1 || ah <= 1) return false;
            double tw = tex.width, th = tex.height;
            double s = double.min(aw / tw, ah / th);
            double w = tw * s, h = th * s;
            rect.init((float) ((get_width() - w) / 2), (float) (TOP_INSET + (ah - h) / 2), (float) w, (float) h);
            return true;
        }

        public void crop_rect(out Graphene.Rect rect) {
            Graphene.Rect img;
            rect = Graphene.Rect();
            if (!image_rect(out img)) return;
            rect.init((float) (img.origin.x + crop_x * img.size.width),
                      (float) (img.origin.y + crop_y * img.size.height),
                      (float) (crop_w * img.size.width),
                      (float) (crop_h * img.size.height));
        }

        public override void snapshot(Snapshot snapshot) {
            var tex = shown();
            if (tex == null) return;
            Graphene.Rect img;
            if (!image_rect(out img)) return;
            snapshot.append_scaled_texture(tex, Gsk.ScalingFilter.LINEAR, img);
            if (_mode == Mode.COMPARE && before != null) draw_compare(snapshot, img);
            else if (_mode == Mode.CROP) draw_crop(snapshot, img);
            else draw_tools(snapshot, img);
        }

        private void draw_compare(Snapshot snapshot, Graphene.Rect img) {
            float split = (float) (img.size.width * divider);
            var clip = Graphene.Rect();
            clip.init(img.origin.x, img.origin.y, split, img.size.height);
            snapshot.push_clip(clip);
            snapshot.append_scaled_texture(before, Gsk.ScalingFilter.LINEAR, img);
            snapshot.pop();
            var white = Gdk.RGBA();
            white.parse("white");
            var line = Graphene.Rect();
            line.init(img.origin.x + split - 1, img.origin.y, 2, img.size.height);
            snapshot.append_color(white, line);
            float cx = img.origin.x + split, cy = img.origin.y + img.size.height / 2;
            var knob = Graphene.Rect();
            knob.init(cx - 14, cy - 14, 28, 28);
            var rounded = Gsk.RoundedRect();
            rounded.init_from_rect(knob, 14);
            var shadow = Gdk.RGBA();
            shadow.parse("rgba(0,0,0,0.35)");
            snapshot.append_outset_shadow(rounded, shadow, 0, 2, 0, 6);
            snapshot.push_rounded_clip(rounded);
            snapshot.append_color(white, knob);
            snapshot.pop();
            var dark = Gdk.RGBA();
            dark.parse("#3a3a3a");
            var bar = Graphene.Rect();
            bar.init(cx - 5, cy - 6, 2, 12);
            snapshot.append_color(dark, bar);
            bar.init(cx + 3, cy - 6, 2, 12);
            snapshot.append_color(dark, bar);
            draw_tag(snapshot, _("Before"), img.origin.x + 12, img.origin.y + 12, split > 90);
            draw_tag(snapshot, _("After"), img.origin.x + img.size.width - 12, img.origin.y + 12, img.size.width - split > 90, true);
        }

        private void draw_tag(Snapshot snapshot, string text, float x, float y, bool visible, bool from_right = false) {
            if (!visible) return;
            var layout = create_pango_layout(text);
            int lw, lh;
            layout.get_pixel_size(out lw, out lh);
            float w = lw + 16, h = lh + 6;
            float left = from_right ? x - w : x;
            var box = Graphene.Rect();
            box.init(left, y, w, h);
            var rounded = Gsk.RoundedRect();
            rounded.init_from_rect(box, h / 2);
            var bg = Gdk.RGBA();
            bg.parse("rgba(0,0,0,0.55)");
            snapshot.push_rounded_clip(rounded);
            snapshot.append_color(bg, box);
            snapshot.pop();
            var fg = Gdk.RGBA();
            fg.parse("white");
            snapshot.save();
            var p = Graphene.Point();
            p.init(left + 8, y + 3);
            snapshot.translate(p);
            snapshot.append_layout(layout, fg);
            snapshot.restore();
        }

        private void draw_crop(Snapshot snapshot, Graphene.Rect img) {
            Graphene.Rect c;
            crop_rect(out c);
            var shade = Gdk.RGBA();
            shade.parse("rgba(0,0,0,0.55)");
            var r = Graphene.Rect();
            r.init(img.origin.x, img.origin.y, img.size.width, c.origin.y - img.origin.y);
            snapshot.append_color(shade, r);
            float bottom = c.origin.y + c.size.height;
            r.init(img.origin.x, bottom, img.size.width, img.origin.y + img.size.height - bottom);
            snapshot.append_color(shade, r);
            r.init(img.origin.x, c.origin.y, c.origin.x - img.origin.x, c.size.height);
            snapshot.append_color(shade, r);
            float right = c.origin.x + c.size.width;
            r.init(right, c.origin.y, img.origin.x + img.size.width - right, c.size.height);
            snapshot.append_color(shade, r);

            var grid = Gdk.RGBA();
            grid.parse("rgba(255,255,255,0.45)");
            for (int i = 1; i < 3; i++) {
                r.init(c.origin.x + c.size.width * i / 3.0f, c.origin.y, 1, c.size.height);
                snapshot.append_color(grid, r);
                r.init(c.origin.x, c.origin.y + c.size.height * i / 3.0f, c.size.width, 1);
                snapshot.append_color(grid, r);
            }
            var white = Gdk.RGBA();
            white.parse("white");
            var border = Gsk.RoundedRect();
            border.init_from_rect(c, 0);
            float[] widths = { 1.5f, 1.5f, 1.5f, 1.5f };
            Gdk.RGBA[] colors = { white, white, white, white };
            snapshot.append_border(border, widths, colors);

            float len = float.min(22, float.min(c.size.width, c.size.height) / 3);
            float t = 4;
            float[,] corners = {
                { c.origin.x - t / 2, c.origin.y - t / 2, 1, 1 },
                { right + t / 2, c.origin.y - t / 2, -1, 1 },
                { c.origin.x - t / 2, bottom + t / 2, 1, -1 },
                { right + t / 2, bottom + t / 2, -1, -1 }
            };
            for (int i = 0; i < 4; i++) {
                float x = corners[i, 0], y = corners[i, 1], dx = corners[i, 2], dy = corners[i, 3];
                r.init(dx > 0 ? x : x - len, dy > 0 ? y : y - t, len, t);
                snapshot.append_color(white, r);
                r.init(dx > 0 ? x : x - t, dy > 0 ? y : y - len, t, len);
                snapshot.append_color(white, r);
            }
        }

        private Handle hit_test(double x, double y) {
            if (_mode == Mode.COMPARE) {
                Graphene.Rect img;
                if (!image_rect(out img)) return Handle.NONE;
                double split = img.origin.x + img.size.width * divider;
                if ((x - split).abs() < HANDLE_REACH * 2 && y >= img.origin.y && y <= img.origin.y + img.size.height)
                    return Handle.DIVIDER;
                return Handle.NONE;
            }
            if (_mode != Mode.CROP) return Handle.NONE;
            Graphene.Rect c;
            crop_rect(out c);
            double l = c.origin.x, t = c.origin.y, r = l + c.size.width, b = t + c.size.height;
            bool near_l = (x - l).abs() < HANDLE_REACH, near_r = (x - r).abs() < HANDLE_REACH;
            bool near_t = (y - t).abs() < HANDLE_REACH, near_b = (y - b).abs() < HANDLE_REACH;
            bool in_x = x > l - HANDLE_REACH && x < r + HANDLE_REACH;
            bool in_y = y > t - HANDLE_REACH && y < b + HANDLE_REACH;
            if (near_l && near_t) return Handle.TOP_LEFT;
            if (near_r && near_t) return Handle.TOP_RIGHT;
            if (near_l && near_b) return Handle.BOTTOM_LEFT;
            if (near_r && near_b) return Handle.BOTTOM_RIGHT;
            if (near_t && in_x) return Handle.TOP;
            if (near_b && in_x) return Handle.BOTTOM;
            if (near_l && in_y) return Handle.LEFT;
            if (near_r && in_y) return Handle.RIGHT;
            if (x > l && x < r && y > t && y < b) return Handle.MOVE;
            return Handle.NONE;
        }

        private string? cursor_for(Handle h) {
            switch (h) {
                case Handle.MOVE: return "move";
                case Handle.TOP_LEFT: return "nw-resize";
                case Handle.TOP_RIGHT: return "ne-resize";
                case Handle.BOTTOM_LEFT: return "sw-resize";
                case Handle.BOTTOM_RIGHT: return "se-resize";
                case Handle.TOP: return "n-resize";
                case Handle.BOTTOM: return "s-resize";
                case Handle.LEFT: return "w-resize";
                case Handle.RIGHT: return "e-resize";
                case Handle.DIVIDER: return "col-resize";
                default: return null;
            }
        }

        private void update_cursor() {
            set_cursor_from_name(null);
        }

        private void on_drag_begin(double x, double y) {
            drag_handle = hit_test(x, y);
            drag_start_x = x;
            drag_start_y = y;
            start_cx = crop_x;
            start_cy = crop_y;
            start_cw = crop_w;
            start_ch = crop_h;
            if (drag_handle == Handle.DIVIDER) move_divider(x);
        }

        private void move_divider(double x) {
            Graphene.Rect img;
            if (!image_rect(out img)) return;
            divider = ((x - img.origin.x) / img.size.width).clamp(0.0, 1.0);
        }

        private void on_drag_update(double dx, double dy) {
            if (drag_handle == Handle.NONE) return;
            if (drag_handle == Handle.DIVIDER) {
                move_divider(drag_start_x + dx);
                return;
            }
            Graphene.Rect img;
            if (!image_rect(out img)) return;
            double nx = dx / img.size.width, ny = dy / img.size.height;
            double l = start_cx, t = start_cy, r = start_cx + start_cw, b = start_cy + start_ch;
            const double MIN = 0.04;
            switch (drag_handle) {
                case Handle.MOVE:
                    l = (start_cx + nx).clamp(0.0, 1.0 - start_cw);
                    t = (start_cy + ny).clamp(0.0, 1.0 - start_ch);
                    r = l + start_cw;
                    b = t + start_ch;
                    break;
                case Handle.TOP_LEFT: l += nx; t += ny; break;
                case Handle.TOP_RIGHT: r += nx; t += ny; break;
                case Handle.BOTTOM_LEFT: l += nx; b += ny; break;
                case Handle.BOTTOM_RIGHT: r += nx; b += ny; break;
                case Handle.TOP: t += ny; break;
                case Handle.BOTTOM: b += ny; break;
                case Handle.LEFT: l += nx; break;
                case Handle.RIGHT: r += nx; break;
                default: break;
            }
            l = l.clamp(0.0, 1.0);
            t = t.clamp(0.0, 1.0);
            r = r.clamp(0.0, 1.0);
            b = b.clamp(0.0, 1.0);
            if (r - l < MIN) {
                if (drag_handle == Handle.LEFT || drag_handle == Handle.TOP_LEFT || drag_handle == Handle.BOTTOM_LEFT) l = r - MIN;
                else r = l + MIN;
            }
            if (b - t < MIN) {
                if (drag_handle == Handle.TOP || drag_handle == Handle.TOP_LEFT || drag_handle == Handle.TOP_RIGHT) t = b - MIN;
                else b = t + MIN;
            }
            crop_x = l;
            crop_y = t;
            crop_w = r - l;
            crop_h = b - t;
            if (aspect > 0 && drag_handle != Handle.MOVE) enforce_aspect(drag_handle);
            queue_draw();
        }

        private void enforce_aspect(Handle anchor) {
            var tex = uncropped ?? edited;
            if (tex == null) return;
            double iw = tex.width, ih = tex.height;
            double w = crop_w * iw, h = crop_h * ih;
            bool horizontal = anchor == Handle.LEFT || anchor == Handle.RIGHT;
            bool vertical = anchor == Handle.TOP || anchor == Handle.BOTTOM;
            if (horizontal) h = w / aspect;
            else if (vertical) w = h * aspect;
            else if (w / h > aspect) w = h * aspect;
            else h = w / aspect;
            if (w > iw) { w = iw; h = w / aspect; }
            if (h > ih) { h = ih; w = h * aspect; }
            double nw = w / iw, nh = h / ih;
            double right = crop_x + crop_w, bottom = crop_y + crop_h;
            bool keep_right = anchor == Handle.LEFT || anchor == Handle.TOP_LEFT || anchor == Handle.BOTTOM_LEFT;
            bool keep_bottom = anchor == Handle.TOP || anchor == Handle.TOP_LEFT || anchor == Handle.TOP_RIGHT;
            double nx = keep_right ? right - nw : crop_x;
            double ny = keep_bottom ? bottom - nh : crop_y;
            if (vertical) nx = crop_x + (crop_w - nw) / 2;
            if (horizontal) ny = crop_y + (crop_h - nh) / 2;
            crop_x = nx.clamp(0.0, 1.0 - nw);
            crop_y = ny.clamp(0.0, 1.0 - nh);
            crop_w = nw;
            crop_h = nh;
        }

        public void apply_aspect(double ratio) {
            aspect = ratio;
            if (ratio <= 0) {
                queue_draw();
                return;
            }
            var tex = uncropped ?? edited;
            if (tex == null) return;
            double iw = tex.width, ih = tex.height;
            double w = iw, h = ih;
            double cx = (crop_x + crop_w / 2) * iw, cy = (crop_y + crop_h / 2) * ih;
            if (w / h > ratio) w = h * ratio;
            else h = w / ratio;
            crop_w = w / iw;
            crop_h = h / ih;
            crop_x = (cx / iw - crop_w / 2).clamp(0.0, 1.0 - crop_w);
            crop_y = (cy / ih - crop_h / 2).clamp(0.0, 1.0 - crop_h);
            queue_draw();
            crop_changed();
        }

        private bool widget_to_source(double wx, double wy, out double nx, out double ny) {
            nx = ny = 0;
            Graphene.Rect img;
            var tex = shown();
            if (geometry == null || tex == null) return false;
            if (!image_rect(out img)) return false;
            double ox = (wx - img.origin.x) / img.size.width * geometry.out_width;
            double oy = (wy - img.origin.y) / img.size.height * geometry.out_height;
            double sx, sy;
            geometry.map(ox, oy, out sx, out sy);
            nx = sx / geometry.source_width;
            ny = sy / geometry.source_height;
            return true;
        }

        private bool source_to_widget(double nx, double ny, out double wx, out double wy) {
            wx = wy = 0;
            Graphene.Rect img;
            if (geometry == null || shown() == null) return false;
            if (!image_rect(out img)) return false;
            double ox, oy;
            geometry.source_to_output(nx * geometry.source_width, ny * geometry.source_height, out ox, out oy);
            wx = img.origin.x + ox / geometry.out_width * img.size.width;
            wy = img.origin.y + oy / geometry.out_height * img.size.height;
            return true;
        }

        private double widget_per_source_long_side() {
            Graphene.Rect img;
            if (geometry == null) return 1;
            if (!image_rect(out img)) return 1;
            return img.size.width / geometry.out_width * geometry.scale * double.max(geometry.source_width, geometry.source_height);
        }

        private void tool_begin(double x, double y) {
            tool_start_x = x;
            tool_start_y = y;
            tool_origin.clear();
            double nx, ny;
            if (!widget_to_source(x, y, out nx, out ny)) return;
            switch (tool) {
                case "pick":
                    picked(nx, ny);
                    return;
                case "brush":
                    if (component == null) return;
                    edit_begin();
                    current_stroke = new BrushStroke();
                    current_stroke.radius = brush_radius;
                    current_stroke.feather = brush_feather;
                    current_stroke.flow = brush_flow;
                    current_stroke.erase = brush_erase;
                    current_stroke.add_point(nx, ny);
                    component.strokes.add(current_stroke);
                    tool_handle = "stroke";
                    strokes_changed(false);
                    return;
                case "linear":
                    if (component == null) return;
                    edit_begin();
                    tool_handle = pick_linear_handle(x, y);
                    if (tool_handle == "") {
                        component.s("x0", nx);
                        component.s("y0", ny);
                        component.s("x1", nx);
                        component.s("y1", ny);
                        tool_handle = "end";
                    }
                    foreach (var k in new string[] { "x0", "y0", "x1", "y1" }) tool_origin[k] = component.g(k);
                    tool_origin["nx"] = nx;
                    tool_origin["ny"] = ny;
                    return;
                case "radial":
                    if (component == null) return;
                    edit_begin();
                    tool_handle = pick_radial_handle(x, y);
                    if (tool_handle == "") {
                        component.s("cx", nx);
                        component.s("cy", ny);
                        component.s("rx", 0.001);
                        component.s("ry", 0.001);
                        tool_handle = "create";
                    }
                    foreach (var k in new string[] { "cx", "cy", "rx", "ry" }) tool_origin[k] = component.g(k, 0.25);
                    tool_origin["nx"] = nx;
                    tool_origin["ny"] = ny;
                    return;
                case "guide":
                    edit_begin();
                    double[] g = guides;
                    g += nx;
                    g += ny;
                    g += nx;
                    g += ny;
                    if (g.length > 16) g = g[4:g.length];
                    guides = g;
                    tool_handle = "guide";
                    return;
                case "heal":
                    if (spots == null) return;
                    edit_begin();
                    int hit_index;
                    bool source;
                    hit_spot(x, y, out hit_index, out source);
                    if (hit_index >= 0) {
                        selected_spot = hit_index;
                        spot_selected(hit_index);
                        tool_handle = source ? "spot-source" : "spot";
                        var sp = spots[hit_index];
                        tool_origin["x"] = sp.x;
                        tool_origin["y"] = sp.y;
                        tool_origin["sx"] = sp.source_x;
                        tool_origin["sy"] = sp.source_y;
                    } else {
                        var sp = new SpotEdit();
                        sp.mode = spot_mode;
                        sp.x = nx;
                        sp.y = ny;
                        sp.radius = spot_radius;
                        sp.source_x = nx;
                        sp.source_y = ny;
                        spots.add(sp);
                        selected_spot = spots.size - 1;
                        spot_selected(selected_spot);
                        tool_handle = "spot-new";
                        spots_changed(false);
                    }
                    tool_origin["nx"] = nx;
                    tool_origin["ny"] = ny;
                    return;
                default:
                    return;
            }
        }

        private void tool_update(double dx, double dy) {
            double nx, ny;
            if (!widget_to_source(tool_start_x + dx, tool_start_y + dy, out nx, out ny)) return;
            double ox = tool_origin.has_key("nx") ? tool_origin["nx"] : nx, oy = tool_origin.has_key("ny") ? tool_origin["ny"] : ny;
            double ddx = nx - ox, ddy = ny - oy;
            switch (tool_handle) {
                case "guide":
                    guides[guides.length - 2] = nx;
                    guides[guides.length - 1] = ny;
                    break;
                case "stroke":
                    current_stroke.add_point(nx, ny);
                    cursor_x = tool_start_x + dx;
                    cursor_y = tool_start_y + dy;
                    strokes_changed(false);
                    break;
                case "end":
                    component.s("x1", nx);
                    component.s("y1", ny);
                    gradient_changed(false);
                    break;
                case "start":
                    component.s("x0", tool_origin["x0"] + ddx);
                    component.s("y0", tool_origin["y0"] + ddy);
                    gradient_changed(false);
                    break;
                case "line":
                    foreach (var k in new string[] { "x0", "x1" }) component.s(k, tool_origin[k] + ddx);
                    foreach (var k in new string[] { "y0", "y1" }) component.s(k, tool_origin[k] + ddy);
                    gradient_changed(false);
                    break;
                case "create":
                    component.s("rx", double.max(0.005, (nx - tool_origin["cx"]).abs()));
                    component.s("ry", double.max(0.005, (ny - tool_origin["cy"]).abs()));
                    gradient_changed(false);
                    break;
                case "center":
                    component.s("cx", tool_origin["cx"] + ddx);
                    component.s("cy", tool_origin["cy"] + ddy);
                    gradient_changed(false);
                    break;
                case "rx":
                    component.s("rx", double.max(0.005, (nx - tool_origin["cx"]).abs()));
                    gradient_changed(false);
                    break;
                case "ry":
                    component.s("ry", double.max(0.005, (ny - tool_origin["cy"]).abs()));
                    gradient_changed(false);
                    break;
                case "spot":
                    var sp = spots[selected_spot];
                    sp.x = tool_origin["x"] + ddx;
                    sp.y = tool_origin["y"] + ddy;
                    spots_changed(false);
                    break;
                case "spot-source":
                    var ss = spots[selected_spot];
                    ss.source_x = tool_origin["sx"] + ddx;
                    ss.source_y = tool_origin["sy"] + ddy;
                    ss.auto_source = false;
                    spots_changed(false);
                    break;
                case "spot-new":
                    var sn = spots[selected_spot];
                    double r = Math.sqrt(ddx * ddx * geometry.source_width * geometry.source_width + ddy * ddy * geometry.source_height * geometry.source_height) / double.max(geometry.source_width, geometry.source_height);
                    if (r > 0.004) sn.radius = r;
                    spots_changed(false);
                    break;
                default:
                    break;
            }
            queue_draw();
        }

        private void tool_end() {
            string h = tool_handle;
            tool_handle = "";
            current_stroke = null;
            if (h == "guide") guides_changed(true);
            else if (h == "stroke") strokes_changed(true);
            else if (h.has_prefix("spot")) spots_changed(true);
            else gradient_changed(true);
            queue_draw();
        }

        private string pick_linear_handle(double x, double y) {
            double ax, ay, bx, by;
            if (!source_to_widget(component.g("x0", 0.5), component.g("y0", 0.3), out ax, out ay)) return "";
            source_to_widget(component.g("x1", 0.5), component.g("y1", 0.7), out bx, out by);
            if (!component.geo.has_key("x0")) return "";
            if (Math.hypot(x - ax, y - ay) < 14) return "start";
            if (Math.hypot(x - bx, y - by) < 14) return "end";
            if (Math.hypot(x - (ax + bx) / 2, y - (ay + by) / 2) < 14) return "line";
            return "";
        }

        private string pick_radial_handle(double x, double y) {
            if (!component.geo.has_key("cx")) return "";
            double cx, cy, rx_w, ry_w;
            source_to_widget(component.g("cx"), component.g("cy"), out cx, out cy);
            double ex, ey;
            source_to_widget(component.g("cx") + component.g("rx"), component.g("cy"), out ex, out ey);
            rx_w = Math.hypot(ex - cx, ey - cy);
            source_to_widget(component.g("cx"), component.g("cy") + component.g("ry"), out ex, out ey);
            ry_w = Math.hypot(ex - cx, ey - cy);
            if (Math.hypot(x - cx, y - cy) < 14) return "center";
            if (Math.hypot(x - (cx + rx_w), y - cy) < 14 || Math.hypot(x - (cx - rx_w), y - cy) < 14) return "rx";
            if (Math.hypot(x - cx, y - (cy + ry_w)) < 14 || Math.hypot(x - cx, y - (cy - ry_w)) < 14) return "ry";
            return "";
        }

        private void hit_spot(double x, double y, out int index, out bool source) {
            index = -1;
            source = false;
            if (spots == null) return;
            double scale = widget_per_source_long_side();
            for (int i = spots.size - 1; i >= 0; i--) {
                var sp = spots[i];
                double wx, wy;
                double r = double.max(8, sp.radius * scale);
                if (sp.mode != "fill") {
                    source_to_widget(sp.source_x, sp.source_y, out wx, out wy);
                    if (Math.hypot(x - wx, y - wy) < r) {
                        index = i;
                        source = true;
                        return;
                    }
                }
                source_to_widget(sp.x, sp.y, out wx, out wy);
                if (Math.hypot(x - wx, y - wy) < r) {
                    index = i;
                    return;
                }
            }
        }

        private void draw_tools(Snapshot snapshot, Graphene.Rect img) {
            if (mask_overlay != null && show_overlay) {
                snapshot.push_opacity(0.55);
                snapshot.append_scaled_texture(mask_overlay, Gsk.ScalingFilter.LINEAR, img);
                snapshot.pop();
            }
            var bounds = Graphene.Rect();
            bounds.init(0, 0, get_width(), get_height());
            var cr = snapshot.append_cairo(bounds);
            cr.set_line_width(1.5);
            cr.save();
            cr.rectangle(img.origin.x, img.origin.y, img.size.width, img.size.height);
            cr.clip();
            if (component != null && (tool == "linear" || tool == "radial" || tool == "brush")) {
                if (component.kind == "linear" && component.geo.has_key("x0")) {
                    double ax, ay, bx, by;
                    source_to_widget(component.g("x0"), component.g("y0"), out ax, out ay);
                    source_to_widget(component.g("x1"), component.g("y1"), out bx, out by);
                    double dx = bx - ax, dy = by - ay, len = double.max(1, Math.hypot(dx, dy));
                    double px = -dy / len * 2000, py = dx / len * 2000;
                    cr.set_source_rgba(1, 1, 1, 0.85);
                    foreach (var t in new double[] { 0, 0.5, 1 }) {
                        double cx = ax + dx * t, cy = ay + dy * t;
                        if (t == 0.5) cr.set_dash({ 6, 4 }, 0);
                        else cr.set_dash(null, 0);
                        cr.move_to(cx - px, cy - py);
                        cr.line_to(cx + px, cy + py);
                        cr.stroke();
                    }
                    cr.set_dash(null, 0);
                    handle(cr, ax, ay);
                    handle(cr, bx, by);
                    handle(cr, (ax + bx) / 2, (ay + by) / 2);
                } else if (component.kind == "radial" && component.geo.has_key("cx")) {
                    double cx, cy, ex, ey, fx, fy;
                    source_to_widget(component.g("cx"), component.g("cy"), out cx, out cy);
                    source_to_widget(component.g("cx") + component.g("rx"), component.g("cy"), out ex, out ey);
                    source_to_widget(component.g("cx"), component.g("cy") + component.g("ry"), out fx, out fy);
                    double rx = Math.hypot(ex - cx, ey - cy), ry = Math.hypot(fx - cx, fy - cy);
                    cr.save();
                    cr.translate(cx, cy);
                    cr.rotate(component.g("angle", 0) * Math.PI / 180.0);
                    cr.scale(double.max(rx, 1), double.max(ry, 1));
                    cr.arc(0, 0, 1, 0, 2 * Math.PI);
                    cr.restore();
                    cr.set_source_rgba(1, 1, 1, 0.9);
                    cr.stroke();
                    double inner = 1 - component.g("feather", 0.5);
                    if (inner > 0.02) {
                        cr.save();
                        cr.translate(cx, cy);
                        cr.rotate(component.g("angle", 0) * Math.PI / 180.0);
                        cr.scale(double.max(rx * inner, 1), double.max(ry * inner, 1));
                        cr.arc(0, 0, 1, 0, 2 * Math.PI);
                        cr.restore();
                        cr.set_dash({ 5, 4 }, 0);
                        cr.stroke();
                        cr.set_dash(null, 0);
                    }
                    handle(cr, cx, cy);
                    handle(cr, cx + rx, cy);
                    handle(cr, cx - rx, cy);
                    handle(cr, cx, cy + ry);
                    handle(cr, cx, cy - ry);
                }
            }
            cr.restore();
            if (tool == "guide") {
                cr.set_source_rgba(1, 0.85, 0.2, 0.95);
                cr.set_line_width(2);
                for (int i = 0; i + 3 < guides.length; i += 4) {
                    double ax, ay, bx, by;
                    source_to_widget(guides[i], guides[i + 1], out ax, out ay);
                    source_to_widget(guides[i + 2], guides[i + 3], out bx, out by);
                    cr.move_to(ax, ay);
                    cr.line_to(bx, by);
                    cr.stroke();
                    handle(cr, ax, ay);
                    handle(cr, bx, by);
                    cr.set_source_rgba(1, 0.85, 0.2, 0.95);
                    cr.set_line_width(2);
                }
            }
            if (tool == "brush" && cursor_x >= 0) {
                double r = brush_radius * widget_per_source_long_side();
                cr.set_source_rgba(1, 1, 1, 0.9);
                cr.arc(cursor_x, cursor_y, r, 0, 2 * Math.PI);
                cr.stroke();
                if (brush_feather > 0.02) {
                    cr.set_source_rgba(1, 1, 1, 0.5);
                    cr.arc(cursor_x, cursor_y, r * (1 - brush_feather), 0, 2 * Math.PI);
                    cr.stroke();
                }
                if (brush_erase) {
                    cr.move_to(cursor_x - 5, cursor_y);
                    cr.line_to(cursor_x + 5, cursor_y);
                    cr.stroke();
                }
            }
            if (tool == "heal" && spots != null) {
                double scale = widget_per_source_long_side();
                for (int i = 0; i < spots.size; i++) {
                    var sp = spots[i];
                    double wx, wy, sx, sy;
                    source_to_widget(sp.x, sp.y, out wx, out wy);
                    double r = sp.radius * scale;
                    bool sel = i == selected_spot;
                    cr.set_source_rgba(1, 1, 1, sel ? 1 : 0.7);
                    cr.set_line_width(sel ? 2 : 1.25);
                    cr.arc(wx, wy, r, 0, 2 * Math.PI);
                    cr.stroke();
                    source_to_widget(sp.source_x, sp.source_y, out sx, out sy);
                    if (sp.mode != "fill") {
                        cr.set_dash({ 4, 3 }, 0);
                        cr.arc(sx, sy, r, 0, 2 * Math.PI);
                        cr.stroke();
                        double d = Math.hypot(sx - wx, sy - wy);
                        if (d > r * 2) {
                            double ux = (sx - wx) / d, uy = (sy - wy) / d;
                            cr.move_to(wx + ux * r, wy + uy * r);
                            cr.line_to(sx - ux * r, sy - uy * r);
                            cr.stroke();
                        }
                        cr.set_dash(null, 0);
                    }
                }
            }
        }

        private void handle(Cairo.Context cr, double x, double y) {
            cr.arc(x, y, 5, 0, 2 * Math.PI);
            cr.set_source_rgba(1, 1, 1, 1);
            cr.fill_preserve();
            cr.set_source_rgba(0, 0, 0, 0.45);
            cr.set_line_width(1);
            cr.stroke();
            cr.set_line_width(1.5);
        }
    }
}