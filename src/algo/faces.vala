using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class FaceSignature : Object {
        public float[] values;

        public FaceSignature(float[] values) {
            this.values = values;
        }
    }

    namespace Faces {

        private const int WORK_SIDE = 640;
        private const int CROP = 64;

        private class Integral : Object {
            public int w;
            public int h;
            public double[] sum;
            public double[] sq;
            public double[] skin;

            public Integral(float[] lum, float[] skin_plane, int w, int h) {
                this.w = w;
                this.h = h;
                sum = new double[(w + 1) * (h + 1)];
                sq = new double[(w + 1) * (h + 1)];
                skin = new double[(w + 1) * (h + 1)];
                for (int y = 0; y < h; y++) {
                    double rs = 0, rq = 0, rk = 0;
                    for (int x = 0; x < w; x++) {
                        double v = lum[y * w + x];
                        rs += v;
                        rq += v * v;
                        rk += skin_plane[y * w + x];
                        int i = (y + 1) * (w + 1) + x + 1, up = y * (w + 1) + x + 1;
                        sum[i] = sum[up] + rs;
                        sq[i] = sq[up] + rq;
                        skin[i] = skin[up] + rk;
                    }
                }
            }

            public double box(double[] t, double x0, double y0, double x1, double y1) {
                int ax = ((int) x0).clamp(0, w), ay = ((int) y0).clamp(0, h);
                int bx = ((int) x1).clamp(ax + 1, w), by = ((int) y1).clamp(ay + 1, h);
                if (bx <= ax || by <= ay) return 0;
                double s = t[by * (w + 1) + bx] - t[ay * (w + 1) + bx] - t[by * (w + 1) + ax] + t[ay * (w + 1) + ax];
                return s / ((bx - ax) * (by - ay));
            }
        }

        private double skin_likelihood(float r, float g, float b) {
            float y = 0.299f * r + 0.587f * g + 0.114f * b;
            float cb = (b - y) * 0.564f, cr = (r - y) * 0.713f;
            if (y < 0.3f || y > 0.98f) return 0;
            if (cr <= 0.005f || cb > 0.02f) return 0;
            double hue = Math.atan2(cr, -cb) * 180 / Math.PI;
            if (hue < 25 || hue > 75) return 0;
            double chroma = Math.sqrt(cr * cr + cb * cb);
            if (chroma < 0.03 || chroma > 0.19) return 0;
            return 1;
        }

        private double sigmoid(double x) {
            return 1.0 / (1.0 + Math.exp(-x));
        }

        private double window_score(Integral ii, float[] lum, int w, double x, double y, double s, bool use_skin) {
            double m = ii.box(ii.sum, x, y, x + s, y + s);
            double var = ii.box(ii.sq, x, y, x + s, y + s) - m * m;
            if (var < 0.0025) return 0;
            double sd = Math.sqrt(var);
            double eye_l = ii.box(ii.sum, x + 0.14 * s, y + 0.24 * s, x + 0.42 * s, y + 0.44 * s);
            double eye_r = ii.box(ii.sum, x + 0.58 * s, y + 0.24 * s, x + 0.86 * s, y + 0.44 * s);
            double bridge = ii.box(ii.sum, x + 0.43 * s, y + 0.24 * s, x + 0.57 * s, y + 0.46 * s);
            double cheeks = ii.box(ii.sum, x + 0.15 * s, y + 0.5 * s, x + 0.85 * s, y + 0.64 * s);
            double forehead = ii.box(ii.sum, x + 0.22 * s, y + 0.04 * s, x + 0.78 * s, y + 0.2 * s);
            double mouth = ii.box(ii.sum, x + 0.32 * s, y + 0.72 * s, x + 0.68 * s, y + 0.82 * s);
            double eyes = (eye_l + eye_r) / 2;
            double e1 = (bridge - eye_l) / sd, e2 = (bridge - eye_r) / sd, e3 = (cheeks - eyes) / sd;
            double e4 = (forehead - eyes) / sd, e6 = (cheeks - mouth) / sd;
            double balance = (eye_l - eye_r).abs() / sd;
            if (e1 < 0.25 || e2 < 0.25 || e3 < 0.35 || balance > 0.9) return 0;
            double skin_frac = 1;
            if (use_skin) {
                skin_frac = ii.box(ii.skin, x + 0.2 * s, y + 0.45 * s, x + 0.8 * s, y + 0.9 * s);
                if (skin_frac < 0.5) return 0;
                double left_out = ii.box(ii.skin, x - 0.35 * s, y + 0.2 * s, x - 0.05 * s, y + 0.8 * s);
                double right_out = ii.box(ii.skin, x + 1.05 * s, y + 0.2 * s, x + 1.35 * s, y + 0.8 * s);
                double above = ii.box(ii.skin, x + 0.1 * s, y - 0.3 * s, x + 0.9 * s, y - 0.02 * s);
                double outside = (left_out + right_out + above) / 3;
                if (skin_frac - outside < 0.25) return 0;
            }
            int grid = 12;
            double sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0;
            int n = 0;
            for (int j = 0; j < grid; j++) {
                for (int i = 0; i < grid / 2; i++) {
                    double va = ii.box(ii.sum, x + s * i / grid, y + s * j / grid, x + s * (i + 1) / grid, y + s * (j + 1) / grid);
                    double vb = ii.box(ii.sum, x + s * (grid - 1 - i) / grid, y + s * j / grid, x + s * (grid - i) / grid, y + s * (j + 1) / grid);
                    sa += va; sb += vb; saa += va * va; sbb += vb * vb; sab += va * vb;
                    n++;
                }
            }
            double cov = sab / n - sa / n * sb / n;
            double den = Math.sqrt(double.max(1e-12, (saa / n - Math.pow(sa / n, 2)) * (sbb / n - Math.pow(sb / n, 2))));
            double sym = cov / den;
            if (sym < 0.3) return 0;
            double score = 0.2 * sigmoid((e1 + e2 - 1.0) * 2) + 0.2 * sigmoid((e3 - 0.8) * 2) + 0.1 * sigmoid(e4 * 2) + 0.15 * sigmoid(e6 * 2) + 0.2 * sym.clamp(0, 1) + 0.15 * skin_frac;
            return score;
        }

        public FaceBox[] detect(FloatImage img) {
            double up = 1.0;
            int side = int.min(img.width, img.height);
            var work = img;
            if (side < 360) {
                up = 360.0 / side;
                work = SuperResolution.lanczos_resize(img, (int) (img.width * up), (int) (img.height * up));
            } else if (int.max(img.width, img.height) > WORK_SIDE) {
                work = img.scaled_to_fit(WORK_SIDE);
            }
            var small = AlgoUtil.encoded_copy(work);
            int w = small.width, h = small.height;
            int n = w * h;
            var lum = new float[n];
            var skin = new float[n];
            double sat_sum = 0;
            for (int i = 0; i < n; i++) {
                float r = small.data[i * 4], g = small.data[i * 4 + 1], b = small.data[i * 4 + 2];
                lum[i] = 0.299f * r + 0.587f * g + 0.114f * b;
                skin[i] = (float) skin_likelihood(r, g, b);
                sat_sum += float.max(r, float.max(g, b)) - float.min(r, float.min(g, b));
            }
            bool use_skin = sat_sum / n > 0.04;
            var ii = new Integral(lum, skin, w, h);
            var cands = new Gee.ArrayList<FaceBox?>();
            var lock_m = new Mutex();
            var sizes = new Gee.ArrayList<double?>();
            for (double s = 24; s <= int.min(w, h) * 0.9; s *= 1.2) sizes.add(s);
            Parallel.range(sizes.size, (start, end) => {
                for (int si = start; si < end; si++) {
                    double s = sizes[si];
                    double stride = double.max(1.0, s / 10);
                    for (double y = 0; y + s <= h; y += stride) {
                        for (double x = 0; x + s <= w; x += stride) {
                            double sc = window_score(ii, lum, w, x, y, s, use_skin);
                            if (sc < 0.68) continue;
                            FaceBox fb = FaceBox();
                            fb.x = x;
                            fb.y = y;
                            fb.width = s;
                            fb.height = s;
                            fb.score = sc;
                            lock_m.lock();
                            cands.add(fb);
                            lock_m.unlock();
                        }
                    }
                }
            }, 1);
            cands.sort((a, b) => a.score > b.score ? -1 : (a.score < b.score ? 1 : 0));
            FaceBox[] result = {};
            var used = new bool[cands.size];
            for (int i = 0; i < cands.size; i++) {
                if (used[i]) continue;
                var best = cands[i];
                int support = 0;
                double ax = 0, ay = 0, aw = 0, wsum = 0;
                for (int j = i; j < cands.size; j++) {
                    if (used[j]) continue;
                    if (iou(best, cands[j]) < 0.2) continue;
                    used[j] = true;
                    support++;
                    double wt = cands[j].score;
                    ax += cands[j].x * wt;
                    ay += cands[j].y * wt;
                    aw += cands[j].width * wt;
                    wsum += wt;
                }
                if (support < 4) continue;
                FaceBox fb = FaceBox();
                double bw = aw / wsum;
                fb.x = (ax / wsum) / w;
                fb.y = (ay / wsum) / h;
                fb.width = bw / w;
                fb.height = bw * 1.15 / h;
                fb.score = (best.score * (1 - Math.exp(-support / 4.0))).clamp(0, 1);
                result += fb;
            }
            FaceBox[] kept = {};
            for (int i = 0; i < result.length; i++) {
                double cx = result[i].x + result[i].width / 2, cy = result[i].y + result[i].height / 2;
                bool inside = false;
                for (int j = 0; j < result.length; j++) {
                    if (j == i || result[j].width <= result[i].width) continue;
                    if (cx > result[j].x && cx < result[j].x + result[j].width && cy > result[j].y && cy < result[j].y + result[j].height) inside = true;
                }
                if (!inside) kept += result[i];
            }
            return kept;
        }

        private double iou(FaceBox a, FaceBox b) {
            double ix = double.max(0, double.min(a.x + a.width, b.x + b.width) - double.max(a.x, b.x));
            double iy = double.max(0, double.min(a.y + a.height, b.y + b.height) - double.max(a.y, b.y));
            double inter = ix * iy;
            double iou_v = inter / (a.width * a.height + b.width * b.height - inter);
            double contain = inter / double.min(a.width * a.height, b.width * b.height);
            return double.max(iou_v, contain > 0.45 ? 0.5 : 0);
        }

        private int uniform_index(int code) {
            int transitions = 0;
            for (int i = 0; i < 8; i++) {
                int a = (code >> i) & 1, b = (code >> ((i + 1) % 8)) & 1;
                if (a != b) transitions++;
            }
            if (transitions > 2) return 58;
            int idx = 0;
            for (int c = 0; c < code; c++) {
                int t = 0;
                for (int i = 0; i < 8; i++) {
                    int a = (c >> i) & 1, b = (c >> ((i + 1) % 8)) & 1;
                    if (a != b) t++;
                }
                if (t <= 2) idx++;
            }
            return idx;
        }

        public float[] descriptor(FloatImage img, FaceBox face) {
            int iw = img.width, ih = img.height;
            double fx = face.x * iw, fy = face.y * ih, fw = face.width * iw, fh = face.height * ih;
            var crop = new float[CROP * CROP];
            for (int y = 0; y < CROP; y++) {
                for (int x = 0; x < CROP; x++) {
                    float r, g, b, a;
                    img.sample(fx + (x + 0.5) * fw / CROP, fy + (y + 0.5) * fh / CROP, out r, out g, out b, out a);
                    crop[y * CROP + x] = Transfer.linear_to_srgb(0.2627f * r + 0.678f * g + 0.0593f * b);
                }
            }
            double mean = 0, sd = 0;
            foreach (float v in crop) mean += v;
            mean /= crop.length;
            foreach (float v in crop) sd += (v - mean) * (v - mean);
            sd = Math.sqrt(sd / crop.length) + 1e-4;
            for (int i = 0; i < crop.length; i++) crop[i] = (float) ((crop[i] - mean) / sd);
            var lut = new int[256];
            for (int c = 0; c < 256; c++) lut[c] = uniform_index(c);
            int grid = 4, cell = CROP / grid;
            var desc = new float[grid * grid * 59];
            int[] ox = { -1, 0, 1, 1, 1, 0, -1, -1 };
            int[] oy = { -1, -1, -1, 0, 1, 1, 1, 0 };
            for (int y = 1; y < CROP - 1; y++) {
                for (int x = 1; x < CROP - 1; x++) {
                    float c = crop[y * CROP + x];
                    int code = 0;
                    for (int k = 0; k < 8; k++) if (crop[(y + oy[k]) * CROP + x + ox[k]] >= c) code |= 1 << k;
                    int gx = int.min(x / cell, grid - 1), gy = int.min(y / cell, grid - 1);
                    desc[(gy * grid + gx) * 59 + lut[code]] += 1;
                }
            }
            double norm = 0;
            for (int i = 0; i < desc.length; i++) {
                desc[i] = Math.sqrtf(desc[i]);
                norm += desc[i] * desc[i];
            }
            norm = Math.sqrt(norm) + 1e-9;
            for (int i = 0; i < desc.length; i++) desc[i] = (float) (desc[i] / norm);
            return desc;
        }

        public double distance(float[] a, float[] b) {
            if (a.length != b.length || a.length == 0) return 2.0;
            double s = 0;
            for (int i = 0; i < a.length; i++) {
                double d = a[i] - b[i];
                s += d * d;
            }
            return Math.sqrt(s);
        }

        public int[] cluster(FaceSignature[] items, double threshold) {
            int n = items.length;
            var label = new int[n];
            for (int i = 0; i < n; i++) label[i] = i;
            var dist = new double[n * n];
            for (int i = 0; i < n; i++)
                for (int j = i + 1; j < n; j++) {
                    double d = distance(items[i].values, items[j].values);
                    dist[i * n + j] = d;
                    dist[j * n + i] = d;
                }
            var size = new int[n];
            var alive = new bool[n];
            for (int i = 0; i < n; i++) {
                size[i] = 1;
                alive[i] = true;
            }
            while (true) {
                double best = double.MAX;
                int ba = -1, bb = -1;
                for (int a = 0; a < n; a++) {
                    if (!alive[a]) continue;
                    for (int b = a + 1; b < n; b++) {
                        if (!alive[b]) continue;
                        if (dist[a * n + b] < best) {
                            best = dist[a * n + b];
                            ba = a;
                            bb = b;
                        }
                    }
                }
                if (ba < 0 || best > threshold) break;
                for (int k = 0; k < n; k++) {
                    if (!alive[k] || k == ba || k == bb) continue;
                    double d = (size[ba] * dist[ba * n + k] + size[bb] * dist[bb * n + k]) / (size[ba] + size[bb]);
                    dist[ba * n + k] = d;
                    dist[k * n + ba] = d;
                }
                size[ba] += size[bb];
                alive[bb] = false;
                for (int i = 0; i < n; i++) if (label[i] == bb) label[i] = ba;
            }
            var remap = new Gee.HashMap<int, int>();
            var result = new int[n];
            for (int i = 0; i < n; i++) {
                if (!remap.has_key(label[i])) remap[label[i]] = remap.size;
                result[i] = remap[label[i]];
            }
            return result;
        }
    }
}
