namespace Singularity.Apps.Photos {

    public interface SyncRemote : Object {
        public abstract string id { owned get; }
        public abstract async Gee.Map<string, string> list(Cancellable? cancellable) throws Error;
        public abstract async Bytes download(string name, Cancellable? cancellable) throws Error;
        public abstract async string upload(string name, Bytes data, Cancellable? cancellable) throws Error;
    }

    public class FolderRemote : Object, SyncRemote {
        public string root { get; construct; }

        public FolderRemote(string root) {
            Object(root: root);
        }

        public string id {
            owned get { return "folder:" + root; }
        }

        private void walk(File dir, string prefix, Gee.Map<string, string> out_map) throws Error {
            var e = dir.enumerate_children(FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = e.next_file()) != null) {
                string name = info.get_name();
                var child = dir.get_child(name);
                string rel = prefix == "" ? name : prefix + "/" + name;
                if (info.get_file_type() == FileType.DIRECTORY) walk(child, rel, out_map);
                else if (!name.has_suffix(".part")) out_map[rel] = SyncEngine.hash_file(child);
            }
        }

        public async Gee.Map<string, string> list(Cancellable? cancellable) throws Error {
            var map = new Gee.HashMap<string, string>();
            var dir = File.new_for_path(root);
            if (dir.query_exists()) walk(dir, "", map);
            return map;
        }

        public async Bytes download(string name, Cancellable? cancellable) throws Error {
            uint8[] data;
            FileUtils.get_data(Path.build_filename(root, name), out data);
            return new Bytes.take((owned) data);
        }

