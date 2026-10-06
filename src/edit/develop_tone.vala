using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class ToneSettings : Object {
        public float exposure = 1.0f;
        public float wb_r = 1.0f;
        public float wb_g = 1.0f;
        public float wb_b = 1.0f;
        public float highlights = 0;
        public float shadows = 0;
        public float whites = 0;
        public float blacks = 0;
        public float contrast = 0;
        public float brightness = 0;
        public float black_point = 0;
        public float white_point = 1;
        public float saturation = 0;
        public float vibrance = 0;
        public float texture = 0;
        public float clarity = 0;
        public float dehaze = 0;
        public float[]? master = null;
        public float[]? red = null;
        public float[]? green = null;
        public float[]? blue = null;
        public float[] hsl_hue = new float[8];
        public float[] hsl_sat = new float[8];
        public float[] hsl_lum = new float[8];
        public bool has_hsl = false;
        public float[] bw_mix = new float[8];
        public bool bw = false;
        public bool sepia = false;
        public float[] grade_hue = new float[4];
        public float[] grade_sat = new float[4];
        public float[] grade_lum = new float[4];
        public bool has_grading = false;
        public float grade_blending = 0.5f;
        public float grade_balance = 0;
        public float cal_shadow_tint = 0;
        public float[] cal_hue = new float[3];
        public float[] cal_sat = new float[3];
        public bool has_calibration = false;
        public Lut3D? lut = null;
        public float lut_amount = 1;
        public string profile = "";
        public float[]? base_curve = null;
        public float profile_amount = 1;

        public bool needs_neighbourhood() {
            return highlights.abs() > 1e-6 || shadows.abs() > 1e-6 || texture.abs() > 1e-6 || clarity.abs() > 1e-6 || dehaze.abs() > 1e-6;
        }
    }

    namespace Tone {

        private float[]? raw_base_lut = null;

        public unowned float[] raw_base() {
            if (raw_base_lut == null) {
                var c = new CurvePoints();
                c.set_points({ 0.06, 0.2, 0.45, 0.75 }, { 0.035, 0.2, 0.55, 0.86 });
                raw_base_lut = c.lut(1024);
            }
            return raw_base_lut;
        }

        public float smooth(float e0, float e1, float x) {
            float t = ((x - e0) / (e1 - e0)).clamp(0, 1);
            return t * t * (3 - 2 * t);
        }

        public void scale(FloatImage img, float k) {
            int w = img.width;
            Parallel.range(img.height, (start, end) => {
                for (size_t i = (size_t) start * w * 4; i < (size_t) end * w * 4; i++) if ((i & 3) != 3) img.data[i] *= k;
            });
        }

        public float[] parametric_lut(DevelopSettings d) {
            double[] amounts = { d.get("tone.shadows"), d.get("tone.darks"), d.get("tone.lights"), d.get("tone.highlights") };
            double s1 = d.get("tone.split1"), s2 = d.get("tone.split2"), s3 = d.get("tone.split3");
            double[] edges = { 0, s1, s2, s3, 1 };
            var table = new float[1024];
            for (int i = 0; i < 1024; i++) {
                double x = i / 1023.0;
                double y = x;
                for (int r = 0; r < 4; r++) {
                    if (amounts[r].abs() < 1e-9) continue;
                    double lo = edges[r], hi = edges[r + 1];
                    double c = (lo + hi) / 2, half = (hi - lo) * 0.9 + 0.05;
                    double dist = (x - c).abs() / half;
                    if (dist >= 1) continue;
                    double bump = 0.5 + 0.5 * Math.cos(Math.PI * dist);
                    double room = r < 2 ? (1 - x) : x;
                    y += amounts[r] * 0.22 * bump * Math.sqrt(double.max(0, room * x * 4)).clamp(0, 1);
                }
                table[i] = (float) y.clamp(0, 1);
            }
            for (int i = 1; i < 1024; i++) if (table[i] < table[i - 1]) table[i] = table[i - 1];
            return table;
        }

        public float lookup(float[] lut, float v) {
            if (v <= 0) return lut[0] + v;
            if (v >= 1) return lut[lut.length - 1] + (v - 1);
            float f = v * (lut.length - 1);
            int i = (int) f;
            if (i >= lut.length - 1) return lut[lut.length - 1];
            float t = f - i;
            return lut[i] * (1 - t) + lut[i + 1] * t;
        }

        private bool is_identity_lut(float[] lut) {
            for (int i = 0; i < lut.length; i++) if ((lut[i] - (float) i / (lut.length - 1)).abs() > 1e-5f) return false;
            return true;
        }

        public ToneSettings settings(EditParams p) {
            var t = new ToneSettings();
            var d = p.develop;
            var eff = EditPipeline.effective_values(p);
            t.exposure = (float) Math.pow(2.0, eff[Adjustment.EXPOSURE] * 2.0);
            double warmth = eff[Adjustment.WARMTH], tint = eff[Adjustment.TINT];
            t.wb_r = (float) Math.pow(2.0, warmth * 0.35 + tint * 0.08);
            t.wb_g = (float) Math.pow(2.0, -tint * 0.3);
            t.wb_b = (float) Math.pow(2.0, -warmth * 0.35 + tint * 0.08);
            t.highlights = (float) eff[Adjustment.HIGHLIGHTS];
            t.shadows = (float) eff[Adjustment.SHADOWS];
            t.whites = (float) eff[Adjustment.WHITES];
            t.blacks = (float) eff[Adjustment.BLACKS];
            t.contrast = (float) eff[Adjustment.CONTRAST];
            t.brightness = (float) eff[Adjustment.BRIGHTNESS];
            t.saturation = (float) eff[Adjustment.SATURATION];
            t.vibrance = (float) eff[Adjustment.VIBRANCE];
            t.texture = (float) eff[Adjustment.TEXTURE];
            t.clarity = (float) eff[Adjustment.CLARITY];
            t.dehaze = (float) eff[Adjustment.DEHAZE];
            t.black_point = (float) p.black_point;
            t.white_point = (float) p.white_point;
            var param = parametric_lut(d);
            var master = d.curve("master").lut(1024);
            var composed = new float[1024];
            for (int i = 0; i < 1024; i++) composed[i] = lookup(master, param[i]);
            if (!is_identity_lut(composed)) t.master = composed;
            if (d.has_curve("red")) t.red = d.curve("red").lut(1024);
            if (d.has_curve("green")) t.green = d.curve("green").lut(1024);
            if (d.has_curve("blue")) t.blue = d.curve("blue").lut(1024);
            for (int i = 0; i < 8; i++) {
                t.hsl_hue[i] = (float) d.get("hsl.hue." + HSL_BANDS[i]);
                t.hsl_sat[i] = (float) d.get("hsl.sat." + HSL_BANDS[i]);
                t.hsl_lum[i] = (float) d.get("hsl.lum." + HSL_BANDS[i]);
                t.bw_mix[i] = (float) d.get("bw." + HSL_BANDS[i]);
                if (t.hsl_hue[i] != 0 || t.hsl_sat[i] != 0 || t.hsl_lum[i] != 0) t.has_hsl = true;
            }
            var f = FilterPreset.find(p.filter);
            var mode = f != null ? f.mode : FilterPreset.Mode.COLOR;
            t.bw = d.get_string("treatment") == "bw" || mode == FilterPreset.Mode.MONO;
            t.sepia = mode == FilterPreset.Mode.SEPIA;
            string[] zones = { "shadows", "midtones", "highlights", "global" };
            for (int i = 0; i < 4; i++) {
                t.grade_hue[i] = (float) d.get("grading." + zones[i] + ".hue");
                t.grade_sat[i] = (float) d.get("grading." + zones[i] + ".sat");
                t.grade_lum[i] = (float) d.get("grading." + zones[i] + ".lum");
                if (t.grade_sat[i] != 0 || t.grade_lum[i] != 0) t.has_grading = true;
            }
            t.grade_blending = (float) d.get("grading.blending");
            t.grade_balance = (float) d.get("grading.balance");
            t.cal_shadow_tint = (float) d.get("calibration.shadows.tint");
            string[] prim = { "red", "green", "blue" };
            for (int i = 0; i < 3; i++) {
                t.cal_hue[i] = (float) d.get("calibration." + prim[i] + ".hue");
                t.cal_sat[i] = (float) d.get("calibration." + prim[i] + ".sat");
                if (t.cal_hue[i] != 0 || t.cal_sat[i] != 0) t.has_calibration = true;
            }
            if (t.cal_shadow_tint != 0) t.has_calibration = true;
            string lut_path = d.get_string("lut");
            if (lut_path != "") {
                t.lut = Lut3D.cached(lut_path);
                t.lut_amount = (float) d.get("lut.amount");
            }
            t.profile = d.get_string("profile");
            t.profile_amount = (float) d.get("profile.amount");
            CreativeProfiles.apply(t);
            return t;
        }

        public void rgb_to_hsl(float r, float g, float b, out float h, out float s, out float l) {
            float mx = float.max(r, float.max(g, b)), mn = float.min(r, float.min(g, b));
            l = (mx + mn) / 2;
            float dd = mx - mn;
            if (dd < 1e-6f) {
                h = 0;
                s = 0;
                return;
            }
            s = l > 0.5f ? dd / (2 - mx - mn) : dd / (mx + mn);
            s = s.clamp(0, 1);
            if (mx == r) h = (g - b) / dd + (g < b ? 6 : 0);
            else if (mx == g) h = (b - r) / dd + 2;
            else h = (r - g) / dd + 4;
            h *= 60;
        }

        private float hue_channel(float p, float q, float t) {
            if (t < 0) t += 1;
            if (t > 1) t -= 1;
            if (t < 1.0f / 6) return p + (q - p) * 6 * t;
            if (t < 0.5f) return q;
            if (t < 2.0f / 3) return p + (q - p) * (2.0f / 3 - t) * 6;
            return p;
        }

        public void hsl_to_rgb(float h, float s, float l, out float r, out float g, out float b) {
            if (s <= 0) {
                r = g = b = l;
                return;
            }
            float q = l < 0.5f ? l * (1 + s) : l + s - l * s;
            float p = 2 * l - q;
            float hh = ((h % 360) + 360) % 360 / 360;
            r = hue_channel(p, q, hh + 1.0f / 3);
            g = hue_channel(p, q, hh);
            b = hue_channel(p, q, hh - 1.0f / 3);
        }

        public void band_weights(float hue, float[] weights) {
            float total = 0;
            for (int i = 0; i < 8; i++) {
                float c = (float) HSL_BAND_HUES[i];
                float prev = (float) HSL_BAND_HUES[(i + 7) % 8], next = (float) HSL_BAND_HUES[(i + 1) % 8];
                float d = hue - c;
                while (d > 180) d -= 360;
                while (d < -180) d += 360;
                float span = d >= 0 ? ((next - c + 360) % 360) : ((c - prev + 360) % 360);
                float x = d.abs() / span;
                float w = x >= 1 ? 0 : (float) (0.5 + 0.5 * Math.cos(Math.PI * x));
                weights[i] = w;
                total += w;
            }
            if (total > 1e-6f) for (int i = 0; i < 8; i++) weights[i] /= total;
        }

        private float encode(float v) {
            return Transfer.linear_to_srgb(v);
        }

        private float decode(float v) {
            return Transfer.srgb_to_linear(v);
        }

        public void pixel(ToneSettings t, ref float r, ref float g, ref float b, float[] weights) {
            r *= t.exposure * t.wb_r;
            g *= t.exposure * t.wb_g;
            b *= t.exposure * t.wb_b;
            float er = encode(r), eg = encode(g), eb = encode(b);
            if (t.black_point > 1e-6f || t.white_point < 1 - 1e-6f) {
                float range = t.white_point - t.black_point;
                er = (er - t.black_point) / range;
                eg = (eg - t.black_point) / range;
                eb = (eb - t.black_point) / range;
            }
            if (t.base_curve != null) {
                er = lookup(t.base_curve, er);
                eg = lookup(t.base_curve, eg);
                eb = lookup(t.base_curve, eb);
            }
            if (t.whites != 0) {
                er += t.whites * 0.2f * er * smooth(0.5f, 1.0f, er);
                eg += t.whites * 0.2f * eg * smooth(0.5f, 1.0f, eg);
                eb += t.whites * 0.2f * eb * smooth(0.5f, 1.0f, eb);
            }
            if (t.blacks != 0) {
                er += t.blacks * 0.2f * (1 - smooth(0, 0.5f, er)) * (1 - er.clamp(0, 1));
                eg += t.blacks * 0.2f * (1 - smooth(0, 0.5f, eg)) * (1 - eg.clamp(0, 1));
                eb += t.blacks * 0.2f * (1 - smooth(0, 0.5f, eb)) * (1 - eb.clamp(0, 1));
            }
            if (t.contrast != 0) {
                er = contrast_curve(er, t.contrast);
                eg = contrast_curve(eg, t.contrast);
                eb = contrast_curve(eb, t.contrast);
            }
            if (t.brightness != 0) {
                er = (float) EditPipeline.brightness(er.clamp(0, 1), t.brightness);
                eg = (float) EditPipeline.brightness(eg.clamp(0, 1), t.brightness);
                eb = (float) EditPipeline.brightness(eb.clamp(0, 1), t.brightness);
            }
            if (t.master != null) {
                er = lookup(t.master, er);
                eg = lookup(t.master, eg);
                eb = lookup(t.master, eb);
            }
            if (t.red != null) er = lookup(t.red, er);
            if (t.green != null) eg = lookup(t.green, eg);
            if (t.blue != null) eb = lookup(t.blue, eb);
            if (t.has_calibration) calibration(t, ref er, ref eg, ref eb);
            if (t.has_hsl) hsl(t, ref er, ref eg, ref eb, weights);
            if (t.vibrance != 0) {
                float l = 0.2627f * er + 0.6780f * eg + 0.0593f * eb;
                float mx = float.max(er, float.max(eg, eb)).clamp(0, 1);
                float mn = float.min(er, float.min(eg, eb)).clamp(0, 1);
                float f = 1 + t.vibrance * (1 - (mx - mn));
                er = l + (er - l) * f;
                eg = l + (eg - l) * f;
                eb = l + (eb - l) * f;
            }
            if (t.saturation != 0) {
                float l = 0.2627f * er + 0.6780f * eg + 0.0593f * eb;
                er = l + (er - l) * (1 + t.saturation);
                eg = l + (eg - l) * (1 + t.saturation);
                eb = l + (eb - l) * (1 + t.saturation);
            }
            if (t.has_grading) grading(t, ref er, ref eg, ref eb);
            if (t.bw) {
                float l = 0.2627f * er + 0.6780f * eg + 0.0593f * eb;
                float h, s, ll;
                rgb_to_hsl(er.clamp(0, 1), eg.clamp(0, 1), eb.clamp(0, 1), out h, out s, out ll);
                band_weights(h, weights);
                float k = 0;
                for (int i = 0; i < 8; i++) k += weights[i] * t.bw_mix[i];
                l *= 1 + k * s;
                er = eg = eb = l;
            } else if (t.sepia) {
                float cr = er.clamp(0, 1), cg = eg.clamp(0, 1), cb = eb.clamp(0, 1);
                er = 0.393f * cr + 0.769f * cg + 0.189f * cb;
                eg = 0.349f * cr + 0.686f * cg + 0.168f * cb;
                eb = 0.272f * cr + 0.534f * cg + 0.131f * cb;
            }
            if (t.lut != null && t.lut_amount > 0) {
                float lr, lg, lb;
                t.lut.apply(er.clamp(0, 1), eg.clamp(0, 1), eb.clamp(0, 1), out lr, out lg, out lb);
                er += (lr - er) * t.lut_amount;
                eg += (lg - eg) * t.lut_amount;
                eb += (lb - eb) * t.lut_amount;
            }
            r = decode(er);
            g = decode(eg);
            b = decode(eb);
        }

        public float contrast_curve(float e, float c) {
            if (e <= 0 || e >= 1) return e;
            if (c > 0) {
                float s = e * e * (3 - 2 * e);
                return e + (s - e) * c;
            }
            float inv = (float) (0.5 - Math.sin(Math.asin(1.0 - 2.0 * e) / 3.0));
            return e + (inv - e) * (-c);
        }

        private void hsl(ToneSettings t, ref float r, ref float g, ref float b, float[] weights) {
            float h, s, l;
            rgb_to_hsl(r.clamp(0, 1), g.clamp(0, 1), b.clamp(0, 1), out h, out s, out l);
            if (s < 1e-4f) return;
            band_weights(h, weights);
            float dh = 0, ds = 0, dl = 0;
            for (int i = 0; i < 8; i++) {
                if (weights[i] <= 0) continue;
                dh += weights[i] * t.hsl_hue[i];
                ds += weights[i] * t.hsl_sat[i];
                dl += weights[i] * t.hsl_lum[i];
            }
            float nh = h + dh * 30;
            float ns = (s * (1 + ds)).clamp(0, 1);
            float nl = (l + dl * 0.3f * s * (1 - (2 * l - 1).abs())).clamp(0, 1);
            float nr, ng, nb;
            hsl_to_rgb(nh, ns, nl, out nr, out ng, out nb);
            float over_r = r - r.clamp(0, 1), over_g = g - g.clamp(0, 1), over_b = b - b.clamp(0, 1);
            r = nr + over_r;
            g = ng + over_g;
            b = nb + over_b;
        }

        private void tint_vector(float hue, out float tr, out float tg, out float tb) {
            hsl_to_rgb(hue, 1, 0.5f, out tr, out tg, out tb);
            float mean = (tr + tg + tb) / 3;
            tr -= mean;
            tg -= mean;
            tb -= mean;
        }

        private void grading(ToneSettings t, ref float r, ref float g, ref float b) {
            float lum = (0.2627f * r + 0.6780f * g + 0.0593f * b).clamp(0, 1);
            float pivot = 0.5f - t.grade_balance * 0.3f;
            float power = 1.0f / (0.35f + t.grade_blending);
            float ws = (float) Math.pow((1 - lum / pivot).clamp(0, 1), power);
            float wh = (float) Math.pow(((lum - pivot) / (1 - pivot)).clamp(0, 1), power);
            float wm = (1 - ws - wh).clamp(0, 1);
            float[] w = { ws, wm, wh, 1 };
            for (int i = 0; i < 4; i++) {
                if (t.grade_sat[i] == 0 && t.grade_lum[i] == 0) continue;
                float tr, tg, tb;
                tint_vector(t.grade_hue[i], out tr, out tg, out tb);
                float k = t.grade_sat[i] * 0.35f * w[i];
                float lk = t.grade_lum[i] * 0.25f * w[i];
                r += tr * k + lk;
                g += tg * k + lk;
                b += tb * k + lk;
            }
        }

        private void calibration(ToneSettings t, ref float r, ref float g, ref float b) {
            if (t.cal_shadow_tint != 0) {
                float lum = (0.2627f * r + 0.6780f * g + 0.0593f * b).clamp(0, 1);
                float k = t.cal_shadow_tint * 0.06f * (1 - lum) * (1 - lum);
                g -= k;
                r += k * 0.5f;
                b += k * 0.5f;
            }
            float h, s, l;
            rgb_to_hsl(r.clamp(0, 1), g.clamp(0, 1), b.clamp(0, 1), out h, out s, out l);
            if (s < 1e-4f) return;
            float dh = 0, ds = 0;
            float[] centers = { 0, 120, 240 };
            for (int i = 0; i < 3; i++) {
                float d = h - centers[i];
                while (d > 180) d -= 360;
                while (d < -180) d += 360;
                float x = d.abs() / 120;
                float wt = x >= 1 ? 0 : (float) (0.5 + 0.5 * Math.cos(Math.PI * x));
                dh += wt * t.cal_hue[i] * 20;
                ds += wt * t.cal_sat[i] * 0.5f;
            }
            float nr, ng, nb;
            hsl_to_rgb(h + dh, (s * (1 + ds)).clamp(0, 1), l, out nr, out ng, out nb);
            r = nr + (r - r.clamp(0, 1));
            g = ng + (g - g.clamp(0, 1));
            b = nb + (b - b.clamp(0, 1));
        }

        public void neighbourhood(FloatImage img, ToneSettings t, double res) {
            if (t.dehaze.abs() > 1e-6f) Detail.dehaze(img, t.dehaze, res);
            if (t.highlights.abs() > 1e-6f || t.shadows.abs() > 1e-6f || t.texture.abs() > 1e-6f || t.clarity.abs() > 1e-6f)
                Detail.local_tone(img, t.highlights, t.shadows, t.texture, t.clarity, t.exposure, res);
        }

        public void render(FloatImage img, EditParams p, double res) {
            var t = settings(p);
            neighbourhood(img, t, res);
            apply_pixels(img, t);
        }

        public void apply_pixels(FloatImage img, ToneSettings t) {
            int w = img.width;
            Parallel.range(img.height, (start, end) => {
                var weights = new float[8];
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    float r = img.data[i * 4], g = img.data[i * 4 + 1], b = img.data[i * 4 + 2];
                    pixel(t, ref r, ref g, ref b, weights);
                    img.data[i * 4] = r;
                    img.data[i * 4 + 1] = g;
                    img.data[i * 4 + 2] = b;
                }
            });
        }
    }

    namespace CreativeProfiles {

        public const string[] IDS = { "", "vivid", "landscape", "portrait", "neutral", "monochrome", "matte" };

        public string label(string id) {
            switch (id) {
                case "vivid": return _("Vivid");
                case "landscape": return _("Landscape");
                case "portrait": return _("Portrait");
                case "neutral": return _("Neutral");
                case "monochrome": return _("Monochrome");
                case "matte": return _("Matte");
                default: return _("Standard");
            }
        }

        public void apply(ToneSettings t) {
            float k = t.profile_amount;
            switch (t.profile) {
                case "vivid":
                    t.saturation += 0.2f * k;
                    t.contrast += 0.15f * k;
                    t.vibrance += 0.15f * k;
                    break;
                case "landscape":
                    t.hsl_sat[3] += 0.25f * k;
                    t.hsl_sat[4] += 0.2f * k;
                    t.hsl_sat[5] += 0.25f * k;
                    t.has_hsl = true;
                    t.contrast += 0.1f * k;
                    t.clarity += 0.1f * k;
                    break;
                case "portrait":
                    t.contrast -= 0.08f * k;
                    t.hsl_sat[1] -= 0.1f * k;
                    t.hsl_lum[1] += 0.1f * k;
                    t.has_hsl = true;
                    break;
                case "neutral":
                    t.contrast -= 0.2f * k;
                    t.saturation -= 0.1f * k;
                    break;
                case "monochrome":
                    t.bw = k >= 0.5f;
                    break;
                case "matte":
                    t.contrast -= 0.1f * k;
                    t.blacks += 0.35f * k;
                    t.saturation -= 0.15f * k;
                    break;
                default:
                    break;
            }
        }
    }
}
