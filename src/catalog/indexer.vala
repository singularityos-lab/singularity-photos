namespace Singularity.Apps.Photos {

    public class IndexedFile {
        public string path;
        public int64 size;
        public int64 mtime;
        public bool edited;
    }

    public class IndexedMetadata {
        public int64 id;
        public int64 mtime;
        public PhotoMetadata meta;
    }

    public class LibraryIndexer : Object {
        public const int BATCH = 400;

        public Catalog catalog { get; construct; }
        public bool running { get; private set; default = false; }

        public signal void progress(int done, int total);
        public signal void finished();

        private Cancellable? cancellable = null;
        private bool rescan_pending = false;
        private File[] pending_roots = {};

        public LibraryIndexer(Catalog catalog) {
            Object(catalog: catalog);
        }

        public static bool indexable(string name) {
            if (name.has_prefix(".")) return false;
            return Codecs.is_supported_name(name) || Catalog.kind_for(name) == "video";
        }

        public static void walk(File folder, Gee.ArrayList<IndexedFile> result, Cancellable? cancellable, int depth = 0) {
            if (depth > 32 || (cancellable != null && cancellable.is_cancelled())) return;
            try {
                var e = folder.enumerate_children("standard::name,standard::type,standard::size,standard::is-hidden,time::modified",
                    FileQueryInfoFlags.NONE, cancellable);
                FileInfo? info;
                while ((info = e.next_file(cancellable)) != null) {
                    string name = info.get_name();
                    if (name.has_prefix(".")) continue;
                    var child = folder.get_child(name);
                    if (info.get_file_type() == FileType.DIRECTORY) {
                        walk(child, result, cancellable, depth + 1);
                    } else if (info.get_file_type() == FileType.REGULAR && indexable(name)) {
                        var f = new IndexedFile();
                        f.path = child.get_path() ?? "";
                        f.size = info.get_size();
                        var dt = info.get_modification_date_time();
                        f.mtime = dt != null ? dt.to_unix() : 0;
                        f.edited = EditStore.has_edits(child);
                        if (f.path != "") result.add(f);
                    }
                }
            } catch (Error e) {
            }
        }

        public void apply_files(Gee.List<IndexedFile> files, File[] roots, bool mark_missing) {
            var seen = new Gee.HashSet<string>();
            catalog.begin();
            foreach (var root in roots) {
                string rp = root.get_path() ?? "";
                if (rp != "" && FileUtils.test(rp, FileTest.IS_DIR)) catalog.ensure_folder(rp);
            }
            var dirs = new Gee.HashSet<string>();
            foreach (var f in files) dirs.add(Path.get_dirname(f.path));
            foreach (var d in dirs) ensure_chain(d, roots);
            foreach (var f in files) {
                bool changed_file;
                var r = catalog.upsert_file(f.path, f.size, f.mtime, out changed_file);
                seen.add(f.path);
                if (r.edited != f.edited) {
                    r.edited = f.edited;
                    catalog.save(r);
                }
                foreach (var copy in catalog.virtual_copies(r)) {
                    bool e = EditStore.has_edits(copy.file());
                    if (copy.edited != e) {
                        copy.edited = e;
                        catalog.save(copy);
                    }
                }
            }
            if (mark_missing) {
                foreach (var r in catalog.photos.values.to_array()) {
                    if (r.master_id != 0 || seen.contains(r.path)) continue;
                    bool under = false;
                    foreach (var root in roots) {
                        string rp = root.get_path() ?? "";
                        if (rp != "" && r.path.has_prefix(rp + "/")) under = true;
                    }
                    if (!under) continue;
                    catalog.mark_missing(r, !FileUtils.test(r.path, FileTest.EXISTS));
                }
            }
            catalog.commit();
        }

        private void ensure_chain(string dir, File[] roots) {
            foreach (var root in roots) {
                string rp = root.get_path() ?? "";
                if (rp == "" || !dir.has_prefix(rp + "/")) continue;
                var chain = new Gee.ArrayList<string>();
                string cur = dir;
                while (cur.length > rp.length) {
                    chain.insert(0, cur);
                    cur = Path.get_dirname(cur);
                }
                foreach (var c in chain) catalog.ensure_folder(c);
                return;
            }
        }

        public Gee.ArrayList<PhotoRecord> needing_metadata() {
            var list = new Gee.ArrayList<PhotoRecord>();
            foreach (var r in catalog.photos.values) {
                if (r.master_id == 0 && !r.missing && r.meta_mtime != r.mtime) list.add(r);
            }
            return list;
        }

        public static IndexedMetadata read_metadata(int64 id, string path, int64 mtime) {
            var m = new IndexedMetadata();
            m.id = id;
            m.mtime = mtime;
            var file = File.new_for_path(path);
            m.meta = MetadataReader.read(file);
            return m;
        }

        public void apply_metadata(Gee.List<IndexedMetadata> list) {
            catalog.begin();
            foreach (var m in list) {
                var r = catalog.photos[m.id];
                if (r == null) continue;
                r.apply_metadata(m.meta);
                if (r.rating == 0 && m.meta.rating > 0) r.rating = m.meta.rating.clamp(0, 5);
                if (r.rating == 0 && m.meta.rating < 0) r.flag = PickFlag.REJECT;
                if (r.label == "" && m.meta.label != "") r.label = CatalogXmp.label_from_xmp(m.meta.label);
                r.meta_mtime = m.mtime;
                catalog.save(r);
                string[] paths = m.meta.hierarchical_keywords.length > 0 ? m.meta.hierarchical_keywords : m.meta.keywords;
                foreach (var path in paths) {
                    var k = catalog.ensure_keyword_path(path);
                    catalog.assign_keyword(r, k.id);
                }
                foreach (var copy in catalog.virtual_copies(r)) {
                    copy.meta_json = r.meta_json;
                    copy.meta_mtime = r.meta_mtime;
                    copy.camera = r.camera;
                    copy.lens = r.lens;
                    copy.captured = r.captured;
                    catalog.save(copy);
                }
            }
            catalog.commit();
        }

        public void scan_sync(File[] roots, bool with_metadata = true) {
            var files = new Gee.ArrayList<IndexedFile>();
            foreach (var root in roots) walk(root, files, null);
            apply_files(files, roots, true);
            if (!with_metadata) return;
            var metas = new Gee.ArrayList<IndexedMetadata>();
            foreach (var r in needing_metadata()) metas.add(read_metadata(r.id, r.path, r.mtime));
            apply_metadata(metas);
        }

        public void cancel() {
            if (cancellable != null) cancellable.cancel();
        }

        public void scan(File[] roots) {
            if (running) {
                rescan_pending = true;
                pending_roots = roots;
                return;
            }
            running = true;
            cancellable = new Cancellable();
            var c = cancellable;
            File[] scan_roots = roots;
            new Thread<void>("photos-index", () => {
                var files = new Gee.ArrayList<IndexedFile>();
                foreach (var root in scan_roots) walk(root, files, c);
                Idle.add(() => {
                    if (!c.is_cancelled()) {
                        for (int i = 0; i < files.size; i += BATCH) {
                            var chunk = files.slice(i, int.min(files.size, i + BATCH));
                            apply_files(chunk, scan_roots, false);
                        }
                        mark_missing_under(files, scan_roots);
                    }
                    read_metadata_async(c);
                    return Source.REMOVE;
                });
            });
        }

        private void mark_missing_under(Gee.List<IndexedFile> files, File[] roots) {
            var seen = new Gee.HashSet<string>();
            foreach (var f in files) seen.add(f.path);
            catalog.begin();
            foreach (var r in catalog.photos.values.to_array()) {
                if (r.master_id != 0 || seen.contains(r.path)) continue;
                foreach (var root in roots) {
                    string rp = root.get_path() ?? "";
                    if (rp != "" && r.path.has_prefix(rp + "/")) {
                        catalog.mark_missing(r, !FileUtils.test(r.path, FileTest.EXISTS));
                        break;
                    }
                }
            }
            catalog.commit();
        }

        private void read_metadata_async(Cancellable c) {
            var todo = needing_metadata();
            int total = todo.size;
            if (total == 0 || c.is_cancelled()) {
                done();
                return;
            }
            var ids = new int64[total];
            var paths = new string[total];
            var mtimes = new int64[total];
            for (int i = 0; i < total; i++) {
                ids[i] = todo[i].id;
                paths[i] = todo[i].path;
                mtimes[i] = todo[i].mtime;
            }
            new Thread<void>("photos-meta", () => {
                var batch = new Gee.ArrayList<IndexedMetadata>();
                for (int i = 0; i < total && !c.is_cancelled(); i++) {
                    batch.add(read_metadata(ids[i], paths[i], mtimes[i]));
                    if (batch.size >= 100 || i == total - 1) {
                        var send = batch;
                        batch = new Gee.ArrayList<IndexedMetadata>();
                        int reached = i + 1;
                        Idle.add(() => {
                            apply_metadata(send);
                            progress(reached, total);
                            return Source.REMOVE;
                        });
                    }
                }
                Idle.add(() => {
                    done();
                    return Source.REMOVE;
                });
            });
        }

        private void done() {
            running = false;
            finished();
            if (rescan_pending) {
                rescan_pending = false;
                scan(pending_roots);
            }
        }
    }
}
