namespace Singularity.Apps.Photos {

    public enum ImportMode {
        COPY,
        MOVE,
        ADD
    }

    public class ImportOptions : Object {
        public ImportMode mode = ImportMode.COPY;
        public File destination;
        public string structure = "date";
        public string rename_template = "{original}";
        public bool skip_duplicates = true;
        public string preset_id = "";
        public string[] keywords = {};
        public string creator = "";
        public string copyright = "";
        public int start_sequence = 1;
    }

    public class ImportCandidate : Object {
        public File file;
        public int64 size = 0;
        public DateTime? captured = null;
        public string camera = "";
        public bool selected = true;
        public bool duplicate = false;
        public string hash = "";

        public ImportCandidate(File file) {
            this.file = file;
        }
    }

    public class ImportResult : Object {
        public int imported = 0;
        public int skipped_duplicates = 0;
        public int failed = 0;
        public Gee.ArrayList<PhotoRecord> records = new Gee.ArrayList<PhotoRecord>();
        public Gee.ArrayList<string> errors = new Gee.ArrayList<string>();
    }

    public class PhotoImporter : Object {
        public Catalog catalog { get; construct; }

        public PhotoImporter(Catalog catalog) {
            Object(catalog: catalog);
        }

        public static Gee.ArrayList<ImportCandidate> scan_source(File source) {
            var list = new Gee.ArrayList<ImportCandidate>();
            var files = new Gee.ArrayList<IndexedFile>();
            if (FileUtils.test(source.get_path() ?? "", FileTest.IS_DIR)) {
                LibraryIndexer.walk(source, files, null);
            } else {
                try {
                    var info = source.query_info("standard::size,time::modified", FileQueryInfoFlags.NONE);
                    var f = new IndexedFile();
                    f.path = source.get_path() ?? "";
                    f.size = info.get_size();
                    var dt = info.get_modification_date_time();
                    f.mtime = dt != null ? dt.to_unix() : 0;
                    list.add(candidate_for(f));
                    return list;
                } catch (Error e) {
                    return list;
                }
            }
            foreach (var f in files) list.add(candidate_for(f));
            list.sort((a, b) => {
                int64 ta = a.captured != null ? a.captured.to_unix() : 0;
                int64 tb = b.captured != null ? b.captured.to_unix() : 0;
                return ta < tb ? -1 : (ta > tb ? 1 : a.file.get_basename().collate(b.file.get_basename()));
            });
            return list;
        }

        private static ImportCandidate candidate_for(IndexedFile f) {
            var c = new ImportCandidate(File.new_for_path(f.path));
            c.size = f.size;
            var meta = MetadataReader.read(c.file);
            DateTime? taken = meta.date_taken;
            if (taken != null) c.captured = taken;
            else if (f.mtime > 0) c.captured = new DateTime.from_unix_local(f.mtime);
            c.camera = meta.camera_label();
            return c;
        }

        public void mark_duplicates(Gee.List<ImportCandidate> candidates) {
            foreach (var c in candidates) {
                c.hash = Catalog.file_hash(c.file.get_path()) ?? "";
                c.duplicate = c.hash != "" && catalog.find_duplicate(c.hash, c.size) != null;
                if (c.duplicate) c.selected = false;
            }
        }

        public static string sanitize(string s) {
            var sb = new StringBuilder();
            unichar ch;
            int i = 0;
            while (s.get_next_char(ref i, out ch)) {
                if (ch == '/' || ch == '\\' || ch == ':' || ch == '*' || ch == '?' || ch == '"' || ch == '<' || ch == '>' || ch == '|') sb.append_c('_');
                else sb.append_unichar(ch);
            }
            return sb.str.strip();
        }

        public static string render_name(string template, File source, DateTime? captured, string camera, int sequence) {
            string base_name = source.get_basename() ?? "photo";
            int dot = base_name.last_index_of_char('.');
            string stem = dot > 0 ? base_name.substring(0, dot) : base_name;
            string ext = dot > 0 ? base_name.substring(dot).down() : "";
            var t = captured ?? new DateTime.now_local();
            string name = template;
            name = name.replace("{original}", stem);
            name = name.replace("{date}", t.format("%Y-%m-%d"));
            name = name.replace("{time}", t.format("%H%M%S"));
            name = name.replace("{year}", t.format("%Y"));
            name = name.replace("{month}", t.format("%m"));
            name = name.replace("{day}", t.format("%d"));
            name = name.replace("{camera}", camera != "" ? camera.replace(" ", "-") : "camera");
            name = name.replace("{seq}", "%04d".printf(sequence));
            name = sanitize(name);
            if (name == "") name = stem;
            return name + ext;
        }

