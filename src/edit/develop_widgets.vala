using Gtk;
using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class HistogramView : Widget {
        private int[] red = new int[256];
        private int[] green = new int[256];
        private int[] blue = new int[256];
        private int[] luma = new int[256];
        private int peak = 1;
        public bool clipped_shadows { get; private set; default = false; }
        public bool clipped_highlights { get; private set; default = false; }

        construct {
            add_css_class("photo-histogram");
            height_request = 96;
            hexpand = true;
        }

        public void update_from_rgba8(uint8[] px) {
            var r = new int[256];
            var g = new int[256];
            var b = new int[256];
            var l = new int[256];
            int n = px.length / 4;
            int step = int.max(1, n / 250000);
            int lo = 0, hi = 0, count = 0;
            for (int i = 0; i < n; i += step) {
                int o = i * 4;
                if (px[o + 3] == 0) continue;
                r[px[o]]++;
                g[px[o + 1]]++;
                b[px[o + 2]]++;
                int y = (int) (0.2126 * px[o] + 0.7152 * px[o + 1] + 0.0722 * px[o + 2] + 0.5);
                l[y.clamp(0, 255)]++;
                if (px[o] == 0 && px[o + 1] == 0 && px[o + 2] == 0) lo++;
                if (px[o] == 255 || px[o + 1] == 255 || px[o + 2] == 255) hi++;
                count++;
            }
            red = r;
            green = g;
            blue = b;
            luma = l;
            int m = 1;
            for (int i = 1; i < 255; i++) m = int.max(m, int.max(r[i], int.max(g[i], b[i])));
            peak = m;
            clipped_shadows = count > 0 && lo > count / 1000;
            clipped_highlights = count > 0 && hi > count / 1000;
            queue_draw();
        }

        public int[] luma_bins() {
            return luma;
        }

        private void channel_path(Cairo.Context cr, int[] bins, double w, double h) {
            cr.move_to(0, h);
            for (int i = 0; i < 256; i++) {
                double v = Math.sqrt((double) bins[i] / peak).clamp(0, 1);
                cr.line_to(i * w / 255.0, h - v * (h - 2));
            }
            cr.line_to(w, h);
            cr.close_path();
        }

        public override void snapshot(Snapshot snapshot) {
            int w = get_width(), h = get_height();
            if (w <= 0 || h <= 0) return;
            var rect = Graphene.Rect();
            rect.init(0, 0, w, h);
            var rounded = Gsk.RoundedRect();
            rounded.init_from_rect(rect, 10);
            snapshot.push_rounded_clip(rounded);
            var bg = Gdk.RGBA();
            bg.parse("rgba(0,0,0,0.30)");
            snapshot.append_color(bg, rect);
            var cr = snapshot.append_cairo(rect);
            cr.set_operator(Cairo.Operator.ADD);
            cr.set_source_rgba(0.95, 0.25, 0.25, 0.55);
            channel_path(cr, red, w, h);
            cr.fill();
            cr.set_source_rgba(0.3, 0.85, 0.35, 0.55);
            channel_path(cr, green, w, h);
            cr.fill();
            cr.set_source_rgba(0.3, 0.45, 1.0, 0.55);
            channel_path(cr, blue, w, h);
            cr.fill();
            cr.set_operator(Cairo.Operator.OVER);
            cr.set_source_rgba(1, 1, 1, 0.12);
            for (int i = 1; i < 4; i++) {
                cr.rectangle(Math.round(w * i / 4.0), 0, 1, h);
                cr.fill();
            }
            if (clipped_shadows) {
                cr.set_source_rgba(0.35, 0.55, 1.0, 0.95);
                cr.rectangle(4, 4, 8, 8);
                cr.fill();
            }
            if (clipped_highlights) {
                cr.set_source_rgba(1, 0.35, 0.3, 0.95);
                cr.rectangle(w - 12, 4, 8, 8);
                cr.fill();
            }
            snapshot.pop();
        }
    }

    public class CurveEditor : Widget {
        public DevelopSettings? settings { get; set; }
        public string channel { get; set; default = "master"; }
        public int[]? histogram { get; set; }

        public signal void begin_change();
        public signal void changed();

        private int drag_index = -1;
        private const double MARGIN = 8;

        construct {
            add_css_class("photo-curve-editor");
            height_request = 220;
            hexpand = true;
            focusable = true;
            notify["channel"].connect(queue_draw);
            notify["histogram"].connect(queue_draw);
            var drag = new GestureDrag();
            drag.drag_begin.connect(on_begin);
            drag.drag_update.connect(on_update);
            drag.drag_end.connect((x, y) => {
                if (drag_index >= 0) changed();
                drag_index = -1;
            });
            add_controller(drag);
            var click = new GestureClick();
            click.pressed.connect((n, x, y) => {
                if (n != 2 || settings == null) return;
                var c = settings.curve(channel);
                int i = hit(x, y);
                if (i < 0) return;
                begin_change();
                c.remove_at(i);
                changed();
                queue_draw();
            });
            add_controller(click);
        }

        private void to_view(double x, double y, out double vx, out double vy) {
            double w = get_width() - MARGIN * 2, h = get_height() - MARGIN * 2;
            vx = MARGIN + x * w;
            vy = MARGIN + (1 - y) * h;
        }

        private void from_view(double vx, double vy, out double x, out double y) {
            double w = get_width() - MARGIN * 2, h = get_height() - MARGIN * 2;
            x = ((vx - MARGIN) / w).clamp(0, 1);
            y = (1 - (vy - MARGIN) / h).clamp(0, 1);
        }

        private int hit(double vx, double vy) {
            if (settings == null) return -1;
            var c = settings.curve(channel);
            for (int i = 0; i < c.xs.length; i++) {
                double px, py;
                to_view(c.xs[i], c.ys[i], out px, out py);
                if ((px - vx).abs() < 10 && (py - vy).abs() < 10) return i;
            }
            return -1;
        }

        private double start_x;
        private double start_y;

        private void on_begin(double x, double y) {
            if (settings == null) return;
            start_x = x;
            start_y = y;
            begin_change();
            int i = hit(x, y);
            var c = settings.curve(channel);
            if (i < 0) {
                double cx, cy;
                from_view(x, y, out cx, out cy);
                var lut = c.lut(256);
                c.add(cx, lut[(int) (cx * 255)]);
                i = hit(x, y);
                if (i < 0) {
                    for (int k = 0; k < c.xs.length; k++) if ((c.xs[k] - cx).abs() < 1e-9) i = k;
                }
            }
            drag_index = i;
            queue_draw();
        }

        private void on_update(double dx, double dy) {
            if (settings == null || drag_index < 0) return;
            var c = settings.curve(channel);
            if (drag_index >= c.xs.length) return;
            double nx, ny;
            from_view(start_x + dx, start_y + dy, out nx, out ny);
            double lo = drag_index > 0 ? c.xs[drag_index - 1] + 0.01 : 0;
            double hi = drag_index < c.xs.length - 1 ? c.xs[drag_index + 1] - 0.01 : 1;
            c.xs[drag_index] = nx.clamp(lo, hi);
            c.ys[drag_index] = ny;
            changed();
            queue_draw();
        }

        public override void snapshot(Snapshot snapshot) {
            int w = get_width(), h = get_height();
            if (w <= 0 || h <= 0) return;
            var rect = Graphene.Rect();
            rect.init(0, 0, w, h);
            var rounded = Gsk.RoundedRect();
            rounded.init_from_rect(rect, 10);
            snapshot.push_rounded_clip(rounded);
            var bg = Gdk.RGBA();
            bg.parse("rgba(0,0,0,0.30)");
            snapshot.append_color(bg, rect);
            var cr = snapshot.append_cairo(rect);
            double iw = w - MARGIN * 2, ih = h - MARGIN * 2;
            if (histogram != null && histogram.length == 256) {
                int peak = 1;
                for (int i = 1; i < 255; i++) peak = int.max(peak, histogram[i]);
                cr.set_source_rgba(1, 1, 1, 0.08);
                cr.move_to(MARGIN, MARGIN + ih);
                for (int i = 0; i < 256; i++) cr.line_to(MARGIN + i * iw / 255, MARGIN + ih - Math.sqrt((double) histogram[i] / peak).clamp(0, 1) * ih);
                cr.line_to(MARGIN + iw, MARGIN + ih);
                cr.close_path();
                cr.fill();
            }
            cr.set_source_rgba(1, 1, 1, 0.12);
            cr.set_line_width(1);
            for (int i = 1; i < 4; i++) {
                cr.move_to(MARGIN + Math.round(iw * i / 4) + 0.5, MARGIN);
                cr.line_to(MARGIN + Math.round(iw * i / 4) + 0.5, MARGIN + ih);
                cr.move_to(MARGIN, MARGIN + Math.round(ih * i / 4) + 0.5);
                cr.line_to(MARGIN + iw, MARGIN + Math.round(ih * i / 4) + 0.5);
            }
            cr.stroke();
            cr.set_source_rgba(1, 1, 1, 0.25);
            cr.move_to(MARGIN, MARGIN + ih);
            cr.line_to(MARGIN + iw, MARGIN);
            cr.stroke();
            if (settings != null) {
                var c = settings.curve(channel);
                var lut = channel == "master" ? compose_master() : c.lut(256);
                switch (channel) {
                    case "red": cr.set_source_rgba(1, 0.4, 0.4, 1); break;
                    case "green": cr.set_source_rgba(0.45, 0.95, 0.5, 1); break;
                    case "blue": cr.set_source_rgba(0.45, 0.6, 1, 1); break;
                    default: cr.set_source_rgba(1, 1, 1, 0.95); break;
                }
                cr.set_line_width(2);
                for (int i = 0; i < lut.length; i++) {
                    double x = MARGIN + (double) i / (lut.length - 1) * iw, y = MARGIN + (1 - lut[i]) * ih;
                    if (i == 0) cr.move_to(x, y);
                    else cr.line_to(x, y);
                }
                cr.stroke();
                for (int i = 0; i < c.xs.length; i++) {
                    double px, py;
                    to_view(c.xs[i], c.ys[i], out px, out py);
                    cr.arc(px, py, i == drag_index ? 6 : 4.5, 0, 2 * Math.PI);
                    cr.set_source_rgba(1, 1, 1, 1);
                    cr.fill_preserve();
                    cr.set_source_rgba(0, 0, 0, 0.5);
                    cr.set_line_width(1);
                    cr.stroke();
                }
            }
            snapshot.pop();
        }

        private float[] compose_master() {
            var param = Tone.parametric_lut(settings);
            var master = settings.curve("master").lut(1024);
            var out_lut = new float[256];
            for (int i = 0; i < 256; i++) out_lut[i] = Tone.lookup(master, Tone.lookup(param, i / 255.0f));
            return out_lut;
        }
    }

    public class ColorWheel : Widget {
        public double hue { get; set; default = 0; }
        public double saturation { get; set; default = 0; }

        public signal void begin_change();
        public signal void changed();

        private double drag_x;
        private double drag_y;

        construct {
            add_css_class("photo-color-wheel");
            width_request = 120;
            height_request = 120;
            halign = Align.CENTER;
            notify["hue"].connect(queue_draw);
            notify["saturation"].connect(queue_draw);
            var drag = new GestureDrag();
            drag.drag_begin.connect((x, y) => {
                begin_change();
                drag_x = x;
                drag_y = y;
                pick(x, y);
            });
            drag.drag_update.connect((dx, dy) => pick(drag_x + dx, drag_y + dy));
            drag.drag_end.connect((x, y) => changed());
            add_controller(drag);
            var click = new GestureClick();
            click.pressed.connect((n, x, y) => {
                if (n != 2) return;
                begin_change();
                saturation = 0;
                changed();
            });
            add_controller(click);
        }

        private void pick(double x, double y) {
            double cx = get_width() / 2.0, cy = get_height() / 2.0;
            double r = double.min(cx, cy) - 4;
            double dx = x - cx, dy = cy - y;
            double d = Math.sqrt(dx * dx + dy * dy);
            double a = Math.atan2(dy, dx) * 180 / Math.PI;
            if (a < 0) a += 360;
            hue = a;
            saturation = (d / r).clamp(0, 1);
            changed();
        }

        public override void snapshot(Snapshot snapshot) {
            int w = get_width(), h = get_height();
            if (w <= 0 || h <= 0) return;
            var rect = Graphene.Rect();
            rect.init(0, 0, w, h);
            var cr = snapshot.append_cairo(rect);
            double cx = w / 2.0, cy = h / 2.0, r = double.min(cx, cy) - 4;
            for (int i = 0; i < 360; i += 2) {
                float rr, gg, bb;
                Tone.hsl_to_rgb(i, 0.75f, 0.55f, out rr, out gg, out bb);
                var pattern = new Cairo.Pattern.radial(cx, cy, 0, cx, cy, r);
                pattern.add_color_stop_rgba(0, 0.5, 0.5, 0.5, 1);
                pattern.add_color_stop_rgba(1, rr, gg, bb, 1);
                cr.set_source(pattern);
                cr.move_to(cx, cy);
                double a0 = -(i - 1.2) * Math.PI / 180, a1 = -(i + 2.2) * Math.PI / 180;
                cr.arc_negative(cx, cy, r, a0, a1);
                cr.close_path();
                cr.fill();
            }
            cr.set_source_rgba(1, 1, 1, 0.35);
            cr.set_line_width(1);
            cr.arc(cx, cy, r, 0, 2 * Math.PI);
            cr.stroke();
            double px = cx + Math.cos(hue * Math.PI / 180) * saturation * r;
            double py = cy - Math.sin(hue * Math.PI / 180) * saturation * r;
            cr.arc(px, py, 6, 0, 2 * Math.PI);
            cr.set_source_rgba(1, 1, 1, 1);
            cr.set_line_width(2.5);
            cr.stroke_preserve();
            cr.set_source_rgba(0, 0, 0, 0.35);
            cr.set_line_width(1);
            cr.stroke();
        }
    }
}
