namespace Singularity.Apps.Photos {

    public class LensCalibration : Object {
        public string kind = "";
        public string model = "";
        public double focal = 0;
        public double aperture = 0;
        public double distance = 0;
        public double[] k = {};
    }

    public class LensProfile : Object {
        public string maker = "";
        public string model = "";
        public string mount = "";
        public double crop_factor = 1.0;
        public string source = "";
        public Gee.ArrayList<LensCalibration> calibrations = new Gee.ArrayList<LensCalibration>();

        public string id() {
            return maker + "|" + model;
        }

        public string label() {
            string m = model.down().has_prefix(maker.down()) ? model : (maker + " " + model).strip();
            return m;
        }

        public bool has_kind(string kind) {
            foreach (var c in calibrations) if (c.kind == kind) return true;
            return false;
        }

        public double[]? interpolate(string kind, double focal, double aperture = 0) {
            LensCalibration? lo = null, hi = null;
            foreach (var c in calibrations) {
                if (c.kind != kind) continue;
                if (kind == "vignetting" && aperture > 0 && lo != null && c.focal == lo.focal) {
                    if ((c.aperture - aperture).abs() < (lo.aperture - aperture).abs()) lo = c;
                    continue;
                }
                if (c.focal <= focal && (lo == null || c.focal > lo.focal || (c.focal == lo.focal && kind == "vignetting" && (c.aperture - aperture).abs() < (lo.aperture - aperture).abs()))) lo = c;
                if (c.focal >= focal && (hi == null || c.focal < hi.focal || (c.focal == hi.focal && kind == "vignetting" && (c.aperture - aperture).abs() < (hi.aperture - aperture).abs()))) hi = c;
            }
            if (lo == null && hi == null) return null;
            if (lo == null) return hi.k;
            if (hi == null || hi == lo || (hi.focal - lo.focal).abs() < 1e-6) return lo.k;
            double t = (focal - lo.focal) / (hi.focal - lo.focal);
            int n = int.min(lo.k.length, hi.k.length);
            var out_k = new double[n];
            for (int i = 0; i < n; i++) out_k[i] = lo.k[i] + (hi.k[i] - lo.k[i]) * t;
            return out_k;
        }

        public string model_of(string kind) {
            foreach (var c in calibrations) if (c.kind == kind) return c.model;
            return "";
        }
    }

    namespace LensDatabase {

        private Gee.ArrayList<LensProfile>? lenses = null;
        private Mutex db_lock;

        public string[] search_dirs() {
            string[] dirs = {};
            string? extra = Environment.get_variable("SINGULARITY_PHOTOS_LENS_DIRS");
            if (extra != null) foreach (var d in extra.split(":")) if (d != "") dirs += d;
            dirs += Path.build_filename(Environment.get_user_data_dir(), "lensfun");
            dirs += Path.build_filename(Environment.get_user_data_dir(), "singularity-photos", "lenses");
            foreach (var d in Environment.get_system_data_dirs()) {
                dirs += Path.build_filename(d, "lensfun", "version_1");
                dirs += Path.build_filename(d, "lensfun");
                dirs += Path.build_filename(d, "singularity-photos", "lenses");
            }
            dirs += "/var/lib/lensfun-updates/version_1";
            return dirs;
        }

        private string child_text(Xml.Node* node, string name) {
            for (Xml.Node* c = node->children; c != null; c = c->next) {
                if (c->type == Xml.ElementType.ELEMENT_NODE && c->name == name && c->get_prop("lang") == null) return (c->get_content() ?? "").strip();
            }
            return "";
        }

        private double prop_double(Xml.Node* node, string name, double fallback = 0) {
            string? v = node->get_prop(name);
            return v != null ? double.parse(v) : fallback;
        }

