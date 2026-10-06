using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class RetouchAdjustment : Object {
        public const string[] KINDS = { "levels", "curves", "hue-saturation", "exposure", "brightness-contrast", "black-white", "invert", "threshold", "develop" };

        public string kind = "levels";
        public Gee.TreeMap<string, double?> values = new Gee.TreeMap<string, double?>();
        public CurvePoints[] curves = { new CurvePoints(), new CurvePoints(), new CurvePoints(), new CurvePoints() };
        public EditParams develop = new EditParams();

        public RetouchAdjustment(string kind) {
            this.kind = kind;
        }

        public static string label_for(string kind) {
            switch (kind) {
                case "levels": return _("Levels");
                case "curves": return _("Curves");
                case "hue-saturation": return _("Hue/Saturation");
                case "exposure": return _("Exposure");
                case "brightness-contrast": return _("Brightness/Contrast");
                case "black-white": return _("Black and White");
                case "invert": return _("Invert");
                case "threshold": return _("Threshold");
                default: return _("Develop");
            }
        }

        public static string[] keys_for(string kind) {
            switch (kind) {
                case "levels": return { "input-black", "input-white", "gamma", "output-black", "output-white" };
                case "hue-saturation": return { "hue", "saturation", "lightness", "colorize" };
                case "exposure": return { "exposure", "offset", "gamma" };
                case "brightness-contrast": return { "brightness", "contrast" };
                case "black-white": return { "reds", "yellows", "greens", "cyans", "blues", "magentas" };
                case "threshold": return { "level" };
                default: return {};
            }
        }

        public static string key_label(string key) {
            switch (key) {
                case "input-black": return _("Input Black");
                case "input-white": return _("Input White");
                case "gamma": return _("Gamma");
                case "output-black": return _("Output Black");
                case "output-white": return _("Output White");
                case "hue": return _("Hue");
                case "saturation": return _("Saturation");
                case "lightness": return _("Lightness");
                case "colorize": return _("Colorize");
                case "exposure": return _("Exposure");
                case "offset": return _("Offset");
                case "brightness": return _("Brightness");
                case "contrast": return _("Contrast");
                case "reds": return _("Reds");
                case "yellows": return _("Yellows");
                case "greens": return _("Greens");
                case "cyans": return _("Cyans");
                case "blues": return _("Blues");
                case "magentas": return _("Magentas");
                case "level": return _("Level");
                default: return key;
            }
        }

        public static void range_for(string key, out double min, out double max, out double def) {
            switch (key) {
                case "input-black": min = 0; max = 1; def = 0; return;
                case "input-white": min = 0; max = 1; def = 1; return;
                case "gamma": min = 0.1; max = 9.99; def = 1; return;
                case "output-black": min = 0; max = 1; def = 0; return;
                case "output-white": min = 0; max = 1; def = 1; return;
                case "hue": min = -180; max = 180; def = 0; return;
                case "saturation": min = -1; max = 1; def = 0; return;
                case "lightness": min = -1; max = 1; def = 0; return;
                case "colorize": min = 0; max = 1; def = 0; return;
                case "exposure": min = -5; max = 5; def = 0; return;
                case "offset": min = -0.5; max = 0.5; def = 0; return;
                case "brightness": min = -1; max = 1; def = 0; return;
                case "contrast": min = -1; max = 1; def = 0; return;
                case "reds": min = -2; max = 3; def = 0.4; return;
                case "yellows": min = -2; max = 3; def = 0.6; return;
                case "greens": min = -2; max = 3; def = 0.4; return;
                case "cyans": min = -2; max = 3; def = 0.6; return;
                case "blues": min = -2; max = 3; def = 0.2; return;
                case "magentas": min = -2; max = 3; def = 0.8; return;
                case "level": min = 0; max = 1; def = 0.5; return;
                default: min = -1; max = 1; def = 0; return;
            }
        }

        public double value_of(string key) {
            if (values.has_key(key)) return values[key];
            double min, max, def;
            range_for(key, out min, out max, out def);
            return def;
        }

        public void put(string key, double v) {
            double min, max, def;
            range_for(key, out min, out max, out def);
            values[key] = v.clamp(min, max);
        }

        public RetouchAdjustment copy() {
            var a = new RetouchAdjustment(kind);
            foreach (var e in values.entries) a.values[e.key] = e.value;
            for (int i = 0; i < 4; i++) a.curves[i] = curves[i].copy();
            a.develop = develop.copy();
            return a;
        }

        public string to_json() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("kind");
            b.add_string_value(kind);
            b.set_member_name("values");
            b.begin_object();
            foreach (var e in values.entries) {
                b.set_member_name(e.key);
                b.add_double_value(e.value);
            }
            b.end_object();
            b.set_member_name("curves");
            b.begin_array();
            foreach (var c in curves) c.write(b);
            b.end_array();
            if (kind == "develop") {
                b.set_member_name("develop");
                b.add_string_value(develop.to_json());
            }
            b.end_object();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            return gen.to_data(null);
        }

        public static RetouchAdjustment from_json(string text) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(text);
            var o = parser.get_root().get_object();
            var a = new RetouchAdjustment(o.has_member("kind") ? o.get_string_member("kind") : "levels");
            if (o.has_member("values")) {
                var v = o.get_object_member("values");
                foreach (var name in v.get_members()) a.put(name, json_double(v.get_member(name)));
            }
            if (o.has_member("curves")) {
                var arr = o.get_array_member("curves");
                for (int i = 0; i < 4 && i < (int) arr.get_length(); i++) a.curves[i] = CurvePoints.read(arr.get_element(i));
            }
            if (o.has_member("develop")) a.develop = EditParams.from_json(o.get_string_member("develop"));
            return a;
        }

        public void apply_encoded(FloatImage img, int x0, int y0, int w, int h) {
            switch (kind) {
                case "curves":
                    var master = curves[0].lut(4096);
                    var cr = curves[1].lut(4096);
                    var cg = curves[2].lut(4096);
                    var cb = curves[3].lut(4096);
                    each(img, x0, y0, w, h, (d, i) => {
                        d[i] = lookup(cr, lookup(master, d[i]));
                        d[i + 1] = lookup(cg, lookup(master, d[i + 1]));
                        d[i + 2] = lookup(cb, lookup(master, d[i + 2]));
                    });
                    return;
                case "develop":
                    if (x0 == 0 && y0 == 0 && w == img.width && h == img.height) {
                        RetouchDevelop.apply_layer(img, develop);
                    } else {
                        var part = img.cropped(x0, y0, w, h);
                        RetouchDevelop.apply_layer(part, develop);
                        img.paste(part, x0, y0);
                    }
                    return;
                default:
                    var snapshot = copy();
                    each(img, x0, y0, w, h, (d, i) => {
                        float r = d[i], g = d[i + 1], b = d[i + 2];
                        snapshot.pixel(ref r, ref g, ref b);
                        d[i] = r;
                        d[i + 1] = g;
                        d[i + 2] = b;
                    });
                    return;
            }
        }

        private delegate void PixelFunc(float[] data, size_t i);

        private static void each(FloatImage img, int x0, int y0, int w, int h, PixelFunc func) {
            Parallel.range(h, (start, end) => {
                for (int y = y0 + start; y < y0 + end; y++) {
                    for (int x = x0; x < x0 + w; x++) func(img.data, img.offset(x, y));
                }
            });
        }

        private static float lookup(float[] table, float v) {
            float t = v.clamp(0, 1) * (table.length - 1);
            int i = (int) t;
            if (i >= table.length - 1) return table[table.length - 1];
            float f = t - i;
            return table[i] * (1 - f) + table[i + 1] * f;
        }

        public void pixel(ref float r, ref float g, ref float b) {
            switch (kind) {
                case "levels":
                    float ib = (float) value_of("input-black"), iw = (float) value_of("input-white");
                    float gm = (float) value_of("gamma"), ob = (float) value_of("output-black"), ow = (float) value_of("output-white");
                    float range = float.max(1e-4f, iw - ib);
                    r = ob + (ow - ob) * Math.powf(((r - ib) / range).clamp(0, 1), 1 / gm);
                    g = ob + (ow - ob) * Math.powf(((g - ib) / range).clamp(0, 1), 1 / gm);
                    b = ob + (ow - ob) * Math.powf(((b - ib) / range).clamp(0, 1), 1 / gm);
                    return;
                case "hue-saturation":
                    float h, s, l;
                    RetouchColor.rgb_to_hsl(r, g, b, out h, out s, out l);
                    float light = (float) value_of("lightness");
                    if (value_of("colorize") > 0.5) {
                        h = (float) ((value_of("hue") + 360) % 360);
                        s = (float) ((value_of("saturation") + 1) / 2);
                    } else {
                        h += (float) value_of("hue");
                        float sat = (float) value_of("saturation");
                        s = sat >= 0 ? s + (1 - s) * sat * s.clamp(0, 1) * 2 : s * (1 + sat);
                        s = s.clamp(0, 1);
                    }
                    l = light >= 0 ? l + (1 - l) * light : l * (1 + light);
                    RetouchColor.hsl_to_rgb(h, s, l, out r, out g, out b);
                    return;
                case "exposure":
                    float mul = Math.powf(2, (float) value_of("exposure"));
                    float off = (float) value_of("offset"), gam = (float) value_of("gamma");
                    r = Math.powf((Transfer.linear_to_srgb(Transfer.srgb_to_linear(r) * mul) + off).clamp(0, 1), 1 / gam);
                    g = Math.powf((Transfer.linear_to_srgb(Transfer.srgb_to_linear(g) * mul) + off).clamp(0, 1), 1 / gam);
                    b = Math.powf((Transfer.linear_to_srgb(Transfer.srgb_to_linear(b) * mul) + off).clamp(0, 1), 1 / gam);
                    return;
                case "brightness-contrast":
                    float br = (float) value_of("brightness") * 0.5f, ct = (float) value_of("contrast");
                    float k = ct >= 0 ? 1 / float.max(0.01f, 1 - ct * 0.99f) : 1 + ct;
                    r = ((r + br - 0.5f) * k + 0.5f).clamp(0, 1);
                    g = ((g + br - 0.5f) * k + 0.5f).clamp(0, 1);
                    b = ((b + br - 0.5f) * k + 0.5f).clamp(0, 1);
                    return;
                case "black-white":
                    float gray = black_white(r, g, b);
                    r = g = b = gray.clamp(0, 1);
                    return;
                case "invert":
                    r = 1 - r;
                    g = 1 - g;
                    b = 1 - b;
                    return;
                case "threshold":
                    float lv = RetouchColor.luma_encoded(r, g, b) >= value_of("level") ? 1 : 0;
                    r = g = b = lv;
                    return;
                default:
                    return;
            }
        }

        private float black_white(float r, float g, float b) {
            float mn = float.min(r, float.min(g, b));
            float mx = float.max(r, float.max(g, b));
            if (mx - mn < 1e-6f) return r;
            float mid = r + g + b - mn - mx;
            string primary, secondary;
            if (mx == r) {
                primary = "reds";
                secondary = mn == b ? "yellows" : "magentas";
            } else if (mx == g) {
                primary = "greens";
                secondary = mn == b ? "yellows" : "cyans";
            } else {
                primary = "blues";
                secondary = mn == r ? "cyans" : "magentas";
            }
            return mn + (float) value_of(primary) * (mx - mid) + (float) value_of(secondary) * (mid - mn);
        }
    }
}
