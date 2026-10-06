using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace Detail {

        public float[] log_luminance(FloatImage img, float gain) {
            var plane = new float[img.pixel_count()];
            int w = img.width;
            Parallel.range(img.height, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    float y = WorkingSpace.luminance(img.data[i * 4], img.data[i * 4 + 1], img.data[i * 4 + 2]) * gain;
                    plane[i] = (float) Math.log2(float.max(y, 1e-5f));
                }
            });
            return plane;
        }

        public void local_tone(FloatImage img, float highlights, float shadows, float texture, float clarity, float exposure, double res) {
            int w = img.width, h = img.height;
            var l = log_luminance(img, exposure);
            int min_side = int.min(w, h);
            float[]? base_ts = null;
            if (highlights.abs() > 1e-6f || shadows.abs() > 1e-6f) {
                int radius = int.max(2, (int) (min_side * 0.03));
                int sw = int.max(8, w / 4), sh = int.max(8, h / 4);
                var small = Filters.resize_plane(l, w, h, sw, sh);
                var smooth = Filters.guided_plane(small, small, sw, sh, int.max(1, radius / 4), 0.4f);
                base_ts = Filters.resize_plane(smooth, sw, sh, w, h);
            }
            float[]? clarity_base = null;
            if (clarity.abs() > 1e-6f) {
                int radius = int.max(2, (int) (min_side * 0.015));
                clarity_base = Filters.guided_plane(l, l, w, h, radius, 0.25f);
            }
            float[]? tex_fine = null;
            float[]? tex_coarse = null;
            if (texture.abs() > 1e-6f) {
                double s1 = double.max(0.6, 1.2 * res * 2.5);
                tex_fine = Filters.gaussian_plane(l, w, h, s1 * 0.5);
                tex_coarse = Filters.gaussian_plane(l, w, h, s1 * 3.0);
            }
            Parallel.range(h, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    float ll = l[i];
                    float delta = 0;
                    if (base_ts != null) {
                        float e = Transfer.linear_to_srgb((float) Math.pow(2.0, base_ts[i]).clamp(0, 4));
                        float hm = Tone.smooth(0.45f, 1.0f, e);
                        float sm = 1 - Tone.smooth(0.0f, 0.55f, e);
                        delta += highlights * 1.4f * hm + shadows * 1.6f * sm;
                    }
                    if (clarity_base != null) {
                        float e = Transfer.linear_to_srgb((float) Math.pow(2.0, ll).clamp(0, 1));
                        float mid = 1 - (2 * e - 1).abs();
                        delta += clarity * 0.9f * (ll - clarity_base[i]) * (0.35f + 0.65f * mid);
                    }
                    if (tex_fine != null) delta += texture * 1.2f * (tex_fine[i] - tex_coarse[i]);
                    if (delta == 0) continue;
                    float gain = (float) Math.pow(2.0, delta.clamp(-4, 4));
                    img.data[i * 4] *= gain;
                    img.data[i * 4 + 1] *= gain;
                    img.data[i * 4 + 2] *= gain;
                }
            });
        }

        private float[] min_filter(float[] plane, int w, int h, int r) {
            var tmp = new float[plane.length];
            var out_plane = new float[plane.length];
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        float m = float.MAX;
                        for (int k = int.max(0, x - r); k <= int.min(w - 1, x + r); k++) m = float.min(m, plane[(size_t) y * w + k]);
                        tmp[(size_t) y * w + x] = m;
                    }
                }
            });
            Parallel.range(w, (start, end) => {
                for (int x = start; x < end; x++) {
                    for (int y = 0; y < h; y++) {
                        float m = float.MAX;
                        for (int k = int.max(0, y - r); k <= int.min(h - 1, y + r); k++) m = float.min(m, tmp[(size_t) k * w + x]);
                        out_plane[(size_t) y * w + x] = m;
                    }
                }
            });
            return out_plane;
        }

        public void dehaze(FloatImage img, float amount, double res) {
            int w = img.width, h = img.height;
            var small = img.scaled_to_fit(480);
            int sw = small.width, sh = small.height;
            var dark = new float[(size_t) sw * sh];
            for (size_t i = 0; i < dark.length; i++)
                dark[i] = float.min(small.data[i * 4], float.min(small.data[i * 4 + 1], small.data[i * 4 + 2]));
            int r = int.max(2, int.min(sw, sh) / 60);
            var dmin = min_filter(dark, sw, sh, r);
            var sorted = dmin.copy();
            sort_floats(sorted);
            float threshold = sorted[(int) (sorted.length * 0.999).clamp(0, sorted.length - 1)];
            double ar = 0, ag = 0, ab = 0;
            int n = 0;
            for (size_t i = 0; i < dmin.length; i++) {
                if (dmin[i] < threshold) continue;
                ar += small.data[i * 4];
                ag += small.data[i * 4 + 1];
                ab += small.data[i * 4 + 2];
                n++;
            }
            float air_r = n > 0 ? (float) (ar / n) : 1, air_g = n > 0 ? (float) (ag / n) : 1, air_b = n > 0 ? (float) (ab / n) : 1;
            air_r = float.max(air_r, 0.05f);
            air_g = float.max(air_g, 0.05f);
            air_b = float.max(air_b, 0.05f);
            if (amount < 0) {
                float k = -amount * 0.6f;
                Parallel.range(h, (start, end) => {
                    for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                        img.data[i * 4] = img.data[i * 4] * (1 - k) + air_r * k;
                        img.data[i * 4 + 1] = img.data[i * 4 + 1] * (1 - k) + air_g * k;
                        img.data[i * 4 + 2] = img.data[i * 4 + 2] * (1 - k) + air_b * k;
                    }
                });
                return;
            }
            var norm = new float[(size_t) sw * sh];
            for (size_t i = 0; i < norm.length; i++)
                norm[i] = float.min(small.data[i * 4] / air_r, float.min(small.data[i * 4 + 1] / air_g, small.data[i * 4 + 2] / air_b));
            var nd = min_filter(norm, sw, sh, r);
            float omega = 0.95f * amount;
            var trans = new float[nd.length];
            for (size_t i = 0; i < nd.length; i++) trans[i] = 1 - omega * nd[i];
            var guide = small.luminance(0.2627f, 0.6780f, 0.0593f);
            var refined = Filters.guided_plane(guide, trans, sw, sh, r * 2, 0.001f);
            var full_t = Filters.resize_plane(refined, sw, sh, w, h);
            Parallel.range(h, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    float t = float.max(full_t[i], 0.12f);
                    img.data[i * 4] = float.max(0, (img.data[i * 4] - air_r) / t + air_r);
                    img.data[i * 4 + 1] = float.max(0, (img.data[i * 4 + 1] - air_g) / t + air_g);
                    img.data[i * 4 + 2] = float.max(0, (img.data[i * 4 + 2] - air_b) / t + air_b);
                }
            });
        }

        private void sort_floats(float[] a) {
            qsort_floats(a, 0, a.length - 1);
        }

        private void qsort_floats(float[] a, int lo, int hi) {
            while (lo < hi) {
                float pivot = a[(lo + hi) / 2];
                int i = lo, j = hi;
                while (i <= j) {
                    while (a[i] < pivot) i++;
                    while (a[j] > pivot) j--;
                    if (i <= j) {
                        float t = a[i];
                        a[i] = a[j];
                        a[j] = t;
                        i++;
                        j--;
                    }
                }
                if (j - lo < hi - i) {
                    qsort_floats(a, lo, j);
                    lo = i;
                } else {
                    qsort_floats(a, i, hi);
                    hi = j;
                }
            }
        }

        public void color_noise(FloatImage img, double amount, double detail, double smoothness, double res) {
            int w = img.width, h = img.height;
            size_t n = img.pixel_count();
            var y = new float[n];
            var cb = new float[n];
            var cr = new float[n];
            for (size_t i = 0; i < n; i++) {
                float r = Transfer.linear_to_srgb(img.data[i * 4]), g = Transfer.linear_to_srgb(img.data[i * 4 + 1]), b = Transfer.linear_to_srgb(img.data[i * 4 + 2]);
                y[i] = 0.2627f * r + 0.6780f * g + 0.0593f * b;
                cb[i] = b - y[i];
                cr[i] = r - y[i];
            }
            int radius = int.max(1, (int) Math.round((2 + amount * 10 + smoothness * 6) * double.max(res, 0.25)));
            float eps = (float) (0.0005 + (1 - detail) * 0.01);
            var fcb = Filters.guided_plane(y, cb, w, h, radius, eps);
            var fcr = Filters.guided_plane(y, cr, w, h, radius, eps);
            float k = (float) amount.clamp(0, 1);
            Parallel.range(h, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    float ncb = cb[i] + (fcb[i] - cb[i]) * k;
                    float ncr = cr[i] + (fcr[i] - cr[i]) * k;
                    float r = ncr + y[i];
                    float b = ncb + y[i];
                    float g = (y[i] - 0.2627f * r - 0.0593f * b) / 0.6780f;
                    img.data[i * 4] = Transfer.srgb_to_linear(r);
                    img.data[i * 4 + 1] = Transfer.srgb_to_linear(g);
                    img.data[i * 4 + 2] = Transfer.srgb_to_linear(b);
                }
            });
        }

        public void sharpen(FloatImage img, double amount, double radius, double detail, double masking, double res, float[]? mask = null) {
            if (amount <= 1e-6 && mask == null) return;
            int w = img.width, h = img.height;
            size_t n = img.pixel_count();
            var y = new float[n];
            for (size_t i = 0; i < n; i++)
                y[i] = Transfer.linear_to_srgb(WorkingSpace.luminance(img.data[i * 4], img.data[i * 4 + 1], img.data[i * 4 + 2]).clamp(0, 4));
            double sigma = double.max(0.35, radius * double.max(res, 0.2));
            var blur = Filters.gaussian_plane(y, w, h, sigma);
            float[]? edge = null;
            if (masking > 1e-6) {
                var soft = Filters.gaussian_plane(y, w, h, double.max(1.0, sigma * 1.5));
                edge = new float[n];
                Parallel.range(h, (start, end) => {
                    for (int yy = start; yy < end; yy++) {
                        for (int x = 0; x < w; x++) {
                            size_t i = (size_t) yy * w + x;
                            float gx = soft[(size_t) yy * w + int.min(x + 1, w - 1)] - soft[(size_t) yy * w + int.max(x - 1, 0)];
                            float gy = soft[(size_t) int.min(yy + 1, h - 1) * w + x] - soft[(size_t) int.max(yy - 1, 0) * w + x];
                            float g = Math.sqrtf(gx * gx + gy * gy) * 8;
                            edge[i] = Tone.smooth((float) masking * 0.6f, (float) masking * 0.6f + 0.15f, g);
                        }
                    }
                });
            }
            float threshold = (float) (0.01 + (1 - detail) * 0.12);
            float k = (float) (amount * 1.6);
            Parallel.range(h, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    float d = y[i] - blur[i];
                    float limited = d.abs() < threshold ? d : (d > 0 ? threshold : -threshold) + (d - (d > 0 ? threshold : -threshold)) * (float) detail;
                    float m = edge != null ? edge[i] : 1.0f;
                    float kk = mask != null ? (float) (k + mask[i] * 1.6) : k;
                    if (mask != null && mask[i] < 0) kk = k + mask[i];
                    float ny = y[i] + kk * limited * m;
                    float lin_old = Transfer.srgb_to_linear(y[i]);
                    float lin_new = Transfer.srgb_to_linear(ny);
                    float gain = lin_old > 1e-5f ? float.max(0, lin_new / lin_old) : 1.0f;
                    img.data[i * 4] *= gain;
                    img.data[i * 4 + 1] *= gain;
                    img.data[i * 4 + 2] *= gain;
                }
            });
        }

        public void sharpen_final(FloatImage img, EditParams p, double res) {
            var eff = EditPipeline.effective_values(p);
            double amount = eff[Adjustment.SHARPNESS];
            if (amount <= 1e-6) return;
            sharpen(img, amount, p.develop.get("detail.sharpen.radius"), p.develop.get("detail.sharpen.detail"), p.develop.get("detail.sharpen.masking"), res);
        }
    }

    namespace Effects {

        private float hash_noise(int x, int y, uint seed) {
            uint h = (uint) x * 374761393u + (uint) y * 668265263u + seed * 2246822519u;
            h = (h ^ (h >> 13)) * 1274126177u;
            h = h ^ (h >> 16);
            return (h & 0xFFFFFF) / 16777215.0f;
        }

        private float value_noise(double x, double y, uint seed) {
            int x0 = (int) Math.floor(x), y0 = (int) Math.floor(y);
            float tx = (float) (x - x0), ty = (float) (y - y0);
            tx = tx * tx * (3 - 2 * tx);
            ty = ty * ty * (3 - 2 * ty);
            float a = hash_noise(x0, y0, seed), b = hash_noise(x0 + 1, y0, seed);
            float c = hash_noise(x0, y0 + 1, seed), d = hash_noise(x0 + 1, y0 + 1, seed);
            return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
        }

        public void apply(FloatImage img, EditParams p, double res) {
            var eff = EditPipeline.effective_values(p);
            double amount = eff[Adjustment.VIGNETTE];
            var d = p.develop;
            double grain = d.get("effects.grain.amount");
            if (amount.abs() < 1e-6 && grain < 1e-6) return;
            int w = img.width, h = img.height;
            double midpoint = d.get("effects.vignette.midpoint");
            double roundness = d.get("effects.vignette.roundness");
            double feather = d.get("effects.vignette.feather");
            double protect = d.get("effects.vignette.highlights");
            double inner = midpoint * 0.6;
            double outer = inner + 0.05 + feather * 1.3;
            double aspect = (double) w / h;
            double stretch = Math.pow(aspect, -roundness);
            double gsize = double.max(0.5, (0.6 + d.get("effects.grain.size") * 3.0) * double.max(res, 0.15));
            double rough = d.get("effects.grain.roughness");
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    double ny = (y + 0.5) / h - 0.5;
                    for (int x = 0; x < w; x++) {
                        size_t i = img.offset(x, y);
                        float er = Transfer.linear_to_srgb(img.data[i]);
                        float eg = Transfer.linear_to_srgb(img.data[i + 1]);
                        float eb = Transfer.linear_to_srgb(img.data[i + 2]);
                        if (amount.abs() > 1e-6) {
                            double nx = ((x + 0.5) / w - 0.5) * (roundness >= 0 ? 1.0 : stretch);
                            double yy = ny * (roundness >= 0 ? 1.0 / stretch : 1.0);
                            double r = Math.sqrt(nx * nx + yy * yy) / Math.sqrt(0.5);
                            float f = Tone.smooth((float) inner, (float) outer, (float) r);
                            if (protect > 1e-6) {
                                float l = 0.2627f * er + 0.6780f * eg + 0.0593f * eb;
                                f *= 1 - (float) protect * Tone.smooth(0.6f, 1.0f, l);
                            }
                            if (f > 0) {
                                if (amount > 0) {
                                    float k = 1 - (float) amount * 0.7f * f;
                                    er *= k;
                                    eg *= k;
                                    eb *= k;
                                } else {
                                    float k = (float) (-amount) * 0.5f * f;
                                    er += k * (1 - er);
                                    eg += k * (1 - eg);
                                    eb += k * (1 - eb);
                                }
                            }
                        }
                        if (grain > 1e-6) {
                            double gx = x / gsize, gy = y / gsize;
                            float n1 = value_noise(gx, gy, 17u) - 0.5f;
                            float n2 = value_noise(gx * 2.3, gy * 2.3, 71u) - 0.5f;
                            float nval = n1 * (float) (1 - rough * 0.5) + n2 * (float) rough;
                            float l = (0.2627f * er + 0.6780f * eg + 0.0593f * eb).clamp(0, 1);
                            float k = (float) grain * 0.22f * nval * (0.3f + 2.8f * l * (1 - l));
                            er += k;
                            eg += k;
                            eb += k;
                        }
                        img.data[i] = Transfer.srgb_to_linear(er);
                        img.data[i + 1] = Transfer.srgb_to_linear(eg);
                        img.data[i + 2] = Transfer.srgb_to_linear(eb);
                    }
                }
            });
        }
    }

    public class Lut3D : Object {
        public int size = 0;
        public float[] table = {};
        public string title = "";

        private static Gee.HashMap<string, Lut3D>? cache = null;
        private static Mutex cache_lock;

        public static Lut3D? cached(string path) {
            cache_lock.lock();
            if (cache == null) cache = new Gee.HashMap<string, Lut3D>();
            Lut3D? lut = cache[path];
            if (lut == null) {
                try {
                    lut = Lut3D.load(path);
                    cache[path] = lut;
                } catch (Error e) {
                    warning("Photos: cannot load LUT %s: %s", path, e.message);
                }
            }
            cache_lock.unlock();
            return lut;
        }

        public static Lut3D load(string path) throws Error {
            string text;
            FileUtils.get_contents(path, out text);
            return parse(text);
        }

        public static Lut3D parse(string text) throws Error {
            var lut = new Lut3D();
            float[] values = {};
            double[] dmin = { 0, 0, 0 }, dmax = { 1, 1, 1 };
            foreach (var raw in text.split("\n")) {
                string line = raw.strip();
                if (line == "" || line.has_prefix("#")) continue;
                if (line.has_prefix("TITLE")) {
                    lut.title = line.substring(5).strip().replace("\"", "");
                    continue;
                }
                if (line.has_prefix("LUT_3D_SIZE")) {
                    lut.size = int.parse(line.substring(11).strip());
                    continue;
                }
                if (line.has_prefix("LUT_1D_SIZE")) throw new IOError.NOT_SUPPORTED(_("One-dimensional LUTs are not supported"));
                if (line.has_prefix("DOMAIN_MIN") || line.has_prefix("DOMAIN_MAX")) {
                    var parts = line.split_set(" \t");
                    double[] v = {};
                    foreach (var part in parts) if (part != "" && !part.has_prefix("DOMAIN")) v += double.parse(part);
                    if (v.length == 3) {
                        if (line.has_prefix("DOMAIN_MIN")) dmin = v;
                        else dmax = v;
                    }
                    continue;
                }
                if (!(line[0].isdigit() || line[0] == '-' || line[0] == '.')) continue;
                var parts = line.split_set(" \t");
                int got = 0;
                foreach (var part in parts) {
                    if (part == "") continue;
                    values += (float) double.parse(part);
                    got++;
                }
                if (got != 3) throw new IOError.INVALID_DATA(_("Malformed LUT line"));
            }
            if (lut.size < 2 || values.length != lut.size * lut.size * lut.size * 3)
                throw new IOError.INVALID_DATA(_("The LUT size does not match its data"));
            for (int i = 0; i < values.length; i++) {
                int c = i % 3;
                values[i] = (float) ((values[i] - dmin[c]) / (dmax[c] - dmin[c]));
            }
            lut.table = values;
            return lut;
        }

        private float channel(int c, int r0, int r1, int g0, int g1, int b0, int b1, float tr, float tg, float tb) {
            int n = size;
            float c000 = table[((b0 * n + g0) * n + r0) * 3 + c], c100 = table[((b0 * n + g0) * n + r1) * 3 + c];
            float c010 = table[((b0 * n + g1) * n + r0) * 3 + c], c110 = table[((b0 * n + g1) * n + r1) * 3 + c];
            float c001 = table[((b1 * n + g0) * n + r0) * 3 + c], c101 = table[((b1 * n + g0) * n + r1) * 3 + c];
            float c011 = table[((b1 * n + g1) * n + r0) * 3 + c], c111 = table[((b1 * n + g1) * n + r1) * 3 + c];
            float c00 = c000 * (1 - tr) + c100 * tr, c10 = c010 * (1 - tr) + c110 * tr;
            float c01 = c001 * (1 - tr) + c101 * tr, c11 = c011 * (1 - tr) + c111 * tr;
            float c0 = c00 * (1 - tg) + c10 * tg, c1 = c01 * (1 - tg) + c11 * tg;
            return c0 * (1 - tb) + c1 * tb;
        }

        public void apply(float r, float g, float b, out float or, out float og, out float ob) {
            int n = size;
            float fr = r * (n - 1), fg = g * (n - 1), fb = b * (n - 1);
            int r0 = (int) fr, g0 = (int) fg, b0 = (int) fb;
            int r1 = int.min(r0 + 1, n - 1), g1 = int.min(g0 + 1, n - 1), b1 = int.min(b0 + 1, n - 1);
            float tr = fr - r0, tg = fg - g0, tb = fb - b0;
            or = channel(0, r0, r1, g0, g1, b0, b1, tr, tg, tb);
            og = channel(1, r0, r1, g0, g1, b0, b1, tr, tg, tb);
            ob = channel(2, r0, r1, g0, g1, b0, b1, tr, tg, tb);
        }
    }
}
