using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace Upright {

        public const double MAX_TILT_DEGREES = 30.0;

        public struct Segment {
            public double x0;
            public double y0;
            public double x1;
            public double y1;
            public double weight;
        }

        public double[] forward(double vertical, double horizontal, double rotate, double aspect, double scale, double x, double y, int width, int height) {
            double f = int.max(width, height);
            double cx = width / 2.0, cy = height / 2.0;
            double ax = vertical * MAX_TILT_DEGREES * Math.PI / 180.0;
            double ay = horizontal * MAX_TILT_DEGREES * Math.PI / 180.0;
            double az = rotate * Math.PI / 180.0;
            double[] rx = { 1, 0, 0, 0, Math.cos(ax), -Math.sin(ax), 0, Math.sin(ax), Math.cos(ax) };
            double[] ry = { Math.cos(ay), 0, Math.sin(ay), 0, 1, 0, -Math.sin(ay), 0, Math.cos(ay) };
            double[] rz = { Math.cos(az), -Math.sin(az), 0, Math.sin(az), Math.cos(az), 0, 0, 0, 1 };
            var r = Matrix3.multiply(rz, Matrix3.multiply(ry, rx));
            double[] k = { f, 0, 0, 0, f, 0, 0, 0, 1 };
            double[] kinv = { 1 / f, 0, 0, 0, 1 / f, 0, 0, 0, 1 };
            double sx = scale, sy = scale;
            if (aspect > 0) sx *= 1 + aspect * 0.5;
            else sy *= 1 - aspect * 0.5;
            double[] tin = { 1, 0, -cx, 0, 1, -cy, 0, 0, 1 };
            double[] tout = { sx, 0, cx + x * width * 0.5, 0, sy, cy + y * height * 0.5, 0, 0, 1 };
            var m = Matrix3.multiply(tout, Matrix3.multiply(k, Matrix3.multiply(r, Matrix3.multiply(kinv, tin))));
            if (m[8].abs() > 1e-12) for (int i = 0; i < 9; i++) m[i] /= m[8];
            return m;
        }

        public double[] homography(double vertical, double horizontal, double rotate, double aspect, double scale, double x, double y, int width, int height) {
            var inv = Matrix3.invert(forward(vertical, horizontal, rotate, aspect, scale, x, y, width, height));
            if (inv[8].abs() > 1e-12) for (int i = 0; i < 9; i++) inv[i] /= inv[8];
            return inv;
        }

        public Segment[] detect_segments(FloatImage img, out int work_w, out int work_h) {
            var small = img.scaled_to_fit(900);
            int w = small.width, h = small.height;
            work_w = w;
            work_h = h;
            var lum = Filters.gaussian_plane(AlgoUtil.perceptual_luma(small), w, h, 1.2);
            float[] gx, gy;
            var mag = AlgoUtil.sobel_magnitude(lum, w, h, out gx, out gy);
            var hist = new int[1024];
            float mmax = 1e-6f;
            foreach (float m in mag) if (m > mmax) mmax = m;
            foreach (float m in mag) hist[(int) (m / mmax * 1023)]++;
            int target = (int) (mag.length * 0.90), acc = 0;
            float thresh = mmax;
            for (int i = 0; i < 1024; i++) {
                acc += hist[i];
                if (acc >= target) {
                    thresh = float.max(i / 1023.0f * mmax, 0.04f);
                    break;
                }
            }
            var edge = new uint8[w * h];
            for (int y = 1; y < h - 1; y++) {
                for (int x = 1; x < w - 1; x++) {
                    int i = y * w + x;
                    float m = mag[i];
                    if (m < thresh) continue;
                    float dx = gx[i] / m, dy = gy[i] / m;
                    int ox = (int) Math.round(dx), oy = (int) Math.round(dy);
                    if (mag[(y + oy) * w + x + ox] > m || mag[(y - oy) * w + x - ox] > m) continue;
                    edge[i] = 1;
                }
            }
            int nt = 360;
            double diag = Math.sqrt((double) w * w + (double) h * h);
            int nr = (int) (2 * diag) + 1;
            var accum = new int[nt * nr];
            var cos_t = new double[nt];
            var sin_t = new double[nt];
            for (int t = 0; t < nt; t++) {
                double th = t * Math.PI / nt;
                cos_t[t] = Math.cos(th);
                sin_t[t] = Math.sin(th);
            }
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int i = y * w + x;
                    if (edge[i] == 0) continue;
                    double ga = Math.atan2(gy[i], gx[i]);
                    if (ga < 0) ga += Math.PI;
                    int tc = (int) Math.round(ga / Math.PI * nt);
                    for (int dt = -6; dt <= 6; dt++) {
                        int t = ((tc + dt) % nt + nt) % nt;
                        double rho = x * cos_t[t] + y * sin_t[t];
                        int ri = (int) Math.round(rho + diag);
                        if (ri >= 0 && ri < nr) accum[t * nr + ri]++;
                    }
                }
            }
            int min_votes = int.max(25, int.min(w, h) / 10);
            Segment[] segs = {};
            var used = new uint8[nt * nr];
            for (int pick = 0; pick < 80; pick++) {
                int best = -1, bv = min_votes - 1;
                for (int i = 0; i < accum.length; i++) {
                    if (used[i] != 0) continue;
                    if (accum[i] > bv) {
                        bv = accum[i];
                        best = i;
                    }
                }
                if (best < 0) break;
                int bt = best / nr, br = best % nr;
                for (int dt = -4; dt <= 4; dt++) {
                    for (int dr = -6; dr <= 6; dr++) {
                        int t = bt + dt, rr = br + dr;
                        if (t < 0 || t >= nt || rr < 0 || rr >= nr) continue;
                        used[t * nr + rr] = 1;
                    }
                }
                double ct = cos_t[bt], st = sin_t[bt], rho = br - diag;
                double lo = double.MAX, hi = -double.MAX;
                int support = 0;
                for (int y = 0; y < h; y++) {
                    for (int x = 0; x < w; x++) {
                        if (edge[y * w + x] == 0) continue;
                        if ((x * ct + y * st - rho).abs() > 1.5) continue;
                        double along = -x * st + y * ct;
                        if (along < lo) lo = along;
                        if (along > hi) hi = along;
                        support++;
                    }
                }
                double len = hi - lo;
                if (support < min_votes || len < int.min(w, h) * 0.12) continue;
                Segment s = Segment();
                s.x0 = rho * ct - lo * st;
                s.y0 = rho * st + lo * ct;
                s.x1 = rho * ct - hi * st;
                s.y1 = rho * st + hi * ct;
                s.weight = double.min(support, len);
                segs += s;
            }
            return segs;
        }

        private double deviation(double dx, double dy, bool vertical) {
            double a = vertical ? Math.atan2(dx, dy) : Math.atan2(dy, dx);
            while (a > Math.PI / 2) a -= Math.PI;
            while (a <= -Math.PI / 2) a += Math.PI;
            return a * 180.0 / Math.PI;
        }

        private double cost(Segment[] segs, bool[] kinds, bool use_vertical, bool use_horizontal, double v, double hz, double rot, int w, int h, double lambda) {
            var f = forward(v, hz, rot, 0, 1, 0, 0, w, h);
            double c = 0;
            for (int i = 0; i < segs.length; i++) {
                bool is_v = kinds[i];
                if (is_v && !use_vertical) continue;
                if (!is_v && !use_horizontal) continue;
                double ax, ay, bx, by;
                AlgoUtil.apply_h(f, segs[i].x0, segs[i].y0, out ax, out ay);
                AlgoUtil.apply_h(f, segs[i].x1, segs[i].y1, out bx, out by);
                double d = deviation(bx - ax, by - ay, is_v);
                c += segs[i].weight * double.min(d * d, 100.0);
            }
            return c + lambda * (v * v + hz * hz) * 1000.0;
        }

        private double minimize_1d(owned CostFunc fn, double lo, double hi) {
            double best = 0, bc = fn(0);
            int steps = 40;
            for (int i = 0; i <= steps; i++) {
                double x = lo + (hi - lo) * i / steps;
                double c = fn(x);
                if (c < bc) {
                    bc = c;
                    best = x;
                }
            }
            double span = (hi - lo) / steps;
            for (int round = 0; round < 3; round++) {
                double a = best - span, b = best + span;
                for (int i = 0; i <= 20; i++) {
                    double x = a + (b - a) * i / 20;
                    double c = fn(x);
                    if (c < bc) {
                        bc = c;
                        best = x;
                    }
                }
                span /= 10;
            }
            return best;
        }

        private delegate double CostFunc(double x);

        public void solve(FloatImage img, string mode, out double vertical, out double horizontal, out double rotate) {
            vertical = 0;
            horizontal = 0;
            rotate = 0;
            int ww, wh;
            var segs = detect_segments(img, out ww, out wh);
            if (segs.length == 0) return;
            bool[] kinds = new bool[segs.length];
            Segment[] kept = {};
            bool[] kept_kinds = {};
            int nv = 0, nh = 0;
            for (int i = 0; i < segs.length; i++) {
                double dv = deviation(segs[i].x1 - segs[i].x0, segs[i].y1 - segs[i].y0, true);
                double dh = deviation(segs[i].x1 - segs[i].x0, segs[i].y1 - segs[i].y0, false);
                if (dv.abs() < 25) {
                    kept += segs[i];
                    kept_kinds += true;
                    nv++;
                } else if (dh.abs() < 25) {
                    kept += segs[i];
                    kept_kinds += false;
                    nh++;
                }
            }
            kinds = kept_kinds;
            segs = kept;
            if (segs.length == 0) return;
            double v = 0, hz = 0, r = 0;
            bool use_v = nv > 0, use_h = nh > 0;
            double lambda = mode == "auto" ? 0.02 : 0.0;
            switch (mode) {
                case "level":
                    r = minimize_1d((x) => cost(segs, kinds, use_v, use_h, 0, 0, x, ww, wh, 0), -10, 10);
                    break;
                case "vertical":
                    for (int round = 0; round < 5; round++) {
                        double cr = r;
                        v = minimize_1d((x) => cost(segs, kinds, use_v, false, x, 0, cr, ww, wh, 0), -1, 1);
                        double cv = v;
                        r = minimize_1d((x) => cost(segs, kinds, use_v, use_h && nv < 2, cv, 0, x, ww, wh, 0), -10, 10);
                    }
                    break;
                default:
                    bool allow_h = mode == "full" || nh >= 2;
                    for (int round = 0; round < 6; round++) {
                        double cr = r, ch = hz;
                        v = minimize_1d((x) => cost(segs, kinds, use_v, use_h, x, ch, cr, ww, wh, lambda), -1, 1);
                        double cv = v;
                        if (allow_h) hz = minimize_1d((x) => cost(segs, kinds, use_v, use_h, cv, x, cr, ww, wh, lambda), -1, 1);
                        double ch2 = hz;
                        r = minimize_1d((x) => cost(segs, kinds, use_v, use_h, cv, ch2, x, ww, wh, lambda), -10, 10);
                    }
                    break;
            }
            vertical = v.clamp(-1, 1);
            horizontal = hz.clamp(-1, 1);
            rotate = r.clamp(-10, 10);
        }
    }
}
