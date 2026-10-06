using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public enum RetouchTool {
        MOVE,
        MARQUEE_RECT,
        MARQUEE_ELLIPSE,
        LASSO,
        POLYGON,
        MAGIC_WAND,
        QUICK_SELECT,
        BRUSH,
        ERASER,
        MASK_BRUSH,
        CLONE,
        HEAL,
        PATCH,
        LIQUIFY,
        TRANSFORM,
        TEXT,
        EYEDROPPER;

        public string icon() {
            switch (this) {
                case MOVE: return "singularity-markup-select-symbolic";
                case MARQUEE_RECT: return "singularity-markup-rectangle-symbolic";
                case MARQUEE_ELLIPSE: return "singularity-markup-ellipse-symbolic";
                case LASSO: return "singularity-markup-highlighter-symbolic";
                case POLYGON: return "singularity-markup-line-symbolic";
                case MAGIC_WAND: return "singularity-photos-enhance-symbolic";
                case QUICK_SELECT: return "singularity-markup-highlighter-symbolic";
                case BRUSH: return "singularity-markup-pen-symbolic";
                case ERASER: return "singularity-retouch-eraser-symbolic";
                case MASK_BRUSH: return "singularity-retouch-mask-symbolic";
                case CLONE: return "singularity-retouch-clone-symbolic";
                case HEAL: return "singularity-retouch-heal-symbolic";
                case PATCH: return "singularity-retouch-patch-symbolic";
                case LIQUIFY: return "singularity-retouch-liquify-symbolic";
                case TRANSFORM: return "singularity-retouch-transform-symbolic";
                case TEXT: return "singularity-markup-text-symbolic";
                default: return "color-select-symbolic";
            }
        }

        public string label() {
            switch (this) {
                case MOVE: return _("Move (V)");
                case MARQUEE_RECT: return _("Rectangle Selection (M)");
                case MARQUEE_ELLIPSE: return _("Ellipse Selection");
                case LASSO: return _("Lasso (L)");
                case POLYGON: return _("Polygonal Lasso");
                case MAGIC_WAND: return _("Magic Wand (W)");
                case QUICK_SELECT: return _("Quick Selection");
                case BRUSH: return _("Brush (B)");
                case ERASER: return _("Eraser (E)");
                case MASK_BRUSH: return _("Mask Brush");
                case CLONE: return _("Clone Stamp (S)");
                case HEAL: return _("Healing Brush (J)");
                case PATCH: return _("Patch");
                case LIQUIFY: return _("Liquify");
                case TRANSFORM: return _("Transform (T)");
                case TEXT: return _("Text");
                default: return _("Eyedropper (I)");
            }
        }

        public bool uses_brush() {
            return this == BRUSH || this == ERASER || this == MASK_BRUSH || this == CLONE || this == HEAL || this == LIQUIFY || this == QUICK_SELECT;
        }

        public bool paints_pixels() {
            return this == BRUSH || this == ERASER || this == CLONE || this == HEAL;
        }
    }

    public enum TransformMode {
        FREE,
        PERSPECTIVE,
        WARP
    }

    private class StrokeBackup {
        public const int TILE = 256;
        public RetouchLayer layer;
        public bool mask;
        public int width;
        public int height;
        public Gee.HashMap<int, FloatImage> tiles = new Gee.HashMap<int, FloatImage>();
        public Gee.HashMap<int, Bytes> mask_tiles = new Gee.HashMap<int, Bytes>();
        public int bx0 = int.MAX;
        public int by0 = int.MAX;
        public int bx1 = int.MIN;
        public int by1 = int.MIN;

        public StrokeBackup(RetouchLayer layer, bool mask, int w, int h) {
            this.layer = layer;
            this.mask = mask;
            width = w;
            height = h;
        }

        public void touch(int x0, int y0, int x1, int y1) {
            x0 = int.max(0, x0);
            y0 = int.max(0, y0);
            x1 = int.min(width - 1, x1);
            y1 = int.min(height - 1, y1);
            if (x0 > x1 || y0 > y1) return;
            for (int ty = y0 / TILE; ty <= y1 / TILE; ty++) {
                for (int tx = x0 / TILE; tx <= x1 / TILE; tx++) {
                    int key = ty * 65536 + tx;
                    int px = tx * TILE, py = ty * TILE;
                    int tw = int.min(TILE, width - px), th = int.min(TILE, height - py);
                    bx0 = int.min(bx0, px);
                    by0 = int.min(by0, py);
                    bx1 = int.max(bx1, px + tw);
                    by1 = int.max(by1, py + th);
                    if (mask) {
                        if (mask_tiles.has_key(key)) continue;
                        var region = RetouchDocument.crop_plane(layer.mask, width, px, py, tw, th);
                        mask_tiles[key] = new Bytes((uint8[]) region);
                    } else {
                        if (tiles.has_key(key)) continue;
                        tiles[key] = layer.pixels.cropped(px, py, tw, th);
                    }
                }
            }
        }

        public void commit(RetouchDocument doc) {
            if (bx0 > bx1) return;
            int w = bx1 - bx0, h = by1 - by0;
            if (mask) {
                var before = RetouchDocument.crop_plane(layer.mask, width, bx0, by0, w, h);
                foreach (var e in mask_tiles.entries) {
                    int tx = e.key % 65536, ty = e.key / 65536;
                    int px = tx * TILE, py = ty * TILE;
                    int tw = int.min(TILE, width - px), th = int.min(TILE, height - py);
                    unowned uint8[] raw = e.value.get_data();
                    for (int y = 0; y < th; y++) {
                        for (int x = 0; x < tw; x++) {
                            float v = 0;
                            Memory.copy(&v, &raw[((size_t) y * tw + x) * sizeof(float)], sizeof(float));
                            before[(size_t) (py - by0 + y) * w + (px - bx0 + x)] = v;
                        }
                    }
                }
                doc.push_mask_step(layer, bx0, by0, w, h, before);
            } else {
                var before = layer.pixels.cropped(bx0, by0, w, h);
                foreach (var e in tiles.entries) {
                    int tx = e.key % 65536, ty = e.key / 65536;
                    before.paste(e.value, tx * TILE - bx0, ty * TILE - by0);
                }
                doc.push_pixel_step(layer, bx0, by0, before);
            }
        }
    }

    public class RetouchController : Object {
        public RetouchDocument doc { get; set; }
        public RetouchCanvas canvas { get; construct; }
        public RetouchTool tool { get; set; default = RetouchTool.MOVE; }
        public RetouchLayer? active { get; set; default = null; }
        public bool edit_mask { get; set; default = false; }
        public double brush_size { get; set; default = 40; }
        public double hardness { get; set; default = 0.5; }
        public double brush_opacity { get; set; default = 1.0; }
        public double tolerance { get; set; default = 0.12; }
        public bool contiguous { get; set; default = true; }
        public bool sample_all { get; set; default = false; }
        public SelectionOp selection_op { get; set; default = SelectionOp.REPLACE; }
        public LiquifyBrush liquify_brush { get; set; default = LiquifyBrush.FORWARD; }
        public TransformMode transform_mode { get; set; default = TransformMode.FREE; }
        public bool mask_reveal { get; set; default = false; }
        public float fg_r = 1;
        public float fg_g = 1;
        public float fg_b = 1;

        public signal void message(string text);
        public signal void state_changed();
        public signal void layer_created(RetouchLayer layer);
        public signal void color_picked();

        private double hover_x = -1;
        private double hover_y = -1;
        private double start_x;
        private double start_y;
        private double last_x;
        private double last_y;
        private bool pressed = false;
        private double[] path = {};
        private double[] polygon_points = {};
        private bool clone_source_set = false;
        private double clone_src_x;
        private double clone_src_y;
        private double clone_dx;
        private double clone_dy;
        private bool clone_aligned_started = false;
        private FloatImage? clone_source = null;
        private float[]? heal_mask = null;
        private StrokeBackup? backup = null;
        private int stroke_x0;
        private int stroke_y0;
        private int stroke_x1;
        private int stroke_y1;

        public RetouchLiquify? liquify { get; private set; default = null; }
        private FloatImage? liquify_original = null;
        private RetouchLayer? liquify_layer = null;

        public bool transforming { get; private set; default = false; }
        private RetouchLayer? transform_layer = null;
        private FloatImage? transform_source = null;
        private int transform_src_x;
        private int transform_src_y;
        private double[] control = {};
        private int grid_cols = 1;
        private int grid_rows = 1;
        private int drag_point = -1;
        private bool drag_move = false;
        private bool drag_rotate = false;
        private double[] control_start = {};

        public RetouchController(RetouchCanvas canvas) {
            Object(canvas: canvas);
            canvas.pointer_pressed.connect(on_press);
            canvas.pointer_dragged.connect(on_drag);
            canvas.pointer_released.connect(on_release);
            canvas.pointer_moved.connect((x, y) => {
                hover_x = x;
                hover_y = y;
                if (tool.uses_brush() || tool == RetouchTool.POLYGON || transforming) canvas.queue_draw();
            });
            canvas.draw_overlay.connect(draw_overlay);
            notify["tool"].connect(() => {
                if (tool != RetouchTool.POLYGON) polygon_points = {};
                if (tool == RetouchTool.LIQUIFY) begin_liquify();
                else if (liquify != null) cancel_liquify();
                if (tool == RetouchTool.TRANSFORM) begin_transform();
                else if (transforming) cancel_transform();
                canvas.queue_draw();
            });
        }

        private RetouchLayer? pixel_target() {
            if (active == null || active.locked) return null;
            if (active.kind != RetouchLayerKind.RASTER || active.pixels == null) return null;
            return active;
        }

        private SelectionOp op_for(Gdk.ModifierType state) {
            bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            bool alt = (state & Gdk.ModifierType.ALT_MASK) != 0;
            if (shift && alt) return SelectionOp.INTERSECT;
            if (shift) return SelectionOp.ADD;
            if (alt) return SelectionOp.SUBTRACT;
            return selection_op;
        }

        private Gdk.ModifierType press_state;

        private void on_press(double x, double y, uint button, Gdk.ModifierType state) {
            if (doc == null) return;
            press_state = state;
            pressed = true;
            start_x = last_x = x;
            start_y = last_y = y;
            path = { x, y };
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            bool alt = (state & Gdk.ModifierType.ALT_MASK) != 0;
            if (transforming) {
                transform_press(x, y, state);
                return;
            }
            switch (tool) {
                case RetouchTool.MOVE:
                    if (active != null && !active.locked && (active.kind == RetouchLayerKind.RASTER || active.kind == RetouchLayerKind.EMBEDDED || active.kind == RetouchLayerKind.TEXT))
                        doc.record_structure(_("Move"));
                    break;
                case RetouchTool.MAGIC_WAND:
                    doc.record_selection(_("Magic Wand"));
                    var shape = RetouchSelection.magic_wand(sample_all || active == null ? doc.composite : doc.render_layer_pixels(active), (int) x, (int) y, tolerance, contiguous);
                    apply_selection(shape, op_for(state));
                    pressed = false;
                    break;
                case RetouchTool.POLYGON:
                    double[] pts = polygon_points;
                    if (pts.length >= 6) {
                        double fx, fy, px2, py2;
                        canvas.to_view(pts[0], pts[1], out fx, out fy);
                        canvas.to_view(x, y, out px2, out py2);
                        if ((fx - px2).abs() < 8 && (fy - py2).abs() < 8) {
                            close_polygon(state);
                            pressed = false;
                            return;
                        }
                    }
                    pts += x;
                    pts += y;
                    polygon_points = pts;
                    pressed = false;
                    canvas.queue_draw();
                    break;
                case RetouchTool.EYEDROPPER:
                    pick_color(x, y);
                    break;
                case RetouchTool.TEXT:
                    create_text_at((int) x, (int) y);
                    pressed = false;
                    break;
                case RetouchTool.CLONE:
                case RetouchTool.HEAL:
                    if (ctrl || alt) {
                        clone_source_set = true;
                        clone_src_x = x;
                        clone_src_y = y;
                        clone_aligned_started = false;
                        pressed = false;
                        message(_("Source set"));
                        canvas.queue_draw();
                        return;
                    }
                    begin_paint(x, y);
                    break;
                case RetouchTool.BRUSH:
                case RetouchTool.ERASER:
                case RetouchTool.MASK_BRUSH:
                    begin_paint(x, y);
                    break;
                case RetouchTool.LIQUIFY:
                    if (liquify == null) begin_liquify();
                    break;
                default:
                    break;
            }
        }

        private void on_drag(double x, double y, Gdk.ModifierType state) {
            if (!pressed || doc == null) return;
            double px = last_x, py = last_y;
            last_x = x;
            last_y = y;
            if (transforming) {
                transform_drag(x, y, state);
                return;
            }
            switch (tool) {
                case RetouchTool.MOVE:
                    if (active == null || active.locked) break;
                    int nx = (int) Math.round(x - start_x), ny = (int) Math.round(y - start_y);
                    move_active(nx, ny);
                    break;
                case RetouchTool.MARQUEE_RECT:
                case RetouchTool.MARQUEE_ELLIPSE:
                case RetouchTool.PATCH:
                    canvas.queue_draw();
                    break;
                case RetouchTool.LASSO:
                case RetouchTool.QUICK_SELECT:
                    double[] p = path;
                    p += x;
                    p += y;
                    path = p;
                    canvas.queue_draw();
                    break;
                case RetouchTool.BRUSH:
                case RetouchTool.ERASER:
                case RetouchTool.MASK_BRUSH:
                case RetouchTool.CLONE:
                case RetouchTool.HEAL:
                    paint_segment(px, py, x, y);
                    break;
                case RetouchTool.LIQUIFY:
                    liquify_segment(px, py, x, y);
                    break;
                default:
                    break;
            }
        }

        private int move_base_x;
        private int move_base_y;
        private int moved_x = 0;
        private int moved_y = 0;

        private void move_active(int nx, int ny) {
            int ddx = nx - moved_x, ddy = ny - moved_y;
            if (ddx == 0 && ddy == 0) return;
            moved_x = nx;
            moved_y = ny;
            if (active.kind == RetouchLayerKind.TEXT && active.text != null) {
                var t = active.text.copy();
                t.x += ddx;
                t.y += ddy;
                active.text = t;
            } else {
                active.x += ddx;
                active.y += ddy;
            }
            doc.recomposite();
        }

        private void on_release(double x, double y, Gdk.ModifierType state) {
            if (!pressed || doc == null) return;
            pressed = false;
            if (transforming) {
                transform_release();
                return;
            }
            switch (tool) {
                case RetouchTool.MOVE:
                    moved_x = 0;
                    moved_y = 0;
                    break;
                case RetouchTool.MARQUEE_RECT:
                case RetouchTool.MARQUEE_ELLIPSE:
                    doc.record_selection(_("Selection"));
                    if ((x - start_x).abs() < 1 && (y - start_y).abs() < 1) {
                        if (op_for(press_state) == SelectionOp.REPLACE) doc.selection = null;
                        doc.recomposite();
                        break;
                    }
                    var shape = tool == RetouchTool.MARQUEE_RECT
                        ? RetouchSelection.rect(doc.width, doc.height, start_x, start_y, x - start_x, y - start_y)
                        : RetouchSelection.ellipse(doc.width, doc.height, start_x, start_y, x - start_x, y - start_y);
                    apply_selection(shape, op_for(press_state));
                    break;
                case RetouchTool.LASSO:
                    if (path.length >= 6) {
                        doc.record_selection(_("Lasso"));
                        apply_selection(RetouchSelection.polygon(doc.width, doc.height, path), op_for(press_state));
                    }
                    break;
                case RetouchTool.QUICK_SELECT:
                    doc.record_selection(_("Quick Selection"));
                    bool subtract = (press_state & Gdk.ModifierType.ALT_MASK) != 0;
                    doc.selection = RetouchSelection.quick_select(doc.composite, doc.selection, path, brush_size / 2, subtract);
                    if (RetouchSelection.is_empty(doc.selection)) doc.selection = null;
                    doc.recomposite();
                    break;
                case RetouchTool.PATCH:
                    finish_patch(x, y);
                    break;
                case RetouchTool.BRUSH:
                case RetouchTool.ERASER:
                case RetouchTool.MASK_BRUSH:
                case RetouchTool.CLONE:
                case RetouchTool.HEAL:
                    end_paint();
                    break;
                default:
                    break;
            }
            path = {};
            state_changed();
            canvas.queue_draw();
        }

        public void apply_selection(float[] shape, SelectionOp op) {
            doc.selection = RetouchSelection.combine(doc.selection, shape, op);
            if (RetouchSelection.is_empty(doc.selection)) doc.selection = null;
            canvas.invalidate();
            state_changed();
        }

        public void close_polygon(Gdk.ModifierType state = 0) {
            if (polygon_points.length >= 6) {
                doc.record_selection(_("Polygonal Lasso"));
                apply_selection(RetouchSelection.polygon(doc.width, doc.height, polygon_points), op_for(state));
            }
            polygon_points = {};
            canvas.queue_draw();
        }

        public void cancel_polygon() {
            polygon_points = {};
            canvas.queue_draw();
        }

        private void pick_color(double x, double y) {
            int ix = (int) x, iy = (int) y;
            if (ix < 0 || iy < 0 || ix >= doc.width || iy >= doc.height) return;
            size_t i = doc.composite.offset(ix, iy);
            RetouchColor.pixel_to_encoded(doc.composite.data[i], doc.composite.data[i + 1], doc.composite.data[i + 2], out fg_r, out fg_g, out fg_b);
            color_picked();
        }

        public void set_color(float r, float g, float b) {
            fg_r = r;
            fg_g = g;
            fg_b = b;
        }

        private void create_text_at(int x, int y) {
            doc.record_structure(_("Text"));
            var layer = new RetouchLayer(_("Text"), RetouchLayerKind.TEXT);
            layer.text = new RetouchText();
            layer.text.text = _("Caption");
            layer.text.x = x;
            layer.text.y = y;
            layer.text.r = fg_r;
            layer.text.g = fg_g;
            layer.text.b = fg_b;
            int size = int.max(12, doc.height / 24);
            layer.text.font = "Sans Bold %d".printf(size);
            doc.add_layer(layer, active);
            doc.structure_changed();
            doc.recomposite();
            layer_created(layer);
        }

        private void begin_paint(double x, double y) {
            if (tool == RetouchTool.MASK_BRUSH) {
                if (active == null) {
                    message(_("Select a layer to paint its mask"));
                    pressed = false;
                    return;
                }
                if (active.mask == null) {
                    doc.record_structure(_("Add Mask"));
                    active.mask = doc.full_plane(1.0f);
                }
                backup = new StrokeBackup(active, true, doc.width, doc.height);
            } else {
                var target = pixel_target();
                if (target == null) {
                    message(_("Select an unlocked pixel layer to paint on"));
                    pressed = false;
                    return;
                }
                if ((tool == RetouchTool.CLONE || tool == RetouchTool.HEAL) && !clone_source_set && tool == RetouchTool.CLONE) {
                    message(_("Ctrl+click to set the clone source"));
                    pressed = false;
                    return;
                }
                backup = new StrokeBackup(target, false, target.pixels.width, target.pixels.height);
                if (tool == RetouchTool.CLONE || tool == RetouchTool.HEAL) {
                    if (clone_source_set) {
                        if (!clone_aligned_started) {
                            clone_dx = clone_src_x - x;
                            clone_dy = clone_src_y - y;
                            clone_aligned_started = true;
                        }
                        clone_source = sample_all ? doc.composite.copy() : doc.render_layer_pixels(target);
                    }
                    heal_mask = new float[(size_t) target.pixels.width * target.pixels.height];
                }
            }
            stroke_x0 = int.MAX;
            stroke_y0 = int.MAX;
            stroke_x1 = int.MIN;
            stroke_y1 = int.MIN;
            dab(x, y);
        }

        private void dab(double x, double y) {
            double r = brush_size / 2;
            int x0 = (int) Math.floor(x - r) - 1, y0 = (int) Math.floor(y - r) - 1;
            int x1 = (int) Math.ceil(x + r) + 1, y1 = (int) Math.ceil(y + r) + 1;
            stroke_x0 = int.min(stroke_x0, x0);
            stroke_y0 = int.min(stroke_y0, y0);
            stroke_x1 = int.max(stroke_x1, x1);
            stroke_y1 = int.max(stroke_y1, y1);
            if (backup == null) return;
            var layer = backup.layer;
            float opacity = (float) brush_opacity;
            if (tool == RetouchTool.MASK_BRUSH) {
                backup.touch(x0, y0, x1, y1);
                RetouchBrush.mask_dab(layer.mask, doc.width, doc.height, x, y, r, hardness, mask_reveal ? 1.0f : 0.0f, opacity * 0.35f);
            } else {
                backup.touch(x0 - layer.x, y0 - layer.y, x1 - layer.x, y1 - layer.y);
                if (tool == RetouchTool.BRUSH || tool == RetouchTool.ERASER) {
                    float wr, wg, wb;
                    RetouchColor.pixel_to_working(fg_r, fg_g, fg_b, out wr, out wg, out wb);
                    RetouchBrush.paint_dab(layer.pixels, layer.x, layer.y, x, y, r, hardness, wr, wg, wb, opacity * 0.35f, doc.selection, doc.width, tool == RetouchTool.ERASER);
                } else if (clone_source != null) {
                    RetouchBrush.clone_dab(layer.pixels, layer.x, layer.y, clone_source, x, y, clone_dx, clone_dy, r, hardness, opacity, doc.selection, doc.width, heal_mask);
                } else if (heal_mask != null) {
                    int rr = (int) Math.ceil(r);
                    for (int yy = (int) y - rr; yy <= (int) y + rr; yy++) {
                        int ly = yy - layer.y;
                        if (ly < 0 || ly >= layer.pixels.height) continue;
                        for (int xx = (int) x - rr; xx <= (int) x + rr; xx++) {
                            int lx = xx - layer.x;
                            if (lx < 0 || lx >= layer.pixels.width) continue;
                            double d = Math.sqrt((xx + 0.5 - x) * (xx + 0.5 - x) + (yy + 0.5 - y) * (yy + 0.5 - y));
                            if (d <= r) heal_mask[(size_t) ly * layer.pixels.width + lx] = 1;
                        }
                    }
                }
            }
            doc.update_rect(x0, y0, x1 - x0, y1 - y0);
        }

        private void paint_segment(double ax, double ay, double bx, double by) {
            if (backup == null) return;
            RetouchBrush.stroke(ax, ay, bx, by, brush_size * 0.15, (x, y) => dab(x, y));
        }

        private void end_paint() {
            if (backup == null) return;
            var layer = backup.layer;
            if (tool == RetouchTool.HEAL && heal_mask != null) {
                bool any = false;
                for (size_t i = 0; i < heal_mask.length; i++) {
                    if (heal_mask[i] > 0.02f) {
                        heal_mask[i] = 1;
                        any = true;
                    } else {
                        heal_mask[i] = 0;
                    }
                }
                if (any) {
                    backup.touch(stroke_x0 - layer.x, stroke_y0 - layer.y, stroke_x1 - layer.x, stroke_y1 - layer.y);
                    if (clone_source != null) Heal.heal_region(layer.pixels, heal_mask, (int) Math.round(clone_dx), (int) Math.round(clone_dy));
                    else Heal.fill_region(layer.pixels, heal_mask);
                }
            }
            backup.commit(doc);
            backup = null;
            clone_source = null;
            heal_mask = null;
            doc.update_rect(stroke_x0 - 2, stroke_y0 - 2, stroke_x1 - stroke_x0 + 4, stroke_y1 - stroke_y0 + 4);
            state_changed();
        }

        private void finish_patch(double x, double y) {
            if (doc.selection == null) {
                message(_("Select the area to patch first"));
                return;
            }
            var target = pixel_target();
            if (target == null) {
                message(_("Select an unlocked pixel layer"));
                return;
            }
            int dx = (int) Math.round(x - start_x), dy = (int) Math.round(y - start_y);
            if (dx == 0 && dy == 0) return;
            int bx, by, bw, bh;
            if (!RetouchSelection.bounds(doc.selection, doc.width, doc.height, out bx, out by, out bw, out bh)) return;
            var b = new StrokeBackup(target, false, target.pixels.width, target.pixels.height);
            b.touch(0, 0, target.pixels.width - 1, target.pixels.height - 1);
            RetouchOps.patch(doc, target, doc.selection, dx, dy);
            b.commit(doc);
            doc.update_rect(bx - 4, by - 4, bw + 8, bh + 8);
        }

        public void begin_liquify() {
            var target = pixel_target();
            if (target == null) {
                message(_("Select an unlocked pixel layer to liquify"));
                return;
            }
            liquify_layer = target;
            liquify_original = target.pixels;
            liquify = new RetouchLiquify(target.pixels);
            state_changed();
        }

        private void liquify_segment(double ax, double ay, double bx, double by) {
            if (liquify == null) return;
            double lx = liquify_layer.x, ly = liquify_layer.y;
            RetouchBrush.stroke(ax, ay, bx, by, brush_size * 0.2, (x, y) => {
                double mx = (bx - ax), my = (by - ay);
                double len = Math.sqrt(mx * mx + my * my);
                double sx = len > 0 ? mx / len * brush_size * 0.05 : 0, sy = len > 0 ? my / len * brush_size * 0.05 : 0;
                liquify.apply_brush(liquify_brush, x - lx, y - ly, sx, sy, brush_size / 2, brush_opacity);
            });
            liquify_layer.pixels = liquify.render();
            doc.recomposite();
        }

        public void apply_liquify() {
            if (liquify == null) return;
            var result = liquify_layer.pixels;
            liquify_layer.pixels = liquify_original;
            doc.record_structure(_("Liquify"));
            liquify_layer.pixels = result;
            liquify = null;
            liquify_original = null;
            liquify_layer = null;
            doc.recomposite();
            state_changed();
        }

        public void cancel_liquify() {
            if (liquify == null) return;
            liquify_layer.pixels = liquify_original;
            liquify = null;
            liquify_original = null;
            liquify_layer = null;
            doc.recomposite();
            state_changed();
        }

        public void reset_liquify() {
            if (liquify == null) return;
            liquify.reset();
            liquify_layer.pixels = liquify_original;
            doc.recomposite();
        }

        public void begin_transform() {
            var target = pixel_target();
            if (target == null && active != null && active.kind == RetouchLayerKind.EMBEDDED && !active.locked) target = active;
            if (target == null) {
                message(_("Select an unlocked pixel layer to transform"));
                return;
            }
            transform_layer = target;
            transform_source = doc.layer_source(target);
            transform_src_x = target.x;
            transform_src_y = target.y;
            setup_grid();
            transforming = true;
            state_changed();
            canvas.queue_draw();
        }

        public void setup_grid() {
            if (transform_source == null) return;
            grid_cols = transform_mode == TransformMode.WARP ? 3 : 1;
            grid_rows = grid_cols;
            double[] pts = {};
            double w = transform_source.width, h = transform_source.height;
            for (int j = 0; j <= grid_rows; j++) {
                for (int i = 0; i <= grid_cols; i++) {
                    pts += transform_src_x + w * i / grid_cols;
                    pts += transform_src_y + h * j / grid_rows;
                }
            }
            control = pts;
            canvas.queue_draw();
        }

        private int hit_control(double x, double y) {
            for (int i = 0; i < control.length / 2; i++) {
                double vx, vy, px, py;
                canvas.to_view(control[i * 2], control[i * 2 + 1], out vx, out vy);
                canvas.to_view(x, y, out px, out py);
                if ((vx - px).abs() < 10 && (vy - py).abs() < 10) return i;
            }
            return -1;
        }

        private bool inside_quad(double x, double y) {
            double[] quad = corner_points();
            bool inside = false;
            for (int i = 0, j = 3; i < 4; j = i++) {
                double xi = quad[i * 2], yi = quad[i * 2 + 1], xj = quad[j * 2], yj = quad[j * 2 + 1];
                if (((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)) inside = !inside;
            }
            return inside;
        }

        private double[] corner_points() {
            int stride = grid_cols + 1;
            int[] idx = { 0, grid_cols, grid_rows * stride + grid_cols, grid_rows * stride };
            double[] q = {};
            foreach (int i in idx) {
                q += control[i * 2];
                q += control[i * 2 + 1];
            }
            return q;
        }

        private void transform_press(double x, double y, Gdk.ModifierType state) {
            drag_point = hit_control(x, y);
            control_start = control;
            drag_move = drag_point < 0 && inside_quad(x, y);
            drag_rotate = drag_point < 0 && !drag_move && transform_mode == TransformMode.FREE;
        }

        private void transform_drag(double x, double y, Gdk.ModifierType state) {
            double dx = x - start_x, dy = y - start_y;
            var pts = control_start.copy();
            int n = pts.length / 2;
            if (drag_move) {
                for (int i = 0; i < n; i++) {
                    pts[i * 2] += dx;
                    pts[i * 2 + 1] += dy;
                }
            } else if (drag_rotate) {
                double cx = 0, cy = 0;
                for (int i = 0; i < n; i++) {
                    cx += pts[i * 2];
                    cy += pts[i * 2 + 1];
                }
                cx /= n;
                cy /= n;
                double a = Math.atan2(y - cy, x - cx) - Math.atan2(start_y - cy, start_x - cx);
                if ((state & Gdk.ModifierType.SHIFT_MASK) != 0) a = Math.round(a / (Math.PI / 12)) * (Math.PI / 12);
                for (int i = 0; i < n; i++) {
                    double px = pts[i * 2] - cx, py = pts[i * 2 + 1] - cy;
                    pts[i * 2] = cx + px * Math.cos(a) - py * Math.sin(a);
                    pts[i * 2 + 1] = cy + px * Math.sin(a) + py * Math.cos(a);
                }
            } else if (drag_point >= 0) {
                if (transform_mode == TransformMode.FREE && grid_cols == 1) {
                    int opposite = 3 - drag_point;
                    double ox = pts[opposite * 2], oy = pts[opposite * 2 + 1];
                    double sx0 = pts[drag_point * 2] - ox, sy0 = pts[drag_point * 2 + 1] - oy;
                    double sx = sx0.abs() > 1e-6 ? (x - ox) / sx0 : 1, sy = sy0.abs() > 1e-6 ? (y - oy) / sy0 : 1;
                    if ((state & Gdk.ModifierType.SHIFT_MASK) != 0) {
                        double s = (sx.abs() > sy.abs()) ? sx : sy;
                        sx = s;
                        sy = s;
                    }
                    for (int i = 0; i < n; i++) {
                        pts[i * 2] = ox + (pts[i * 2] - ox) * sx;
                        pts[i * 2 + 1] = oy + (pts[i * 2 + 1] - oy) * sy;
                    }
                } else {
                    pts[drag_point * 2] += dx;
                    pts[drag_point * 2 + 1] += dy;
                }
            }
            control = pts;
            canvas.queue_draw();
        }

        private void transform_release() {
            drag_point = -1;
            drag_move = false;
            drag_rotate = false;
            preview_transform();
        }

        private FloatImage render_transform(out int ox, out int oy) {
            const int SUB = 24;
            double[] mesh;
            if (grid_cols == 1) {
                double[] quad = { control[0], control[1], control[2], control[3], control[6], control[7], control[4], control[5] };
                mesh = RetouchMesh.mesh_from_quad(quad, SUB);
            } else {
                mesh = RetouchMesh.mesh_from_grid(control, grid_cols, grid_rows, SUB);
            }
            double minx = double.MAX, miny = double.MAX, maxx = -double.MAX, maxy = -double.MAX;
            for (int i = 0; i < mesh.length / 2; i++) {
                minx = double.min(minx, mesh[i * 2]);
                miny = double.min(miny, mesh[i * 2 + 1]);
                maxx = double.max(maxx, mesh[i * 2]);
                maxy = double.max(maxy, mesh[i * 2 + 1]);
            }
            ox = (int) Math.floor(double.max(minx, -doc.width));
            oy = (int) Math.floor(double.max(miny, -doc.height));
            int w = int.min((int) Math.ceil(maxx) - ox, doc.width * 3), h = int.min((int) Math.ceil(maxy) - oy, doc.height * 3);
            for (int i = 0; i < mesh.length / 2; i++) {
                mesh[i * 2] -= ox;
                mesh[i * 2 + 1] -= oy;
            }
            return RetouchMesh.render(transform_source, mesh, SUB, int.max(1, w), int.max(1, h));
        }

        public void preview_transform() {
            if (!transforming) return;
            int ox, oy;
            var img = render_transform(out ox, out oy);
            transform_layer.pixels = img;
            transform_layer.x = ox;
            transform_layer.y = oy;
            if (transform_layer.kind == RetouchLayerKind.EMBEDDED) doc.invalidate_layer(transform_layer);
            doc.recomposite();
        }

        public void apply_transform() {
            if (!transforming) return;
            int ox, oy;
            var img = render_transform(out ox, out oy);
            transform_layer.pixels = transform_source;
            transform_layer.x = transform_src_x;
            transform_layer.y = transform_src_y;
            doc.record_structure(_("Transform"));
            if (transform_layer.kind == RetouchLayerKind.EMBEDDED) {
                transform_layer.kind = RetouchLayerKind.RASTER;
                transform_layer.source_uri = "";
                doc.invalidate_layer(transform_layer);
            }
            transform_layer.pixels = img;
            transform_layer.x = ox;
            transform_layer.y = oy;
            transforming = false;
            transform_layer = null;
            transform_source = null;
            doc.recomposite();
            state_changed();
            canvas.queue_draw();
        }

        public void cancel_transform() {
            if (!transforming) return;
            if (transform_layer.kind == RetouchLayerKind.RASTER) transform_layer.pixels = transform_source;
            transform_layer.x = transform_src_x;
            transform_layer.y = transform_src_y;
            if (transform_layer.kind == RetouchLayerKind.EMBEDDED) doc.invalidate_layer(transform_layer);
            transforming = false;
            transform_layer = null;
            transform_source = null;
            doc.recomposite();
            state_changed();
            canvas.queue_draw();
        }

        private void view_point(double x, double y, out double vx, out double vy) {
            canvas.to_view(x, y, out vx, out vy);
        }

        private void draw_overlay(Cairo.Context cr) {
            if (doc == null) return;
            cr.set_line_width(1.5);
            if (transforming && control.length > 0) {
                int stride = grid_cols + 1;
                cr.set_source_rgba(1, 1, 1, 0.9);
                for (int j = 0; j <= grid_rows; j++) {
                    for (int i = 0; i <= grid_cols; i++) {
                        double vx, vy;
                        view_point(control[(j * stride + i) * 2], control[(j * stride + i) * 2 + 1], out vx, out vy);
                        if (i > 0) {
                            double px, py;
                            view_point(control[(j * stride + i - 1) * 2], control[(j * stride + i - 1) * 2 + 1], out px, out py);
                            cr.move_to(px, py);
                            cr.line_to(vx, vy);
                        }
                        if (j > 0) {
                            double px, py;
                            view_point(control[((j - 1) * stride + i) * 2], control[((j - 1) * stride + i) * 2 + 1], out px, out py);
                            cr.move_to(px, py);
                            cr.line_to(vx, vy);
                        }
                    }
                }
                cr.stroke();
                for (int i = 0; i < control.length / 2; i++) {
                    double vx, vy;
                    view_point(control[i * 2], control[i * 2 + 1], out vx, out vy);
                    cr.rectangle(vx - 5, vy - 5, 10, 10);
                    cr.set_source_rgba(1, 1, 1, 1);
                    cr.fill_preserve();
                    cr.set_source_rgba(0, 0, 0, 0.8);
                    cr.stroke();
                }
                return;
            }
            if (pressed && (tool == RetouchTool.MARQUEE_RECT || tool == RetouchTool.MARQUEE_ELLIPSE)) {
                double ax, ay, bx, by;
                view_point(start_x, start_y, out ax, out ay);
                view_point(last_x, last_y, out bx, out by);
                cr.save();
                if (tool == RetouchTool.MARQUEE_ELLIPSE) {
                    cr.translate((ax + bx) / 2, (ay + by) / 2);
                    cr.scale(double.max(0.5, (bx - ax).abs() / 2), double.max(0.5, (by - ay).abs() / 2));
                    cr.arc(0, 0, 1, 0, 2 * Math.PI);
                    cr.restore();
                } else {
                    cr.restore();
                    cr.rectangle(double.min(ax, bx), double.min(ay, by), (bx - ax).abs(), (by - ay).abs());
                }
                dashed(cr);
            }
            if (pressed && tool == RetouchTool.PATCH && doc.selection != null) {
                double ax, ay, bx, by;
                view_point(start_x, start_y, out ax, out ay);
                view_point(last_x, last_y, out bx, out by);
                cr.move_to(ax, ay);
                cr.line_to(bx, by);
                dashed(cr);
            }
            if ((tool == RetouchTool.LASSO || tool == RetouchTool.QUICK_SELECT) && path.length >= 4 && pressed) {
                for (int i = 0; i < path.length / 2; i++) {
                    double vx, vy;
                    view_point(path[i * 2], path[i * 2 + 1], out vx, out vy);
                    if (i == 0) cr.move_to(vx, vy);
                    else cr.line_to(vx, vy);
                }
                if (tool == RetouchTool.LASSO) cr.close_path();
                dashed(cr);
            }
            if (tool == RetouchTool.POLYGON && polygon_points.length >= 2) {
                for (int i = 0; i < polygon_points.length / 2; i++) {
                    double vx, vy;
                    view_point(polygon_points[i * 2], polygon_points[i * 2 + 1], out vx, out vy);
                    if (i == 0) cr.move_to(vx, vy);
                    else cr.line_to(vx, vy);
                }
                if (hover_x >= 0) {
                    double hx, hy;
                    view_point(hover_x, hover_y, out hx, out hy);
                    cr.line_to(hx, hy);
                }
                dashed(cr);
            }
            if (tool.uses_brush() && hover_x >= 0) {
                double vx, vy;
                view_point(hover_x, hover_y, out vx, out vy);
                double r = brush_size / 2 * canvas.zoom;
                cr.arc(vx, vy, r, 0, 2 * Math.PI);
                cr.set_source_rgba(0, 0, 0, 0.7);
                cr.set_line_width(2.5);
                cr.stroke_preserve();
                cr.set_source_rgba(1, 1, 1, 0.9);
                cr.set_line_width(1);
                cr.stroke();
                if (hardness < 0.95) {
                    cr.arc(vx, vy, r * hardness, 0, 2 * Math.PI);
                    cr.set_source_rgba(1, 1, 1, 0.4);
                    cr.stroke();
                }
            }
            if ((tool == RetouchTool.CLONE || tool == RetouchTool.HEAL) && clone_source_set) {
                double sx = clone_src_x, sy = clone_src_y;
                if (clone_aligned_started && hover_x >= 0) {
                    sx = hover_x + clone_dx;
                    sy = hover_y + clone_dy;
                }
                double vx, vy;
                view_point(sx, sy, out vx, out vy);
                cr.move_to(vx - 8, vy);
                cr.line_to(vx + 8, vy);
                cr.move_to(vx, vy - 8);
                cr.line_to(vx, vy + 8);
                cr.set_source_rgba(0, 0, 0, 0.8);
                cr.set_line_width(3);
                cr.stroke_preserve();
                cr.set_source_rgba(1, 1, 1, 1);
                cr.set_line_width(1.2);
                cr.stroke();
            }
        }

        private void dashed(Cairo.Context cr) {
            cr.set_source_rgba(0, 0, 0, 0.9);
            cr.set_line_width(1.2);
            cr.set_dash({ 4.0, 4.0 }, 0);
            cr.stroke_preserve();
            cr.set_source_rgba(1, 1, 1, 0.9);
            cr.set_dash({ 4.0, 4.0 }, 4);
            cr.stroke();
            cr.set_dash(null, 0);
        }
    }
}
