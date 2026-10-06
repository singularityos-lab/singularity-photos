namespace Singularity.Apps.Photos {

    public class EditImage : Object {
        public int width;
        public int height;
        public uint8[] data;

        public EditImage(int width, int height) {
            this.width = width;
            this.height = height;
            data = new uint8[(size_t) width * height * 4];
        }

        public EditImage.from_rgba(int width, int height, uint8[] rgba, int stride, bool has_alpha) {
            this(width, height);
            int channels = has_alpha ? 4 : 3;
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    int s = y * stride + x * channels;
                    int d = (y * width + x) * 4;
                    data[d] = rgba[s];
                    data[d + 1] = rgba[s + 1];
                    data[d + 2] = rgba[s + 2];
                    data[d + 3] = has_alpha ? rgba[s + 3] : 255;
                }
            }
        }

        public EditImage copy() {
            var c = new EditImage(width, height);
            Memory.copy(c.data, data, data.length);
            return c;
        }

        public void get_pixel(int x, int y, out uint8 r, out uint8 g, out uint8 b, out uint8 a) {
            int i = (y * width + x) * 4;
            r = data[i];
            g = data[i + 1];
            b = data[i + 2];
            a = data[i + 3];
        }

        public void set_pixel(int x, int y, uint8 r, uint8 g, uint8 b, uint8 a = 255) {
            int i = (y * width + x) * 4;
            data[i] = r;
            data[i + 1] = g;
            data[i + 2] = b;
            data[i + 3] = a;
        }

        public EditImage scaled_to_fit(int max_side) {
            if (width <= max_side && height <= max_side) return this;
            double f = (double) max_side / int.max(width, height);
            int w = int.max(1, (int) Math.round(width * f));
            int h = int.max(1, (int) Math.round(height * f));
            var out_img = new EditImage(w, h);
            double sx = (double) width / w, sy = (double) height / h;
            for (int y = 0; y < h; y++) {
                int y0 = (int) (y * sy), y1 = int.max(y0 + 1, (int) ((y + 1) * sy));
                y1 = int.min(y1, height);
                for (int x = 0; x < w; x++) {
                    int x0 = (int) (x * sx), x1 = int.max(x0 + 1, (int) ((x + 1) * sx));
                    x1 = int.min(x1, width);
                    uint acc_r = 0, acc_g = 0, acc_b = 0, acc_a = 0, n = 0;
                    for (int yy = y0; yy < y1; yy++) {
                        for (int xx = x0; xx < x1; xx++) {
                            int i = (yy * width + xx) * 4;
                            acc_r += data[i];
                            acc_g += data[i + 1];
                            acc_b += data[i + 2];
                            acc_a += data[i + 3];
                            n++;
                        }
                    }
                    int d = (y * w + x) * 4;
                    out_img.data[d] = (uint8) ((acc_r + n / 2) / n);
                    out_img.data[d + 1] = (uint8) ((acc_g + n / 2) / n);
                    out_img.data[d + 2] = (uint8) ((acc_b + n / 2) / n);
                    out_img.data[d + 3] = (uint8) ((acc_a + n / 2) / n);
                }
            }
            return out_img;
        }
    }

    namespace EditPipeline {

        public const double LUMA_R = 0.2126;
        public const double LUMA_G = 0.7152;
        public const double LUMA_B = 0.0722;

        public double smoothstep(double e0, double e1, double x) {
            double t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
            return t * t * (3.0 - 2.0 * t);
        }

        public uint8 to_byte(double v) {
            return (uint8) (v.clamp(0.0, 1.0) * 255.0 + 0.5);
        }

        public double straighten_scale(double w, double h, double degrees) {
            double t = (degrees.abs() * Math.PI / 180.0);
            if (t < 1e-9 || w <= 0 || h <= 0) return 1.0;
            return Math.cos(t) + double.max(w / h, h / w) * Math.sin(t);
        }

        public void rotated_size(EditParams p, int w0, int h0, out int w1, out int h1) {
            bool swap = p.quarter_turns % 2 == 1;
            w1 = swap ? h0 : w0;
            h1 = swap ? w0 : h0;
        }

        public void output_size(EditParams p, int w0, int h0, out int ow, out int oh) {
            int w1, h1;
            rotated_size(p, w0, h0, out w1, out h1);
            ow = int.max(1, (int) Math.round(p.crop_w * w1));
            oh = int.max(1, (int) Math.round(p.crop_h * h1));
        }

        public void map_point(EditParams p, int w0, int h0, double ox, double oy, out double sx, out double sy) {
            int w1, h1;
            rotated_size(p, w0, h0, out w1, out h1);
            double px = p.crop_x * w1 + ox;
            double py = p.crop_y * h1 + oy;
            if (p.straighten.abs() > 1e-9) {
                double s = straighten_scale(w1, h1, p.straighten);
                double a = -p.straighten * Math.PI / 180.0;
                double cx = w1 / 2.0, cy = h1 / 2.0;
                double dx = px - cx, dy = py - cy;
                double rx = dx * Math.cos(a) - dy * Math.sin(a);
                double ry = dx * Math.sin(a) + dy * Math.cos(a);
                px = cx + rx / s;
                py = cy + ry / s;
            }
            if (p.flip) px = w1 - px;
            switch (p.quarter_turns) {
                case 1:
                    sx = py;
                    sy = h0 - px;
                    break;
                case 2:
                    sx = w0 - px;
                    sy = h0 - py;
                    break;
                case 3:
                    sx = w0 - py;
                    sy = px;
                    break;
                default:
                    sx = px;
                    sy = py;
                    break;
            }
        }

        private void sample(EditImage src, double x, double y, out double r, out double g, out double b, out double a) {
            double fx = x - 0.5, fy = y - 0.5;
            fx = fx.clamp(0.0, src.width - 1);
            fy = fy.clamp(0.0, src.height - 1);
            int x0 = (int) Math.floor(fx), y0 = (int) Math.floor(fy);
            int x1 = int.min(x0 + 1, src.width - 1), y1 = int.min(y0 + 1, src.height - 1);
            double tx = fx - x0, ty = fy - y0;
            int i00 = (y0 * src.width + x0) * 4, i10 = (y0 * src.width + x1) * 4;
            int i01 = (y1 * src.width + x0) * 4, i11 = (y1 * src.width + x1) * 4;
            double w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty;
            unowned uint8[] d = src.data;
            r = d[i00] * w00 + d[i10] * w10 + d[i01] * w01 + d[i11] * w11;
            g = d[i00 + 1] * w00 + d[i10 + 1] * w10 + d[i01 + 1] * w01 + d[i11 + 1] * w11;
            b = d[i00 + 2] * w00 + d[i10 + 2] * w10 + d[i01 + 2] * w01 + d[i11 + 2] * w11;
            a = d[i00 + 3] * w00 + d[i10 + 3] * w10 + d[i01 + 3] * w01 + d[i11 + 3] * w11;
        }

        public EditImage apply_geometry(EditImage src, EditParams p) {
            if (!p.has_geometry()) return src.copy();
            int ow, oh;
            output_size(p, src.width, src.height, out ow, out oh);
            var out_img = new EditImage(ow, oh);
            int w1, h1;
            rotated_size(p, src.width, src.height, out w1, out h1);
            double fx = p.crop_w * w1 / ow, fy = p.crop_h * h1 / oh;
            for (int y = 0; y < oh; y++) {
                for (int x = 0; x < ow; x++) {
                    double sx, sy;
                    map_point(p, src.width, src.height, (x + 0.5) * fx, (y + 0.5) * fy, out sx, out sy);
                    double r, g, b, a;
                    sample(src, sx, sy, out r, out g, out b, out a);
                    int i = (y * ow + x) * 4;
                    out_img.data[i] = (uint8) (r + 0.5).clamp(0, 255);
                    out_img.data[i + 1] = (uint8) (g + 0.5).clamp(0, 255);
                    out_img.data[i + 2] = (uint8) (b + 0.5).clamp(0, 255);
                    out_img.data[i + 3] = (uint8) (a + 0.5).clamp(0, 255);
                }
            }
            return out_img;
        }

        public double effective(EditParams p, Adjustment a) {
            double v = p.get_value(a);
            var f = FilterPreset.find(p.filter);
            if (f != null) v += f.offsets[a];
            return v.clamp(a.min_value(), 1.0);
        }

        public void color_pixel(EditParams p, double[] eff, FilterPreset.Mode mode, ref double r, ref double g, ref double b) {
            double range = p.white_point - p.black_point;
            if (p.black_point > 1e-9 || p.white_point < 1.0 - 1e-9) {
                r = (r - p.black_point) / range;
                g = (g - p.black_point) / range;
                b = (b - p.black_point) / range;
            }
            double e = eff[Adjustment.EXPOSURE];
            if (e != 0.0) {
                double m = Math.pow(2.0, e * 2.0);
                r *= m;
                g *= m;
                b *= m;
            }
            double br = eff[Adjustment.BRIGHTNESS];
            if (br != 0.0) {
                r = brightness(r.clamp(0, 1), br);
                g = brightness(g.clamp(0, 1), br);
                b = brightness(b.clamp(0, 1), br);
            }
            double c = eff[Adjustment.CONTRAST];
            if (c != 0.0) {
                r = (r - 0.5) * (1.0 + c) + 0.5;
                g = (g - 0.5) * (1.0 + c) + 0.5;
                b = (b - 0.5) * (1.0 + c) + 0.5;
            }
            double hi = eff[Adjustment.HIGHLIGHTS], sh = eff[Adjustment.SHADOWS];
            if (hi != 0.0 || sh != 0.0) {
                double l = (LUMA_R * r + LUMA_G * g + LUMA_B * b).clamp(0, 1);
                double d = hi * 0.35 * smoothstep(0.5, 1.0, l) + sh * 0.35 * (1.0 - smoothstep(0.0, 0.5, l));
                r += d;
                g += d;
                b += d;
            }
            double wa = eff[Adjustment.WARMTH];
            if (wa != 0.0) {
                r += wa * 0.12;
                b -= wa * 0.12;
            }
            double ti = eff[Adjustment.TINT];
            if (ti != 0.0) {
                g -= ti * 0.12;
                r += ti * 0.04;
                b += ti * 0.04;
            }
            double sa = eff[Adjustment.SATURATION];
            if (sa != 0.0) {
                double l = LUMA_R * r + LUMA_G * g + LUMA_B * b;
                r = l + (r - l) * (1.0 + sa);
                g = l + (g - l) * (1.0 + sa);
                b = l + (b - l) * (1.0 + sa);
            }
            double vi = eff[Adjustment.VIBRANCE];
            if (vi != 0.0) {
                double l = LUMA_R * r + LUMA_G * g + LUMA_B * b;
                double mx = double.max(r, double.max(g, b)).clamp(0, 1);
                double mn = double.min(r, double.min(g, b)).clamp(0, 1);
                double f = 1.0 + vi * (1.0 - (mx - mn));
                r = l + (r - l) * f;
                g = l + (g - l) * f;
                b = l + (b - l) * f;
            }
            if (mode == FilterPreset.Mode.MONO) {
                double l = LUMA_R * r + LUMA_G * g + LUMA_B * b;
                r = l;
                g = l;
                b = l;
            } else if (mode == FilterPreset.Mode.SEPIA) {
                double cr = r.clamp(0, 1), cg = g.clamp(0, 1), cb = b.clamp(0, 1);
                r = 0.393 * cr + 0.769 * cg + 0.189 * cb;
                g = 0.349 * cr + 0.686 * cg + 0.168 * cb;
                b = 0.272 * cr + 0.534 * cg + 0.131 * cb;
            }
        }

        public double brightness(double v, double amount) {
            if (amount > 0) return 1.0 - Math.pow(1.0 - v, 1.0 + amount * 1.5);
            return Math.pow(v, 1.0 - amount * 1.5);
        }

        public double[] effective_values(EditParams p) {
            var eff = new double[Adjustment.COUNT];
            for (int i = 0; i < Adjustment.COUNT; i++) eff[i] = effective(p, (Adjustment) i);
            return eff;
        }

        public void apply_color(EditImage img, EditParams p) {
            var eff = effective_values(p);
            var f = FilterPreset.find(p.filter);
            var mode = f != null ? f.mode : FilterPreset.Mode.COLOR;
            bool any = p.black_point > 1e-9 || p.white_point < 1.0 - 1e-9 || mode != FilterPreset.Mode.COLOR;
            for (int i = 0; i < Adjustment.COUNT; i++) {
                if (i == Adjustment.SHARPNESS || i == Adjustment.VIGNETTE) continue;
                if (eff[i] != 0.0) any = true;
            }
            if (any) {
                unowned uint8[] d = img.data;
                int n = img.width * img.height;
                for (int i = 0; i < n; i++) {
                    int o = i * 4;
                    double r = d[o] / 255.0, g = d[o + 1] / 255.0, b = d[o + 2] / 255.0;
                    color_pixel(p, eff, mode, ref r, ref g, ref b);
                    d[o] = to_byte(r);
                    d[o + 1] = to_byte(g);
                    d[o + 2] = to_byte(b);
                }
            }
            if (eff[Adjustment.SHARPNESS] > 0.0) sharpen(img, eff[Adjustment.SHARPNESS]);
            if (eff[Adjustment.VIGNETTE] != 0.0) vignette(img, eff[Adjustment.VIGNETTE]);
        }

        public void sharpen(EditImage img, double amount) {
            int w = img.width, h = img.height;
            if (w < 3 || h < 3) return;
            var src = img.data.copy();
            double k = amount * 1.5;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int o = (y * w + x) * 4;
                    for (int c = 0; c < 3; c++) {
                        int sum = 0;
                        for (int dy = -1; dy <= 1; dy++) {
                            int yy = (y + dy).clamp(0, h - 1);
                            for (int dx = -1; dx <= 1; dx++) {
                                int xx = (x + dx).clamp(0, w - 1);
                                sum += src[(yy * w + xx) * 4 + c];
                            }
                        }
                        double v = src[o + c];
                        double blurred = sum / 9.0;
                        img.data[o + c] = to_byte((v + k * (v - blurred)) / 255.0);
                    }
                }
            }
        }

        public double vignette_factor(double nx, double ny) {
            double dx = nx - 0.5, dy = ny - 0.5;
            double r = Math.sqrt(dx * dx + dy * dy) / Math.sqrt(0.5);
            return smoothstep(0.3, 1.0, r);
        }

        public void vignette(EditImage img, double amount) {
            int w = img.width, h = img.height;
            for (int y = 0; y < h; y++) {
                double ny = (y + 0.5) / h;
                for (int x = 0; x < w; x++) {
                    double f = vignette_factor((x + 0.5) / w, ny);
                    if (f <= 0.0) continue;
                    int o = (y * w + x) * 4;
                    for (int c = 0; c < 3; c++) {
                        double v = img.data[o + c] / 255.0;
                        if (amount > 0) v *= 1.0 - amount * 0.7 * f;
                        else v += -amount * 0.5 * f * (1.0 - v);
                        img.data[o + c] = to_byte(v);
                    }
                }
            }
        }

        public EditImage render(EditImage src, EditParams p, bool with_color = true) {
            var img = apply_geometry(src, p);
            if (with_color) apply_color(img, p);
            return img;
        }

        public int[] luma_histogram(EditImage img) {
            var hist = new int[256];
            int n = img.width * img.height;
            for (int i = 0; i < n; i++) {
                int o = i * 4;
                double l = LUMA_R * img.data[o] + LUMA_G * img.data[o + 1] + LUMA_B * img.data[o + 2];
                hist[(int) (l + 0.5).clamp(0, 255)]++;
            }
            return hist;
        }

        public int percentile(int[] hist, double fraction) {
            int total = 0;
            foreach (int c in hist) total += c;
            if (total == 0) return 0;
            double target = fraction * total;
            int acc = 0;
            for (int i = 0; i < hist.length; i++) {
                acc += hist[i];
                if (acc > target) return i;
            }
            return hist.length - 1;
        }

        public EditParams auto_enhance(EditImage img, EditParams current) {
            var p = current.copy();
            p.reset_color();
            var sample_img = img.scaled_to_fit(512);
            var hist = luma_histogram(sample_img);
            int lo = percentile(hist, 0.005);
            int hi = percentile(hist, 0.995);
            if (hi - lo >= 16 && (lo > 2 || hi < 253)) {
                p.black_point = lo / 255.0;
                p.white_point = hi / 255.0;
            }
            double sum = 0;
            int total = 0;
            double range = p.white_point - p.black_point;
            for (int i = 0; i < 256; i++) {
                double v = ((i / 255.0 - p.black_point) / range).clamp(0, 1);
                sum += v * hist[i];
                total += hist[i];
            }
            double mean = total > 0 ? sum / total : 0.5;
            if (mean < 0.4) p.set_value(Adjustment.SHADOWS, ((0.4 - mean) * 1.5).clamp(0, 0.5));
            else if (mean > 0.6) p.set_value(Adjustment.HIGHLIGHTS, (-(mean - 0.6) * 1.5).clamp(-0.5, 0));
            p.set_value(Adjustment.VIBRANCE, 0.15);
            p.filter = current.filter;
            return p;
        }
    }
}
