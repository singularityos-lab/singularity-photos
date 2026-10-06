namespace Singularity.Apps.Photos {

    public enum Adjustment {
        EXPOSURE,
        BRIGHTNESS,
        CONTRAST,
        HIGHLIGHTS,
        SHADOWS,
        SATURATION,
        VIBRANCE,
        WARMTH,
        TINT,
        SHARPNESS,
        VIGNETTE,
        WHITES,
        BLACKS,
        TEXTURE,
        CLARITY,
        DEHAZE;

        public const int COUNT = 16;

        public string key() {
            switch (this) {
                case EXPOSURE: return "exposure";
                case BRIGHTNESS: return "brightness";
                case CONTRAST: return "contrast";
                case HIGHLIGHTS: return "highlights";
                case SHADOWS: return "shadows";
                case SATURATION: return "saturation";
                case VIBRANCE: return "vibrance";
                case WARMTH: return "warmth";
                case TINT: return "tint";
                case SHARPNESS: return "sharpness";
                case WHITES: return "whites";
                case BLACKS: return "blacks";
                case TEXTURE: return "texture";
                case CLARITY: return "clarity";
                case DEHAZE: return "dehaze";
                default: return "vignette";
            }
        }

        public string label() {
            switch (this) {
                case EXPOSURE: return _("Exposure");
                case BRIGHTNESS: return _("Brightness");
                case CONTRAST: return _("Contrast");
                case HIGHLIGHTS: return _("Highlights");
                case SHADOWS: return _("Shadows");
                case SATURATION: return _("Saturation");
                case VIBRANCE: return _("Vibrance");
                case WARMTH: return _("Warmth");
                case TINT: return _("Tint");
                case SHARPNESS: return _("Sharpness");
                case WHITES: return _("Whites");
                case BLACKS: return _("Blacks");
                case TEXTURE: return _("Texture");
                case CLARITY: return _("Clarity");
                case DEHAZE: return _("Dehaze");
                default: return _("Vignette");
            }
        }

        public double min_value() {
            if (this == SHARPNESS) return 0.0;
            if (this == EXPOSURE) return -2.5;
            return -1.0;
        }

        public double max_value() {
            return this == EXPOSURE ? 2.5 : 1.0;
        }

        public static Adjustment? from_key(string key) {
            for (int i = 0; i < COUNT; i++) {
                if (((Adjustment) i).key() == key) return (Adjustment) i;
            }
            return null;
        }
    }

    public enum AspectPreset {
        FREE,
        ORIGINAL,
        SQUARE,
        FOUR_THREE,
        THREE_TWO,
        SIXTEEN_NINE,
        FIVE_FOUR;

        public const int COUNT = 7;

        public string label() {
            switch (this) {
                case FREE: return _("Free");
                case ORIGINAL: return _("Original");
                case SQUARE: return _("Square");
                case FOUR_THREE: return "4:3";
                case THREE_TWO: return "3:2";
                case SIXTEEN_NINE: return "16:9";
                default: return "5:4";
            }
        }

        public double ratio(double image_ratio) {
            switch (this) {
                case FREE: return 0.0;
                case ORIGINAL: return image_ratio;
                case SQUARE: return 1.0;
                case FOUR_THREE: return image_ratio >= 1.0 ? 4.0 / 3.0 : 3.0 / 4.0;
                case THREE_TWO: return image_ratio >= 1.0 ? 3.0 / 2.0 : 2.0 / 3.0;
                case SIXTEEN_NINE: return image_ratio >= 1.0 ? 16.0 / 9.0 : 9.0 / 16.0;
                default: return image_ratio >= 1.0 ? 5.0 / 4.0 : 4.0 / 5.0;
            }
        }
    }

    public class EditSnapshot : Object {
        public string name = "";
        public int64 time = 0;
        public string params_json = "";

        public EditSnapshot(string name, EditParams p) {
            this.name = name;
            time = get_real_time() / 1000000;
            params_json = p.to_json();
        }

        public EditParams? restore() {
            try {
                return EditParams.from_json(params_json);
            } catch (Error e) {
                return null;
            }
        }
    }

    public class EditParams : Object {
        public const int FORMAT_VERSION = 2;
        public const double MAX_STRAIGHTEN = 45.0;

        public double[] values = new double[Adjustment.COUNT];
        public int quarter_turns { get; set; default = 0; }
        public bool flip { get; set; default = false; }
        public double straighten { get; set; default = 0.0; }
        public double crop_x { get; set; default = 0.0; }
        public double crop_y { get; set; default = 0.0; }
        public double crop_w { get; set; default = 1.0; }
        public double crop_h { get; set; default = 1.0; }
        public double black_point { get; set; default = 0.0; }
        public double white_point { get; set; default = 1.0; }
        public string filter { get; set; default = "none"; }
        public DevelopSettings develop = new DevelopSettings();
        public Gee.ArrayList<LocalAdjustment> locals = new Gee.ArrayList<LocalAdjustment>();
        public Gee.ArrayList<SpotEdit> spots = new Gee.ArrayList<SpotEdit>();
        public Gee.ArrayList<EditSnapshot> snapshots = new Gee.ArrayList<EditSnapshot>();
        public Gee.ArrayList<EditSnapshot> history = new Gee.ArrayList<EditSnapshot>();

        public double get_value(Adjustment a) {
            return values[a];
        }

        public void set_value(Adjustment a, double v) {
            values[a] = v.clamp(a.min_value(), a.max_value());
        }

        public void set_crop(double x, double y, double w, double h) {
            w = w.clamp(0.01, 1.0);
            h = h.clamp(0.01, 1.0);
            crop_x = x.clamp(0.0, 1.0 - w);
            crop_y = y.clamp(0.0, 1.0 - h);
            crop_w = w;
            crop_h = h;
        }

        public void rotate(int turns) {
            quarter_turns = ((quarter_turns + turns) % 4 + 4) % 4;
            double x = crop_x, y = crop_y, w = crop_w, h = crop_h;
            int t = ((turns % 4) + 4) % 4;
            for (int i = 0; i < t; i++) {
                double nx = 1.0 - y - h, ny = x;
                x = nx;
                y = ny;
                double tmp = w;
                w = h;
                h = tmp;
            }
            set_crop(x, y, w, h);
        }

        public void toggle_flip() {
            flip = !flip;
            straighten = -straighten;
            set_crop(1.0 - crop_x - crop_w, crop_y, crop_w, crop_h);
        }

        public bool has_crop() {
            return crop_x > 1e-6 || crop_y > 1e-6 || crop_w < 1.0 - 1e-6 || crop_h < 1.0 - 1e-6;
        }

        public bool has_geometry() {
            return quarter_turns != 0 || flip || straighten.abs() > 1e-6 || has_crop() || has_transform();
        }

        public bool has_transform() {
            return develop.has_prefix("transform.") || develop.get_string("upright", "off") != "off" || develop.has_prefix("lens.");
        }

        public bool has_locals() {
            foreach (var l in locals) if (l.has_effect()) return true;
            return false;
        }

        public bool has_color() {
            if (filter != "none") return true;
            if (black_point > 1e-6 || white_point < 1.0 - 1e-6) return true;
            foreach (var v in values) if (v.abs() > 1e-6) return true;
            if (!develop.is_default() || has_locals() || spots.size > 0) return true;
            return false;
        }

        public bool is_identity() {
            return !has_geometry() && !has_color();
        }

        public void reset_color() {
            for (int i = 0; i < Adjustment.COUNT; i++) values[i] = 0.0;
            black_point = 0.0;
            white_point = 1.0;
            filter = "none";
            var keep = new Gee.HashMap<string, double?>();
            foreach (var e in develop.values.entries) if (e.key.has_prefix("transform.") || e.key.has_prefix("lens.")) keep[e.key] = e.value;
            string upright = develop.get_string("upright");
            develop = new DevelopSettings();
            foreach (var e in keep.entries) develop.set(e.key, e.value);
            develop.set_string("upright", upright);
            locals.clear();
            spots.clear();
        }

        public EditParams copy() {
            var p = new EditParams();
            p.assign(this);
            return p;
        }

        public void assign(EditParams o) {
            for (int i = 0; i < Adjustment.COUNT; i++) values[i] = o.values[i];
            quarter_turns = o.quarter_turns;
            flip = o.flip;
            straighten = o.straighten;
            crop_x = o.crop_x;
            crop_y = o.crop_y;
            crop_w = o.crop_w;
            crop_h = o.crop_h;
            black_point = o.black_point;
            white_point = o.white_point;
            filter = o.filter;
            develop = o.develop.copy();
            locals.clear();
            foreach (var l in o.locals) locals.add(l.copy());
            spots.clear();
            foreach (var sp in o.spots) spots.add(sp.copy());
        }

        public void assign_all(EditParams o) {
            assign(o);
            snapshots.clear();
            snapshots.add_all(o.snapshots);
            history.clear();
            history.add_all(o.history);
        }

        private string locals_json() {
            var b = new Json.Builder();
            b.begin_array();
            foreach (var l in locals) l.write(b);
            foreach (var sp in spots) sp.write(b);
            b.end_array();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            return gen.to_data(null);
        }

        public bool equals(EditParams o) {
            for (int i = 0; i < Adjustment.COUNT; i++) if ((values[i] - o.values[i]).abs() > 1e-9) return false;
            return quarter_turns == o.quarter_turns && flip == o.flip
                && (straighten - o.straighten).abs() < 1e-9
                && (crop_x - o.crop_x).abs() < 1e-9 && (crop_y - o.crop_y).abs() < 1e-9
                && (crop_w - o.crop_w).abs() < 1e-9 && (crop_h - o.crop_h).abs() < 1e-9
                && (black_point - o.black_point).abs() < 1e-9 && (white_point - o.white_point).abs() < 1e-9
                && filter == o.filter
                && develop.equals(o.develop)
                && locals.size == o.locals.size && spots.size == o.spots.size
                && locals_json() == o.locals_json();
        }

        public string to_json(bool with_store = false) {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("version");
            b.add_int_value(FORMAT_VERSION);
            b.set_member_name("rotation");
            b.add_int_value(quarter_turns * 90);
            b.set_member_name("flip");
            b.add_boolean_value(flip);
            b.set_member_name("straighten");
            b.add_double_value(straighten);
            b.set_member_name("crop");
            b.begin_array();
            b.add_double_value(crop_x);
            b.add_double_value(crop_y);
            b.add_double_value(crop_w);
            b.add_double_value(crop_h);
            b.end_array();
            b.set_member_name("levels");
            b.begin_array();
            b.add_double_value(black_point);
            b.add_double_value(white_point);
            b.end_array();
            b.set_member_name("filter");
            b.add_string_value(filter);
            b.set_member_name("adjust");
            b.begin_object();
            for (int i = 0; i < Adjustment.COUNT; i++) {
                if (values[i].abs() < 1e-9) continue;
                b.set_member_name(((Adjustment) i).key());
                b.add_double_value(values[i]);
            }
            b.end_object();
            if (!develop.is_default()) {
                b.set_member_name("develop");
                develop.write(b);
            }
            if (locals.size > 0) {
                b.set_member_name("locals");
                b.begin_array();
                foreach (var l in locals) l.write(b);
                b.end_array();
            }
            if (spots.size > 0) {
                b.set_member_name("spots");
                b.begin_array();
                foreach (var sp in spots) sp.write(b);
                b.end_array();
            }
            if (with_store) {
                write_snapshots(b, "snapshots", snapshots);
                write_snapshots(b, "history", history);
            }
            b.end_object();
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.set_root(b.get_root());
            return gen.to_data(null);
        }

        private static void write_snapshots(Json.Builder b, string member, Gee.ArrayList<EditSnapshot> list) {
            if (list.size == 0) return;
            b.set_member_name(member);
            b.begin_array();
            foreach (var snap in list) {
                b.begin_object();
                b.set_member_name("name");
                b.add_string_value(snap.name);
                b.set_member_name("time");
                b.add_int_value(snap.time);
                b.set_member_name("params");
                b.add_string_value(snap.params_json);
                b.end_object();
            }
            b.end_array();
        }

        private static void read_snapshots(Json.Object o, string member, Gee.ArrayList<EditSnapshot> list) {
            if (!o.has_member(member) || o.get_member(member).get_node_type() != Json.NodeType.ARRAY) return;
            o.get_array_member(member).foreach_element((a, i, e) => {
                if (e.get_node_type() != Json.NodeType.OBJECT) return;
                var so = e.get_object();
                var snap = new EditSnapshot("", new EditParams());
                snap.name = so.has_member("name") ? so.get_string_member("name") : "";
                snap.time = so.has_member("time") ? so.get_int_member("time") : 0;
                snap.params_json = so.has_member("params") ? so.get_string_member("params") : "";
                list.add(snap);
            });
        }

        private static double member_double(Json.Node node) {
            return node.get_value_type() == typeof(int64) ? (double) node.get_int() : node.get_double();
        }

        public static EditParams from_json(string text) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(text);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT)
                throw new IOError.INVALID_DATA("Not an edit file");
            var o = root.get_object();
            if (o.has_member("version") && o.get_int_member("version") > FORMAT_VERSION)
                throw new IOError.NOT_SUPPORTED("Edit file is from a newer version");
            var p = new EditParams();
            if (o.has_member("rotation")) {
                int deg = (int) o.get_int_member("rotation");
                p.quarter_turns = (((deg / 90) % 4) + 4) % 4;
            }
            if (o.has_member("flip")) p.flip = o.get_boolean_member("flip");
            if (o.has_member("straighten"))
                p.straighten = member_double(o.get_member("straighten")).clamp(-MAX_STRAIGHTEN, MAX_STRAIGHTEN);
            if (o.has_member("crop")) {
                var a = o.get_array_member("crop");
                if (a.get_length() == 4)
                    p.set_crop(member_double(a.get_element(0)), member_double(a.get_element(1)),
                               member_double(a.get_element(2)), member_double(a.get_element(3)));
            }
            if (o.has_member("levels")) {
                var a = o.get_array_member("levels");
                if (a.get_length() == 2) {
                    p.black_point = member_double(a.get_element(0)).clamp(0.0, 0.9);
                    p.white_point = member_double(a.get_element(1)).clamp(p.black_point + 0.05, 1.0);
                }
            }
            if (o.has_member("filter")) {
                string f = o.get_string_member("filter");
                p.filter = FilterPreset.find(f) != null ? f : "none";
            }
            if (o.has_member("adjust")) {
                var adj = o.get_object_member("adjust");
                foreach (var name in adj.get_members()) {
                    var a = Adjustment.from_key(name);
                    if (a != null) p.set_value(a, member_double(adj.get_member(name)));
                }
            }
            if (o.has_member("develop")) p.develop = DevelopSettings.read(o.get_member("develop"));
            if (o.has_member("locals") && o.get_member("locals").get_node_type() == Json.NodeType.ARRAY) {
                o.get_array_member("locals").foreach_element((arr, i, e) => {
                    if (e.get_node_type() == Json.NodeType.OBJECT) p.locals.add(LocalAdjustment.read(e.get_object()));
                });
            }
            if (o.has_member("spots") && o.get_member("spots").get_node_type() == Json.NodeType.ARRAY) {
                o.get_array_member("spots").foreach_element((arr, i, e) => {
                    if (e.get_node_type() == Json.NodeType.OBJECT) p.spots.add(SpotEdit.read(e.get_object()));
                });
            }
            read_snapshots(o, "snapshots", p.snapshots);
            read_snapshots(o, "history", p.history);
            return p;
        }
    }

    public class FilterPreset : Object {
        public enum Mode {
            COLOR,
            MONO,
            SEPIA
        }

        public string id;
        public string name;
        public Mode mode;
        public double[] offsets = new double[Adjustment.COUNT];

        private FilterPreset(string id, string name, Mode mode) {
            this.id = id;
            this.name = name;
            this.mode = mode;
        }

        private FilterPreset with(Adjustment a, double v) {
            offsets[a] = v;
            return this;
        }

        private static FilterPreset[]? presets = null;

        public static unowned FilterPreset[] all() {
            if (presets == null) {
                presets = {
                    new FilterPreset("none", _("Original"), Mode.COLOR),
                    new FilterPreset("vivid", _("Vivid"), Mode.COLOR).with(Adjustment.SATURATION, 0.25).with(Adjustment.CONTRAST, 0.15).with(Adjustment.VIBRANCE, 0.2),
                    new FilterPreset("warm", _("Warm"), Mode.COLOR).with(Adjustment.WARMTH, 0.45).with(Adjustment.VIBRANCE, 0.1),
                    new FilterPreset("cool", _("Cool"), Mode.COLOR).with(Adjustment.WARMTH, -0.45).with(Adjustment.CONTRAST, 0.05),
                    new FilterPreset("fade", _("Fade"), Mode.COLOR).with(Adjustment.CONTRAST, -0.3).with(Adjustment.BRIGHTNESS, 0.12).with(Adjustment.SATURATION, -0.25),
                    new FilterPreset("dramatic", _("Dramatic"), Mode.COLOR).with(Adjustment.CONTRAST, 0.35).with(Adjustment.HIGHLIGHTS, -0.3).with(Adjustment.SHADOWS, -0.2).with(Adjustment.VIGNETTE, 0.4),
                    new FilterPreset("mono", _("Mono"), Mode.MONO),
                    new FilterPreset("noir", _("Noir"), Mode.MONO).with(Adjustment.CONTRAST, 0.45).with(Adjustment.VIGNETTE, 0.3),
                    new FilterPreset("sepia", _("Sepia"), Mode.SEPIA)
                };
            }
            return presets;
        }

        public static FilterPreset? find(string id) {
            foreach (unowned FilterPreset f in all()) if (f.id == id) return f;
            return null;
        }
    }
}