        public Gee.ArrayList<LensProfile> parse(string xml, string source = "") {
            var list = new Gee.ArrayList<LensProfile>();
            Xml.Doc* doc = Xml.Parser.read_memory(xml, xml.length, null, null, Xml.ParserOption.NONET | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING);
            if (doc == null) return list;
            Xml.Node* root = doc->get_root_element();
            if (root != null) {
                for (Xml.Node* n = root->children; n != null; n = n->next) {
                    if (n->type != Xml.ElementType.ELEMENT_NODE || n->name != "lens") continue;
                    var lens = new LensProfile();
                    lens.maker = child_text(n, "maker");
                    lens.model = child_text(n, "model");
                    lens.mount = child_text(n, "mount");
                    lens.source = source;
                    string crop = child_text(n, "cropfactor");
                    if (crop != "") lens.crop_factor = double.parse(crop);
                    for (Xml.Node* c = n->children; c != null; c = c->next) {
                        if (c->type != Xml.ElementType.ELEMENT_NODE || c->name != "calibration") continue;
                        for (Xml.Node* e = c->children; e != null; e = e->next) {
                            if (e->type != Xml.ElementType.ELEMENT_NODE) continue;
                            var cal = new LensCalibration();
                            cal.kind = e->name;
                            cal.model = e->get_prop("model") ?? "";
                            cal.focal = prop_double(e, "focal");
                            cal.aperture = prop_double(e, "aperture");
                            cal.distance = prop_double(e, "distance");
                            if (cal.kind == "distortion") {
                                if (cal.model == "poly3") cal.k = { prop_double(e, "k1") };
                                else if (cal.model == "poly5") cal.k = { prop_double(e, "k1"), prop_double(e, "k2") };
                                else if (cal.model == "ptlens") cal.k = { prop_double(e, "a"), prop_double(e, "b"), prop_double(e, "c") };
                                else continue;
                            } else if (cal.kind == "tca") {
                                if (cal.model == "linear") cal.k = { prop_double(e, "kr", 1), prop_double(e, "kb", 1) };
                                else if (cal.model == "poly3") cal.k = { prop_double(e, "vr", 1), prop_double(e, "vb", 1) };
                                else continue;
                            } else if (cal.kind == "vignetting") {
                                if (cal.model != "pa") continue;
                                cal.k = { prop_double(e, "k1"), prop_double(e, "k2"), prop_double(e, "k3") };
                            } else {
                                continue;
                            }
                            lens.calibrations.add(cal);
                        }
                    }
                    if (lens.model != "" && lens.calibrations.size > 0) list.add(lens);
                }
            }
            delete doc;
            return list;
        }

        private void load_locked() {
            if (lenses != null) return;
            lenses = new Gee.ArrayList<LensProfile>();
            foreach (var dir in search_dirs()) {
                Dir d;
                try {
                    d = Dir.open(dir);
                } catch (Error e) {
                    continue;
                }
                string? name;
                while ((name = d.read_name()) != null) {
                    if (!name.has_suffix(".xml")) continue;
                    string path = Path.build_filename(dir, name);
                    try {
                        string text;
                        FileUtils.get_contents(path, out text);
                        lenses.add_all(parse(text, path));
                    } catch (Error e) {
                    }
                }
            }
        }

        public void reload() {
            db_lock.lock();
            lenses = null;
            load_locked();
            db_lock.unlock();
        }

        public void add_profiles(Gee.Collection<LensProfile> extra) {
            db_lock.lock();
            load_locked();
            lenses.add_all(extra);
            db_lock.unlock();
        }

        public int count() {
            db_lock.lock();
            load_locked();
            int n = lenses.size;
            db_lock.unlock();
            return n;
        }

        private string norm(string s) {
            var sb = new StringBuilder();
            foreach (var part in s.down().replace("/", " ").replace("-", " ").split(" ")) {
                if (part == "") continue;
                sb.append(part);
                sb.append_c(' ');
            }
            return sb.str.strip();
        }

        private int score(LensProfile lens, string wanted, string maker) {
            string a = norm(lens.model), b = norm(wanted);
            if (a == b) return 1000;
            int s = 0;
            var tokens = b.split(" ");
            foreach (var t in tokens) if (t != "" && a.contains(t)) s += 10 + t.length;
            foreach (var t in a.split(" ")) if (t != "" && !b.contains(t)) s -= 3;
            if (maker != "" && norm(lens.maker).contains(norm(maker).split(" ")[0])) s += 5;
            return s;
        }

        public LensProfile? find(string lens_name, string maker = "") {
            if (lens_name.strip() == "") return null;
            db_lock.lock();
            load_locked();
            LensProfile? best = null;
            int best_score = 20;
            foreach (var l in lenses) {
                int s = score(l, lens_name, maker);
                if (s > best_score) {
                    best = l;
                    best_score = s;
                }
            }
            db_lock.unlock();
            return best;
        }

        public LensProfile? by_id(string id) {
            db_lock.lock();
            load_locked();
            LensProfile? found = null;
            foreach (var l in lenses) if (l.id() == id) found = l;
            db_lock.unlock();
            return found;
        }

        public Gee.List<LensProfile> all() {
            db_lock.lock();
            load_locked();
            var copy = new Gee.ArrayList<LensProfile>();
            copy.add_all(lenses);
            db_lock.unlock();
            return copy;
        }
    }
}
