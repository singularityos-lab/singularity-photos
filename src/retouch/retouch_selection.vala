using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public enum SelectionOp {
        REPLACE,
        ADD,
        SUBTRACT,
        INTERSECT
    }

    namespace RetouchSelection {

        public float[] rect(int w, int h, double x, double y, double rw, double rh) {
            var plane = new float[(size_t) w * h];
            double x1 = x + rw, y1 = y + rh;
            if (rw < 0) { x1 = x; x += rw; }
            if (rh < 0) { y1 = y; y += rh; }
            int ix0 = int.max(0, (int) Math.floor(x)), iy0 = int.max(0, (int) Math.floor(y));
            int ix1 = int.min(w, (int) Math.ceil(x1)), iy1 = int.min(h, (int) Math.ceil(y1));
            for (int yy = iy0; yy < iy1; yy++) {
                double cy = double.min(yy + 1, y1) - double.max(yy, y);
                for (int xx = ix0; xx < ix1; xx++) {
                    double cx = double.min(xx + 1, x1) - double.max(xx, x);
                    plane[(size_t) yy * w + xx] = (float) (cx * cy).clamp(0, 1);
                }
            }
            return plane;
        }

        public float[] ellipse(int w, int h, double x, double y, double rw, double rh) {
            var plane = new float[(size_t) w * h];
            if (rw < 0) { x += rw; rw = -rw; }
            if (rh < 0) { y += rh; rh = -rh; }
            if (rw < 0.5 || rh < 0.5) return plane;
            double cx = x + rw / 2, cy = y + rh / 2, ax = rw / 2, ay = rh / 2;
            int ix0 = int.max(0, (int) Math.floor(x) - 1), iy0 = int.max(0, (int) Math.floor(y) - 1);
            int ix1 = int.min(w, (int) Math.ceil(x + rw) + 1), iy1 = int.min(h, (int) Math.ceil(y + rh) + 1);
            double edge = 1.0 / double.min(ax, ay);
            for (int yy = iy0; yy < iy1; yy++) {
                for (int xx = ix0; xx < ix1; xx++) {
                    double dx = (xx + 0.5 - cx) / ax, dy = (yy + 0.5 - cy) / ay;
                    double d = Math.sqrt(dx * dx + dy * dy);
                    plane[(size_t) yy * w + xx] = (float) ((1.0 - d) / edge + 0.5).clamp(0, 1);
                }
            }
            return plane;
        }

        public float[] polygon(int w, int h, double[] points) {
            var plane = new float[(size_t) w * h];
            int n = points.length / 2;
            if (n < 3) return plane;
            const int SUB = 4;
            var xs = new double[n];
            for (int yy = 0; yy < h; yy++) {
                for (int s = 0; s < SUB; s++) {
                    double sy = yy + (s + 0.5) / SUB;
                    int count = 0;
                    for (int i = 0; i < n; i++) {
                        double ax = points[i * 2], ay = points[i * 2 + 1];
                        double bx = points[((i + 1) % n) * 2], by = points[((i + 1) % n) * 2 + 1];
                        if ((ay <= sy && by > sy) || (by <= sy && ay > sy)) xs[count++] = ax + (sy - ay) / (by - ay) * (bx - ax);
                    }
                    for (int i = 1; i < count; i++) {
                        double v = xs[i];
                        int j = i - 1;
                        while (j >= 0 && xs[j] > v) {
                            xs[j + 1] = xs[j];
                            j--;
                        }
                        xs[j + 1] = v;
                    }
                    for (int i = 0; i + 1 < count; i += 2) {
                        double a = xs[i].clamp(0, w), b = xs[i + 1].clamp(0, w);
                        int ia = (int) Math.floor(a), ib = (int) Math.floor(b);
                        for (int xx = ia; xx <= ib && xx < w; xx++) {
                            double cover = double.min(xx + 1, b) - double.max(xx, a);
                            if (cover > 0) plane[(size_t) yy * w + xx] += (float) (cover / SUB);
                        }
                    }
                }
            }
            for (size_t i = 0; i < plane.length; i++) plane[i] = plane[i].clamp(0, 1);
            return plane;
        }

        public float[] combine(float[]? existing, float[] shape, SelectionOp op) {
            if (existing == null || op == SelectionOp.REPLACE) {
                if (op == SelectionOp.SUBTRACT || op == SelectionOp.INTERSECT) return new float[shape.length];
                return shape;
            }
            var out_plane = existing.copy();
            for (size_t i = 0; i < out_plane.length; i++) {
                switch (op) {
                    case SelectionOp.ADD: out_plane[i] = float.max(out_plane[i], shape[i]); break;
                    case SelectionOp.SUBTRACT: out_plane[i] = out_plane[i] * (1 - shape[i]); break;
                    default: out_plane[i] = float.min(out_plane[i], shape[i]); break;
                }
            }
            return out_plane;
        }

        public float[] invert(float[]? plane, int w, int h) {
            var out_plane = new float[(size_t) w * h];
            for (size_t i = 0; i < out_plane.length; i++) out_plane[i] = plane != null ? 1 - plane[i] : 1;
            return out_plane;
        }

        public bool is_empty(float[]? plane) {
            if (plane == null) return true;
            foreach (var v in plane) if (v > 0.002f) return false;
            return true;
        }

        public bool bounds(float[] plane, int w, int h, out int bx, out int by, out int bw, out int bh) {
            int x0 = w, y0 = h, x1 = -1, y1 = -1;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    if (plane[(size_t) y * w + x] <= 0.002f) continue;
                    if (x < x0) x0 = x;
                    if (x > x1) x1 = x;
                    if (y < y0) y0 = y;
                    if (y > y1) y1 = y;
                }
            }
            bx = x0;
            by = y0;
            bw = x1 - x0 + 1;
            bh = y1 - y0 + 1;
            return x1 >= 0;
        }

        private float color_distance(FloatImage img, size_t i, float r, float g, float b) {
            float er, eg, eb;
            RetouchColor.pixel_to_encoded(img.data[i], img.data[i + 1], img.data[i + 2], out er, out eg, out eb);
            return float.max((er - r).abs(), float.max((eg - g).abs(), (eb - b).abs()));
        }

        public float[] magic_wand(FloatImage img, int sx, int sy, double tolerance, bool contiguous) {
            int w = img.width, h = img.height;
            var plane = new float[(size_t) w * h];
            if (sx < 0 || sy < 0 || sx >= w || sy >= h) return plane;
            float r, g, b;
            size_t si = img.offset(sx, sy);
            RetouchColor.pixel_to_encoded(img.data[si], img.data[si + 1], img.data[si + 2], out r, out g, out b);
            float tol = (float) tolerance;
            if (!contiguous) {
                Parallel.range(h, (start, end) => {
                    for (int y = start; y < end; y++)
                        for (int x = 0; x < w; x++)
                            if (color_distance(img, img.offset(x, y), r, g, b) <= tol) plane[(size_t) y * w + x] = 1;
                });
                return plane;
            }
            var visited = new uint8[(size_t) w * h];
            var stack = new int[(size_t) w * h];
            int head = 0, tail = 0;
            stack[tail++] = sy * w + sx;
            visited[sy * w + sx] = 1;
            while (head < tail) {
                int p = stack[head++];
                int x = p % w, y = p / w;
                if (color_distance(img, (size_t) p * 4, r, g, b) > tol) continue;
                plane[p] = 1;
                int[] nb = { p - 1, p + 1, p - w, p + w };
                bool[] ok = { x > 0, x < w - 1, y > 0, y < h - 1 };
                for (int k = 0; k < 4; k++) {
                    if (!ok[k] || visited[nb[k]] != 0) continue;
                    visited[nb[k]] = 1;
                    stack[tail++] = nb[k];
                }
            }
            return plane;
        }

        public float[] quick_select(FloatImage img, float[]? existing, double[] stroke, double radius, bool subtract) {
            int w = img.width, h = img.height;
            var seeds = new float[(size_t) w * h];
            double sr = 0, sg = 0, sb = 0, sr2 = 0, sg2 = 0, sb2 = 0;
            int n = 0;
            int pts = stroke.length / 2;
            for (int k = 0; k < pts; k++) {
                int cx = (int) stroke[k * 2], cy = (int) stroke[k * 2 + 1];
                int rr = (int) Math.ceil(radius);
                for (int y = int.max(0, cy - rr); y < int.min(h, cy + rr + 1); y++) {
                    for (int x = int.max(0, cx - rr); x < int.min(w, cx + rr + 1); x++) {
                        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) > radius * radius) continue;
                        size_t idx = (size_t) y * w + x;
                        if (seeds[idx] != 0) continue;
                        seeds[idx] = 1;
                        float er, eg, eb;
                        RetouchColor.pixel_to_encoded(img.data[idx * 4], img.data[idx * 4 + 1], img.data[idx * 4 + 2], out er, out eg, out eb);
                        sr += er; sg += eg; sb += eb;
                        sr2 += er * er; sg2 += eg * eg; sb2 += eb * eb;
                        n++;
                    }
                }
            }
            if (n == 0) return existing ?? new float[(size_t) w * h];
            float mr = (float) (sr / n), mg = (float) (sg / n), mb = (float) (sb / n);
            double variance = (sr2 / n - mr * mr) + (sg2 / n - mg * mg) + (sb2 / n - mb * mb);
            float tol = (float) (0.08 + 2.2 * Math.sqrt(double.max(0, variance / 3))).clamp(0.08, 0.45);
            var luma = img.luminance(0.2627f, 0.6780f, 0.0593f);
            var region = new float[(size_t) w * h];
            var queue = new int[(size_t) w * h];
            int head = 0, tail = 0;
            for (int i = 0; i < w * h; i++) {
                if (seeds[i] == 0) continue;
                region[i] = 1;
                queue[tail++] = i;
            }
            while (head < tail) {
                int p = queue[head++];
                int x = p % w, y = p / w;
                int[] nb = { p - 1, p + 1, p - w, p + w };
                bool[] ok = { x > 0, x < w - 1, y > 0, y < h - 1 };
                for (int k = 0; k < 4; k++) {
                    if (!ok[k]) continue;
                    int q = nb[k];
                    if (region[q] != 0) continue;
                    float edge = (Transfer.linear_to_srgb(luma[q]) - Transfer.linear_to_srgb(luma[p])).abs();
                    if (edge > tol * 0.6f) continue;
                    if (color_distance(img, (size_t) q * 4, mr, mg, mb) > tol) continue;
                    region[q] = 1;
                    queue[tail++] = q;
                }
            }
            var refined = Filters.guided_plane(luma, region, w, h, int.max(1, (int) (radius / 4)), 1e-4f);
            for (size_t i = 0; i < refined.length; i++) refined[i] = refined[i].clamp(0, 1);
            return combine(existing, refined, subtract ? SelectionOp.SUBTRACT : SelectionOp.ADD);
        }

        public float[] feather(float[] plane, int w, int h, double radius) {
            if (radius < 0.3) return plane.copy();
            var out_plane = Filters.gaussian_plane(plane, w, h, radius);
            for (size_t i = 0; i < out_plane.length; i++) out_plane[i] = out_plane[i].clamp(0, 1);
            return out_plane;
        }

        private void edt_1d(float[] f, float[] d, int[] v, float[] z, int n) {
            int k = 0;
            v[0] = 0;
            z[0] = -float.MAX;
            z[1] = float.MAX;
            for (int q = 1; q < n; q++) {
                float s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k]);
                while (s <= z[k]) {
                    k--;
                    s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k]);
                }
                k++;
                v[k] = q;
                z[k] = s;
                z[k + 1] = float.MAX;
            }
            k = 0;
            for (int q = 0; q < n; q++) {
                while (z[k + 1] < q) k++;
                d[q] = (q - v[k]) * (q - v[k]) + f[v[k]];
            }
        }

        public float[] distance_to(float[] plane, int w, int h, bool inside) {
            const float INF = 1e20f;
            var grid = new float[(size_t) w * h];
            for (size_t i = 0; i < grid.length; i++) {
                bool sel = plane[i] >= 0.5f;
                grid[i] = (inside ? !sel : sel) ? 0 : INF;
            }
            Parallel.range(w, (start, end) => {
                var f = new float[h];
                var d = new float[h];
                var v = new int[h];
                var z = new float[h + 1];
                for (int x = start; x < end; x++) {
                    for (int y = 0; y < h; y++) f[y] = grid[(size_t) y * w + x];
                    edt_1d(f, d, v, z, h);
                    for (int y = 0; y < h; y++) grid[(size_t) y * w + x] = d[y];
                }
            });
            Parallel.range(h, (start, end) => {
                var f = new float[w];
                var d = new float[w];
                var v = new int[w];
                var z = new float[w + 1];
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) f[x] = grid[(size_t) y * w + x];
                    edt_1d(f, d, v, z, w);
                    for (int x = 0; x < w; x++) grid[(size_t) y * w + x] = Math.sqrtf(d[x]);
                }
            });
            return grid;
        }

        public float[] expand(float[] plane, int w, int h, double amount) {
            if (amount.abs() < 0.5) return plane.copy();
            var out_plane = new float[plane.length];
            if (amount > 0) {
                var dist = distance_to(plane, w, h, false);
                for (size_t i = 0; i < plane.length; i++) out_plane[i] = plane[i] >= 0.5f ? 1 : (float) (amount + 1 - dist[i]).clamp(0, 1);
            } else {
                var dist = distance_to(plane, w, h, true);
                for (size_t i = 0; i < plane.length; i++) out_plane[i] = plane[i] < 0.5f ? 0 : (float) (dist[i] + amount).clamp(0, 1);
            }
            return out_plane;
        }

        public float[] smooth(float[] plane, int w, int h, double radius) {
            if (radius < 0.5) return plane.copy();
            var blurred = Filters.gaussian_plane(plane, w, h, radius);
            for (size_t i = 0; i < blurred.length; i++) blurred[i] = ((blurred[i] - 0.5f) * 4 + 0.5f).clamp(0, 1);
            return blurred;
        }

        public float[] refine_edge(FloatImage img, float[] plane, double radius, double contrast) {
            int w = img.width, h = img.height;
            var luma = img.luminance(0.2627f, 0.6780f, 0.0593f);
            for (size_t i = 0; i < luma.length; i++) luma[i] = Transfer.linear_to_srgb(luma[i]);
            var refined = Filters.guided_plane(luma, plane, w, h, int.max(1, (int) radius), 2e-4f);
            float k = 1 + (float) contrast * 6;
            for (size_t i = 0; i < refined.length; i++) refined[i] = ((refined[i] - 0.5f) * k + 0.5f).clamp(0, 1);
            return refined;
        }

        public float[] luminance_range(FloatImage img, double lo, double hi, double soft) {
            int w = img.width, h = img.height;
            var plane = new float[(size_t) w * h];
            for (size_t i = 0; i < plane.length; i++) {
                float er, eg, eb;
                RetouchColor.pixel_to_encoded(img.data[i * 4], img.data[i * 4 + 1], img.data[i * 4 + 2], out er, out eg, out eb);
                double l = RetouchColor.luma_encoded(er, eg, eb);
                double a = soft > 0 ? ((l - (lo - soft)) / soft).clamp(0, 1) : (l >= lo ? 1 : 0);
                double b = soft > 0 ? (((hi + soft) - l) / soft).clamp(0, 1) : (l <= hi ? 1 : 0);
                plane[i] = (float) double.min(a, b);
            }
            return plane;
        }

        public float[] color_range(FloatImage img, float r, float g, float b, double fuzziness) {
            int w = img.width, h = img.height;
            var plane = new float[(size_t) w * h];
            float f = (float) double.max(0.01, fuzziness);
            for (size_t i = 0; i < plane.length; i++) {
                float er, eg, eb;
                RetouchColor.pixel_to_encoded(img.data[i * 4], img.data[i * 4 + 1], img.data[i * 4 + 2], out er, out eg, out eb);
                float d = Math.sqrtf((er - r) * (er - r) + (eg - g) * (eg - g) + (eb - b) * (eb - b));
                plane[i] = (1 - d / f).clamp(0, 1);
            }
            return plane;
        }

        public float[] from_segmentation(FloatImage img, bool sky) {
            var small = img.scaled_to_fit(1024);
            var plane = sky ? Segmentation.sky(small) : Segmentation.subject(small);
            if (small.width == img.width && small.height == img.height) return plane;
            var full = Filters.resize_plane(plane, small.width, small.height, img.width, img.height);
            for (size_t i = 0; i < full.length; i++) full[i] = full[i].clamp(0, 1);
            return full;
        }

        public float[] from_alpha(FloatImage img) {
            return img.channel(3);
        }
    }
}