        public async string upload(string name, Bytes data, Cancellable? cancellable) throws Error {
            string path = Path.build_filename(root, name);
            DirUtils.create_with_parents(Path.get_dirname(path), 0755);
            FileUtils.set_data(path + ".part", data.get_data());
            FileUtils.rename(path + ".part", path);
            return SyncEngine.hash_bytes(data);
        }
    }

    public class DavRemote : Object, SyncRemote {
        private WebDav dav;
        private string ident;

        public DavRemote(WebDav dav, string ident) {
            this.dav = dav;
            this.ident = ident;
        }

        public static DavRemote for_account(Singularity.Accounts.Account account) {
            return new DavRemote(WebDav.for_account(account, "Singularity Photos/Sync"), "dav:" + account.id);
        }

        public string id {
            owned get { return ident; }
        }

        public async Gee.Map<string, string> list(Cancellable? cancellable) throws Error {
            return yield dav.list(cancellable);
        }

        public async Bytes download(string name, Cancellable? cancellable) throws Error {
            return yield dav.get(name, cancellable);
        }

        public async string upload(string name, Bytes data, Cancellable? cancellable) throws Error {
            return yield dav.put(name, data, true, cancellable);
        }
    }

    public class SyncReport : Object {
        public int pushed = 0;
        public int pulled = 0;
        public int conflicts = 0;
        public int unchanged = 0;
        public Gee.ArrayList<string> errors = new Gee.ArrayList<string>();
    }

    public class SyncEngine : Object {
        public string root { get; construct; }
        public SyncRemote remote { get; construct; }
        public bool originals { get; set; default = false; }
        public bool catalog_snapshot { get; set; default = true; }
        public string device_name { get; set; default = Environment.get_host_name(); }
        public string catalog_path { get; set; default = Catalog.default_path(); }
        private Json.Object state = new Json.Object();

        public SyncEngine(string root, SyncRemote remote) {
            Object(root: root, remote: remote);
            load_state();
        }

        public static string hash_bytes(Bytes b) {
            return Checksum.compute_for_bytes(ChecksumType.SHA256, b);
        }

        public static string hash_file(File f) {
            try {
                uint8[] data;
                FileUtils.get_data(f.get_path(), out data);
                return Checksum.compute_for_data(ChecksumType.SHA256, data);
            } catch (Error e) {
                return "";
            }
        }

        private string state_path() {
            string? forced = Environment.get_variable("SINGULARITY_PHOTOS_SYNC_DIR");
            string dir = forced != null && forced != "" ? forced : Path.build_filename(Environment.get_user_data_dir(), "singularity-photos", "sync");
            return Path.build_filename(dir, Checksum.compute_for_string(ChecksumType.SHA1, remote.id + "\n" + root).substring(0, 16) + ".json");
        }

        private void load_state() {
            try {
                string text;
                FileUtils.get_contents(state_path(), out text);
                var parser = new Json.Parser();
                parser.load_from_data(text);
                if (parser.get_root().get_node_type() == Json.NodeType.OBJECT) state = parser.get_root().get_object();
            } catch (Error e) {
            }
        }

        private void save_state() throws Error {
            string p = state_path();
            DirUtils.create_with_parents(Path.get_dirname(p), 0755);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(state);
            var gen = new Json.Generator();
            gen.set_root(node);
            FileUtils.set_contents(p + ".part", gen.to_data(null));
            FileUtils.rename(p + ".part", p);
        }

        private void base_of(string key, out string local, out string remote_tag) {
            local = "";
            remote_tag = "";
            if (!state.has_member(key)) return;
            var o = state.get_object_member(key);
            local = o.get_string_member_with_default("local", "");
            remote_tag = o.get_string_member_with_default("remote", "");
        }

        private void set_base(string key, string local, string remote_tag) {
            var o = new Json.Object();
            o.set_string_member("local", local);
            o.set_string_member("remote", remote_tag);
            state.set_object_member(key, o);
        }

        private void collect(File dir, string prefix, Gee.List<string> out_list) {
            try {
                var e = dir.enumerate_children(FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? info;
                while ((info = e.next_file()) != null) {
                    string name = info.get_name();
                    if (name.has_prefix(".")) continue;
                    string rel = prefix == "" ? name : prefix + "/" + name;
                    if (info.get_file_type() == FileType.DIRECTORY) collect(dir.get_child(name), rel, out_list);
                    else if (Codecs.is_supported_name(name)) out_list.add(rel);
                }
            } catch (Error e) {
            }
        }

        private File photo(string rel) {
            return File.new_for_path(Path.build_filename(root, rel));
        }

        private File? local_file(bool meta, string rel) {
            return meta ? XmpSidecar.find(photo(rel)) : EditStore.find_sidecar(photo(rel));
        }

        private Bytes? local_bytes(bool meta, string rel) {
            var f = local_file(meta, rel);
            if (f == null) return null;
            try {
                uint8[] data;
                FileUtils.get_data(f.get_path(), out data);
                return new Bytes.take((owned) data);
            } catch (Error e) {
                return null;
            }
        }

        private void write_local(bool meta, string rel, Bytes data) throws Error {
            if (meta) {
                var target = local_file(true, rel) ?? XmpSidecar.beside(photo(rel));
                DirUtils.create_with_parents(target.get_parent().get_path(), 0755);
                FileUtils.set_data(target.get_path() + ".part", data.get_data());
                FileUtils.rename(target.get_path() + ".part", target.get_path());
                return;
            }
            var sb = new StringBuilder();
            sb.append_len((string) data.get_data(), (ssize_t) data.get_size());
            EditStore.save(photo(rel), EditParams.from_json(sb.str));
        }

        private void keep_conflict(bool meta, string rel, Bytes local) {
            var f = photo(rel);
            string suffix = meta ? ".xmp" : ".edit.json";
            string target = Path.build_filename(Path.get_dirname(f.get_path()), "." + f.get_basename() + ".conflict-" + new DateTime.now_local().format("%Y%m%d%H%M%S") + suffix);
            try {
                FileUtils.set_data(target, local.get_data());
            } catch (Error e) {
            }
        }

        public async Gee.List<string> catalog_backups(Cancellable? cancellable = null) throws Error {
            var list = new Gee.ArrayList<string>();
            var map = yield remote.list(cancellable);
            foreach (var k in map.keys) if (k.has_prefix("catalog/") && k.has_suffix(".db")) list.add(k.substring(8, k.length - 11));
            list.sort();
            return list;
        }

        public async void restore_catalog(string device, string target_path, Cancellable? cancellable = null) throws Error {
            var data = yield remote.download("catalog/" + device.replace("/", "_") + ".db", cancellable);
            DirUtils.create_with_parents(Path.get_dirname(target_path), 0755);
            if (FileUtils.test(target_path, FileTest.EXISTS)) FileUtils.rename(target_path, target_path + ".before-restore");
            FileUtils.set_data(target_path + ".part", data.get_data());
            FileUtils.rename(target_path + ".part", target_path);
        }

        public async SyncReport sync(Cancellable? cancellable = null) throws Error {
            var report = new SyncReport();
            var remote_map = yield remote.list(cancellable);
            var photos = new Gee.ArrayList<string>();
            collect(File.new_for_path(root), "", photos);
            if (originals) {
                foreach (var rel in photos) {
                    if (cancellable != null && cancellable.is_cancelled()) break;
                    string key = "originals/" + rel;
                    if (remote_map.has_key(key)) continue;
                    try {
                        uint8[] data;
                        FileUtils.get_data(photo(rel).get_path(), out data);
                        yield remote.upload(key, new Bytes.take((owned) data), cancellable);
                        report.pushed++;
                    } catch (Error e) {
                        report.errors.add("%s: %s".printf(rel, e.message));
                    }
                }
                foreach (var key in remote_map.keys) {
                    if (!key.has_prefix("originals/")) continue;
                    string rel = key.substring(10);
                    var target = photo(rel);
                    if (target.query_exists()) continue;
                    try {
                        var data = yield remote.download(key, cancellable);
                        DirUtils.create_with_parents(Path.get_dirname(target.get_path()), 0755);
                        FileUtils.set_data(target.get_path(), data.get_data());
                        report.pulled++;
                    } catch (Error e) {
                        report.errors.add("%s: %s".printf(rel, e.message));
                    }
                }
            }
            photos.clear();
            collect(File.new_for_path(root), "", photos);
            var keys = new Gee.TreeSet<string>();
            foreach (var rel in photos) {
                keys.add("edits/" + rel + ".edit.json");
                keys.add("meta/" + rel + ".xmp");
            }
            foreach (var k in remote_map.keys) if (k.has_prefix("edits/") || k.has_prefix("meta/")) keys.add(k);
            var untagged = new Gee.ArrayList<string>();
            foreach (var key in keys) {
                if (cancellable != null && cancellable.is_cancelled()) break;
                bool meta = key.has_prefix("meta/");
                string rel = meta ? key.substring(5, key.length - 5 - 4) : key.substring(6, key.length - 6 - 10);
                if (!photo(rel).query_exists()) continue;
                var local = local_bytes(meta, rel);
                string lh = local != null ? hash_bytes(local) : "";
                string rt = remote_map.has_key(key) ? remote_map[key] : "";
                string bl, br;
                base_of(key, out bl, out br);
                bool local_changed = lh != bl;
                bool remote_changed = rt != br;
                try {
                    if (!local_changed && !remote_changed) {
                        report.unchanged++;
                    } else if (local_changed && !remote_changed) {
                        if (local == null) {
                            report.unchanged++;
                            continue;
                        }
                        string tag = yield remote.upload(key, local, cancellable);
                        if (tag == "") untagged.add(key);
                        set_base(key, lh, tag);
                        report.pushed++;
                    } else if (!local_changed && remote_changed) {
                        if (rt == "") {
                            set_base(key, lh, rt);
                            continue;
                        }
                        var data = yield remote.download(key, cancellable);
                        write_local(meta, rel, data);
                        var now = local_bytes(meta, rel);
                        set_base(key, now != null ? hash_bytes(now) : "", rt);
                        report.pulled++;
                    } else {
                        if (rt != "") {
                            var data = yield remote.download(key, cancellable);
                            if (local != null && hash_bytes(data) == lh) {
                                set_base(key, lh, rt);
                                report.unchanged++;
                                continue;
                            }
                            if (local != null) keep_conflict(meta, rel, local);
                            write_local(meta, rel, data);
                            var now = local_bytes(meta, rel);
                            set_base(key, now != null ? hash_bytes(now) : "", rt);
                            report.conflicts++;
                        } else if (local != null) {
                            string tag = yield remote.upload(key, local, cancellable);
                            if (tag == "") untagged.add(key);
                            set_base(key, lh, tag);
                            report.pushed++;
                        }
                    }
                } catch (Error e) {
                    report.errors.add("%s: %s".printf(rel, e.message));
                }
            }
            if (untagged.size > 0) {
                var fresh = yield remote.list(cancellable);
                foreach (var key in untagged) {
                    string bl, br;
                    base_of(key, out bl, out br);
                    if (fresh.has_key(key)) set_base(key, bl, fresh[key]);
                }
            }
            if (catalog_snapshot && FileUtils.test(catalog_path, FileTest.IS_REGULAR)) {
                try {
                    string snap = Path.build_filename(Path.get_dirname(catalog_path), ".sync-snapshot.db");
                    FileUtils.remove(snap);
                    Sqlite.Database db;
                    if (Sqlite.Database.open_v2(catalog_path, out db, Sqlite.OPEN_READONLY) == Sqlite.OK) {
                        string escaped = snap.replace("'", "''");
                        if (db.exec("VACUUM INTO '%s'".printf(escaped)) == Sqlite.OK) {
                            uint8[] data;
                            FileUtils.get_data(snap, out data);
                            string safe = device_name.replace("/", "_");
                            yield remote.upload("catalog/" + safe + ".db", new Bytes.take((owned) data), cancellable);
                        }
                    }
                    FileUtils.remove(snap);
                } catch (Error e) {
                    report.errors.add(_("Catalog: %s").printf(e.message));
                }
            }
            save_state();
            return report;
        }
    }
}
