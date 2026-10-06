namespace Singularity.Apps.Photos {

    public class LibraryFilter : Object {
        public string text = "";
        public int rating = 0;
        public string rating_op = ">=";
        public string flag = "any";
        public string[] labels = {};
        public string edited = "any";
        public string kind = "any";
        public string camera = "";
        public string lens = "";
        public int year = 0;
        public int month = 0;
        public int64 keyword_id = 0;
        public string place = "";
        public int64 folder_id = 0;
        public bool include_subfolders = true;
        public bool collapse_stacks = true;
        public Gee.HashSet<int64?> expanded_stacks = new Gee.HashSet<int64?>(id_hash, id_equal);
        public bool hide_missing = false;
        public string sort_key = "captured";
        public bool ascending = false;

        public bool is_active() {
            return text != "" || rating > 0 || flag != "any" || labels.length > 0 || edited != "any" || kind != "any"
                || camera != "" || lens != "" || year != 0 || keyword_id != 0 || place != "";
        }

        public void reset_attributes() {
            text = "";
            rating = 0;
            rating_op = ">=";
            flag = "any";
            labels = {};
            edited = "any";
            kind = "any";
            camera = "";
            lens = "";
            year = 0;
            month = 0;
            keyword_id = 0;
            place = "";
        }

        public static bool text_matches(PhotoRecord r, Catalog catalog, string needle) {
            string n = needle.down();
            if (r.name().down().contains(n)) return true;
            foreach (var s in new string[] { r.title, r.caption, r.camera, r.lens, r.location, r.city, r.country, r.creator, r.copy_name }) {
                if (s != "" && s.down().contains(n)) return true;
            }
            foreach (var id in r.keywords) {
                var k = catalog.keywords[id];
                if (k == null) continue;
                if (k.name.down().contains(n)) return true;
                if (k.synonyms != "" && k.synonyms.down().contains(n)) return true;
            }
            return false;
        }

        private bool in_folder(PhotoRecord r, Catalog catalog) {
            if (r.folder_id == folder_id) return true;
            if (!include_subfolders) return false;
            var f = catalog.folders[folder_id];
            if (f == null) return false;
            return r.path.has_prefix(f.path + "/");
        }

        public bool matches(PhotoRecord r, Catalog catalog) {
            if (hide_missing && r.missing) return false;
            if (folder_id != 0 && !in_folder(r, catalog)) return false;
            if (collapse_stacks && r.stack_id != 0 && r.stack_pos != 0 && !expanded_stacks.contains(r.stack_id)) return false;
            if (text != "") {
                foreach (var word in text.split(" ")) {
                    if (word.strip() == "") continue;
                    if (!text_matches(r, catalog, word.strip())) return false;
                }
            }
            if (rating > 0 || rating_op == "==") {
                if (rating_op == ">=" && r.rating < rating) return false;
                if (rating_op == "<=" && r.rating > rating) return false;
                if (rating_op == "==" && r.rating != rating) return false;
            }
            switch (flag) {
                case "pick": if (r.flag != PickFlag.PICK) return false; break;
                case "reject": if (r.flag != PickFlag.REJECT) return false; break;
                case "unflagged": if (r.flag != PickFlag.NONE) return false; break;
                case "not-rejected": if (r.flag == PickFlag.REJECT) return false; break;
                default: break;
            }
            if (labels.length > 0) {
                bool ok = false;
                foreach (var l in labels) if (l == r.label || (l == "none" && r.label == "")) ok = true;
                if (!ok) return false;
            }
            if (edited == "edited" && !r.edited) return false;
            if (edited == "unedited" && r.edited) return false;
            if (kind == "virtual") {
                if (!r.is_virtual_copy()) return false;
            } else if (kind != "any" && r.kind != kind) {
                return false;
            }
            if (camera != "" && r.camera != camera) return false;
            if (lens != "" && r.lens != lens) return false;
            if (year != 0 || month != 0) {
                var t = r.captured_time();
                if (t == null) return false;
                if (year != 0 && t.get_year() != year) return false;
                if (month != 0 && t.get_month() != month) return false;
            }
            if (keyword_id != 0) {
                bool found = false;
                foreach (var id in r.keywords) if (catalog.keyword_under(id, keyword_id)) found = true;
                if (!found) return false;
            }
            if (place != "") {
                string p = place.down();
                if (!r.city.down().contains(p) && !r.country.down().contains(p) && !r.location.down().contains(p)) return false;
            }
            return true;
        }

        public void sort(Gee.ArrayList<PhotoRecord> list) {
            string key = sort_key;
            bool asc = ascending;
            list.sort((a, b) => {
                int c;
                switch (key) {
                    case "name": c = a.name().collate(b.name()); break;
                    case "added": c = a.added < b.added ? -1 : (a.added > b.added ? 1 : 0); break;
                    case "rating": c = a.rating - b.rating; break;
                    default: c = a.captured < b.captured ? -1 : (a.captured > b.captured ? 1 : 0); break;
                }
                if (c == 0) c = a.path.collate(b.path);
                if (c == 0) c = a.id < b.id ? -1 : (a.id > b.id ? 1 : 0);
                return asc ? c : -c;
            });
        }
    }

    public class SmartRule : Object {
        public string field = "rating";
        public string op = ">=";
        public string value = "";

        public SmartRule(string field, string op, string value) {
            this.field = field;
            this.op = op;
            this.value = value;
        }
    }

    public class SmartRules : Object {
        public const string[] FIELDS = { "rating", "flag", "label", "keyword", "camera", "lens", "date", "text", "kind", "edited", "folder", "gps", "person" };

        public bool match_all = true;
        public Gee.ArrayList<SmartRule> rules = new Gee.ArrayList<SmartRule>();

        public static string field_title(string field) {
            switch (field) {
                case "rating": return _("Rating");
                case "flag": return _("Flag");
                case "label": return _("Color Label");
                case "keyword": return _("Keyword");
                case "camera": return _("Camera");
                case "lens": return _("Lens");
                case "date": return _("Capture Date");
                case "text": return _("Any Text");
                case "kind": return _("File Type");
                case "edited": return _("Edited");
                case "folder": return _("Folder");
                case "person": return _("Person");
                default: return _("Has Location");
            }
        }

        public static string[] ops_for(string field) {
            switch (field) {
                case "rating": return { ">=", "<=", "==", "!=" };
                case "date": return { "within-days", "after", "before" };
                case "camera":
                case "lens":
                case "text":
                case "folder":
                case "person":
                case "keyword": return { "contains", "is", "not" };
                default: return { "is", "not" };
            }
        }

        public static string op_title(string op) {
            switch (op) {
                case ">=": return _("is at least");
                case "<=": return _("is at most");
                case "==": return _("is");
                case "!=": return _("is not");
                case "within-days": return _("is in the last (days)");
                case "after": return _("is after");
                case "before": return _("is before");
                case "contains": return _("contains");
                case "not": return _("is not");
                default: return _("is");
            }
        }

        public static SmartRules parse(string json) {
            var rules = new SmartRules();
            if (json.strip() == "") return rules;
            try {
                var parser = new Json.Parser();
                parser.load_from_data(json);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return rules;
                var o = root.get_object();
                if (o.has_member("match")) rules.match_all = o.get_string_member("match") != "any";
                if (o.has_member("rules")) {
                    o.get_array_member("rules").foreach_element((a, i, e) => {
                        if (e.get_node_type() != Json.NodeType.OBJECT) return;
                        var ro = e.get_object();
                        string v = "";
                        if (ro.has_member("value")) {
                            var vn = ro.get_member("value");
                            v = vn.get_value_type() == typeof(string) ? vn.get_string() : "%g".printf(json_double(vn));
                        }
                        rules.rules.add(new SmartRule(ro.has_member("field") ? ro.get_string_member("field") : "rating",
                                                      ro.has_member("op") ? ro.get_string_member("op") : "is", v));
                    });
                }
            } catch (Error e) {
            }
            return rules;
        }

        public string to_json() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("match");
            b.add_string_value(match_all ? "all" : "any");
            b.set_member_name("rules");
            b.begin_array();
            foreach (var r in rules) {
                b.begin_object();
                b.set_member_name("field");
                b.add_string_value(r.field);
                b.set_member_name("op");
                b.add_string_value(r.op);
                b.set_member_name("value");
                b.add_string_value(r.value);
                b.end_object();
            }
            b.end_array();
            b.end_object();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            return gen.to_data(null);
        }

        public bool matches(PhotoRecord r, Catalog catalog) {
            if (rules.size == 0) return false;
            foreach (var rule in rules) {
                bool ok = rule_matches(rule, r, catalog);
                if (match_all && !ok) return false;
                if (!match_all && ok) return true;
            }
            return match_all;
        }

        private static bool text_op(string op, string subject, string value) {
            string s = subject.down(), v = value.down();
            switch (op) {
                case "is": return s == v;
                case "not": return s != v && !s.contains(v);
                default: return s.contains(v);
            }
        }

        private static DateTime? parse_date(string v) {
            var parts = v.split("-");
            if (parts.length < 1) return null;
            int y = int.parse(parts[0]);
            int m = parts.length > 1 ? int.parse(parts[1]) : 1;
            int d = parts.length > 2 ? int.parse(parts[2]) : 1;
            if (y <= 0) return null;
            return new DateTime.local(y, m.clamp(1, 12), d.clamp(1, 31), 0, 0, 0);
        }

        public static bool rule_matches(SmartRule rule, PhotoRecord r, Catalog catalog) {
            switch (rule.field) {
                case "rating":
                    int v = int.parse(rule.value);
                    switch (rule.op) {
                        case "<=": return r.rating <= v;
                        case "==": return r.rating == v;
                        case "!=": return r.rating != v;
                        default: return r.rating >= v;
                    }
                case "flag":
                    int f = rule.value == "pick" ? 1 : (rule.value == "reject" ? -1 : 0);
                    return rule.op == "not" ? r.flag != f : r.flag == f;
                case "label":
                    string want = rule.value == "none" ? "" : rule.value;
                    return rule.op == "not" ? r.label != want : r.label == want;
                case "keyword":
                    bool any = false;
                    foreach (var id in r.keywords) {
                        var k = catalog.keywords[id];
                        if (k == null) continue;
                        string path = catalog.keyword_path(id);
                        if (rule.op == "is" && (k.name.down() == rule.value.down() || path.down() == rule.value.down())) any = true;
                        else if (rule.op != "is" && (path.down().contains(rule.value.down()) || k.synonyms.down().contains(rule.value.down()))) any = true;
                    }
                    return rule.op == "not" ? !any : any;
                case "camera": return text_op(rule.op, r.camera, rule.value);
                case "lens": return text_op(rule.op, r.lens, rule.value);
                case "folder": return text_op(rule.op, Path.get_dirname(r.path), rule.value);
                case "text":
                    bool hit = LibraryFilter.text_matches(r, catalog, rule.value);
                    return rule.op == "not" ? !hit : hit;
                case "kind":
                    bool same = rule.value == "virtual" ? r.is_virtual_copy() : r.kind == rule.value;
                    return rule.op == "not" ? !same : same;
                case "edited":
                    bool want_edited = rule.value != "false";
                    return rule.op == "not" ? r.edited != want_edited : r.edited == want_edited;
                case "person":
                    bool seen = false;
                    foreach (var f in catalog.faces.values) {
                        if (f.photo_id != r.id || f.person_id == 0) continue;
                        var p = catalog.people[f.person_id];
                        if (p == null) continue;
                        string pn = p.name.down(), v = rule.value.down();
                        if (rule.op == "is" ? pn == v : (rule.op == "contains" ? pn.contains(v) : pn == v)) seen = true;
                    }
                    return rule.op == "not" ? !seen : seen;
                case "gps":
                    bool want_gps = rule.value != "false";
                    return rule.op == "not" ? r.has_gps != want_gps : r.has_gps == want_gps;
                case "date":
                    if (r.captured <= 0) return false;
                    if (rule.op == "within-days") {
                        int64 days = int64.parse(rule.value);
                        int64 now = get_real_time() / 1000000;
                        return now - r.captured <= days * 86400;
                    }
                    var d = parse_date(rule.value);
                    if (d == null) return false;
                    return rule.op == "before" ? r.captured < d.to_unix() : r.captured >= d.to_unix();
                default:
                    return false;
            }
        }
    }
}
