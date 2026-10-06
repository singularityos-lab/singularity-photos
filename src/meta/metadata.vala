namespace Singularity.Apps.Photos {

    public class PhotoMetadata : Object {
        public string make { get; set; default = ""; }
        public string model { get; set; default = ""; }
        public string lens { get; set; default = ""; }
        public string software { get; set; default = ""; }
        public string serial { get; set; default = ""; }
        public double focal_length { get; set; default = 0; }
        public double focal_length_35 { get; set; default = 0; }
        public double aperture { get; set; default = 0; }
        public double exposure_time { get; set; default = 0; }
        public int iso { get; set; default = 0; }
        public double exposure_bias { get; set; default = 0; }
        public bool flash_fired { get; set; default = false; }
        public DateTime? date_taken { get; set; default = null; }
        public int width { get; set; default = 0; }
        public int height { get; set; default = 0; }
        public int orientation { get; set; default = 1; }
        public bool has_gps { get; set; default = false; }
        public double latitude { get; set; default = 0; }
        public double longitude { get; set; default = 0; }
        public double altitude { get; set; default = 0; }

        public string title { get; set; default = ""; }
        public string caption { get; set; default = ""; }
        public string headline { get; set; default = ""; }
        public string creator { get; set; default = ""; }
        public string copyright { get; set; default = ""; }
        public string credit { get; set; default = ""; }
        public string location { get; set; default = ""; }
        public string city { get; set; default = ""; }
        public string state { get; set; default = ""; }
        public string country { get; set; default = ""; }
        public string country_code { get; set; default = ""; }
        public string[] keywords { get; set; default = {}; }
        public string[] hierarchical_keywords { get; set; default = {}; }
        public int rating { get; set; default = 0; }
        public string label { get; set; default = ""; }

        public PhotoMetadata copy() {
            var m = new PhotoMetadata();
            foreach (var spec in get_class().list_properties()) {
                if ((spec.flags & ParamFlags.WRITABLE) == 0) continue;
                var v = Value(spec.value_type);
                get_property(spec.name, ref v);
                m.set_property(spec.name, v);
            }
            return m;
        }

        public string exposure_label() {
            if (exposure_time <= 0) return "";
            if (exposure_time >= 1.0) return "%gs".printf(exposure_time);
            return "1/%ds".printf((int) Math.round(1.0 / exposure_time));
        }

        public string summary() {
            var parts = new Gee.ArrayList<string>();
            if (aperture > 0) parts.add("f/%.1f".printf(aperture));
            string e = exposure_label();
            if (e != "") parts.add(e);
            if (iso > 0) parts.add("ISO %d".printf(iso));
            if (focal_length > 0) parts.add("%d mm".printf((int) Math.round(focal_length)));
            return string.joinv(" · ", parts.to_array());
        }

        public string camera_label() {
            string mk = make.strip(), md = model.strip();
            if (mk != "" && md.down().has_prefix(mk.down())) return md;
            return (mk + " " + md).strip();
        }

        public Json.Node to_json() {
            var b = new Json.Builder();
            b.begin_object();
            foreach (var spec in get_class().list_properties()) {
                var v = Value(spec.value_type);
                get_property(spec.name, ref v);
                if (spec.value_type == typeof(string)) {
                    string s = v.get_string() ?? "";
                    if (s == "") continue;
                    b.set_member_name(spec.name);
                    b.add_string_value(s);
                } else if (spec.value_type == typeof(double)) {
                    if (v.get_double() == 0) continue;
                    b.set_member_name(spec.name);
                    b.add_double_value(v.get_double());
                } else if (spec.value_type == typeof(int)) {
                    b.set_member_name(spec.name);
                    b.add_int_value(v.get_int());
                } else if (spec.value_type == typeof(bool)) {
                    b.set_member_name(spec.name);
                    b.add_boolean_value(v.get_boolean());
                } else if (spec.value_type == typeof(string[])) {
                    unowned string[]? arr = (string[]?) v.get_boxed();
                    if (arr == null || arr.length == 0) continue;
                    b.set_member_name(spec.name);
                    b.begin_array();
                    foreach (var s in arr) b.add_string_value(s);
                    b.end_array();
                } else if (spec.value_type == typeof(DateTime)) {
                    var dt = (DateTime?) v.get_boxed();
                    if (dt == null) continue;
                    b.set_member_name(spec.name);
                    b.add_string_value(dt.format_iso8601());
                }
            }
            b.end_object();
            return b.get_root();
        }

        public static PhotoMetadata from_json(Json.Node node) {
            var m = new PhotoMetadata();
            if (node.get_node_type() != Json.NodeType.OBJECT) return m;
            var o = node.get_object();
            foreach (var spec in m.get_class().list_properties()) {
                if (!o.has_member(spec.name)) continue;
                var member = o.get_member(spec.name);
                if (spec.value_type == typeof(string)) {
                    m.set_property(spec.name, member.get_string() ?? "");
                } else if (spec.value_type == typeof(double)) {
                    m.set_property(spec.name, member.get_value_type() == typeof(int64) ? (double) member.get_int() : member.get_double());
                } else if (spec.value_type == typeof(int)) {
                    m.set_property(spec.name, (int) member.get_int());
                } else if (spec.value_type == typeof(bool)) {
                    m.set_property(spec.name, member.get_boolean());
                } else if (spec.value_type == typeof(string[]) && member.get_node_type() == Json.NodeType.ARRAY) {
                    string[] arr = {};
                    member.get_array().foreach_element((a, i, e) => arr += e.get_string());
                    m.set_property(spec.name, arr);
                } else if (spec.value_type == typeof(DateTime)) {
                    var dt = new DateTime.from_iso8601(member.get_string() ?? "", new TimeZone.local());
                    if (dt != null) m.set_property(spec.name, dt);
                }
            }
            return m;
        }
    }
}
