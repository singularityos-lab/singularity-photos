using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class CfaPattern : Object {
        public int width = 2;
        public int height = 2;
        public int[] colors = { 0, 1, 1, 2 };

        public CfaPattern.bayer(string name) {
            set_name(name);
        }

        public void set_name(string name) {
            width = 2;
            height = 2;
            var c = new int[4];
            string n = name.up();
            if (n.length != 4) n = "RGGB";
            for (int i = 0; i < 4; i++) c[i] = n[i] == 'R' ? 0 : (n[i] == 'G' ? 1 : 2);
            colors = c;
        }

        public string name() {
            var sb = new StringBuilder();
            foreach (int c in colors) sb.append_c(c == 0 ? 'R' : (c == 1 ? 'G' : 'B'));
            return sb.str;
        }

        public bool is_bayer() {
            if (width != 2 || height != 2) return false;
            int g = 0, r = 0, b = 0;
            foreach (int c in colors) {
                if (c == 0) r++;
                else if (c == 1) g++;
                else b++;
            }
            return r == 1 && g == 2 && b == 1 && colors[0] != colors[3] && colors[1] == colors[2];
        }

        public int at(int x, int y) {
            return colors[(y % height) * width + (x % width)];
        }

        public CfaPattern cropped(int dx, int dy) {
            var p = new CfaPattern();
            p.width = width;
            p.height = height;
            var c = new int[width * height];
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++)
                    c[y * width + x] = at(x + dx, y + dy);
            p.colors = c;
            return p;
        }
    }

    namespace Demosaic {

        public FloatImage run(float[] cfa, int w, int h, CfaPattern pattern, string method = "ppg") {
            if (method == "ppg" && pattern.is_bayer() && w >= 8 && h >= 8) return ppg(cfa, w, h, pattern);
            return bilinear(cfa, w, h, pattern);
        }

        public FloatImage bilinear(float[] cfa, int w, int h, CfaPattern pattern) {
            var img = new FloatImage(w, h);
            int reach = pattern.width > 2 ? 2 : 1;
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        size_t o = img.offset(x, y);
                        int own = pattern.at(x, y);
                        float s0 = 0, s1 = 0, s2 = 0, w0 = 0, w1 = 0, w2 = 0;
                        for (int r = 1; r <= reach; r++) {
                            for (int dy = -r; dy <= r; dy++) {
                                int yy = y + dy;
                                if (yy < 0 || yy >= h) continue;
                                for (int dx = -r; dx <= r; dx++) {
                                    if (dx.abs() != r && dy.abs() != r) continue;
                                    int xx = x + dx;
                                    if (xx < 0 || xx >= w) continue;
                                    int c = pattern.at(xx, yy);
                                    float wt = (dx == 0 || dy == 0) ? 1.0f : 0.7f;
                                    wt /= r;
                                    float v = cfa[(size_t) yy * w + xx] * wt;
                                    if (c == 0) { s0 += v; w0 += wt; }
                                    else if (c == 1) { s1 += v; w1 += wt; }
                                    else { s2 += v; w2 += wt; }
                                }
                            }
                            if (w0 > 0 && w1 > 0 && w2 > 0) break;
                        }
                        img.data[o] = w0 > 0 ? s0 / w0 : 0;
                        img.data[o + 1] = w1 > 0 ? s1 / w1 : 0;
                        img.data[o + 2] = w2 > 0 ? s2 / w2 : 0;
                        img.data[o + own] = cfa[(size_t) y * w + x];
                        img.data[o + 3] = 1;
                    }
                }
            });
            return img;
        }

        private FloatImage ppg(float[] cfa, int w, int h, CfaPattern pattern) {
            var img = bilinear(cfa, w, h, pattern);
            unowned float[] d = img.data;
            Parallel.range(h - 6, (start, end) => {
                for (int y = start + 3; y < end + 3; y++) {
                    for (int x = 3; x < w - 3; x++) {
                        int own = pattern.at(x, y);
                        if (own == 1) continue;
                        size_t i = (size_t) y * w + x;
                        float c = cfa[i];
                        float gn = cfa[i - w], gs = cfa[i + w], ge = cfa[i + 1], gw = cfa[i - 1];
                        float dn = (c - cfa[i - 2 * w]).abs() * 2 + (gn - gs).abs();
                        float ds = (c - cfa[i + 2 * w]).abs() * 2 + (gn - gs).abs();
                        float de = (c - cfa[i + 2]).abs() * 2 + (gw - ge).abs();
                        float dw = (c - cfa[i - 2]).abs() * 2 + (gw - ge).abs();
                        float g;
                        float m = float.min(float.min(dn, ds), float.min(de, dw));
                        if (m == dn) g = (gn * 3 + gs + c - cfa[i - 2 * w]) / 4;
                        else if (m == de) g = (ge * 3 + gw + c - cfa[i + 2]) / 4;
                        else if (m == dw) g = (gw * 3 + ge + c - cfa[i - 2]) / 4;
                        else g = (gs * 3 + gn + c - cfa[i + 2 * w]) / 4;
                        float lo = float.min(float.min(gn, gs), float.min(ge, gw));
                        float hi = float.max(float.max(gn, gs), float.max(ge, gw));
                        d[i * 4 + 1] = g.clamp(lo, hi);
                    }
                }
            });
            Parallel.range(h - 6, (start, end) => {
                for (int y = start + 3; y < end + 3; y++) {
                    for (int x = 3; x < w - 3; x++) {
                        if (pattern.at(x, y) != 1) continue;
                        size_t i = (size_t) y * w + x;
                        float g = d[i * 4 + 1];
                        int hc = pattern.at(x + 1, y);
                        int vc = pattern.at(x, y + 1);
                        float hv = g + ((d[(i - 1) * 4 + hc] - d[(i - 1) * 4 + 1]) + (d[(i + 1) * 4 + hc] - d[(i + 1) * 4 + 1])) / 2;
                        float vv = g + ((d[(i - w) * 4 + vc] - d[(i - w) * 4 + 1]) + (d[(i + w) * 4 + vc] - d[(i + w) * 4 + 1])) / 2;
                        d[i * 4 + hc] = float.max(0, hv);
                        d[i * 4 + vc] = float.max(0, vv);
                    }
                }
            });
            Parallel.range(h - 6, (start, end) => {
                for (int y = start + 3; y < end + 3; y++) {
                    for (int x = 3; x < w - 3; x++) {
                        int own = pattern.at(x, y);
                        if (own == 1) continue;
                        int other = 2 - own;
                        size_t i = (size_t) y * w + x;
                        size_t ne = i - w + 1, sw = i + w - 1, nw = i - w - 1, se = i + w + 1;
                        float g = d[i * 4 + 1];
                        float dne = (d[ne * 4 + other] - d[sw * 4 + other]).abs() + (2 * g - d[ne * 4 + 1] - d[sw * 4 + 1]).abs();
                        float dnw = (d[nw * 4 + other] - d[se * 4 + other]).abs() + (2 * g - d[nw * 4 + 1] - d[se * 4 + 1]).abs();
                        float v;
                        if (dne < dnw) v = g + ((d[ne * 4 + other] - d[ne * 4 + 1]) + (d[sw * 4 + other] - d[sw * 4 + 1])) / 2;
                        else if (dnw < dne) v = g + ((d[nw * 4 + other] - d[nw * 4 + 1]) + (d[se * 4 + other] - d[se * 4 + 1])) / 2;
                        else v = g + ((d[ne * 4 + other] - d[ne * 4 + 1]) + (d[sw * 4 + other] - d[sw * 4 + 1]) + (d[nw * 4 + other] - d[nw * 4 + 1]) + (d[se * 4 + other] - d[se * 4 + 1])) / 4;
                        d[i * 4 + other] = float.max(0, v);
                    }
                }
            });
            return img;
        }
    }
}
