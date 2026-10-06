using Gtk;
using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class RetouchCanvas : Widget {
        public RetouchDocument? doc { get; private set; default = null; }
        public double zoom { get; private set; default = 1.0; }
        public double pan_x = 0;
        public double pan_y = 0;
        public float[]? overlay_mask = null;
        public bool show_overlay_mask = false;
        public bool fitted = true;

        public signal void pointer_pressed(double x, double y, uint button, Gdk.ModifierType state);
        public signal void pointer_dragged(double x, double y, Gdk.ModifierType state);
        public signal void pointer_released(double x, double y, Gdk.ModifierType state);
        public signal void pointer_moved(double x, double y);
        public signal void draw_overlay(Cairo.Context cr);
        public signal void zoom_changed();

        private Gdk.Texture? view_texture = null;
        private bool view_dirty = true;
        private int view_w = 0;
        private int view_h = 0;
        private double view_x = 0;
        private double view_y = 0;
        private uint8[]? encode_lut = null;
        private bool panning = false;
        private double pan_start_x;
        private double pan_start_y;
        private double drag_origin_x;
        private double drag_origin_y;
        private bool space_down = false;
        private bool dragging = false;
        private ulong changed_handler = 0;
        private int ants_phase = 0;

        construct {
            hexpand = true;
            vexpand = true;
            focusable = true;
            add_css_class("photo-edit-canvas");
            var lut = new uint8[4096];
            for (int i = 0; i < 4096; i++) lut[i] = Transfer.encode_byte(i / 4095.0f);
            encode_lut = lut;

            var drag = new GestureDrag();
            drag.button = 0;
            drag.drag_begin.connect((x, y) => {
                grab_focus();
                uint button = drag.get_current_button();
                var state = drag.get_current_event_state();
                if (button == 2 || space_down) {
                    panning = true;
                    pan_start_x = pan_x;
                    pan_start_y = pan_y;
                    drag_origin_x = x;
                    drag_origin_y = y;
                    set_cursor_from_name("grabbing");
                    return;
                }
                dragging = true;
                double dx, dy;
                to_doc(x, y, out dx, out dy);
                pointer_pressed(dx, dy, button, state);
            });
            drag.drag_update.connect((ox, oy) => {
                double sx, sy;
                drag.get_start_point(out sx, out sy);
                if (panning) {
                    pan_x = pan_start_x + ox;
                    pan_y = pan_start_y + oy;
                    fitted = false;
                    view_dirty = true;
                    queue_draw();
                    return;
                }
                if (!dragging) return;
                double dx, dy;
                to_doc(sx + ox, sy + oy, out dx, out dy);
                pointer_dragged(dx, dy, drag.get_current_event_state());
            });
            drag.drag_end.connect((ox, oy) => {
                double sx, sy;
                drag.get_start_point(out sx, out sy);
                if (panning) {
                    panning = false;
                    set_cursor_from_name(space_down ? "grab" : null);
                    return;
                }
                if (!dragging) return;
                dragging = false;
                double dx, dy;
                to_doc(sx + ox, sy + oy, out dx, out dy);
                pointer_released(dx, dy, drag.get_current_event_state());
            });
            add_controller(drag);

            var motion = new EventControllerMotion();
            motion.motion.connect((x, y) => {
                double dx, dy;
                to_doc(x, y, out dx, out dy);
                pointer_moved(dx, dy);
            });
            add_controller(motion);

            var scroll = new EventControllerScroll(EventControllerScrollFlags.BOTH_AXES);
            scroll.scroll.connect((dx, dy) => {
                var state = scroll.get_current_event_state();
                if ((state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                    double px = get_width() / 2.0, py = get_height() / 2.0;
                    zoom_at(zoom * (dy < 0 ? 1.15 : 1 / 1.15), px, py);
                    return true;
                }
                pan_x -= dx * 40;
                pan_y -= dy * 40;
                fitted = false;
                view_dirty = true;
                queue_draw();
                return true;
            });
            add_controller(scroll);

            var pinch = new GestureZoom();
            double pinch_start = 1;
            pinch.begin.connect(() => pinch_start = zoom);
            pinch.scale_changed.connect((s) => zoom_at(pinch_start * s, get_width() / 2.0, get_height() / 2.0));
            add_controller(pinch);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval == Gdk.Key.space) {
                    space_down = true;
                    set_cursor_from_name("grab");
                    return true;
                }
                return false;
            });
            keys.key_released.connect((keyval, code, state) => {
                if (keyval == Gdk.Key.space) {
                    space_down = false;
                    set_cursor_from_name(null);
                }
            });
            add_controller(keys);

            Timeout.add(300, () => {
                if (doc != null && doc.selection != null && get_mapped()) {
                    ants_phase = (ants_phase + 1) % 8;
                    view_dirty = true;
                    queue_draw();
                }
                return Source.CONTINUE;
            });
        }

        public void set_document(RetouchDocument? d) {
            if (doc != null && changed_handler != 0) doc.disconnect(changed_handler);
            doc = d;
            changed_handler = 0;
            if (doc != null) changed_handler = doc.changed.connect((x, y, w, h) => invalidate());
            fitted = true;
            invalidate();
        }

        public void invalidate() {
            view_dirty = true;
            queue_draw();
        }

        public void to_doc(double x, double y, out double dx, out double dy) {
            dx = (x - pan_x) / zoom;
            dy = (y - pan_y) / zoom;
        }

        public void to_view(double dx, double dy, out double x, out double y) {
            x = dx * zoom + pan_x;
            y = dy * zoom + pan_y;
        }

        public void fit() {
            fitted = true;
            apply_fit();
            invalidate();
            zoom_changed();
        }

        private void apply_fit() {
            if (doc == null) return;
            double aw = double.max(1, get_width() - 48), ah = double.max(1, get_height() - 140);
            zoom = double.min(aw / doc.width, ah / doc.height);
            if (zoom > 1) zoom = 1;
            pan_x = (get_width() - doc.width * zoom) / 2;
            pan_y = 56 + (get_height() - 140 - doc.height * zoom) / 2;
        }

        public void zoom_at(double z, double px, double py) {
            if (doc == null) return;
            z = z.clamp(0.02, 32);
            double dx = (px - pan_x) / zoom, dy = (py - pan_y) / zoom;
            zoom = z;
            pan_x = px - dx * zoom;
            pan_y = py - dy * zoom;
            fitted = false;
            invalidate();
            zoom_changed();
        }

        public void apply_zoom(double z) {
            zoom_at(z, get_width() / 2.0, get_height() / 2.0);
        }

        public override void size_allocate(int width, int height, int baseline) {
            base.size_allocate(width, height, baseline);
            if (fitted) {
                double before = zoom;
                apply_fit();
                if (before != zoom) Idle.add(() => {
                    zoom_changed();
                    return Source.REMOVE;
                });
            }
            view_dirty = true;
        }

        private void rebuild_view() {
            view_dirty = false;
            view_texture = null;
            if (doc == null) return;
            double x0 = double.max(0, pan_x), y0 = double.max(0, pan_y);
            double x1 = double.min(get_width(), pan_x + doc.width * zoom), y1 = double.min(get_height(), pan_y + doc.height * zoom);
            int w = (int) Math.ceil(x1) - (int) Math.floor(x0), h = (int) Math.ceil(y1) - (int) Math.floor(y0);
            if (w <= 0 || h <= 0) return;
            int scale = get_scale_factor();
            view_x = Math.floor(x0);
            view_y = Math.floor(y0);
            view_w = w * scale;
            view_h = h * scale;
            var px = new uint8[(size_t) view_w * view_h * 4];
            var comp = doc.composite;
            unowned double[] m = WorkingSpace.to_srgb_matrix();
            float m0 = (float) m[0], m1 = (float) m[1], m2 = (float) m[2], m3 = (float) m[3], m4 = (float) m[4];
            float m5 = (float) m[5], m6 = (float) m[6], m7 = (float) m[7], m8 = (float) m[8];
            double inv = 1.0 / (zoom * scale);
            int samples = zoom * scale >= 1 ? 1 : int.min(4, (int) Math.ceil(inv));
            int dw = doc.width, dh = doc.height;
            float[]? sel = doc.selection;
            float[]? ovl = show_overlay_mask ? overlay_mask : null;
            int phase = ants_phase;
            unowned uint8[] lut = encode_lut;
            double ox = view_x - pan_x, oy = view_y - pan_y;
            int vw = view_w;
            Parallel.range(view_h, (start, end) => {
                for (int ty = start; ty < end; ty++) {
                    for (int tx = 0; tx < vw; tx++) {
                        double dxs = (ox + (tx + 0.5) / scale) / zoom, dys = (oy + (ty + 0.5) / scale) / zoom;
                        float r = 0, g = 0, b = 0, a = 0;
                        int n = 0;
                        for (int sy = 0; sy < samples; sy++) {
                            for (int sx = 0; sx < samples; sx++) {
                                int ix = (int) (dxs + (sx - (samples - 1) / 2.0) * inv), iy = (int) (dys + (sy - (samples - 1) / 2.0) * inv);
                                if (ix < 0 || iy < 0 || ix >= dw || iy >= dh) continue;
                                size_t i = comp.offset(ix, iy);
                                float ca = comp.data[i + 3];
                                r += comp.data[i] * ca;
                                g += comp.data[i + 1] * ca;
                                b += comp.data[i + 2] * ca;
                                a += ca;
                                n++;
                            }
                        }
                        if (n > 0) {
                            r /= n;
                            g /= n;
                            b /= n;
                            a /= n;
                        }
                        float lr = m0 * r + m1 * g + m2 * b, lg = m3 * r + m4 * g + m5 * b, lb = m6 * r + m7 * g + m8 * b;
                        int cx = (int) dxs, cy = (int) dys;
                        bool check = ((((int) ((ox * scale + tx) / 8)) + ((int) ((oy * scale + ty) / 8))) & 1) == 0;
                        float bg = check ? 0.8f : 0.6f;
                        lr += bg * (1 - a);
                        lg += bg * (1 - a);
                        lb += bg * (1 - a);
                        if (ovl != null && cx >= 0 && cy >= 0 && cx < dw && cy < dh) {
                            float mv = 1 - ovl[(size_t) cy * dw + cx];
                            lr = lr * (1 - mv * 0.5f) + 0.9f * mv * 0.5f;
                            lg = lg * (1 - mv * 0.5f);
                            lb = lb * (1 - mv * 0.5f);
                        }
                        size_t o = ((size_t) ty * vw + tx) * 4;
                        px[o] = lut[(int) (lr.clamp(0, 1) * 4095)];
                        px[o + 1] = lut[(int) (lg.clamp(0, 1) * 4095)];
                        px[o + 2] = lut[(int) (lb.clamp(0, 1) * 4095)];
                        px[o + 3] = 255;
                        if (sel != null && cx >= 0 && cy >= 0 && cx < dw && cy < dh) {
                            bool inside = sel[(size_t) cy * dw + cx] >= 0.5f;
                            int nx = (int) ((ox + (tx + 1.5) / scale) / zoom), ny = (int) ((oy + (ty + 1.5) / scale) / zoom);
                            bool edge = false;
                            if (nx != cx && nx < dw) edge = (sel[(size_t) cy * dw + nx] >= 0.5f) != inside;
                            if (!edge && ny != cy && ny < dh) edge = (sel[(size_t) ny * dw + cx] >= 0.5f) != inside;
                            if (edge) {
                                uint8 v = (((tx + ty + phase) / 4) & 1) == 0 ? 0 : 255;
                                px[o] = v;
                                px[o + 1] = v;
                                px[o + 2] = v;
                            }
                        }
                    }
                }
            }, 4);
            view_texture = new Gdk.MemoryTexture(view_w, view_h, Gdk.MemoryFormat.R8G8B8A8, new Bytes.take(px), view_w * 4);
        }

        public override void snapshot(Snapshot snapshot) {
            if (doc == null) return;
            if (view_dirty) rebuild_view();
            if (view_texture != null) {
                var rect = Graphene.Rect();
                int scale = get_scale_factor();
                rect.init((float) view_x, (float) view_y, (float) view_w / scale, (float) view_h / scale);
                snapshot.append_texture(view_texture, rect);
            }
            var bounds = Graphene.Rect();
            bounds.init(0, 0, get_width(), get_height());
            var cr = snapshot.append_cairo(bounds);
            draw_overlay(cr);
        }
    }
}
