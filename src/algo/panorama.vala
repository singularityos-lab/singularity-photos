using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class PanoFeatures : Object {
        public double[] points = {};
        public uint32[] descriptors = {};
        public int count = 0;
    }

    namespace Panorama {

        private const int WORK_SIDE = 1000;
        private const int BRIEF_BITS = 256;
        private const int PATCH = 15;

        private int[]? pairs = null;

        private unowned int[] brief_pairs() {
            if (pairs == null) {
                var p = new int[BRIEF_BITS * 4];
                uint32 rng = 0x1234567u;
                for (int i = 0; i < BRIEF_BITS * 4; i++) {
                    int v = PATCH;
                    while (v.abs() > PATCH - 2) {
                        rng = AlgoUtil.hash(rng + 0x9e3779b9u);
                        double u1 = (rng & 0xffff) / 65536.0 + 1e-6, u2 = (rng >> 16) / 65536.0;
                        v = (int) Math.round(Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2) * PATCH / 2.5);
                    }
                    p[i] = v;
                }
                pairs = p;
            }
            return pairs;
        }

        public PanoFeatures features(FloatImage img, int max_points = 1500) {
            var small = img.scaled_to_fit(WORK_SIDE);
            double scale = (double) img.width / small.width;
            int w = small.width, h = small.height;
            var lum = AlgoUtil.perceptual_luma(small);
            float[] gx, gy;
            AlgoUtil.sobel_magnitude(lum, w, h, out gx, out gy);
            var xx = new float[w * h];
            var yy = new float[w * h];
            var xy = new float[w * h];
            for (int i = 0; i < w * h; i++) {
                xx[i] = gx[i] * gx[i];
                yy[i] = gy[i] * gy[i];
                xy[i] = gx[i] * gy[i];
            }
            xx = Filters.gaussian_plane(xx, w, h, 1.5);
            yy = Filters.gaussian_plane(yy, w, h, 1.5);
            xy = Filters.gaussian_plane(xy, w, h, 1.5);
            var resp = new float[w * h];
            for (int i = 0; i < w * h; i++) {
                float det = xx[i] * yy[i] - xy[i] * xy[i], tr = xx[i] + yy[i];
                resp[i] = det - 0.04f * tr * tr;
            }
            int border = PATCH + 6;
            int cells = 10;
            int per_cell = int.max(4, max_points / (cells * cells));
            var feat = new PanoFeatures();
            var smooth = Filters.gaussian_plane(lum, w, h, 1.6);
            unowned int[] bp = brief_pairs();
            double[] pts = {};
            uint32[] descs = {};
            float rmax = 0;
            foreach (float r in resp) if (r > rmax) rmax = r;
            float thresh = rmax * 1e-4f;
            for (int cy = 0; cy < cells; cy++) {
                for (int cx = 0; cx < cells; cx++) {
                    int x0 = int.max(border, cx * w / cells), x1 = int.min(w - border, (cx + 1) * w / cells);
                    int y0 = int.max(border, cy * h / cells), y1 = int.min(h - border, (cy + 1) * h / cells);
                    var cand = new Gee.ArrayList<int>();
                    for (int y = y0; y < y1; y++) {
                        for (int x = x0; x < x1; x++) {
                            float r = resp[y * w + x];
                            if (r <= thresh) continue;
                            bool peak = true;
                            for (int j = -3; j <= 3 && peak; j++)
                                for (int i = -3; i <= 3; i++)
                                    if ((i != 0 || j != 0) && resp[(y + j) * w + x + i] > r) { peak = false; break; }
                            if (peak) cand.add(y * w + x);
                        }
                    }
                    cand.sort((a, b) => resp[a] > resp[b] ? -1 : (resp[a] < resp[b] ? 1 : 0));
                    for (int k = 0; k < int.min(per_cell, cand.size); k++) {
                        int p = cand[k];
                        int x = p % w, y = p / w;
                        double m10 = 0, m01 = 0;
                        for (int j = -PATCH; j <= PATCH; j++)
                            for (int i = -PATCH; i <= PATCH; i++) {
                                if (i * i + j * j > PATCH * PATCH) continue;
                                float v = smooth[(y + j) * w + x + i];
                                m10 += i * v;
                                m01 += j * v;
                            }
                        double ang = Math.atan2(m01, m10);
                        double ca = Math.cos(ang), sa = Math.sin(ang);
                        var d = new uint32[BRIEF_BITS / 32];
                        for (int b = 0; b < BRIEF_BITS; b++) {
                            int ax = bp[b * 4], ay = bp[b * 4 + 1], bx = bp[b * 4 + 2], by = bp[b * 4 + 3];
                            int rax = x + (int) Math.round(ax * ca - ay * sa), ray = y + (int) Math.round(ax * sa + ay * ca);
                            int rbx = x + (int) Math.round(bx * ca - by * sa), rby = y + (int) Math.round(bx * sa + by * ca);
                            if (smooth[ray * w + rax] < smooth[rby * w + rbx]) d[b / 32] |= 1u << (b % 32);
                        }
                        pts += (x + 0.5) * scale;
                        pts += (y + 0.5) * scale;
                        foreach (var v in d) descs += v;
                    }
                }
            }
            feat.points = pts;
            feat.descriptors = descs;
            feat.count = pts.length / 2;
            return feat;
        }

        private int popcount(uint32 v) {
            v = v - ((v >> 1) & 0x55555555u);
            v = (v & 0x33333333u) + ((v >> 2) & 0x33333333u);
            return (int) ((((v + (v >> 4)) & 0x0F0F0F0Fu) * 0x01010101u) >> 24);
        }

        private int hamming(PanoFeatures a, int i, PanoFeatures b, int j) {
            int d = 0;
            for (int k = 0; k < BRIEF_BITS / 32; k++) d += popcount(a.descriptors[i * 8 + k] ^ b.descriptors[j * 8 + k]);
            return d;
        }

        private int[] best_matches(PanoFeatures a, PanoFeatures b, bool ratio) {
            var best = new int[a.count];
            Parallel.range(a.count, (start, end) => {
                for (int i = start; i < end; i++) {
                    int b1 = 999, b2 = 999, bi = -1;
                    for (int j = 0; j < b.count; j++) {
                        int d = hamming(a, i, b, j);
                        if (d < b1) {
                            b2 = b1;
                            b1 = d;
                            bi = j;
                        } else if (d < b2) {
                            b2 = d;
                        }
                    }
                    best[i] = bi >= 0 && b1 < 80 && (!ratio || b1 < 0.8 * b2) ? bi : -1;
                }
            });
            return best;
        }

        public double[]? match_pair(PanoFeatures a, PanoFeatures b, double tolerance, out int inliers, out double[] src_pts, out double[] dst_pts) {
            inliers = 0;
            src_pts = {};
            dst_pts = {};
            var ab = best_matches(a, b, true);
            var ba = best_matches(b, a, false);
            double[] sp = {}, dp = {};
            for (int i = 0; i < a.count; i++) {
                int j = ab[i];
                if (j < 0 || ba[j] != i) continue;
                sp += a.points[i * 2];
                sp += a.points[i * 2 + 1];
                dp += b.points[j * 2];
                dp += b.points[j * 2 + 1];
            }
            int n = sp.length / 2;
            if (n < 8) return null;
            double[]? best_h = null;
            int best_count = 0;
            uint32 rng = 0xabcdefu + (uint32) n;
            double tol2 = tolerance * tolerance;
            for (int it = 0; it < 2000; it++) {
                int[] idx = new int[4];
                for (int k = 0; k < 4; k++) {
                    rng = AlgoUtil.hash(rng + 0x9e3779b9u);
                    idx[k] = (int) (rng % (uint) n);
                }
                if (idx[0] == idx[1] || idx[0] == idx[2] || idx[0] == idx[3] || idx[1] == idx[2] || idx[1] == idx[3] || idx[2] == idx[3]) continue;
                var hm = AlgoUtil.homography_dlt(sp, dp, idx);
                if (Matrix3.determinant(hm).abs() < 1e-6) continue;
                int count = 0;
                for (int k = 0; k < n; k++) {
                    double ox, oy;
                    AlgoUtil.apply_h(hm, sp[k * 2], sp[k * 2 + 1], out ox, out oy);
                    double ex = ox - dp[k * 2], ey = oy - dp[k * 2 + 1];
                    if (ex * ex + ey * ey < tol2) count++;
                }
                if (count > best_count) {
                    best_count = count;
                    best_h = hm;
                }
            }
            if (best_h == null) return null;
            int[] in_idx = {};
            for (int k = 0; k < n; k++) {
                double ox, oy;
                AlgoUtil.apply_h(best_h, sp[k * 2], sp[k * 2 + 1], out ox, out oy);
                double ex = ox - dp[k * 2], ey = oy - dp[k * 2 + 1];
                if (ex * ex + ey * ey < tol2) in_idx += k;
            }
            if (in_idx.length < 12 || in_idx.length < n * 0.15) return null;
            var refined = AlgoUtil.homography_dlt(sp, dp, in_idx);
            double[] s2 = {}, d2 = {};
            foreach (int k in in_idx) {
                s2 += sp[k * 2];
                s2 += sp[k * 2 + 1];
                d2 += dp[k * 2];
                d2 += dp[k * 2 + 1];
            }
            src_pts = s2;
            dst_pts = d2;
            inliers = in_idx.length;
            return refined;
        }

        private double focal_from(double[] hm, int w0, int h0, int w1, int h1) {
            double[] t0 = { 1, 0, w0 / 2.0, 0, 1, h0 / 2.0, 0, 0, 1 };
            double[] t1 = { 1, 0, -w1 / 2.0, 0, 1, -h1 / 2.0, 0, 0, 1 };
            var h = Matrix3.multiply(t1, Matrix3.multiply(hm, t0));
            if (h[8].abs() > 1e-12) for (int i = 0; i < 9; i++) h[i] /= h[8];
            double f0 = -1, f1 = -1;
            double d1 = h[6] * h[7], d2 = (h[7] - h[6]) * (h[7] + h[6]);
            double v1 = d1.abs() > 1e-15 ? -(h[0] * h[1] + h[3] * h[4]) / d1 : -1;
            double v2 = d2.abs() > 1e-15 ? (h[0] * h[0] + h[3] * h[3] - h[1] * h[1] - h[4] * h[4]) / d2 : -1;
            if (v1 < v2) { double t = v1; v1 = v2; v2 = t; }
            if (v1 > 0 && v2 > 0) f1 = Math.sqrt(d1.abs() > d2.abs() ? v1 : v2);
            else if (v1 > 0) f1 = Math.sqrt(v1);
            d1 = h[0] * h[3] + h[1] * h[4];
            d2 = h[0] * h[0] + h[1] * h[1] - h[3] * h[3] - h[4] * h[4];
            v1 = d1.abs() > 1e-15 ? -h[2] * h[5] / d1 : -1;
            v2 = d2.abs() > 1e-15 ? (h[5] * h[5] - h[2] * h[2]) / d2 : -1;
            if (v1 < v2) { double t = v1; v1 = v2; v2 = t; }
            if (v1 > 0 && v2 > 0) f0 = Math.sqrt(d1.abs() > d2.abs() ? v1 : v2);
            else if (v1 > 0) f0 = Math.sqrt(v1);
            if (f0 > 0 && f1 > 0) return Math.sqrt(f0 * f1);
            return -1;
        }

        private void to_output(string projection, double f, double X, double Y, out double u, out double v) {
            if (projection == "cylindrical") {
                u = f * Math.atan2(X, f);
                v = f * Y / Math.sqrt(X * X + f * f);
            } else if (projection == "spherical") {
                u = f * Math.atan2(X, f);
                v = f * Math.atan2(Y, Math.sqrt(X * X + f * f));
            } else {
                u = X;
                v = Y;
            }
        }

        private bool from_output(string projection, double f, double u, double v, out double X, out double Y) {
            if (projection == "cylindrical") {
                double th = u / f;
                if (th.abs() >= Math.PI / 2 * 0.98) { X = 0; Y = 0; return false; }
                X = f * Math.tan(th);
                Y = v / f * Math.sqrt(X * X + f * f);
                return true;
            } else if (projection == "spherical") {
                double th = u / f, ph = v / f;
                if (th.abs() >= Math.PI / 2 * 0.98 || ph.abs() >= Math.PI / 2 * 0.98) { X = 0; Y = 0; return false; }
                X = f * Math.tan(th);
                Y = Math.tan(ph) * Math.sqrt(X * X + f * f);
                return true;
            }
            X = u;
            Y = v;
            return true;
        }

        public FloatImage stitch(FloatImage[] images, string projection, MergeProgress? progress = null) throws Error {
            int n = images.length;
            if (n < 2) throw new IOError.INVALID_ARGUMENT(_("Select at least two overlapping photos"));
            bool crop = projection.has_suffix("+crop");
            string proj = crop ? projection.substring(0, projection.length - 5) : projection;
            if (proj != "cylindrical" && proj != "spherical") proj = "perspective";
            var feats = new PanoFeatures[n];
            for (int i = 0; i < n; i++) {
                feats[i] = features(images[i]);
                if (progress != null) progress(0.2 * (i + 1) / n, _("Finding features"));
            }
            var hs = new double[n * n * 9];
            var have = new bool[n * n];
            var weight = new int[n * n];
            var pair_src = new Gee.HashMap<int, MergePoints>();
            double focal_sum = 0;
            int focal_n = 0;
            for (int i = 0; i < n; i++) {
                for (int j = i + 1; j < n; j++) {
                    int inl;
                    double[] sp, dp;
                    double tol = 3.0 * double.max(1.0, (double) int.max(images[i].width, images[i].height) / WORK_SIDE);
                    var hm = match_pair(feats[i], feats[j], tol, out inl, out sp, out dp);
                    if (hm == null) continue;
                    have[i * n + j] = true;
                    weight[i * n + j] = inl;
                    weight[j * n + i] = inl;
                    have[j * n + i] = true;
                    var inv = Matrix3.invert(hm);
                    for (int k = 0; k < 9; k++) {
                        hs[(i * n + j) * 9 + k] = hm[k];
                        hs[(j * n + i) * 9 + k] = inv[k];
                    }
                    pair_src[i * n + j] = new MergePoints(sp, dp);
                    double f = focal_from(hm, images[i].width, images[i].height, images[j].width, images[j].height);
                    if (f > 0) {
                        focal_sum += Math.log(f);
                        focal_n++;
                    }
                }
                if (progress != null) progress(0.2 + 0.3 * (i + 1) / n, _("Matching"));
            }
            int reference = 0, best_total = -1;
            for (int i = 0; i < n; i++) {
                int total = 0;
                for (int j = 0; j < n; j++) total += weight[i * n + j];
                if (total > best_total) {
                    best_total = total;
                    reference = i;
                }
            }
            var to_ref = new double[n * 9];
            var placed = new bool[n];
            var parent = new int[n];
            placed[reference] = true;
            parent[reference] = -1;
            double[] id = Matrix3.identity();
            for (int k = 0; k < 9; k++) to_ref[reference * 9 + k] = id[k];
            int[] order = { reference };
            for (int step = 1; step < n; step++) {
                int bi = -1, bp = -1, bw = 0;
                for (int i = 0; i < n; i++) {
                    if (placed[i]) continue;
                    for (int p = 0; p < n; p++) {
                        if (!placed[p] || !have[i * n + p]) continue;
                        if (weight[i * n + p] > bw) {
                            bw = weight[i * n + p];
                            bi = i;
                            bp = p;
                        }
                    }
                }
                if (bi < 0) throw new IOError.FAILED(_("Some photos do not overlap enough to be stitched"));
                var hip = hs[(bi * n + bp) * 9:(bi * n + bp) * 9 + 9];
                var hpr = to_ref[bp * 9:bp * 9 + 9];
                var hir = Matrix3.multiply(hpr, hip);
                for (int k = 0; k < 9; k++) to_ref[bi * 9 + k] = hir[k] / hir[8];
                placed[bi] = true;
                parent[bi] = bp;
                order += bi;
            }
            foreach (int i in order) {
                if (i == reference) continue;
                double[] src = {}, dst = {};
                for (int j = 0; j < n; j++) {
                    if (j == i || !placed[j]) continue;
                    MergePoints? mp = null;
                    bool forward = true;
                    if (pair_src.has_key(i * n + j)) mp = pair_src[i * n + j];
                    else if (pair_src.has_key(j * n + i)) { mp = pair_src[j * n + i]; forward = false; }
                    if (mp == null) continue;
                    var hj = to_ref[j * 9:j * 9 + 9];
                    int cnt = mp.src.length / 2;
                    for (int k = 0; k < cnt; k++) {
                        double ix = forward ? mp.src[k * 2] : mp.dst[k * 2], iy = forward ? mp.src[k * 2 + 1] : mp.dst[k * 2 + 1];
                        double jx = forward ? mp.dst[k * 2] : mp.src[k * 2], jy = forward ? mp.dst[k * 2 + 1] : mp.src[k * 2 + 1];
                        double rx, ry;
                        AlgoUtil.apply_h(hj, jx, jy, out rx, out ry);
                        src += ix;
                        src += iy;
                        dst += rx;
                        dst += ry;
                    }
                }
                int cntall = src.length / 2;
                if (cntall >= 12) {
                    var idx = new int[cntall];
                    for (int k = 0; k < cntall; k++) idx[k] = k;
                    var hr = AlgoUtil.homography_dlt(src, dst, idx);
                    for (int k = 0; k < 9; k++) to_ref[i * 9 + k] = hr[k];
                }
            }
            int rw = images[reference].width, rh = images[reference].height;
            double f = focal_n > 0 ? Math.exp(focal_sum / focal_n) : 1.2 * int.max(rw, rh);
            if (f < 0.3 * int.max(rw, rh) || f > 20 * int.max(rw, rh)) f = 1.2 * int.max(rw, rh);
            double rcx = rw / 2.0, rcy = rh / 2.0;
            double umin = double.MAX, umax = -double.MAX, vmin = double.MAX, vmax = -double.MAX;
            for (int i = 0; i < n; i++) {
                int iw = images[i].width, ih = images[i].height;
                var hm = to_ref[i * 9:i * 9 + 9];
                for (int k = 0; k <= 40; k++) {
                    double t = k / 40.0;
                    double[] ex = { t * iw, iw, (1 - t) * iw, 0 };
                    double[] ey = { 0, t * ih, ih, (1 - t) * ih };
                    for (int e = 0; e < 4; e++) {
                        double X, Y;
                        AlgoUtil.apply_h(hm, ex[e], ey[e], out X, out Y);
                        double u, v;
                        to_output(proj, f, X - rcx, Y - rcy, out u, out v);
                        umin = double.min(umin, u);
                        umax = double.max(umax, u);
                        vmin = double.min(vmin, v);
                        vmax = double.max(vmax, v);
                    }
                }
            }
            double out_scale = 1.0;
            double span_u = umax - umin, span_v = vmax - vmin;
            if (span_u * span_v > 80e6 || span_u > 20000 || span_v > 20000) out_scale = double.min(Math.sqrt(80e6 / (span_u * span_v)), 20000 / double.max(span_u, span_v));
            int ow = int.max(1, (int) Math.ceil(span_u * out_scale)), oh = int.max(1, (int) Math.ceil(span_v * out_scale));
            var inv = new double[n * 9];
            for (int i = 0; i < n; i++) {
                var iv = Matrix3.invert(to_ref[i * 9:i * 9 + 9]);
                for (int k = 0; k < 9; k++) inv[i * 9 + k] = iv[k];
            }
            var best_w = new float[(size_t) ow * oh];
            var label = new int[(size_t) ow * oh];
            for (size_t p = 0; p < label.length; p++) label[p] = -1;
            var gains = new float[n];
            var sums = new double[n * n];
            var counts = new int[n * n];
            Parallel.range(oh, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < ow; x++) {
                        double u = umin + (x + 0.5) / out_scale, v = vmin + (y + 0.5) / out_scale;
                        double X, Y;
                        if (!from_output(proj, f, u, v, out X, out Y)) continue;
                        size_t p = (size_t) y * ow + x;
                        for (int i = 0; i < n; i++) {
                            int iw = images[i].width, ih = images[i].height;
                            double sx, sy;
                            AlgoUtil.apply_h(inv[i * 9:i * 9 + 9], X + rcx, Y + rcy, out sx, out sy);
                            if (sx < 0 || sy < 0 || sx >= iw || sy >= ih) continue;
                            float edge = 1.0f + (float) double.min(double.min(sx, iw - sx) / iw, double.min(sy, ih - sy) / ih);
                            if (edge > best_w[p]) {
                                best_w[p] = edge;
                                label[p] = i;
                            }
                        }
                    }
                }
            });
            for (int y = 2; y < oh; y += 4) {
                for (int x = 2; x < ow; x += 4) {
                    double u = umin + (x + 0.5) / out_scale, v = vmin + (y + 0.5) / out_scale;
                    double X, Y;
                    if (!from_output(proj, f, u, v, out X, out Y)) continue;
                    var lum = new double[n];
                    var inside = new bool[n];
                    for (int i = 0; i < n; i++) {
                        double sx, sy;
                        AlgoUtil.apply_h(inv[i * 9:i * 9 + 9], X + rcx, Y + rcy, out sx, out sy);
                        if (sx < 0 || sy < 0 || sx >= images[i].width || sy >= images[i].height) continue;
                        float r, g, b, al;
                        images[i].sample(sx, sy, out r, out g, out b, out al);
                        lum[i] = AlgoUtil.LR * r + AlgoUtil.LG * g + AlgoUtil.LB * b;
                        inside[i] = true;
                    }
                    for (int i = 0; i < n; i++) {
                        if (!inside[i]) continue;
                        for (int j = 0; j < n; j++) {
                            if (j == i || !inside[j]) continue;
                            sums[i * n + j] += lum[i];
                            counts[i * n + j]++;
                        }
                    }
                }
            }
            for (int i = 0; i < n; i++) gains[i] = 1;
            foreach (int i in order) {
                if (i == reference) continue;
                int p = parent[i];
                if (counts[i * n + p] < 20) {
                    gains[i] = gains[p];
                    continue;
                }
                double li = sums[i * n + p], lp = sums[p * n + i];
                if (li <= 1e-9) continue;
                gains[i] = (float) (gains[p] * (lp / li)).clamp(0.5, 2.0);
            }
            if (progress != null) progress(0.65, _("Blending"));
            int levels = MergeUtil.pyramid_levels(ow, oh, 6);
            Gee.ArrayList<FloatImage>? acc = null;
            Gee.ArrayList<MergePlane>? wacc = null;
            for (int i = 0; i < n; i++) {
                var src = images[i];
                int iw = src.width, ih = src.height;
                var wimg = new FloatImage(ow, oh);
                int ii = i;
                float g = gains[i];
                Parallel.range(oh, (start, end) => {
                    for (int y = start; y < end; y++) {
                        for (int x = 0; x < ow; x++) {
                            double u = umin + (x + 0.5) / out_scale, v = vmin + (y + 0.5) / out_scale;
                            double X, Y;
                            size_t d = wimg.offset(x, y);
                            wimg.data[d + 3] = 0;
                            if (!from_output(proj, f, u, v, out X, out Y)) continue;
                            double sx, sy;
                            AlgoUtil.apply_h(inv[ii * 9:ii * 9 + 9], X + rcx, Y + rcy, out sx, out sy);
                            if (sx < 0 || sy < 0 || sx >= iw || sy >= ih) continue;
                            float r, gg, b, a;
                            src.sample(sx, sy, out r, out gg, out b, out a);
                            wimg.data[d] = r * g;
                            wimg.data[d + 1] = gg * g;
                            wimg.data[d + 2] = b * g;
                            wimg.data[d + 3] = 1;
                        }
                    }
                });
                var mask = new float[(size_t) ow * oh];
                for (size_t p = 0; p < mask.length; p++) mask[p] = label[p] == i ? 1 : 0;
                MergeUtil.push_pull_fill(wimg);
                var lap = MergeUtil.laplacian(wimg, levels);
                wimg = null;
                var gm = MergeUtil.gaussian_planes(mask, ow, oh, levels);
                if (acc == null) {
                    acc = new Gee.ArrayList<FloatImage>();
                    wacc = new Gee.ArrayList<MergePlane>();
                    foreach (var l in lap) {
                        acc.add(new FloatImage(l.width, l.height));
                        wacc.add(new MergePlane(new float[l.pixel_count()], l.width, l.height));
                    }
                }
                for (int lv = 0; lv < levels; lv++) {
                    var l = lap[lv];
                    var a = acc[lv];
                    unowned float[] wd = gm[lv].data;
                    unowned float[] ws = wacc[lv].data;
                    size_t np = l.pixel_count();
                    for (size_t p = 0; p < np; p++) {
                        float wt = wd[p];
                        if (wt <= 0) continue;
                        for (int c = 0; c < 3; c++) a.data[p * 4 + c] += l.data[p * 4 + c] * wt;
                        ws[p] += wt;
                    }
                }
                if (progress != null) progress(0.65 + 0.3 * (i + 1) / n, _("Blending"));
            }
            for (int lv = 0; lv < levels; lv++) {
                var a = acc[lv];
                unowned float[] ws = wacc[lv].data;
                for (size_t p = 0; p < a.pixel_count(); p++) {
                    if (ws[p] <= 1e-6f) continue;
                    for (int c = 0; c < 3; c++) a.data[p * 4 + c] /= ws[p];
                }
            }
            var result = MergeUtil.collapse(acc);
            var cov = new uint8[(size_t) ow * oh];
            for (size_t p = 0; p < result.pixel_count(); p++) {
                bool covered = label[p] >= 0;
                cov[p] = covered ? 1 : 0;
                result.data[p * 4 + 3] = covered ? 1 : 0;
                if (!covered) for (int c = 0; c < 3; c++) result.data[p * 4 + c] = 0;
            }
            if (crop) {
                int rx, ry, rcw, rch;
                MergeUtil.largest_rectangle(cov, ow, oh, out rx, out ry, out rcw, out rch);
                if (rcw > 8 && rch > 8) result = result.cropped(rx, ry, rcw, rch);
            }
            if (progress != null) progress(1.0, _("Done"));
            return result;
        }
    }

    public class MergePoints : Object {
        public double[] src;
        public double[] dst;

        public MergePoints(double[] src, double[] dst) {
            this.src = src;
            this.dst = dst;
        }
    }
}
