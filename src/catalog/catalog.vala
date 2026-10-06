namespace Singularity.Apps.Photos {

    public errordomain CatalogError {
        OPEN,
        QUERY
    }

    public class Catalog : Object {
        public const int SCHEMA_VERSION = 1;

        private const string PHOTO_COLUMNS = "id, path, master_id, copy_name, folder_id, size, mtime, hash, rating, flag, label, kind, captured, added, edited, missing, stack_id, stack_pos, camera, lens, iso, aperture, exposure, focal, has_gps, latitude, longitude, title, caption, creator, copyright, location, city, country, meta, meta_mtime";

        private Sqlite.Database db;
        public string db_path { get; private set; }

        public Gee.HashMap<int64?, PhotoRecord> photos = new Gee.HashMap<int64?, PhotoRecord>(id_hash, id_equal);
        public Gee.HashMap<string, PhotoRecord> by_path = new Gee.HashMap<string, PhotoRecord>();
        public Gee.HashMap<int64?, FolderRecord> folders = new Gee.HashMap<int64?, FolderRecord>(id_hash, id_equal);
        public Gee.HashMap<int64?, CollectionRecord> collections = new Gee.HashMap<int64?, CollectionRecord>(id_hash, id_equal);
        public Gee.HashMap<int64?, Gee.ArrayList<int64?>> members = new Gee.HashMap<int64?, Gee.ArrayList<int64?>>(id_hash, id_equal);
        public Gee.HashMap<int64?, KeywordRecord> keywords = new Gee.HashMap<int64?, KeywordRecord>(id_hash, id_equal);
        public Gee.HashMap<int64?, KeywordSet> keyword_sets = new Gee.HashMap<int64?, KeywordSet>(id_hash, id_equal);
        public Gee.HashMap<int64?, FaceRecord> faces = new Gee.HashMap<int64?, FaceRecord>(id_hash, id_equal);
        public Gee.HashMap<int64?, PersonRecord> people = new Gee.HashMap<int64?, PersonRecord>(id_hash, id_equal);

        public signal void changed();
        public signal void photo_changed(PhotoRecord record);

        private int batch_depth = 0;
        private bool pending_change = false;

        private static Catalog? instance = null;

        public static string default_path() {
            return Path.build_filename(Environment.get_user_data_dir(), "singularity-photos", "catalog.db");
        }

        public static Catalog get_default() {
            if (instance == null) {
                try {
                    instance = new Catalog(default_path());
                } catch (Error e) {
                    warning("Photos: catalog unavailable, using memory: %s", e.message);
                    try {
                        instance = new Catalog(":memory:");
                    } catch (Error e2) {
                        error("Photos: %s", e2.message);
                    }
                }
            }
            return instance;
        }

        public Catalog(string path) throws Error {
            db_path = path;
            if (path != ":memory:") DirUtils.create_with_parents(Path.get_dirname(path), 0755);
            if (Sqlite.Database.open_v2(path, out db, Sqlite.OPEN_READWRITE | Sqlite.OPEN_CREATE | Sqlite.OPEN_FULLMUTEX) != Sqlite.OK)
                throw new CatalogError.OPEN("Cannot open %s", path);
            exec("PRAGMA journal_mode=WAL");
            exec("PRAGMA synchronous=NORMAL");
            exec("PRAGMA foreign_keys=OFF");
            create_schema();
            load();
        }

        private void exec(string sql) throws Error {
            string? err;
            if (db.exec(sql, null, out err) != Sqlite.OK) throw new CatalogError.QUERY("%s: %s", err ?? "", sql);
        }

        private void run(string sql) {
            try {
                exec(sql);
            } catch (Error e) {
                warning("Photos catalog: %s", e.message);
            }
        }

        private Sqlite.Statement prepare(string sql) {
            Sqlite.Statement stmt;
            if (db.prepare_v2(sql, -1, out stmt) != Sqlite.OK) warning("Photos catalog: %s: %s", db.errmsg(), sql);
            return stmt;
        }

        private void create_schema() throws Error {
            exec("""CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE IF NOT EXISTS folders (id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, parent_id INTEGER DEFAULT 0);
                CREATE TABLE IF NOT EXISTS photos (id INTEGER PRIMARY KEY, path TEXT NOT NULL, master_id INTEGER DEFAULT 0, copy_name TEXT DEFAULT '',
                    folder_id INTEGER DEFAULT 0, size INTEGER DEFAULT 0, mtime INTEGER DEFAULT 0, hash TEXT DEFAULT '', rating INTEGER DEFAULT 0,
                    flag INTEGER DEFAULT 0, label TEXT DEFAULT '', kind TEXT DEFAULT 'photo', captured INTEGER DEFAULT 0, added INTEGER DEFAULT 0,
                    edited INTEGER DEFAULT 0, missing INTEGER DEFAULT 0, stack_id INTEGER DEFAULT 0, stack_pos INTEGER DEFAULT 0,
                    camera TEXT DEFAULT '', lens TEXT DEFAULT '', iso INTEGER DEFAULT 0, aperture REAL DEFAULT 0, exposure REAL DEFAULT 0,
                    focal REAL DEFAULT 0, has_gps INTEGER DEFAULT 0, latitude REAL DEFAULT 0, longitude REAL DEFAULT 0, title TEXT DEFAULT '',
                    caption TEXT DEFAULT '', creator TEXT DEFAULT '', copyright TEXT DEFAULT '', location TEXT DEFAULT '', city TEXT DEFAULT '',
                    country TEXT DEFAULT '', meta TEXT DEFAULT '', meta_mtime INTEGER DEFAULT 0);
                CREATE INDEX IF NOT EXISTS photos_path ON photos(path);
                CREATE INDEX IF NOT EXISTS photos_hash ON photos(hash);
                CREATE INDEX IF NOT EXISTS photos_captured ON photos(captured);
                CREATE INDEX IF NOT EXISTS photos_folder ON photos(folder_id);
                CREATE TABLE IF NOT EXISTS collections (id INTEGER PRIMARY KEY, name TEXT NOT NULL, kind TEXT DEFAULT 'manual', parent_id INTEGER DEFAULT 0,
                    rules TEXT DEFAULT '', position INTEGER DEFAULT 0);
                CREATE TABLE IF NOT EXISTS collection_photos (collection_id INTEGER, photo_id INTEGER, position INTEGER DEFAULT 0,
                    PRIMARY KEY (collection_id, photo_id));
                CREATE TABLE IF NOT EXISTS keywords (id INTEGER PRIMARY KEY, name TEXT NOT NULL, parent_id INTEGER DEFAULT 0, synonyms TEXT DEFAULT '',
                    UNIQUE (name, parent_id));
                CREATE TABLE IF NOT EXISTS photo_keywords (photo_id INTEGER, keyword_id INTEGER, PRIMARY KEY (photo_id, keyword_id));
                CREATE INDEX IF NOT EXISTS photo_keywords_kw ON photo_keywords(keyword_id);
                CREATE TABLE IF NOT EXISTS keyword_sets (id INTEGER PRIMARY KEY, name TEXT NOT NULL, keywords TEXT DEFAULT '');
                CREATE TABLE IF NOT EXISTS people (id INTEGER PRIMARY KEY, name TEXT DEFAULT '');
                CREATE TABLE IF NOT EXISTS faces (id INTEGER PRIMARY KEY, photo_id INTEGER, x REAL, y REAL, w REAL, h REAL, descriptor TEXT DEFAULT '',
                    person_id INTEGER DEFAULT 0);
                CREATE INDEX IF NOT EXISTS faces_photo ON faces(photo_id);""");
            if (!has_column("faces", "state")) exec("ALTER TABLE faces ADD COLUMN state INTEGER DEFAULT 0");
            var st = prepare("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema', ?)");
            st.bind_text(1, SCHEMA_VERSION.to_string());
            st.step();
        }

        private bool has_column(string table, string column) {
            var st = prepare("PRAGMA table_info(" + table + ")");
            while (st.step() == Sqlite.ROW) if (st.column_text(1) == column) return true;
            return false;
        }

        public string? get_meta(string key) {
            var st = prepare("SELECT value FROM meta WHERE key = ?");
            st.bind_text(1, key);
            if (st.step() == Sqlite.ROW) return st.column_text(0);
            return null;
        }

        public void set_meta(string key, string value) {
            var st = prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)");
            st.bind_text(1, key);
            st.bind_text(2, value);
            st.step();
        }

        private void load() {
            var st = prepare("SELECT " + PHOTO_COLUMNS + " FROM photos");
            while (st.step() == Sqlite.ROW) {
                var r = new PhotoRecord();
                int c = 0;
                r.id = st.column_int64(c++);
                r.path = st.column_text(c++) ?? "";
                r.master_id = st.column_int64(c++);
                r.copy_name = st.column_text(c++) ?? "";
                r.folder_id = st.column_int64(c++);
                r.size = st.column_int64(c++);
                r.mtime = st.column_int64(c++);
                r.hash = st.column_text(c++) ?? "";
                r.rating = st.column_int(c++);
                r.flag = st.column_int(c++);
                r.label = st.column_text(c++) ?? "";
                r.kind = st.column_text(c++) ?? "photo";
                r.captured = st.column_int64(c++);
                r.added = st.column_int64(c++);
                r.edited = st.column_int(c++) != 0;
                r.missing = st.column_int(c++) != 0;
                r.stack_id = st.column_int64(c++);
                r.stack_pos = st.column_int(c++);
                r.camera = st.column_text(c++) ?? "";
                r.lens = st.column_text(c++) ?? "";
                r.iso = st.column_int(c++);
                r.aperture = st.column_double(c++);
                r.exposure = st.column_double(c++);
                r.focal = st.column_double(c++);
                r.has_gps = st.column_int(c++) != 0;
                r.latitude = st.column_double(c++);
                r.longitude = st.column_double(c++);
                r.title = st.column_text(c++) ?? "";
                r.caption = st.column_text(c++) ?? "";
                r.creator = st.column_text(c++) ?? "";
                r.copyright = st.column_text(c++) ?? "";
                r.location = st.column_text(c++) ?? "";
                r.city = st.column_text(c++) ?? "";
                r.country = st.column_text(c++) ?? "";
                r.meta_json = st.column_text(c++) ?? "";
                r.meta_mtime = st.column_int64(c++);
                photos[r.id] = r;
                if (r.master_id == 0) by_path[r.path] = r;
            }
            st = prepare("SELECT id, path, parent_id FROM folders");
            while (st.step() == Sqlite.ROW) {
                var f = new FolderRecord();
                f.id = st.column_int64(0);
                f.path = st.column_text(1) ?? "";
                f.parent_id = st.column_int64(2);
                folders[f.id] = f;
            }
            st = prepare("SELECT id, name, kind, parent_id, rules, position FROM collections");
            while (st.step() == Sqlite.ROW) {
                var c = new CollectionRecord();
                c.id = st.column_int64(0);
                c.name = st.column_text(1) ?? "";
                c.kind = st.column_text(2) ?? "manual";
                c.parent_id = st.column_int64(3);
                c.rules = st.column_text(4) ?? "";
                c.position = st.column_int(5);
                collections[c.id] = c;
                members[c.id] = new Gee.ArrayList<int64?>();
            }
            st = prepare("SELECT collection_id, photo_id FROM collection_photos ORDER BY position");
            while (st.step() == Sqlite.ROW) {
                var list = members[st.column_int64(0)];
                if (list != null) list.add(st.column_int64(1));
            }
            st = prepare("SELECT id, name, parent_id, synonyms FROM keywords");
            while (st.step() == Sqlite.ROW) {
                var k = new KeywordRecord();
                k.id = st.column_int64(0);
                k.name = st.column_text(1) ?? "";
                k.parent_id = st.column_int64(2);
                k.synonyms = st.column_text(3) ?? "";
                keywords[k.id] = k;
            }
            st = prepare("SELECT photo_id, keyword_id FROM photo_keywords");
            while (st.step() == Sqlite.ROW) {
                var r = photos[st.column_int64(0)];
                if (r != null) r.keywords.add(st.column_int64(1));
            }
            st = prepare("SELECT id, name, keywords FROM keyword_sets");
            while (st.step() == Sqlite.ROW) {
                var ks = new KeywordSet();
                ks.id = st.column_int64(0);
                ks.name = st.column_text(1) ?? "";
                ks.keywords = (st.column_text(2) ?? "").split("\n");
                keyword_sets[ks.id] = ks;
            }
            st = prepare("SELECT id, name FROM people");
            while (st.step() == Sqlite.ROW) {
                var p = new PersonRecord();
                p.id = st.column_int64(0);
                p.name = st.column_text(1) ?? "";
                people[p.id] = p;
            }
            st = prepare("SELECT id, photo_id, x, y, w, h, descriptor, person_id, state FROM faces");
            while (st.step() == Sqlite.ROW) {
                var f = new FaceRecord();
                f.id = st.column_int64(0);
                f.photo_id = st.column_int64(1);
                f.x = st.column_double(2);
                f.y = st.column_double(3);
                f.width = st.column_double(4);
                f.height = st.column_double(5);
                f.descriptor = decode_floats(st.column_text(6) ?? "");
                f.person_id = st.column_int64(7);
                f.state = st.column_int(8);
                faces[f.id] = f;
            }
        }

        public void begin() {
            if (batch_depth++ == 0) run("BEGIN");
        }

        public void commit() {
            if (batch_depth == 0) return;
            if (--batch_depth == 0) {
                run("COMMIT");
                if (pending_change) {
                    pending_change = false;
                    changed();
                }
            }
        }

        private void notify_changed() {
            if (batch_depth > 0) pending_change = true;
            else changed();
        }

        public FolderRecord ensure_folder(string path) {
            foreach (var f in folders.values) if (f.path == path) return f;
            int64 parent = 0;
            string? parent_path = Path.get_dirname(path);
            foreach (var f in folders.values) if (f.path == parent_path) parent = f.id;
            var st = prepare("INSERT INTO folders (path, parent_id) VALUES (?, ?)");
            st.bind_text(1, path);
            st.bind_int64(2, parent);
            st.step();
            var rec = new FolderRecord();
            rec.id = db.last_insert_rowid();
            rec.path = path;
            rec.parent_id = parent;
            folders[rec.id] = rec;
            foreach (var f in folders.values) {
                if (f.parent_id == 0 && f.id != rec.id && Path.get_dirname(f.path) == path) {
                    f.parent_id = rec.id;
                    var up = prepare("UPDATE folders SET parent_id = ? WHERE id = ?");
                    up.bind_int64(1, rec.id);
                    up.bind_int64(2, f.id);
                    up.step();
                }
            }
            return rec;
        }

        public FolderRecord? folder_for_path(string path) {
            foreach (var f in folders.values) if (f.path == path) return f;
            return null;
        }

        public void remove_folder(FolderRecord folder) {
            var st = prepare("DELETE FROM folders WHERE id = ?");
            st.bind_int64(1, folder.id);
            st.step();
            folders.unset(folder.id);
            notify_changed();
        }

        public static string kind_for(string name) {
            if (Codecs.is_raw_name(name)) return "raw";
            string n = name.down();
            if (n.has_suffix(".mp4") || n.has_suffix(".mov") || n.has_suffix(".webm") || n.has_suffix(".mkv")) return "video";
            return "photo";
        }

        public PhotoRecord upsert_file(string path, int64 size, int64 mtime, out bool changed_file) {
            changed_file = false;
            var existing = by_path[path];
            if (existing != null) {
                if (existing.size != size || existing.mtime != mtime || existing.missing) {
                    existing.size = size;
                    existing.mtime = mtime;
                    existing.missing = false;
                    existing.hash = "";
                    changed_file = true;
                    save(existing);
                }
                return existing;
            }
            var r = new PhotoRecord();
            r.path = path;
            r.size = size;
            r.mtime = mtime;
            r.captured = mtime;
            r.added = get_real_time() / 1000000;
            r.kind = kind_for(path);
            r.folder_id = ensure_folder(Path.get_dirname(path)).id;
            insert(r);
            changed_file = true;
            return r;
        }

        private void insert(PhotoRecord r) {
            var st = prepare("INSERT INTO photos (path) VALUES (?)");
            st.bind_text(1, r.path);
            st.step();
            r.id = db.last_insert_rowid();
            photos[r.id] = r;
            if (r.master_id == 0) by_path[r.path] = r;
            save(r);
        }

        public void save(PhotoRecord r) {
            var st = prepare("""UPDATE photos SET path = ?, master_id = ?, copy_name = ?, folder_id = ?, size = ?, mtime = ?, hash = ?, rating = ?,
                flag = ?, label = ?, kind = ?, captured = ?, added = ?, edited = ?, missing = ?, stack_id = ?, stack_pos = ?, camera = ?, lens = ?,
                iso = ?, aperture = ?, exposure = ?, focal = ?, has_gps = ?, latitude = ?, longitude = ?, title = ?, caption = ?, creator = ?,
                copyright = ?, location = ?, city = ?, country = ?, meta = ?, meta_mtime = ? WHERE id = ?""");
            int c = 1;
            st.bind_text(c++, r.path);
            st.bind_int64(c++, r.master_id);
            st.bind_text(c++, r.copy_name);
            st.bind_int64(c++, r.folder_id);
            st.bind_int64(c++, r.size);
            st.bind_int64(c++, r.mtime);
            st.bind_text(c++, r.hash);
            st.bind_int(c++, r.rating);
            st.bind_int(c++, r.flag);
            st.bind_text(c++, r.label);
            st.bind_text(c++, r.kind);
            st.bind_int64(c++, r.captured);
            st.bind_int64(c++, r.added);
            st.bind_int(c++, r.edited ? 1 : 0);
            st.bind_int(c++, r.missing ? 1 : 0);
            st.bind_int64(c++, r.stack_id);
            st.bind_int(c++, r.stack_pos);
            st.bind_text(c++, r.camera);
            st.bind_text(c++, r.lens);
            st.bind_int(c++, r.iso);
            st.bind_double(c++, r.aperture);
            st.bind_double(c++, r.exposure);
            st.bind_double(c++, r.focal);
            st.bind_int(c++, r.has_gps ? 1 : 0);
            st.bind_double(c++, r.latitude);
            st.bind_double(c++, r.longitude);
            st.bind_text(c++, r.title);
            st.bind_text(c++, r.caption);
            st.bind_text(c++, r.creator);
            st.bind_text(c++, r.copyright);
            st.bind_text(c++, r.location);
            st.bind_text(c++, r.city);
            st.bind_text(c++, r.country);
            st.bind_text(c++, r.meta_json);
            st.bind_int64(c++, r.meta_mtime);
            st.bind_int64(c++, r.id);
            st.step();
            photo_changed(r);
            notify_changed();
        }

        public PhotoRecord? find_path(string path) {
            return by_path[path];
        }

        public PhotoRecord? get_photo(int64 id) {
            return photos[id];
        }

        public void remove_photo(PhotoRecord r) {
            foreach (var sql in new string[] { "DELETE FROM photos WHERE id = ?", "DELETE FROM photo_keywords WHERE photo_id = ?",
                                               "DELETE FROM collection_photos WHERE photo_id = ?", "DELETE FROM faces WHERE photo_id = ?" }) {
                var st = prepare(sql);
                st.bind_int64(1, r.id);
                st.step();
            }
            photos.unset(r.id);
            if (by_path[r.path] == r) by_path.unset(r.path);
            foreach (var list in members.values) list.remove(r.id);
            var drop = new Gee.ArrayList<int64?>();
            foreach (var f in faces.values) if (f.photo_id == r.id) drop.add(f.id);
            foreach (var id in drop) faces.unset(id);
            if (r.master_id == 0) {
                var copies = new Gee.ArrayList<PhotoRecord>();
                foreach (var p in photos.values) if (p.master_id == r.id) copies.add(p);
                foreach (var p in copies) remove_photo(p);
            }
            notify_changed();
        }

        public void set_rating(PhotoRecord r, int rating) {
            r.rating = rating.clamp(0, 5);
            save(r);
        }

        public void set_flag(PhotoRecord r, int flag) {
            r.flag = flag.clamp(-1, 1);
            save(r);
        }

        public void set_label(PhotoRecord r, string label) {
            r.label = r.label == label ? "" : label;
            save(r);
        }

        public void mark_missing(PhotoRecord r, bool missing) {
            if (r.missing == missing) return;
            r.missing = missing;
            save(r);
            foreach (var p in photos.values) if (p.master_id == r.id && p.missing != missing) {
                p.missing = missing;
                save(p);
            }
        }

        public void relink(PhotoRecord r, string new_path) {
            by_path.unset(r.path);
            string old = r.path;
            r.path = new_path;
            r.missing = false;
            r.folder_id = ensure_folder(Path.get_dirname(new_path)).id;
            by_path[new_path] = r;
            save(r);
            foreach (var p in photos.values) if (p.master_id == r.id) {
                p.path = new_path;
                p.missing = false;
                p.folder_id = r.folder_id;
                save(p);
            }
            if (old != new_path) notify_changed();
        }

        public Gee.ArrayList<PhotoRecord> missing_photos() {
            var list = new Gee.ArrayList<PhotoRecord>();
            foreach (var r in photos.values) if (r.missing && r.master_id == 0) list.add(r);
            return list;
        }

        public string ensure_hash(PhotoRecord r) {
            if (r.hash != "") return r.hash;
            r.hash = file_hash(r.path) ?? "";
            if (r.hash != "") save(r);
            return r.hash;
        }

        public static string? file_hash(string path) {
            try {
                var file = File.new_for_path(path);
                var stream = file.read();
                var sum = new Checksum(ChecksumType.SHA256);
                var buf = new uint8[65536];
                ssize_t n;
                while ((n = stream.read(buf)) > 0) sum.update(buf, n);
                return sum.get_string();
            } catch (Error e) {
                return null;
            }
        }

        public PhotoRecord? find_duplicate(string hash, int64 size) {
            foreach (var r in photos.values) {
                if (r.master_id != 0 || r.size != size || r.missing) continue;
                if (ensure_hash(r) == hash) return r;
            }
            return null;
        }

        public Gee.ArrayList<Gee.ArrayList<PhotoRecord>> duplicate_groups() {
            var by_size = new Gee.HashMap<int64?, Gee.ArrayList<PhotoRecord>>(id_hash, id_equal);
            foreach (var r in photos.values) {
                if (r.master_id != 0 || r.missing) continue;
                if (!by_size.has_key(r.size)) by_size[r.size] = new Gee.ArrayList<PhotoRecord>();
                by_size[r.size].add(r);
            }
            var groups = new Gee.ArrayList<Gee.ArrayList<PhotoRecord>>();
            foreach (var list in by_size.values) {
                if (list.size < 2) continue;
                var by_hash = new Gee.HashMap<string, Gee.ArrayList<PhotoRecord>>();
                foreach (var r in list) {
                    string h = ensure_hash(r);
                    if (h == "") continue;
                    if (!by_hash.has_key(h)) by_hash[h] = new Gee.ArrayList<PhotoRecord>();
                    by_hash[h].add(r);
                }
                foreach (var g in by_hash.values) if (g.size > 1) groups.add(g);
            }
            return groups;
        }

        public PhotoRecord create_virtual_copy(PhotoRecord master) {
            var m = master.master_id != 0 ? photos[master.master_id] ?? master : master;
            int n = 1;
            foreach (var p in photos.values) if (p.master_id == m.id) n++;
            var r = new PhotoRecord();
            r.path = m.path;
            r.master_id = m.id;
            r.copy_name = _("Copy %d").printf(n);
            r.folder_id = m.folder_id;
            r.size = m.size;
            r.mtime = m.mtime;
            r.hash = m.hash;
            r.kind = m.kind;
            r.captured = m.captured;
            r.added = get_real_time() / 1000000;
            r.camera = m.camera;
            r.lens = m.lens;
            r.iso = m.iso;
            r.aperture = m.aperture;
            r.exposure = m.exposure;
            r.focal = m.focal;
            r.has_gps = m.has_gps;
            r.latitude = m.latitude;
            r.longitude = m.longitude;
            r.meta_json = m.meta_json;
            r.meta_mtime = m.meta_mtime;
            insert(r);
            if (m.stack_id == 0) {
                stack(new PhotoRecord[] { m, r });
            } else {
                r.stack_id = m.stack_id;
                r.stack_pos = stack_members(m.stack_id).size;
                save(r);
            }
            foreach (var k in m.keywords) assign_keyword(r, k);
            return r;
        }

        public Gee.ArrayList<PhotoRecord> virtual_copies(PhotoRecord master) {
            var list = new Gee.ArrayList<PhotoRecord>();
            foreach (var p in photos.values) if (p.master_id == master.id) list.add(p);
            return list;
        }

        public int64 stack(PhotoRecord[] records) {
            if (records.length < 2) return 0;
            int64 sid = 0;
            foreach (var r in records) if (r.stack_id != 0) { sid = r.stack_id; break; }
            if (sid == 0) {
                sid = 1;
                foreach (var p in photos.values) sid = int64.max(sid, p.stack_id + 1);
            }
            int pos = stack_members(sid).size;
            begin();
            foreach (var r in records) {
                if (r.stack_id == sid) continue;
                r.stack_id = sid;
                r.stack_pos = pos++;
                save(r);
            }
            commit();
            return sid;
        }

        public void unstack(int64 sid) {
            begin();
            foreach (var r in stack_members(sid)) {
                r.stack_id = 0;
                r.stack_pos = 0;
                save(r);
            }
            commit();
        }

        public void set_stack_top(PhotoRecord top) {
            if (top.stack_id == 0) return;
            var list = stack_members(top.stack_id);
            begin();
            int pos = 1;
            foreach (var r in list) {
                r.stack_pos = r == top ? 0 : pos++;
                save(r);
            }
            commit();
        }

        public Gee.ArrayList<PhotoRecord> stack_members(int64 sid) {
            var list = new Gee.ArrayList<PhotoRecord>();
            if (sid == 0) return list;
            foreach (var p in photos.values) if (p.stack_id == sid) list.add(p);
            list.sort((a, b) => a.stack_pos - b.stack_pos);
            return list;
        }

        public CollectionRecord create_collection(string name, string kind, int64 parent_id = 0, string rules = "") {
            var st = prepare("INSERT INTO collections (name, kind, parent_id, rules, position) VALUES (?, ?, ?, ?, ?)");
            st.bind_text(1, name);
            st.bind_text(2, kind);
            st.bind_int64(3, parent_id);
            st.bind_text(4, rules);
            st.bind_int(5, collections.size);
            st.step();
            var c = new CollectionRecord();
            c.id = db.last_insert_rowid();
            c.name = name;
            c.kind = kind;
            c.parent_id = parent_id;
            c.rules = rules;
            c.position = collections.size;
            collections[c.id] = c;
            members[c.id] = new Gee.ArrayList<int64?>();
            notify_changed();
            return c;
        }

        public void update_collection(CollectionRecord c) {
            var st = prepare("UPDATE collections SET name = ?, kind = ?, parent_id = ?, rules = ?, position = ? WHERE id = ?");
            st.bind_text(1, c.name);
            st.bind_text(2, c.kind);
            st.bind_int64(3, c.parent_id);
            st.bind_text(4, c.rules);
            st.bind_int(5, c.position);
            st.bind_int64(6, c.id);
            st.step();
            notify_changed();
        }

        public void delete_collection(CollectionRecord c) {
            foreach (var child in collections.values.to_array()) if (child.parent_id == c.id) delete_collection(child);
            var st = prepare("DELETE FROM collections WHERE id = ?");
            st.bind_int64(1, c.id);
            st.step();
            st = prepare("DELETE FROM collection_photos WHERE collection_id = ?");
            st.bind_int64(1, c.id);
            st.step();
            collections.unset(c.id);
            members.unset(c.id);
            notify_changed();
        }

        public void add_to_collection(CollectionRecord c, PhotoRecord r) {
            var list = members[c.id];
            if (list == null || c.kind != "manual" || list.contains(r.id)) return;
            var st = prepare("INSERT OR IGNORE INTO collection_photos (collection_id, photo_id, position) VALUES (?, ?, ?)");
            st.bind_int64(1, c.id);
            st.bind_int64(2, r.id);
            st.bind_int(3, list.size);
            st.step();
            list.add(r.id);
            notify_changed();
        }

        public void remove_from_collection(CollectionRecord c, PhotoRecord r) {
            var list = members[c.id];
            if (list == null) return;
            var st = prepare("DELETE FROM collection_photos WHERE collection_id = ? AND photo_id = ?");
            st.bind_int64(1, c.id);
            st.bind_int64(2, r.id);
            st.step();
            list.remove(r.id);
            notify_changed();
        }

        public Gee.ArrayList<PhotoRecord> collection_photos(CollectionRecord c) {
            var out_list = new Gee.ArrayList<PhotoRecord>();
            if (c.is_smart()) {
                var rules = SmartRules.parse(c.rules);
                foreach (var r in photos.values) if (rules.matches(r, this)) out_list.add(r);
                return out_list;
            }
            if (c.is_set()) {
                var seen = new Gee.HashSet<int64?>(id_hash, id_equal);
                foreach (var child in collections.values) {
                    if (child.parent_id != c.id) continue;
                    foreach (var r in collection_photos(child)) if (seen.add(r.id)) out_list.add(r);
                }
                return out_list;
            }
            var list = members[c.id];
            if (list == null) return out_list;
            foreach (var id in list) {
                var r = photos[id];
                if (r != null) out_list.add(r);
            }
            return out_list;
        }

        public Gee.ArrayList<CollectionRecord> child_collections(int64 parent_id) {
            var list = new Gee.ArrayList<CollectionRecord>();
            foreach (var c in collections.values) if (c.parent_id == parent_id) list.add(c);
            list.sort((a, b) => a.position != b.position ? a.position - b.position : strcmp(a.name, b.name));
            return list;
        }

        public KeywordRecord ensure_keyword(string name, int64 parent_id = 0) {
            string clean = name.strip();
            foreach (var k in keywords.values) if (k.parent_id == parent_id && k.name == clean) return k;
            var st = prepare("INSERT INTO keywords (name, parent_id) VALUES (?, ?)");
            st.bind_text(1, clean);
            st.bind_int64(2, parent_id);
            st.step();
            var k = new KeywordRecord();
            k.id = db.last_insert_rowid();
            k.name = clean;
            k.parent_id = parent_id;
            keywords[k.id] = k;
            notify_changed();
            return k;
        }

        public KeywordRecord ensure_keyword_path(string path) {
            int64 parent = 0;
            KeywordRecord? k = null;
            foreach (var part in path.split("|")) {
                if (part.strip() == "") continue;
                k = ensure_keyword(part, parent);
                parent = k.id;
            }
            return k ?? ensure_keyword(path);
        }

        public KeywordRecord? find_keyword(string name) {
            string n = name.strip().down();
            foreach (var k in keywords.values) if (k.name.down() == n) return k;
            foreach (var k in keywords.values) {
                foreach (var syn in k.synonyms.split(",")) if (syn.strip().down() == n && n != "") return k;
            }
            return null;
        }

        public string keyword_path(int64 id) {
            var parts = new Gee.ArrayList<string>();
            var k = keywords[id];
            int guard = 0;
            while (k != null && guard++ < 64) {
                parts.insert(0, k.name);
                k = k.parent_id != 0 ? keywords[k.parent_id] : null;
            }
            return string.joinv("|", parts.to_array());
        }

        public Gee.ArrayList<KeywordRecord> child_keywords(int64 parent_id) {
            var list = new Gee.ArrayList<KeywordRecord>();
            foreach (var k in keywords.values) if (k.parent_id == parent_id) list.add(k);
            list.sort((a, b) => a.name.collate(b.name));
            return list;
        }

        public bool keyword_under(int64 id, int64 ancestor) {
            var k = keywords[id];
            int guard = 0;
            while (k != null && guard++ < 64) {
                if (k.id == ancestor) return true;
                k = k.parent_id != 0 ? keywords[k.parent_id] : null;
            }
            return false;
        }

        public void set_synonyms(KeywordRecord k, string synonyms) {
            k.synonyms = synonyms;
            var st = prepare("UPDATE keywords SET synonyms = ? WHERE id = ?");
            st.bind_text(1, synonyms);
            st.bind_int64(2, k.id);
            st.step();
        }

        public void rename_keyword(KeywordRecord k, string name) {
            k.name = name.strip();
            var st = prepare("UPDATE keywords SET name = ? WHERE id = ?");
            st.bind_text(1, k.name);
            st.bind_int64(2, k.id);
            st.step();
            notify_changed();
        }

        public void delete_keyword(KeywordRecord k) {
            foreach (var child in child_keywords(k.id)) delete_keyword(child);
            var st = prepare("DELETE FROM keywords WHERE id = ?");
            st.bind_int64(1, k.id);
            st.step();
            st = prepare("DELETE FROM photo_keywords WHERE keyword_id = ?");
            st.bind_int64(1, k.id);
            st.step();
            keywords.unset(k.id);
            foreach (var r in photos.values) r.keywords.remove(k.id);
            notify_changed();
        }

        public void assign_keyword(PhotoRecord r, int64 keyword_id) {
            if (r.keywords.contains(keyword_id)) return;
            var st = prepare("INSERT OR IGNORE INTO photo_keywords (photo_id, keyword_id) VALUES (?, ?)");
            st.bind_int64(1, r.id);
            st.bind_int64(2, keyword_id);
            st.step();
            r.keywords.add(keyword_id);
            photo_changed(r);
            notify_changed();
        }

        public void unassign_keyword(PhotoRecord r, int64 keyword_id) {
            var st = prepare("DELETE FROM photo_keywords WHERE photo_id = ? AND keyword_id = ?");
            st.bind_int64(1, r.id);
            st.bind_int64(2, keyword_id);
            st.step();
            r.keywords.remove(keyword_id);
            photo_changed(r);
            notify_changed();
        }

        public string[] keyword_names(PhotoRecord r) {
            var list = new Gee.ArrayList<string>();
            foreach (var id in r.keywords) {
                var k = keywords[id];
                if (k != null) list.add(k.name);
            }
            list.sort((a, b) => a.collate(b));
            return list.to_array();
        }

        public string[] keyword_paths(PhotoRecord r) {
            var list = new Gee.ArrayList<string>();
            foreach (var id in r.keywords) list.add(keyword_path(id));
            list.sort((a, b) => a.collate(b));
            return list.to_array();
        }

        public Gee.ArrayList<KeywordRecord> suggest_keywords(PhotoRecord r, int limit = 9) {
            var scores = new Gee.HashMap<int64?, int>(id_hash, id_equal);
            foreach (var other in photos.values) {
                if (other == r || other.keywords.size == 0) continue;
                int shared = 0;
                foreach (var k in r.keywords) if (other.keywords.contains(k)) shared++;
                int weight = shared * 4;
                if (other.folder_id == r.folder_id) weight += 2;
                if ((other.captured - r.captured).abs() < 3600 * 6) weight += 1;
                if (weight == 0) continue;
                foreach (var k in other.keywords) {
                    if (r.keywords.contains(k)) continue;
                    scores[k] = (scores.has_key(k) ? scores[k] : 0) + weight;
                }
            }
            var ids = new Gee.ArrayList<int64?>();
            ids.add_all(scores.keys);
            ids.sort((a, b) => scores[b] - scores[a]);
            var result = new Gee.ArrayList<KeywordRecord>();
            foreach (var id in ids) {
                if (result.size >= limit) break;
                var k = keywords[id];
                if (k != null) result.add(k);
            }
            if (result.size < limit) {
                var counts = new Gee.HashMap<int64?, int>(id_hash, id_equal);
                foreach (var other in photos.values) foreach (var k in other.keywords) counts[k] = (counts.has_key(k) ? counts[k] : 0) + 1;
                var all_ids = new Gee.ArrayList<int64?>();
                all_ids.add_all(counts.keys);
                all_ids.sort((a, b) => counts[b] - counts[a]);
                foreach (var id in all_ids) {
                    if (result.size >= limit) break;
                    var k = keywords[id];
                    if (k != null && !r.keywords.contains(id) && !result.contains(k)) result.add(k);
                }
            }
            return result;
        }

        public KeywordSet save_keyword_set(string name, string[] words) {
            foreach (var ks in keyword_sets.values) {
                if (ks.name == name) {
                    ks.keywords = words;
                    var up = prepare("UPDATE keyword_sets SET keywords = ? WHERE id = ?");
                    up.bind_text(1, string.joinv("\n", words));
                    up.bind_int64(2, ks.id);
                    up.step();
                    return ks;
                }
            }
            var st = prepare("INSERT INTO keyword_sets (name, keywords) VALUES (?, ?)");
            st.bind_text(1, name);
            st.bind_text(2, string.joinv("\n", words));
            st.step();
            var set = new KeywordSet();
            set.id = db.last_insert_rowid();
            set.name = name;
            set.keywords = words;
            keyword_sets[set.id] = set;
            return set;
        }

        public void delete_keyword_set(KeywordSet ks) {
            var st = prepare("DELETE FROM keyword_sets WHERE id = ?");
            st.bind_int64(1, ks.id);
            st.step();
            keyword_sets.unset(ks.id);
        }

        public static string encode_floats(float[] v) {
            var sb = new StringBuilder();
            foreach (var f in v) {
                if (sb.len > 0) sb.append_c(',');
                sb.append("%.5g".printf(f));
            }
            return sb.str;
        }

        public static float[] decode_floats(string s) {
            if (s == "") return {};
            var parts = s.split(",");
            var v = new float[parts.length];
            for (int i = 0; i < parts.length; i++) v[i] = (float) double.parse(parts[i]);
            return v;
        }

        public FaceRecord add_face(PhotoRecord r, FaceBox box, float[] descriptor) {
            var st = prepare("INSERT INTO faces (photo_id, x, y, w, h, descriptor, person_id) VALUES (?, ?, ?, ?, ?, ?, 0)");
            st.bind_int64(1, r.id);
            st.bind_double(2, box.x);
            st.bind_double(3, box.y);
            st.bind_double(4, box.width);
            st.bind_double(5, box.height);
            st.bind_text(6, encode_floats(descriptor));
            st.step();
            var f = new FaceRecord();
            f.id = db.last_insert_rowid();
            f.photo_id = r.id;
            f.x = box.x;
            f.y = box.y;
            f.width = box.width;
            f.height = box.height;
            f.descriptor = descriptor;
            faces[f.id] = f;
            return f;
        }

        public void set_face_person(FaceRecord f, int64 person_id) {
            f.person_id = person_id;
            var st = prepare("UPDATE faces SET person_id = ? WHERE id = ?");
            st.bind_int64(1, person_id);
            st.bind_int64(2, f.id);
            st.step();
            notify_changed();
        }

        public void set_face_state(FaceRecord f, int state) {
            f.state = state.clamp(-1, 1);
            if (f.state == -1) f.person_id = 0;
            var st = prepare("UPDATE faces SET state = ?, person_id = ? WHERE id = ?");
            st.bind_int(1, f.state);
            st.bind_int64(2, f.person_id);
            st.bind_int64(3, f.id);
            st.step();
            notify_changed();
        }

        public void move_face(FaceRecord f, int64 person_id) {
            f.person_id = person_id;
            f.state = person_id != 0 ? 1 : 0;
            var st = prepare("UPDATE faces SET state = ?, person_id = ? WHERE id = ?");
            st.bind_int(1, f.state);
            st.bind_int64(2, f.person_id);
            st.bind_int64(3, f.id);
            st.step();
            prune_people();
            notify_changed();
        }

        public Gee.ArrayList<FaceRecord> person_faces(int64 person_id) {
            var list = new Gee.ArrayList<FaceRecord>();
            foreach (var f in faces.values) if (f.person_id == person_id) list.add(f);
            list.sort((a, b) => a.state != b.state ? b.state - a.state : (a.id < b.id ? -1 : (a.id > b.id ? 1 : 0)));
            return list;
        }

        public Gee.ArrayList<PhotoRecord> person_photos(int64 person_id) {
            var ids = new Gee.HashSet<int64?>(id_hash, id_equal);
            foreach (var f in faces.values) if (f.person_id == person_id) ids.add(f.photo_id);
            var list = new Gee.ArrayList<PhotoRecord>();
            foreach (var id in ids) if (photos.has_key(id)) list.add(photos[id]);
            return list;
        }

        public PersonRecord? find_person(string name) {
            string n = name.strip().down();
            if (n == "") return null;
            foreach (var p in people.values) if (p.name.down() == n) return p;
            return null;
        }

        public void prune_people() {
            var used = new Gee.HashSet<int64?>(id_hash, id_equal);
            foreach (var f in faces.values) if (f.person_id != 0) used.add(f.person_id);
            foreach (var p in people.values.to_array()) {
                if (used.contains(p.id)) continue;
                var st = prepare("DELETE FROM people WHERE id = ?");
                st.bind_int64(1, p.id);
                st.step();
                people.unset(p.id);
            }
        }

        public PersonRecord create_person(string name) {
            var st = prepare("INSERT INTO people (name) VALUES (?)");
            st.bind_text(1, name);
            st.step();
            var p = new PersonRecord();
            p.id = db.last_insert_rowid();
            p.name = name;
            people[p.id] = p;
            notify_changed();
            return p;
        }

        public void rename_person(PersonRecord p, string name) {
            p.name = name;
            var st = prepare("UPDATE people SET name = ? WHERE id = ?");
            st.bind_text(1, name);
            st.bind_int64(2, p.id);
            st.step();
            notify_changed();
        }

        public void merge_people(PersonRecord into, PersonRecord from) {
            begin();
            foreach (var f in faces.values) if (f.person_id == from.id) set_face_person(f, into.id);
            var st = prepare("DELETE FROM people WHERE id = ?");
            st.bind_int64(1, from.id);
            st.step();
            people.unset(from.id);
            commit();
            notify_changed();
        }

        public bool faces_scanned(PhotoRecord r) {
            return get_meta("faces:" + r.id.to_string()) != null;
        }

        public void mark_faces_scanned(PhotoRecord r) {
            set_meta("faces:" + r.id.to_string(), "1");
        }

        public Gee.ArrayList<PhotoRecord> query(LibraryFilter filter) {
            var list = new Gee.ArrayList<PhotoRecord>();
            foreach (var r in photos.values) if (filter.matches(r, this)) list.add(r);
            filter.sort(list);
            return list;
        }

        public string[] distinct_values(string field) {
            var set = new Gee.TreeSet<string>((a, b) => a.collate(b));
            foreach (var r in photos.values) {
                string v = "";
                switch (field) {
                    case "camera": v = r.camera; break;
                    case "lens": v = r.lens; break;
                    case "city": v = r.city; break;
                    case "country": v = r.country; break;
                    case "location": v = r.location; break;
                    case "year":
                        var t = r.captured_time();
                        v = t != null ? t.get_year().to_string() : "";
                        break;
                    default: break;
                }
                if (v != "") set.add(v);
            }
            return set.to_array();
        }
    }
}
