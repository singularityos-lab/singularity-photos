namespace Singularity.Apps.Photos {

    public struct DevelopKey {
        public unowned string name;
        public double default_value;
        public double min;
        public double max;
    }

    public const string[] HSL_BANDS = { "red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta" };
    public const double[] HSL_BAND_HUES = { 0.0, 30.0, 60.0, 120.0, 180.0, 225.0, 270.0, 315.0 };

    public class CurvePoints : Object {
        public double[] xs = {};
        public double[] ys = {};

        public bool is_identity() {
            if (xs.length == 0) return true;
            for (int i = 0; i < xs.length; i++) if ((xs[i] - ys[i]).abs() > 1e-6) return false;
            return true;
        }

        public void set_points(double[] x, double[] y) {
            xs = x;
            ys = y;
            sort();
        }

        public void add(double x, double y) {
            double[] nx = xs, ny = ys;
            nx += x.clamp(0, 1);
            ny += y.clamp(0, 1);
            xs = nx;
            ys = ny;
            sort();
        }

        public void remove_at(int index) {
            double[] nx = {}, ny = {};
            for (int i = 0; i < xs.length; i++) {
                if (i == index) continue;
                nx += xs[i];
                ny += ys[i];
            }
            xs = nx;
            ys = ny;
        }

        private void sort() {
            int n = xs.length;
            for (int i = 1; i < n; i++) {
                double kx = xs[i], ky = ys[i];
                int j = i - 1;
                while (j >= 0 && xs[j] > kx) {
                    xs[j + 1] = xs[j];
                    ys[j + 1] = ys[j];
                    j--;
                }
                xs[j + 1] = kx;
                ys[j + 1] = ky;
            }
        }

        public CurvePoints copy() {
            var c = new CurvePoints();
            c.xs = xs;
            c.ys = ys;
            return c;
        }

        public bool equals(CurvePoints o) {
            if (xs.length != o.xs.length) return false;
            for (int i = 0; i < xs.length; i++) if ((xs[i] - o.xs[i]).abs() > 1e-9 || (ys[i] - o.ys[i]).abs() > 1e-9) return false;
            return true;
        }

        public float[] lut(int size = 1024) {
            var table = new float[size];
            if (is_identity()) {
                for (int i = 0; i < size; i++) table[i] = (float) i / (size - 1);
                return table;
            }
            double[] x = {}, y = {};
            if (xs[0] > 0) { x += 0.0; y += 0.0; }
            for (int i = 0; i < xs.length; i++) { x += xs[i]; y += ys[i]; }
            if (xs[xs.length - 1] < 1) { x += 1.0; y += 1.0; }
            int n = x.length;
            var m = new double[n];
            var d = new double[n - 1];
            for (int i = 0; i < n - 1; i++) d[i] = (x[i + 1] - x[i]) > 1e-9 ? (y[i + 1] - y[i]) / (x[i + 1] - x[i]) : 0;
            m[0] = d[0];
            m[n - 1] = d[n - 2];
            for (int i = 1; i < n - 1; i++) m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2;
            for (int i = 0; i < n - 1; i++) {
                if (d[i].abs() < 1e-12) {
                    m[i] = 0;
                    m[i + 1] = 0;
                    continue;
                }
                double a = m[i] / d[i], b = m[i + 1] / d[i];
                double s = a * a + b * b;
                if (s > 9) {
                    double t = 3 / Math.sqrt(s);
                    m[i] = t * a * d[i];
                    m[i + 1] = t * b * d[i];
                }
            }
            int seg = 0;
            for (int i = 0; i < size; i++) {
                double t = (double) i / (size - 1);
                while (seg < n - 2 && t > x[seg + 1]) seg++;
                double h = x[seg + 1] - x[seg];
                double v;
                if (h < 1e-9) {
                    v = y[seg];
                } else {
                    double u = ((t - x[seg]) / h).clamp(0, 1);
                    double h00 = 2 * u * u * u - 3 * u * u + 1, h10 = u * u * u - 2 * u * u + u;
                    double h01 = -2 * u * u * u + 3 * u * u, h11 = u * u * u - u * u;
                    v = h00 * y[seg] + h10 * h * m[seg] + h01 * y[seg + 1] + h11 * h * m[seg + 1];
                }
                table[i] = (float) v.clamp(0, 1);
            }
            return table;
        }

        public void write(Json.Builder b) {
            b.begin_array();
            for (int i = 0; i < xs.length; i++) {
                b.begin_array();
                b.add_double_value(xs[i]);
                b.add_double_value(ys[i]);
                b.end_array();
            }
            b.end_array();
        }

        public static CurvePoints read(Json.Node node) {
            var c = new CurvePoints();
            if (node.get_node_type() != Json.NodeType.ARRAY) return c;
            double[] x = {}, y = {};
            node.get_array().foreach_element((a, i, e) => {
                if (e.get_node_type() != Json.NodeType.ARRAY || e.get_array().get_length() < 2) return;
                x += json_double(e.get_array().get_element(0)).clamp(0, 1);
                y += json_double(e.get_array().get_element(1)).clamp(0, 1);
            });
            c.set_points(x, y);
            return c;
        }
    }

    public double json_double(Json.Node node) {
        var t = node.get_value_type();
        if (t == typeof(int64)) return (double) node.get_int();
        if (t == typeof(bool)) return node.get_boolean() ? 1.0 : 0.0;
        if (t == typeof(string)) return double.parse(node.get_string());
        return node.get_double();
    }

    public class DevelopSettings : Object {
        public const string[] CURVE_CHANNELS = { "master", "red", "green", "blue" };

        private static DevelopKey[]? registry = null;

        public Gee.TreeMap<string, double?> values = new Gee.TreeMap<string, double?>();
        public Gee.TreeMap<string, string> strings = new Gee.TreeMap<string, string>();
        public Gee.TreeMap<string, CurvePoints> curves = new Gee.TreeMap<string, CurvePoints>();

        public static unowned DevelopKey[] keys() {
            if (registry == null) {
                DevelopKey[] r = {
                    { "wb.temperature", 5500, 2000, 50000 },
                    { "wb.tint", 0, -150, 150 },
                    { "tone.shadows", 0, -1, 1 },
                    { "tone.darks", 0, -1, 1 },
                    { "tone.lights", 0, -1, 1 },
                    { "tone.highlights", 0, -1, 1 },
                    { "tone.split1", 0.25, 0.05, 0.45 },
                    { "tone.split2", 0.5, 0.3, 0.7 },
                    { "tone.split3", 0.75, 0.55, 0.95 },
                    { "grading.shadows.hue", 0, 0, 360 },
                    { "grading.shadows.sat", 0, 0, 1 },
                    { "grading.shadows.lum", 0, -1, 1 },
                    { "grading.midtones.hue", 0, 0, 360 },
                    { "grading.midtones.sat", 0, 0, 1 },
                    { "grading.midtones.lum", 0, -1, 1 },
                    { "grading.highlights.hue", 0, 0, 360 },
                    { "grading.highlights.sat", 0, 0, 1 },
                    { "grading.highlights.lum", 0, -1, 1 },
                    { "grading.global.hue", 0, 0, 360 },
                    { "grading.global.sat", 0, 0, 1 },
                    { "grading.global.lum", 0, -1, 1 },
                    { "grading.blending", 0.5, 0, 1 },
                    { "grading.balance", 0, -1, 1 },
                    { "detail.sharpen.radius", 1.0, 0.5, 3.0 },
                    { "detail.sharpen.detail", 0.25, 0, 1 },
                    { "detail.sharpen.masking", 0, 0, 1 },
                    { "detail.noise.amount", 0, 0, 1 },
                    { "detail.noise.detail", 0.5, 0, 1 },
                    { "detail.noise.contrast", 0, 0, 1 },
                    { "detail.color.amount", 0, 0, 1 },
                    { "detail.color.detail", 0.5, 0, 1 },
                    { "detail.color.smoothness", 0.5, 0, 1 },
                    { "lens.profile", 0, 0, 1 },
                    { "lens.profile.distortion", 1, 0, 2 },
                    { "lens.profile.vignette", 1, 0, 2 },
                    { "lens.ca", 0, 0, 1 },
                    { "lens.distortion", 0, -1, 1 },
                    { "lens.vignette", 0, -1, 1 },
                    { "lens.vignette.midpoint", 0.5, 0, 1 },
                    { "lens.ca.red", 0, -1, 1 },
                    { "lens.ca.blue", 0, -1, 1 },
                    { "lens.defringe", 0, 0, 1 },
                    { "transform.vertical", 0, -1, 1 },
                    { "transform.horizontal", 0, -1, 1 },
                    { "transform.rotate", 0, -10, 10 },
                    { "transform.aspect", 0, -1, 1 },
                    { "transform.scale", 1, 0.5, 1.5 },
                    { "transform.x", 0, -1, 1 },
                    { "transform.y", 0, -1, 1 },
                    { "effects.vignette.midpoint", 0.5, 0, 1 },
                    { "effects.vignette.roundness", 0, -1, 1 },
                    { "effects.vignette.feather", 0.5, 0, 1 },
                    { "effects.vignette.highlights", 0, 0, 1 },
                    { "effects.grain.amount", 0, 0, 1 },
                    { "effects.grain.size", 0.25, 0, 1 },
                    { "effects.grain.roughness", 0.5, 0, 1 },
                    { "calibration.shadows.tint", 0, -1, 1 },
                    { "calibration.red.hue", 0, -1, 1 },
                    { "calibration.red.sat", 0, -1, 1 },
                    { "calibration.green.hue", 0, -1, 1 },
                    { "calibration.green.sat", 0, -1, 1 },
                    { "calibration.blue.hue", 0, -1, 1 },
                    { "calibration.blue.sat", 0, -1, 1 },
                    { "profile.amount", 1, 0, 2 },
                    { "lut.amount", 1, 0, 1 },
                    { "superres", 0, 0, 1 }
                };
                DevelopKey[] bands = {};
                foreach (unowned string band in HSL_BANDS) {
                    bands += DevelopKey() { name = intern("hsl.hue." + band), default_value = 0, min = -1, max = 1 };
                    bands += DevelopKey() { name = intern("hsl.sat." + band), default_value = 0, min = -1, max = 1 };
                    bands += DevelopKey() { name = intern("hsl.lum." + band), default_value = 0, min = -1, max = 1 };
                    bands += DevelopKey() { name = intern("bw." + band), default_value = 0, min = -1, max = 1 };
                }
                foreach (var k in bands) r += k;
                registry = r;
            }
            return registry;
        }

        private static unowned string intern(string s) {
            return Quark.from_string(s).to_string();
        }

        public static DevelopKey? find_key(string name) {
            foreach (unowned DevelopKey k in keys()) if (k.name == name) return k;
            return null;
        }

        public double get(string key) {
            if (values.has_key(key)) return values[key];
            var k = find_key(key);
            return k != null ? k.default_value : 0.0;
        }

        public void set(string key, double v) {
            var k = find_key(key);
            if (k != null) {
                v = v.clamp(k.min, k.max);
                if ((v - k.default_value).abs() < 1e-9) {
                    values.unset(key);
                    return;
                }
            }
            values[key] = v;
        }

        public string get_string(string key, string fallback = "") {
            return strings.has_key(key) ? strings[key] : fallback;
        }

        public void set_string(string key, string? v) {
            if (v == null || v == "") strings.unset(key);
            else strings[key] = v;
        }

        public CurvePoints curve(string channel) {
            if (!curves.has_key(channel)) curves[channel] = new CurvePoints();
            return curves[channel];
        }

        public bool has_curve(string channel) {
            return curves.has_key(channel) && !curves[channel].is_identity();
        }

        public bool is_default() {
            if (values.size > 0 || strings.size > 0) return false;
            foreach (var c in curves.values) if (!c.is_identity()) return false;
            return true;
        }

        public bool has_prefix(string prefix) {
            foreach (var k in values.keys) if (k.has_prefix(prefix)) return true;
            return false;
        }

        public void reset_prefix(string prefix) {
            var drop = new Gee.ArrayList<string>();
            foreach (var k in values.keys) if (k.has_prefix(prefix)) drop.add(k);
            foreach (var k in drop) values.unset(k);
        }

        public DevelopSettings copy() {
            var d = new DevelopSettings();
            d.assign(this);
            return d;
        }

        public void assign(DevelopSettings o) {
            values.clear();
            strings.clear();
            curves.clear();
            foreach (var e in o.values.entries) values[e.key] = e.value;
            foreach (var e in o.strings.entries) strings[e.key] = e.value;
            foreach (var e in o.curves.entries) if (!e.value.is_identity()) curves[e.key] = e.value.copy();
        }

        public bool equals(DevelopSettings o) {
            if (values.size != o.values.size || strings.size != o.strings.size) return false;
            foreach (var e in values.entries) {
                if (!o.values.has_key(e.key) || (o.values[e.key] - e.value).abs() > 1e-9) return false;
            }
            foreach (var e in strings.entries) if (o.strings[e.key] != e.value) return false;
            foreach (unowned string ch in CURVE_CHANNELS) {
                bool a = has_curve(ch), b = o.has_curve(ch);
                if (a != b) return false;
                if (a && !curve(ch).equals(o.curve(ch))) return false;
            }
            return true;
        }

        public void write(Json.Builder b) {
            b.begin_object();
            foreach (var e in values.entries) {
                b.set_member_name(e.key);
                b.add_double_value(e.value);
            }
            foreach (var e in strings.entries) {
                b.set_member_name(e.key);
                b.add_string_value(e.value);
            }
            foreach (var e in curves.entries) {
                if (e.value.is_identity()) continue;
                b.set_member_name("curve." + e.key);
                e.value.write(b);
            }
            b.end_object();
        }

        public static DevelopSettings read(Json.Node node) {
            var d = new DevelopSettings();
            if (node.get_node_type() != Json.NodeType.OBJECT) return d;
            var o = node.get_object();
            foreach (var name in o.get_members()) {
                var m = o.get_member(name);
                if (name.has_prefix("curve.")) {
                    var c = CurvePoints.read(m);
                    if (!c.is_identity()) d.curves[name.substring(6)] = c;
                } else if (m.get_value_type() == typeof(string)) {
                    d.set_string(name, m.get_string());
                } else if (m.get_node_type() == Json.NodeType.VALUE) {
                    d.set(name, json_double(m));
                }
            }
            return d;
        }
    }

    public class BrushStroke : Object {
        public double radius = 0.03;
        public double feather = 0.5;
        public double flow = 1.0;
        public bool erase = false;
        public double[] points = {};

        public BrushStroke copy() {
            var s = new BrushStroke();
            s.radius = radius;
            s.feather = feather;
            s.flow = flow;
            s.erase = erase;
            s.points = points;
            return s;
        }

        public void add_point(double x, double y) {
            double[] p = points;
            p += x;
            p += y;
            points = p;
        }

        public void write(Json.Builder b) {
            b.begin_object();
            b.set_member_name("radius");
            b.add_double_value(radius);
            b.set_member_name("feather");
            b.add_double_value(feather);
            b.set_member_name("flow");
            b.add_double_value(flow);
            b.set_member_name("erase");
            b.add_boolean_value(erase);
            b.set_member_name("points");
            b.begin_array();
            foreach (var v in points) b.add_double_value(v);
            b.end_array();
            b.end_object();
        }

        public static BrushStroke read(Json.Object o) {
            var s = new BrushStroke();
            if (o.has_member("radius")) s.radius = json_double(o.get_member("radius"));
            if (o.has_member("feather")) s.feather = json_double(o.get_member("feather"));
            if (o.has_member("flow")) s.flow = json_double(o.get_member("flow"));
            if (o.has_member("erase")) s.erase = o.get_boolean_member("erase");
            if (o.has_member("points")) {
                double[] pts = {};
                o.get_array_member("points").foreach_element((a, i, e) => pts += json_double(e));
                s.points = pts;
            }
            return s;
        }
    }

    public class MaskComponent : Object {
        public const string[] KINDS = { "brush", "linear", "radial", "color", "luminance", "depth", "sky", "subject", "all" };

        public string kind = "brush";
        public string mode = "add";
        public bool invert = false;
        public Gee.TreeMap<string, double?> geo = new Gee.TreeMap<string, double?>();
        public Gee.ArrayList<BrushStroke> strokes = new Gee.ArrayList<BrushStroke>();

        public MaskComponent(string kind = "brush") {
            this.kind = kind;
        }

        public double g(string key, double fallback = 0) {
            return geo.has_key(key) ? geo[key] : fallback;
        }

        public void s(string key, double v) {
            geo[key] = v;
        }

        public MaskComponent copy() {
            var c = new MaskComponent(kind);
            c.mode = mode;
            c.invert = invert;
            foreach (var e in geo.entries) c.geo[e.key] = e.value;
            foreach (var st in strokes) c.strokes.add(st.copy());
            return c;
        }

        public void write(Json.Builder b) {
            b.begin_object();
            b.set_member_name("kind");
            b.add_string_value(kind);
            b.set_member_name("mode");
            b.add_string_value(mode);
            b.set_member_name("invert");
            b.add_boolean_value(invert);
            b.set_member_name("geometry");
            b.begin_object();
            foreach (var e in geo.entries) {
                b.set_member_name(e.key);
                b.add_double_value(e.value);
            }
            b.end_object();
            if (strokes.size > 0) {
                b.set_member_name("strokes");
                b.begin_array();
                foreach (var st in strokes) st.write(b);
                b.end_array();
            }
            b.end_object();
        }

        public static MaskComponent read(Json.Object o) {
            var c = new MaskComponent(o.has_member("kind") ? o.get_string_member("kind") : "brush");
            if (o.has_member("mode")) c.mode = o.get_string_member("mode");
            if (o.has_member("invert")) c.invert = o.get_boolean_member("invert");
            if (o.has_member("geometry")) {
                var g = o.get_object_member("geometry");
                foreach (var name in g.get_members()) c.geo[name] = json_double(g.get_member(name));
            }
            if (o.has_member("strokes")) {
                o.get_array_member("strokes").foreach_element((a, i, e) => {
                    if (e.get_node_type() == Json.NodeType.OBJECT) c.strokes.add(BrushStroke.read(e.get_object()));
                });
            }
            return c;
        }
    }

    public class LocalAdjustment : Object {
        public const string[] KEYS = { "exposure", "contrast", "highlights", "shadows", "whites", "blacks", "temperature", "tint", "texture", "clarity", "dehaze", "hue", "saturation", "sharpness", "noise", "defringe" };

        public string id = "";
        public string name = "";
        public bool enabled = true;
        public double amount = 1.0;
        public Gee.TreeMap<string, double?> values = new Gee.TreeMap<string, double?>();
        public Gee.ArrayList<MaskComponent> components = new Gee.ArrayList<MaskComponent>();

        public LocalAdjustment() {
            id = Uuid.string_random();
        }

        public static double min_for(string key) {
            if (key == "exposure") return -4;
            if (key == "hue") return -180;
            if (key == "sharpness" || key == "noise" || key == "defringe") return -1;
            return -1;
        }

        public static double max_for(string key) {
            if (key == "exposure") return 4;
            if (key == "hue") return 180;
            return 1;
        }

        public double get(string key) {
            return values.has_key(key) ? values[key] : 0.0;
        }

        public void set(string key, double v) {
            v = v.clamp(min_for(key), max_for(key));
            if (v.abs() < 1e-9) values.unset(key);
            else values[key] = v;
        }

        public bool has_effect() {
            return enabled && amount > 1e-6 && values.size > 0 && components.size > 0;
        }

        public LocalAdjustment copy() {
            var l = new LocalAdjustment();
            l.id = id;
            l.name = name;
            l.enabled = enabled;
            l.amount = amount;
            foreach (var e in values.entries) l.values[e.key] = e.value;
            foreach (var c in components) l.components.add(c.copy());
            return l;
        }

        public void write(Json.Builder b) {
            b.begin_object();
            b.set_member_name("id");
            b.add_string_value(id);
            b.set_member_name("name");
            b.add_string_value(name);
            b.set_member_name("enabled");
            b.add_boolean_value(enabled);
            b.set_member_name("amount");
            b.add_double_value(amount);
            b.set_member_name("adjust");
            b.begin_object();
            foreach (var e in values.entries) {
                b.set_member_name(e.key);
                b.add_double_value(e.value);
            }
            b.end_object();
            b.set_member_name("mask");
            b.begin_array();
            foreach (var c in components) c.write(b);
            b.end_array();
            b.end_object();
        }

        public static LocalAdjustment read(Json.Object o) {
            var l = new LocalAdjustment();
            if (o.has_member("id")) l.id = o.get_string_member("id");
            if (o.has_member("name")) l.name = o.get_string_member("name");
            if (o.has_member("enabled")) l.enabled = o.get_boolean_member("enabled");
            if (o.has_member("amount")) l.amount = json_double(o.get_member("amount")).clamp(0, 2);
            if (o.has_member("adjust")) {
                var a = o.get_object_member("adjust");
                foreach (var name in a.get_members()) l.set(name, json_double(a.get_member(name)));
            }
            if (o.has_member("mask")) {
                o.get_array_member("mask").foreach_element((arr, i, e) => {
                    if (e.get_node_type() == Json.NodeType.OBJECT) l.components.add(MaskComponent.read(e.get_object()));
                });
            }
            return l;
        }
    }

    public class SpotEdit : Object {
        public string mode = "heal";
        public double x = 0.5;
        public double y = 0.5;
        public double source_x = 0.5;
        public double source_y = 0.5;
        public double radius = 0.02;
        public double feather = 0.5;
        public double opacity = 1.0;
        public bool auto_source = true;

        public SpotEdit copy() {
            var s = new SpotEdit();
            s.mode = mode;
            s.x = x;
            s.y = y;
            s.source_x = source_x;
            s.source_y = source_y;
            s.radius = radius;
            s.feather = feather;
            s.opacity = opacity;
            s.auto_source = auto_source;
            return s;
        }

        public void write(Json.Builder b) {
            b.begin_object();
            b.set_member_name("mode");
            b.add_string_value(mode);
            foreach (var pair in new string[] { "x", "y", "source_x", "source_y", "radius", "feather", "opacity" }) {
                b.set_member_name(pair);
                b.add_double_value(field(pair));
            }
            b.set_member_name("auto_source");
            b.add_boolean_value(auto_source);
            b.end_object();
        }

        private double field(string name) {
            switch (name) {
                case "x": return x;
                case "y": return y;
                case "source_x": return source_x;
                case "source_y": return source_y;
                case "radius": return radius;
                case "feather": return feather;
                default: return opacity;
            }
        }

        public static SpotEdit read(Json.Object o) {
            var s = new SpotEdit();
            if (o.has_member("mode")) s.mode = o.get_string_member("mode");
            if (o.has_member("x")) s.x = json_double(o.get_member("x"));
            if (o.has_member("y")) s.y = json_double(o.get_member("y"));
            if (o.has_member("source_x")) s.source_x = json_double(o.get_member("source_x"));
            if (o.has_member("source_y")) s.source_y = json_double(o.get_member("source_y"));
            if (o.has_member("radius")) s.radius = json_double(o.get_member("radius")).clamp(0.001, 0.5);
            if (o.has_member("feather")) s.feather = json_double(o.get_member("feather")).clamp(0, 1);
            if (o.has_member("opacity")) s.opacity = json_double(o.get_member("opacity")).clamp(0, 1);
            if (o.has_member("auto_source")) s.auto_source = o.get_boolean_member("auto_source");
            return s;
        }
    }
}
