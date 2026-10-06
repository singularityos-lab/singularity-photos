using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace Segmentation {

        private const int WORK_SIDE = 480;

        private float sigmoid(float x) {
            return 1.0f / (1.0f + Math.expf(-x));
        }

        private float[] refine(FloatImage img, float[] small, int sw, int sh, double eps) {
            int w = img.width, h = img.height;
            var up = Filters.resize_plane(small, sw, sh, w, h);
            var guide = AlgoUtil.perceptual_luma(img);
            int radius = int.max(2, int.max(w, h) / 160);
            var q = Filters.guided_plane(guide, up, w, h, radius, (float) eps);
            for (int i = 0; i < q.length; i++) q[i] = q[i].clamp(0, 1);
            return q;
        }

        private float[] flood_from(uint8[] seeds, float[] score, int w, int h, float threshold) {
            var result = new float[w * h];
            var queue = new int[w * h];
            int head = 0, tail = 0;
            for (int i = 0; i < w * h; i++) {
                if (seeds[i] != 0 && score[i] >= threshold) {
                    result[i] = 1;
                    queue[tail++] = i;
                }
            }
            while (head < tail) {
                int p = queue[head++];
                int x = p % w, y = p / w;
                int[] ns = { x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, y > 0 ? p - w : -1, y < h - 1 ? p + w : -1 };
                foreach (int n in ns) {
                    if (n < 0 || result[n] != 0 || score[n] < threshold) continue;
                    result[n] = 1;
                    queue[tail++] = n;
                }
            }
            return result;
        }

        public float[] sky(FloatImage img) {
            var small = AlgoUtil.encoded_copy(img.scaled_to_fit(WORK_SIDE));
            int w = small.width, h = small.height;
            int n = w * h;
            var lum = new float[n];
            for (int i = 0; i < n; i++) lum[i] = small.data[i * 4] * 0.2627f + small.data[i * 4 + 1] * 0.678f + small.data[i * 4 + 2] * 0.0593f;
            float[] gx, gy;
            var grad = AlgoUtil.sobel_magnitude(Filters.gaussian_plane(lum, w, h, 1.0), w, h, out gx, out gy);
            var texture = Filters.box_plane(grad, w, h, 3);
            var score = new float[n];
            for (int y = 0; y < h; y++) {
                float pos = 1.0f - (float) y / h;
                for (int x = 0; x < w; x++) {
                    int i = y * w + x;
                    float r = small.data[i * 4], g = small.data[i * 4 + 1], b = small.data[i * 4 + 2];
                    float mx = float.max(r, float.max(g, b)), mn = float.min(r, float.min(g, b));
                    float sat = mx > 1e-4f ? (mx - mn) / mx : 0;
                    float blue = sigmoid(((b - r) * 6.0f) + 0.5f);
                    float gray_bright = sigmoid((lum[i] - 0.55f) * 10.0f) * (1.0f - sat);
                    float colour = float.max(blue * sigmoid((lum[i] - 0.25f) * 8.0f), gray_bright);
                    float warm_sunset = sigmoid((lum[i] - 0.45f) * 8.0f) * sigmoid((r - g) * 4.0f) * pos;
                    colour = float.max(colour, warm_sunset * 0.8f);
                    float smooth = sigmoid((0.12f - texture[i]) * 30.0f);
                    score[i] = colour * smooth * (0.35f + 0.65f * pos);
                }
            }
            var seeds = new uint8[n];
            for (int x = 0; x < w; x++) for (int y = 0; y < int.max(1, h / 12); y++) seeds[y * w + x] = 1;
            var connected = flood_from(seeds, score, w, h, 0.28f);
            int cnt = 0;
            double[] mean_s = { 0, 0, 0 }, mean_g = { 0, 0, 0 };
            double[] var_s = { 0, 0, 0 }, var_g = { 0, 0, 0 };
            int cg = 0;
            for (int i = 0; i < n; i++) {
                for (int c = 0; c < 3; c++) {
                    double v = small.data[i * 4 + c];
                    if (connected[i] > 0.5f) mean_s[c] += v;
                    else if (score[i] < 0.15f) mean_g[c] += v;
                }
                if (connected[i] > 0.5f) cnt++;
                else if (score[i] < 0.15f) cg++;
            }
            if (cnt < n / 200) return new float[img.pixel_count()];
            for (int c = 0; c < 3; c++) {
                mean_s[c] /= cnt;
                mean_g[c] /= int.max(1, cg);
            }
            for (int i = 0; i < n; i++) {
                for (int c = 0; c < 3; c++) {
                    double v = small.data[i * 4 + c];
                    if (connected[i] > 0.5f) var_s[c] += (v - mean_s[c]) * (v - mean_s[c]);
                    else if (score[i] < 0.15f) var_g[c] += (v - mean_g[c]) * (v - mean_g[c]);
                }
            }
            for (int c = 0; c < 3; c++) {
                var_s[c] = var_s[c] / cnt + 0.002;
                var_g[c] = var_g[c] / int.max(1, cg) + 0.01;
            }
            var prob = new float[n];
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int i = y * w + x;
                    double ls = 0, lg = 0;
                    for (int c = 0; c < 3; c++) {
                        double v = small.data[i * 4 + c];
                        ls += -0.5 * (v - mean_s[c]) * (v - mean_s[c]) / var_s[c] - 0.5 * Math.log(var_s[c]);
                        lg += -0.5 * (v - mean_g[c]) * (v - mean_g[c]) / var_g[c] - 0.5 * Math.log(var_g[c]);
                    }
                    float p = sigmoid((float) ((ls - lg) * 0.5));
                    float smooth = sigmoid((0.15f - texture[i]) * 25.0f);
                    prob[i] = (p * 0.6f + score[i] * 0.4f) * (0.4f + 0.6f * smooth);
                }
            }
            var final_mask = flood_from(seeds, prob, w, h, 0.4f);
            var soft = Filters.gaussian_plane(final_mask, w, h, 0.8);
            return refine(img, soft, w, h, 1e-3);
        }

        private void kmeans_gmm(float[] data, int n, int[] idx, int k, out float[] means, out float[] vars, out float[] weights) {
            means = new float[k * 3];
            vars = new float[k * 3];
            weights = new float[k];
            if (idx.length == 0) {
                for (int i = 0; i < k * 3; i++) vars[i] = 1;
                for (int i = 0; i < k; i++) weights[i] = 1.0f / k;
                return;
            }
            for (int c = 0; c < k; c++) {
                int pick = idx[(c * idx.length) / k + (idx.length / (2 * k))];
                for (int d = 0; d < 3; d++) means[c * 3 + d] = data[pick * 3 + d];
            }
            var assign = new int[idx.length];
            for (int it = 0; it < 8; it++) {
                var sums = new double[k * 3];
                var counts = new int[k];
                for (int j = 0; j < idx.length; j++) {
                    int p = idx[j];
                    float best = float.MAX;
                    int bc = 0;
                    for (int c = 0; c < k; c++) {
                        float dd = 0;
                        for (int d = 0; d < 3; d++) {
                            float t = data[p * 3 + d] - means[c * 3 + d];
                            dd += t * t;
                        }
                        if (dd < best) {
                            best = dd;
                            bc = c;
                        }
                    }
                    assign[j] = bc;
                    counts[bc]++;
                    for (int d = 0; d < 3; d++) sums[bc * 3 + d] += data[p * 3 + d];
                }
                for (int c = 0; c < k; c++) if (counts[c] > 0) for (int d = 0; d < 3; d++) means[c * 3 + d] = (float) (sums[c * 3 + d] / counts[c]);
            }
            var vs = new double[k * 3];
            var cs = new int[k];
            for (int j = 0; j < idx.length; j++) {
                int c = assign[j];
                cs[c]++;
                for (int d = 0; d < 3; d++) {
                    double t = data[idx[j] * 3 + d] - means[c * 3 + d];
                    vs[c * 3 + d] += t * t;
                }
            }
            for (int c = 0; c < k; c++) {
                weights[c] = (float) (cs[c] + 1) / (idx.length + k);
                for (int d = 0; d < 3; d++) vars[c * 3 + d] = (float) (vs[c * 3 + d] / int.max(1, cs[c]) + 0.0015);
            }
        }

        private float gmm_loglik(float[] data, int p, float[] means, float[] vars, float[] weights) {
            int k = weights.length;
            double sum = 0;
            for (int c = 0; c < k; c++) {
                double e = 0, norm = 1;
                for (int d = 0; d < 3; d++) {
                    double t = data[p * 3 + d] - means[c * 3 + d];
                    e += t * t / vars[c * 3 + d];
                    norm *= vars[c * 3 + d];
                }
                sum += weights[c] * Math.exp(-0.5 * e) / Math.sqrt(norm);
            }
            return (float) Math.log(sum + 1e-30);
        }

        private float[] to_lab(FloatImage img) {
            int n = (int) img.pixel_count();
            var lab = new float[n * 3];
            Parallel.range(n, (start, end) => {
                for (int i = start; i < end; i++) {
                    double r = double.max(0, img.data[i * 4]), g = double.max(0, img.data[i * 4 + 1]), b = double.max(0, img.data[i * 4 + 2]);
                    double x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.9505;
                    double y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                    double z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.089;
                    double fx = x > 0.008856 ? Math.cbrt(x) : 7.787 * x + 16.0 / 116;
                    double fy = y > 0.008856 ? Math.cbrt(y) : 7.787 * y + 16.0 / 116;
                    double fz = z > 0.008856 ? Math.cbrt(z) : 7.787 * z + 16.0 / 116;
                    lab[i * 3] = (float) (116 * fy - 16);
                    lab[i * 3 + 1] = (float) (500 * (fx - fy));
                    lab[i * 3 + 2] = (float) (200 * (fy - fz));
                }
            }, 1024);
            return lab;
        }

        public int superpixels(float[] lab, int w, int h, int count, out int[] labels) {
            int n = w * h;
            int step = int.max(4, (int) Math.sqrt((double) n / count));
            int gw = (w + step - 1) / step, gh = (h + step - 1) / step;
            int k = gw * gh;
            var cl = new float[k * 3];
            var cx = new float[k];
            var cy = new float[k];
            for (int j = 0; j < gh; j++) {
                for (int i = 0; i < gw; i++) {
                    int c = j * gw + i;
                    int x = int.min(w - 1, i * step + step / 2), y = int.min(h - 1, j * step + step / 2);
                    cx[c] = x;
                    cy[c] = y;
                    for (int d = 0; d < 3; d++) cl[c * 3 + d] = lab[(y * w + x) * 3 + d];
                }
            }
            var lbl = new int[n];
            float m2 = 10.0f * 10.0f / (step * step);
            for (int it = 0; it < 8; it++) {
                Parallel.range(h, (start, end) => {
                    for (int y = start; y < end; y++) {
                        int gj = int.min(gh - 1, y / step);
                        for (int x = 0; x < w; x++) {
                            int gi = int.min(gw - 1, x / step);
                            float best = float.MAX;
                            int bc = gj * gw + gi;
                            for (int dj = -1; dj <= 1; dj++) {
                                int jj = gj + dj;
                                if (jj < 0 || jj >= gh) continue;
                                for (int di = -1; di <= 1; di++) {
                                    int ii = gi + di;
                                    if (ii < 0 || ii >= gw) continue;
                                    int c = jj * gw + ii;
                                    float d0 = lab[(y * w + x) * 3] - cl[c * 3], d1 = lab[(y * w + x) * 3 + 1] - cl[c * 3 + 1], d2 = lab[(y * w + x) * 3 + 2] - cl[c * 3 + 2];
                                    float sx = x - cx[c], sy = y - cy[c];
                                    float d = d0 * d0 + d1 * d1 + d2 * d2 + (sx * sx + sy * sy) * m2;
                                    if (d < best) {
                                        best = d;
                                        bc = c;
                                    }
                                }
                            }
                            lbl[y * w + x] = bc;
                        }
                    }
                });
                var acc = new double[k * 5];
                var cnt = new int[k];
                for (int y = 0; y < h; y++) {
                    for (int x = 0; x < w; x++) {
                        int c = lbl[y * w + x];
                        cnt[c]++;
                        acc[c * 5] += lab[(y * w + x) * 3];
                        acc[c * 5 + 1] += lab[(y * w + x) * 3 + 1];
                        acc[c * 5 + 2] += lab[(y * w + x) * 3 + 2];
                        acc[c * 5 + 3] += x;
                        acc[c * 5 + 4] += y;
                    }
                }
                for (int c = 0; c < k; c++) {
                    if (cnt[c] == 0) continue;
                    for (int d = 0; d < 3; d++) cl[c * 3 + d] = (float) (acc[c * 5 + d] / cnt[c]);
                    cx[c] = (float) (acc[c * 5 + 3] / cnt[c]);
                    cy[c] = (float) (acc[c * 5 + 4] / cnt[c]);
                }
            }
            var final_lbl = new int[n];
            for (int i = 0; i < n; i++) final_lbl[i] = -1;
            var queue = new int[n];
            int next = 0;
            int min_size = int.max(4, step * step / 4);
            for (int s0 = 0; s0 < n; s0++) {
                if (final_lbl[s0] >= 0) continue;
                int head = 0, tail = 0;
                queue[tail++] = s0;
                final_lbl[s0] = next;
                int adjacent = -1;
                while (head < tail) {
                    int p = queue[head++];
                    int x = p % w, y = p / w;
                    int[] ns = { x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, y > 0 ? p - w : -1, y < h - 1 ? p + w : -1 };
                    foreach (int q in ns) {
                        if (q < 0) continue;
                        if (final_lbl[q] >= 0 && final_lbl[q] != next) adjacent = final_lbl[q];
                        if (final_lbl[q] >= 0 || lbl[q] != lbl[s0]) continue;
                        final_lbl[q] = next;
                        queue[tail++] = q;
                    }
                }
                if (tail < min_size && adjacent >= 0) {
                    for (int t = 0; t < tail; t++) final_lbl[queue[t]] = adjacent;
                } else {
                    next++;
                }
            }
            labels = final_lbl;
            return next;
        }

        private double[] geodesic(int k, Gee.ArrayList<int>[] adj, Gee.ArrayList<double?>[] wts, int source) {
            var dist = new double[k];
            var done = new bool[k];
            for (int i = 0; i < k; i++) dist[i] = double.MAX;
            dist[source] = 0;
            for (int iter = 0; iter < k; iter++) {
                int u = -1;
                double best = double.MAX;
                for (int i = 0; i < k; i++) if (!done[i] && dist[i] < best) { best = dist[i]; u = i; }
                if (u < 0) break;
                done[u] = true;
                for (int e = 0; e < adj[u].size; e++) {
                    int v = adj[u][e];
                    double wv = wts[u][e];
                    double nd = dist[u] + wv;
                    if (nd < dist[v]) dist[v] = nd;
                }
            }
            return dist;
        }

        public float[] saliency(FloatImage small, out int[] sp_labels) {
            int w = small.width, h = small.height, n = w * h;
            var lab = to_lab(small);
            int[] labels;
            int k = superpixels(lab, w, h, 300, out labels);
            sp_labels = labels;
            var mean = new double[k * 3];
            var pos = new double[k * 2];
            var area = new int[k];
            var border = new bool[k];
            var skyp = new double[k];
            var focus = new double[k];
            var sky_mask = sky(small);
            var depth = DepthEstimate.from_defocus(small);
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int i = y * w + x, c = labels[i];
                    area[c]++;
                    for (int d = 0; d < 3; d++) mean[c * 3 + d] += lab[i * 3 + d];
                    pos[c * 2] += (double) x / w;
                    pos[c * 2 + 1] += (double) y / h;
                    skyp[c] += sky_mask[i];
                    focus[c] += depth[i];
                    if (x == 0 || y == 0 || x == w - 1 || y == h - 1) border[c] = true;
                }
            }
            for (int c = 0; c < k; c++) {
                int a = int.max(1, area[c]);
                for (int d = 0; d < 3; d++) mean[c * 3 + d] /= a;
                pos[c * 2] /= a;
                pos[c * 2 + 1] /= a;
                skyp[c] /= a;
                focus[c] /= a;
            }
            var adj = new Gee.ArrayList<int>[k];
            var wts = new Gee.ArrayList<double?>[k];
            for (int c = 0; c < k; c++) {
                adj[c] = new Gee.ArrayList<int>();
                wts[c] = new Gee.ArrayList<double?>();
            }
            var seen = new Gee.HashSet<int>();
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int a = labels[y * w + x];
                    int[] ns = { x < w - 1 ? labels[y * w + x + 1] : a, y < h - 1 ? labels[(y + 1) * w + x] : a };
                    foreach (int b in ns) {
                        if (b == a) continue;
                        int key = int.min(a, b) * k + int.max(a, b);
                        if (seen.contains(key)) continue;
                        seen.add(key);
                        double d = 0;
                        for (int t = 0; t < 3; t++) d += Math.pow(mean[a * 3 + t] - mean[b * 3 + t], 2);
                        d = Math.sqrt(d);
                        adj[a].add(b);
                        wts[a].add(d);
                        adj[b].add(a);
                        wts[b].add(d);
                    }
                }
            }
            int[] borders = {};
            for (int c = 0; c < k; c++) if (border[c]) borders += c;
            for (int i = 0; i < borders.length; i++) {
                for (int j = i + 1; j < borders.length; j++) {
                    adj[borders[i]].add(borders[j]);
                    wts[borders[i]].add(0.0);
                    adj[borders[j]].add(borders[i]);
                    wts[borders[j]].add(0.0);
                }
            }
            var geo = new double[k * k];
            Parallel.range(k, (start, end) => {
                for (int c = start; c < end; c++) {
                    var dd = geodesic(k, adj, wts, c);
                    for (int t = 0; t < k; t++) geo[c * k + t] = dd[t];
                }
            }, 4);
            double sclr = 10.0;
            var wbg = new double[k];
            for (int c = 0; c < k; c++) {
                double ar = 0, len = 0;
                for (int t = 0; t < k; t++) {
                    double e = Math.exp(-geo[c * k + t] * geo[c * k + t] / (2 * sclr * sclr));
                    ar += e;
                    if (border[t]) len += e;
                }
                double bnd = len / Math.sqrt(double.max(ar, 1e-9));
                wbg[c] = 1 - Math.exp(-bnd * bnd / 2);
                wbg[c] = double.max(wbg[c], skyp[c]);
            }
            double dmin = double.MAX, dmax = -double.MAX, dmean = 0;
            for (int c = 0; c < k; c++) {
                dmin = double.min(dmin, focus[c]);
                dmax = double.max(dmax, focus[c]);
                dmean += focus[c] / k;
            }
            double dvar = 0;
            for (int c = 0; c < k; c++) dvar += Math.pow(focus[c] - dmean, 2) / k;
            bool use_focus = Math.sqrt(dvar) > 0.12;
            var wfg = new double[k];
            double fmax = 1e-9;
            for (int c = 0; c < k; c++) {
                double ctr = 0;
                for (int t = 0; t < k; t++) {
                    if (t == c) continue;
                    double dapp = 0;
                    for (int d = 0; d < 3; d++) dapp += Math.pow(mean[c * 3 + d] - mean[t * 3 + d], 2);
                    dapp = Math.sqrt(dapp);
                    double ds = Math.pow(pos[c * 2] - pos[t * 2], 2) + Math.pow(pos[c * 2 + 1] - pos[t * 2 + 1], 2);
                    ctr += dapp * Math.exp(-ds / (2 * 0.25 * 0.25)) * wbg[t];
                }
                double center = Math.exp(-(Math.pow(pos[c * 2] - 0.5, 2) + Math.pow(pos[c * 2 + 1] - 0.5, 2)) / (2 * 0.4 * 0.4));
                ctr *= 0.6 + 0.4 * center;
                if (use_focus) ctr *= 0.35 + 0.65 * (1 - (focus[c] - dmin) / double.max(dmax - dmin, 1e-6));
                ctr *= 1 - skyp[c];
                wfg[c] = ctr;
                fmax = double.max(fmax, ctr);
            }
            for (int c = 0; c < k; c++) wfg[c] /= fmax;
            var a_mat = new double[k * k];
            var bv = new double[k];
            for (int c = 0; c < k; c++) {
                a_mat[c * k + c] += wbg[c] + wfg[c];
                bv[c] = wfg[c];
                for (int e = 0; e < adj[c].size; e++) {
                    int t = adj[c][e];
                    double we = wts[c][e];
                    if (border[c] && border[t] && we == 0.0) continue;
                    double wij = Math.exp(-we * we / (2 * sclr * sclr)) + 0.1;
                    a_mat[c * k + c] += wij;
                    a_mat[c * k + t] -= wij;
                }
            }
            var sal = AlgoUtil.solve_linear(a_mat, bv, k);
            double smax = 1e-9;
            foreach (double v in sal) smax = double.max(smax, v);
            var out_p = new float[n];
            for (int i = 0; i < n; i++) out_p[i] = (float) (sal[labels[i]] / smax).clamp(0, 1);
            return out_p;
        }

        public float[] subject(FloatImage img) {
            var small = img.scaled_to_fit(360);
            int w = small.width, h = small.height, n = w * h;
            int[] labels;
            var sal = saliency(small, out labels);
            var guide_l = AlgoUtil.perceptual_luma(small);
            sal = Filters.guided_plane(guide_l, sal, w, h, 4, 1e-2f);
            var col = to_lab(small);
            for (int i = 0; i < col.length; i++) col[i] /= 100.0f;
            var sky_mask = sky(small);
            float th = otsu(sal);
            var fg = new uint8[n];
            var hard_bg = new uint8[n];
            int nfg = 0;
            for (int i = 0; i < n; i++) {
                if (sky_mask[i] > 0.5f || sal[i] < th * 0.45f) hard_bg[i] = 1;
                if (sal[i] >= th && hard_bg[i] == 0) {
                    fg[i] = 1;
                    nfg++;
                }
            }
            if (nfg < 16) return new float[img.pixel_count()];
            double beta = 0;
            int pairs = 0;
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
                int i = y * w + x;
                if (x < w - 1) { beta += dist2(col, i, i + 1); pairs++; }
                if (y < h - 1) { beta += dist2(col, i, i + w); pairs++; }
            }
            beta = 1.0 / (2 * double.max(beta / pairs, 1e-9));
            for (int iter = 0; iter < 4; iter++) {
                int[] fi = {}, bi = {};
                for (int i = 0; i < n; i++) {
                    if (fg[i] != 0 && (iter > 0 || sal[i] >= th)) fi += i;
                    else if (fg[i] == 0 && (iter > 0 || sal[i] < th * 0.6f)) bi += i;
                }
                if (fi.length < 16 || bi.length < 16) break;
                float[] fm, fv, fw, gm, gv, gw;
                kmeans_gmm(col, n, fi, 5, out fm, out fv, out fw);
                kmeans_gmm(col, n, bi, 5, out gm, out gv, out gw);
                var cut = new GridCut(w, h);
                for (int i = 0; i < n; i++) {
                    float dfg = -gmm_loglik(col, i, fm, fv, fw);
                    float dbg = -gmm_loglik(col, i, gm, gv, gw);
                    float prior = (sal[i] - th) * 30.0f;
                    if (hard_bg[i] != 0) cut.set_terminal(i, 0, 1e6f);
                    else cut.set_terminal(i, float.max(0, dbg - dfg + prior), float.max(0, dfg - dbg - prior));
                }
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
                    int i = y * w + x;
                    if (x < w - 1) {
                        float wv = (float) (8.0 * Math.exp(-beta * dist2(col, i, i + 1)));
                        cut.set_edge(i, 0, wv);
                        cut.set_edge(i + 1, 1, wv);
                    }
                    if (y < h - 1) {
                        float wv = (float) (8.0 * Math.exp(-beta * dist2(col, i, i + w)));
                        cut.set_edge(i, 2, wv);
                        cut.set_edge(i + w, 3, wv);
                    }
                }
                cut.solve();
                int changed = 0;
                for (int i = 0; i < n; i++) {
                    uint8 v = cut.is_source(i) ? 1 : 0;
                    if (v != fg[i]) changed++;
                    fg[i] = v;
                }
                if (changed < n / 500) break;
            }
            var labels_cc = new int[n];
            var sizes = new Gee.ArrayList<int>();
            var queue = new int[n];
            int next = 1;
            for (int s0 = 0; s0 < n; s0++) {
                if (fg[s0] == 0 || labels_cc[s0] != 0) continue;
                int head = 0, tail = 0;
                queue[tail++] = s0;
                labels_cc[s0] = next;
                while (head < tail) {
                    int p = queue[head++];
                    int x = p % w, y = p / w;
                    int[] ns = { x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, y > 0 ? p - w : -1, y < h - 1 ? p + w : -1 };
                    foreach (int q in ns) {
                        if (q < 0 || fg[q] == 0 || labels_cc[q] != 0) continue;
                        labels_cc[q] = next;
                        queue[tail++] = q;
                    }
                }
                sizes.add(tail);
                next++;
            }
            int largest = 0;
            foreach (int sz in sizes) largest = int.max(largest, sz);
            var keep = new float[n];
            for (int i = 0; i < n; i++) {
                int l = labels_cc[i];
                if (l > 0 && sizes[l - 1] >= largest / 5) keep[i] = 1;
            }
            var filled = fill_holes(keep, w, h);
            var soft = Filters.gaussian_plane(filled, w, h, 0.7);
            return refine(img, soft, w, h, 5e-4);
        }

        private float otsu(float[] v) {
            var hist = new double[256];
            foreach (float x in v) hist[(int) (x.clamp(0, 1) * 255)] += 1;
            double total = v.length, sum = 0;
            for (int i = 0; i < 256; i++) sum += i * hist[i];
            double wb = 0, sb = 0, best = -1;
            int t = 128;
            for (int i = 0; i < 256; i++) {
                wb += hist[i];
                if (wb <= 0) continue;
                double wf = total - wb;
                if (wf <= 0) break;
                sb += i * hist[i];
                double mb = sb / wb, mf = (sum - sb) / wf;
                double between = wb * wf * (mb - mf) * (mb - mf);
                if (between > best) {
                    best = between;
                    t = i;
                }
            }
            return float.max(0.15f, (t + 0.5f) / 255.0f);
        }

        private double dist2(float[] col, int a, int b) {
            double d = 0;
            for (int t = 0; t < 3; t++) {
                double v = col[a * 3 + t] - col[b * 3 + t];
                d += v * v;
            }
            return d;
        }

        private float percentile(float[] v, double q) {
            var hist = new int[1024];
            foreach (float x in v) hist[(int) (x.clamp(0, 1) * 1023)]++;
            int target = (int) (v.length * q), acc = 0;
            for (int i = 0; i < 1024; i++) {
                acc += hist[i];
                if (acc > target) return i / 1023.0f;
            }
            return 1.0f;
        }

        private float[] fill_holes(float[] m, int w, int h) {
            var outside = new uint8[w * h];
            var queue = new int[w * h];
            int head = 0, tail = 0;
            for (int x = 0; x < w; x++) {
                foreach (int y in new int[] { 0, h - 1 }) {
                    int p = y * w + x;
                    if (m[p] < 0.5f && outside[p] == 0) { outside[p] = 1; queue[tail++] = p; }
                }
            }
            for (int y = 0; y < h; y++) {
                foreach (int x in new int[] { 0, w - 1 }) {
                    int p = y * w + x;
                    if (m[p] < 0.5f && outside[p] == 0) { outside[p] = 1; queue[tail++] = p; }
                }
            }
            while (head < tail) {
                int p = queue[head++];
                int x = p % w, y = p / w;
                int[] ns = { x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, y > 0 ? p - w : -1, y < h - 1 ? p + w : -1 };
                foreach (int nb in ns) {
                    if (nb < 0 || outside[nb] != 0 || m[nb] >= 0.5f) continue;
                    outside[nb] = 1;
                    queue[tail++] = nb;
                }
            }
            var r = new float[w * h];
            for (int i = 0; i < w * h; i++) r[i] = outside[i] != 0 ? 0 : 1;
            return r;
        }
    }
}
