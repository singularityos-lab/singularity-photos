namespace Singularity.Apps.Photos {

    public class LrcatReport : Object {
        public int photos = 0;
        public int missing = 0;
        public int collections = 0;
        public int smart_collections = 0;
        public int keywords = 0;
        public int ratings = 0;
        public int labels = 0;
        public int flags = 0;
    }

    public class LrcatImporter : Object {
        public Catalog catalog { get; construct; }

        public LrcatImporter(Catalog catalog) {
            Object(catalog: catalog);
        }

        private static string label_for(string lr) {
            string v = lr.strip().down();
            foreach (var l in COLOR_LABELS) if (l == v) return l;
            return "";
        }

        private static bool has_table(Sqlite.Database db, string name) {
            Sqlite.Statement st;
            db.prepare_v2("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", -1, out st);
            st.bind_text(1, name);
            return st.step() == Sqlite.ROW;
        }

        public LrcatReport import_catalog(string lrcat_path) throws Error {
            Sqlite.Database db;
            if (Sqlite.Database.open_v2(lrcat_path, out db, Sqlite.OPEN_READONLY) != Sqlite.OK)
                throw new CatalogError.OPEN(_("Cannot open the Lightroom catalog"));
            foreach (var t in new string[] { "Adobe_images", "AgLibraryFile", "AgLibraryFolder", "AgLibraryRootFolder" }) {
                if (!has_table(db, t)) throw new CatalogError.QUERY(_("Not a Lightroom catalog"));
            }
            var report = new LrcatReport();
            var image_map = new Gee.HashMap<int64?, PhotoRecord>(id_hash, id_equal);
            catalog.begin();
            Sqlite.Statement st;
            db.prepare_v2("""SELECT i.id_local, r.absolutePath, f.pathFromRoot, l.baseName, l.extension,
                    COALESCE(i.rating, 0), COALESCE(i.colorLabels, ''), COALESCE(i.pick, 0), COALESCE(i.masterImage, 0)
                FROM Adobe_images i JOIN AgLibraryFile l ON i.rootFile = l.id_local
                JOIN AgLibraryFolder f ON l.folder = f.id_local JOIN AgLibraryRootFolder r ON f.rootFolder = r.id_local
                ORDER BY COALESCE(i.masterImage, 0), i.id_local""", -1, out st);
            while (st.step() == Sqlite.ROW) {
                int64 image_id = st.column_int64(0);
                string root = st.column_text(1) ?? "";
                string rel = st.column_text(2) ?? "";
                string base_name = st.column_text(3) ?? "";
                string ext = st.column_text(4) ?? "";
                string path = root + rel + base_name + (ext != "" ? "." + ext : "");
                int64 master = st.column_int64(8);
                PhotoRecord? r = null;
                if (master != 0 && image_map.has_key(master)) {
                    r = catalog.create_virtual_copy(image_map[master]);
                } else {
                    r = catalog.find_path(path);
                    if (r == null) {
                        int64 size = 0, mtime = 0;
                        bool exists = FileUtils.test(path, FileTest.EXISTS);
                        if (exists) {
                            try {
                                var info = File.new_for_path(path).query_info("standard::size,time::modified", FileQueryInfoFlags.NONE);
                                size = info.get_size();
                                var dt = info.get_modification_date_time();
                                mtime = dt != null ? dt.to_unix() : 0;
                            } catch (Error e) {
                            }
                        }
                        bool changed_file;
                        r = catalog.upsert_file(path, size, mtime, out changed_file);
                        if (!exists) {
                            catalog.mark_missing(r, true);
                            report.missing++;
                        }
                    }
                }
                image_map[image_id] = r;
                report.photos++;
                double rating = st.column_double(5);
                if (rating > 0) {
                    r.rating = ((int) rating).clamp(0, 5);
                    report.ratings++;
                }
                string label = label_for(st.column_text(6) ?? "");
                if (label != "") {
                    r.label = label;
                    report.labels++;
                }
                double pick = st.column_double(7);
                if (pick != 0) {
                    r.flag = pick > 0 ? PickFlag.PICK : PickFlag.REJECT;
                    report.flags++;
                }
                catalog.save(r);
            }
            if (has_table(db, "AgLibraryKeyword") && has_table(db, "AgLibraryKeywordImage")) {
                var kw_map = new Gee.HashMap<int64?, int64?>(id_hash, id_equal);
                var pending = new Gee.ArrayList<int64?>();
                var names = new Gee.HashMap<int64?, string>(id_hash, id_equal);
                var parents = new Gee.HashMap<int64?, int64?>(id_hash, id_equal);
                db.prepare_v2("SELECT id_local, COALESCE(name, ''), COALESCE(parent, 0) FROM AgLibraryKeyword", -1, out st);
                while (st.step() == Sqlite.ROW) {
                    int64 id = st.column_int64(0);
                    names[id] = st.column_text(1) ?? "";
                    parents[id] = st.column_int64(2);
                    pending.add(id);
                }
                int guard = 0;
                while (pending.size > 0 && guard++ < 64) {
                    var next = new Gee.ArrayList<int64?>();
                    foreach (var id in pending) {
                        int64 parent = parents[id];
                        string name = names[id];
                        if (name == "") {
                            kw_map[id] = 0;
                            continue;
                        }
                        if (parent != 0 && !kw_map.has_key(parent)) {
                            next.add(id);
                            continue;
                        }
                        var k = catalog.ensure_keyword(name, parent != 0 ? kw_map[parent] : 0);
                        kw_map[id] = k.id;
                        report.keywords++;
                    }
                    pending = next;
                }
                db.prepare_v2("SELECT image, tag FROM AgLibraryKeywordImage", -1, out st);
                while (st.step() == Sqlite.ROW) {
                    var r = image_map[st.column_int64(0)];
                    int64? kid = kw_map[st.column_int64(1)];
                    if (r != null && kid != null && kid != 0) catalog.assign_keyword(r, kid);
                }
            }
            if (has_table(db, "AgLibraryCollection")) {
                var col_map = new Gee.HashMap<int64?, CollectionRecord>(id_hash, id_equal);
                var rows = new Gee.ArrayList<int64?>();
                var names = new Gee.HashMap<int64?, string>(id_hash, id_equal);
                var kinds = new Gee.HashMap<int64?, string>(id_hash, id_equal);
                var parents = new Gee.HashMap<int64?, int64?>(id_hash, id_equal);
                db.prepare_v2("SELECT id_local, COALESCE(name, ''), COALESCE(creationId, ''), COALESCE(parent, 0) FROM AgLibraryCollection", -1, out st);
                while (st.step() == Sqlite.ROW) {
                    int64 id = st.column_int64(0);
                    string creation = st.column_text(2) ?? "";
                    if (creation.has_prefix("com.adobe.ag.library.") == false && creation != "") continue;
                    if (creation.contains("quick_collection") || creation.contains("publish")) continue;
                    names[id] = st.column_text(1) ?? "";
                    kinds[id] = creation.contains("smart") ? "smart" : (creation.contains("group") ? "set" : "manual");
                    parents[id] = st.column_int64(3);
                    rows.add(id);
                }
                int guard = 0;
                while (rows.size > 0 && guard++ < 64) {
                    var next = new Gee.ArrayList<int64?>();
                    foreach (var id in rows) {
                        int64 parent = parents[id];
                        if (parent != 0 && parents.has_key(parent) && !col_map.has_key(parent)) {
                            next.add(id);
                            continue;
                        }
                        int64 local_parent = parent != 0 && col_map.has_key(parent) ? col_map[parent].id : 0;
                        string kind = kinds[id];
                        var c = catalog.create_collection(names[id], kind == "smart" ? "manual" : kind, local_parent);
                        col_map[id] = c;
                        if (kind == "smart") report.smart_collections++;
                        else if (kind == "manual") report.collections++;
                    }
                    rows = next;
                }
                if (has_table(db, "AgLibraryCollectionImage")) {
                    db.prepare_v2("SELECT collection, image FROM AgLibraryCollectionImage ORDER BY COALESCE(positionInCollection, 0)", -1, out st);
                    while (st.step() == Sqlite.ROW) {
                        var c = col_map[st.column_int64(0)];
                        var r = image_map[st.column_int64(1)];
                        if (c != null && r != null) catalog.add_to_collection(c, r);
                    }
                }
                if (has_table(db, "AgLibraryCollectionContent")) {
                    db.prepare_v2("SELECT collection, COALESCE(content, '') FROM AgLibraryCollectionContent WHERE owningModule = 'ag.library.smart_collection'", -1, out st);
                    while (st.step() == Sqlite.ROW) {
                        var c = col_map[st.column_int64(0)];
                        if (c == null) continue;
                        var rules = rules_from_lua(st.column_text(1) ?? "");
                        if (rules.rules.size == 0) continue;
                        c.kind = "smart";
                        c.rules = rules.to_json();
                        catalog.update_collection(c);
                    }
                }
            }
            catalog.commit();
            return report;
        }

        public static SmartRules rules_from_lua(string lua) {
            var rules = new SmartRules();
            rules.match_all = !lua.contains("combine = \"union\"");
            try {
                var re = new Regex("criteria = \"([a-zA-Z]+)\",\\s*operation = \"([^\"]+)\",\\s*(?:value = \"?([^\",}]*)\"?)?");
                MatchInfo mi;
                if (re.match(lua, 0, out mi)) {
                    do {
                        string crit = mi.fetch(1);
                        string op = mi.fetch(2);
                        string val = mi.fetch(3) ?? "";
                        switch (crit) {
                            case "rating":
                                string o = op == "<=" ? "<=" : (op == "==" ? "==" : (op == "!=" ? "!=" : ">="));
                                rules.rules.add(new SmartRule("rating", o, val));
                                break;
                            case "pick":
                                rules.rules.add(new SmartRule("flag", op == "!=" ? "not" : "is", val == "1" ? "pick" : (val == "-1" ? "reject" : "none")));
                                break;
                            case "labelColor":
                                rules.rules.add(new SmartRule("label", op == "!=" ? "not" : "is", val.down()));
                                break;
                            case "keywords":
                                rules.rules.add(new SmartRule("keyword", op == "noneOf" ? "not" : "contains", val));
                                break;
                            case "camera":
                                rules.rules.add(new SmartRule("camera", "contains", val));
                                break;
                            case "lens":
                                rules.rules.add(new SmartRule("lens", "contains", val));
                                break;
                            case "all":
                                rules.rules.add(new SmartRule("text", "contains", val));
                                break;
                            default:
                                break;
                        }
                    } while (mi.next());
                }
            } catch (Error e) {
            }
            return rules;
        }
    }
}
