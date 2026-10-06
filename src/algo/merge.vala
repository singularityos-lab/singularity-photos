using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public delegate void MergeProgress(double fraction, string stage);

    public struct FaceBox {
        public double x;
        public double y;
        public double width;
        public double height;
        public double score;
    }

    public class MergePlane : Object {
        public float[] data;
        public int w;
        public int h;

        public MergePlane(float[] data, int w, int h) {
            this.data = data;
            this.w = w;
            this.h = h;
        }
    }

    namespace MergeUtil {

        public float median_plane(float[] p) {
            var hist = new int[4096];
            foreach (float v in p) hist[(int) (v.clamp(0, 1) * 4095)]++;
            int half = p.length / 2, acc = 0;
            for (int i = 0; i < 4096; i++) {
                acc += hist[i];
                if (acc > half) return i / 4095.0f;
            }
            return 1.0f;
        }

        public void mtb_offset(float[] reference, float[] other, int w, int h, out int dx, out int dy) {
            var refs = new Gee.ArrayList<MergePlane>();
            var oths = new Gee.ArrayList<MergePlane>();
            refs.add(new MergePlane(reference, w, h));
            oths.add(new MergePlane(other, w, h));
            while (refs[refs.size - 1].w > 48 && refs[refs.size - 1].h > 48 && refs.size < 7) {
                var ra = refs[refs.size - 1];
                var ob = oths[oths.size - 1];
                int nw, nh;
                var nr = AlgoUtil.half_plane(ra.data, ra.w, ra.h, out nw, out nh);
                var no = AlgoUtil.half_plane(ob.data, ob.w, ob.h, out nw, out nh);
                refs.add(new MergePlane(nr, nw, nh));
                oths.add(new MergePlane(no, nw, nh));
            }
            int sx = 0, sy = 0;
            for (int level = refs.size - 1; level >= 0; level--) {
                sx *= 2;
                sy *= 2;
                int lw = refs[level].w, lh = refs[level].h;
                unowned float[] a = refs[level].data;
                unowned float[] b = oths[level].data;
                float ma = median_plane(a), mb = median_plane(b);
                long best = long.MAX;
                int bx = sx, by = sy;
                int[] order_x = { 0, -1, 1, 0, 0, -1, 1, -1, 1 };
                int[] order_y = { 0, 0, 0, -1, 1, -1, -1, 1, 1 };
                for (int k = 0; k < 9; k++) {
                    {
                        int tx = sx + order_x[k], ty = sy + order_y[k];
                        long err = 0;
                        long total = 0;
                        for (int y = 0; y < lh; y++) {
                            int yy = y - ty;
                            if (yy < 0 || yy >= lh) continue;
                            for (int x = 0; x < lw; x++) {
                                int xx = x - tx;
                                if (xx < 0 || xx >= lw) continue;
                                float va = a[y * lw + x], vb = b[yy * lw + xx];
                                if ((va - ma).abs() < 0.012f || (vb - mb).abs() < 0.012f) continue;
                                total++;
                                if ((va > ma) != (vb > mb)) err++;
                            }
                        }
                        long rate = total > 0 ? err * 1000000 / total : long.MAX;
                        if (rate < best) {
                            best = rate;
                            bx = tx;
                            by = ty;
                        }
                    }
                }
                sx = bx;
                sy = by;
            }
            double best_ssd = double.MAX;
            int fx = sx, fy = sy;
            for (int oy = -2; oy <= 2; oy++) {
                for (int ox = -2; ox <= 2; ox++) {
                    int tx = sx + ox, ty = sy + oy;
                    double ssd = 0;
                    long cnt = 0;
                    for (int y = 2; y < h - 2; y++) {
                        int yy = y - ty;
                        if (yy < 0 || yy >= h) continue;
                        for (int x = 2; x < w - 2; x++) {
                            int xx = x - tx;
                            if (xx < 0 || xx >= w) continue;
                            float va = reference[y * w + x], vb = other[yy * w + xx];
                            if (va < 0.02f || va > 0.98f || vb < 0.02f || vb > 0.98f) continue;
                            double d = va - vb;
                            ssd += d * d;
                            cnt++;
                        }
                    }
                    if (cnt < 64) continue;
                    ssd /= cnt;
                    if (ssd < best_ssd - 1e-12) {
                        best_ssd = ssd;
                        fx = tx;
                        fy = ty;
                    }
                }
            }
            dx = fx;
            dy = fy;
        }

        public FloatImage down(FloatImage img) {
            var b = Filters.gaussian(img, 1.0, true);
            int nw = int.max(1, (img.width + 1) / 2), nh = int.max(1, (img.height + 1) / 2);
            var o = new FloatImage(nw, nh);
            for (int y = 0; y < nh; y++)
                for (int x = 0; x < nw; x++) {
                    size_t s = b.offset(int.min(x * 2, img.width - 1), int.min(y * 2, img.height - 1)), d = o.offset(x, y);
                    for (int c = 0; c < 4; c++) o.data[d + c] = b.data[s + c];
                }
            return o;
        }

        public float[] down_plane(float[] p, int w, int h, out int nw, out int nh) {
            return AlgoUtil.half_plane(p, w, h, out nw, out nh);
        }

        public Gee.ArrayList<FloatImage> laplacian(FloatImage img, int levels) {
            var g = new Gee.ArrayList<FloatImage>();
            g.add(img);
            for (int i = 1; i < levels; i++) g.add(down(g[i - 1]));
            var lap = new Gee.ArrayList<FloatImage>();
            for (int i = 0; i < levels - 1; i++) {
                var up = g[i + 1].resized(g[i].width, g[i].height);
                var l = g[i].copy();
                for (int k = 0; k < l.data.length; k++) l.data[k] -= up.data[k];
                lap.add(l);
            }
            lap.add(g[levels - 1]);
            return lap;
        }

        public FloatImage collapse(Gee.ArrayList<FloatImage> lap) {
            var cur = lap[lap.size - 1].copy();
            for (int i = lap.size - 2; i >= 0; i--) {
                var up = cur.resized(lap[i].width, lap[i].height);
                for (int k = 0; k < up.data.length; k++) up.data[k] += lap[i].data[k];
                cur = up;
            }
            return cur;
        }

        public Gee.ArrayList<MergePlane> gaussian_planes(float[] p, int w, int h, int levels) {
            var list = new Gee.ArrayList<MergePlane>();
            list.add(new MergePlane(p, w, h));
            for (int i = 1; i < levels; i++) {
                var prev = list[i - 1];
                int nw, nh;
                var d = down_plane(prev.data, prev.w, prev.h, out nw, out nh);
                list.add(new MergePlane(d, nw, nh));
            }
            return list;
        }

        public int pyramid_levels(int w, int h, int max_levels) {
            int levels = 1;
            int m = int.min(w, h);
            while (levels < max_levels && m > 24) {
                m /= 2;
                levels++;
            }
            return levels;
        }

        public void push_pull_fill(FloatImage img) {
            int w = img.width, h = img.height;
            bool any_hole = false, any_valid = false;
            for (size_t i = 0; i < img.pixel_count(); i++) {
                if (img.data[i * 4 + 3] < 0.5f) any_hole = true;
                else any_valid = true;
            }
            if (!any_hole || !any_valid) return;
            int nw = (w + 1) / 2, nh = (h + 1) / 2;
            var small = new FloatImage(nw, nh);
            for (int y = 0; y < nh; y++) {
                for (int x = 0; x < nw; x++) {
                    float r = 0, g = 0, b = 0;
                    int n = 0;
                    for (int j = 0; j < 2; j++) for (int i = 0; i < 2; i++) {
                        int fx = int.min(x * 2 + i, w - 1), fy = int.min(y * 2 + j, h - 1);
                        size_t o = img.offset(fx, fy);
                        if (img.data[o + 3] < 0.5f) continue;
                        r += img.data[o];
                        g += img.data[o + 1];
                        b += img.data[o + 2];
                        n++;
                    }
                    size_t d = small.offset(x, y);
                    if (n > 0) {
                        small.data[d] = r / n;
                        small.data[d + 1] = g / n;
                        small.data[d + 2] = b / n;
                        small.data[d + 3] = 1;
                    } else {
                        small.data[d + 3] = 0;
                    }
                }
            }
            if (nw > 1 || nh > 1) push_pull_fill(small);
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    size_t o = img.offset(x, y);
                    if (img.data[o + 3] >= 0.5f) continue;
                    float r, g, b, a;
                    small.sample((x + 0.5) / 2.0, (y + 0.5) / 2.0, out r, out g, out b, out a);
                    img.data[o] = r;
                    img.data[o + 1] = g;
                    img.data[o + 2] = b;
                }
            }
        }

        public void largest_rectangle(uint8[] cov, int w, int h, out int rx, out int ry, out int rw, out int rh) {
            var heights = new int[w];
            int best = 0;
            rx = 0; ry = 0; rw = w; rh = h;
            var stack = new int[w + 1];
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) heights[x] = cov[y * w + x] != 0 ? heights[x] + 1 : 0;
                int top = 0;
                for (int x = 0; x <= w; x++) {
                    int cur = x < w ? heights[x] : 0;
                    while (top > 0 && heights[stack[top - 1]] >= cur) {
                        top--;
                        int hh = heights[stack[top]];
                        int left = top > 0 ? stack[top - 1] + 1 : 0;
                        int area = hh * (x - left);
                        if (area > best) {
                            best = area;
                            rx = left;
                            rw = x - left;
                            rh = hh;
                            ry = y - hh + 1;
                        }
                    }
                    stack[top++] = x;
                }
            }
        }
    }
}