        public static File destination_folder(ImportOptions o, DateTime? captured) {
            var t = captured ?? new DateTime.now_local();
            switch (o.structure) {
                case "date": return o.destination.get_child(t.format("%Y")).get_child(t.format("%Y-%m-%d"));
                case "month": return o.destination.get_child(t.format("%Y")).get_child(t.format("%m"));
                default: return o.destination;
            }
        }

        public static File unique_target(File folder, string name) {
            var target = folder.get_child(name);
            int n = 2;
            int dot = name.last_index_of_char('.');
            string stem = dot > 0 ? name.substring(0, dot) : name;
            string ext = dot > 0 ? name.substring(dot) : "";
            while (target.query_exists()) {
                target = folder.get_child("%s-%d%s".printf(stem, n, ext));
                n++;
            }
            return target;
        }

        private static void carry_sidecars(File source, File target, bool move) {
            string sp = source.get_path() ?? "";
            string tp = target.get_path() ?? "";
            int sd = sp.last_index_of_char('.'), td = tp.last_index_of_char('.');
            if (sd <= 0 || td <= 0) return;
            var xmp = File.new_for_path(sp.substring(0, sd) + ".xmp");
            if (!xmp.query_exists()) return;
            var dest = File.new_for_path(tp.substring(0, td) + ".xmp");
            try {
                if (move) xmp.move(dest, FileCopyFlags.NONE);
                else xmp.copy(dest, FileCopyFlags.NONE);
            } catch (Error e) {
            }
        }

        public ImportResult run(Gee.List<ImportCandidate> candidates, ImportOptions o) {
            var result = new ImportResult();
            int sequence = o.start_sequence;
            var seen_hashes = new Gee.HashSet<string>();
            foreach (var c in candidates) {
                if (!c.selected) continue;
                if (o.skip_duplicates) {
                    if (c.hash == "") c.hash = Catalog.file_hash(c.file.get_path()) ?? "";
                    if (c.hash != "" && (catalog.find_duplicate(c.hash, c.size) != null || seen_hashes.contains(c.hash))) {
                        result.skipped_duplicates++;
                        continue;
                    }
                    if (c.hash != "") seen_hashes.add(c.hash);
                }
                File target;
                try {
                    if (o.mode == ImportMode.ADD) {
                        target = c.file;
                    } else {
                        var folder = destination_folder(o, c.captured);
                        DirUtils.create_with_parents(folder.get_path(), 0755);
                        target = unique_target(folder, render_name(o.rename_template, c.file, c.captured, c.camera, sequence));
                        if (o.mode == ImportMode.MOVE) c.file.move(target, FileCopyFlags.NONE);
                        else c.file.copy(target, FileCopyFlags.NONE);
                        carry_sidecars(c.file, target, o.mode == ImportMode.MOVE);
                    }
                } catch (Error e) {
                    result.failed++;
                    result.errors.add("%s: %s".printf(c.file.get_basename(), e.message));
                    continue;
                }
                sequence++;
                bool changed_file;
                var r = catalog.upsert_file(target.get_path(), c.size, now_mtime(target), out changed_file);
                if (c.hash != "") r.hash = c.hash;
                var meta = MetadataReader.read(target);
                if (o.creator != "") meta.creator = o.creator;
                if (o.copyright != "") meta.copyright = o.copyright;
                r.apply_metadata(meta);
                if (c.captured != null && meta.date_taken == null) r.captured = c.captured.to_unix();
                r.meta_mtime = r.mtime;
                catalog.save(r);
                foreach (var kw in o.keywords) {
                    if (kw.strip() == "") continue;
                    catalog.assign_keyword(r, catalog.ensure_keyword_path(kw).id);
                }
                if (o.preset_id != "") {
                    var preset = DevelopPresets.find(o.preset_id);
                    if (preset != null) {
                        var p = EditStore.load(target) ?? new EditParams();
                        DevelopPresets.apply(p, preset);
                        try {
                            EditStore.save(target, p);
                            r.edited = true;
                            catalog.save(r);
                        } catch (Error e) {
                            result.errors.add(e.message);
                        }
                    }
                }
                result.records.add(r);
                result.imported++;
            }
            return result;
        }

        private static int64 now_mtime(File f) {
            try {
                var info = f.query_info("time::modified", FileQueryInfoFlags.NONE);
                var dt = info.get_modification_date_time();
                return dt != null ? dt.to_unix() : 0;
            } catch (Error e) {
                return 0;
            }
        }

        public static Gee.ArrayList<File> removable_sources() {
            var list = new Gee.ArrayList<File>();
            var monitor = VolumeMonitor.get();
            foreach (var mount in monitor.get_mounts()) {
                var root = mount.get_root();
                if (root == null) continue;
                var dcim = root.get_child("DCIM");
                if (dcim.query_exists()) list.add(dcim);
                else if (mount.can_unmount()) list.add(root);
            }
            return list;
        }
    }
}
