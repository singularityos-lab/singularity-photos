namespace Singularity.Apps.Photos {

    public class EditStore : Object {
        public const string SIDECAR_SUFFIX = ".edit.json";

        private static int xmp_policy = -1;

        public static void set_write_xmp(bool enabled) {
            xmp_policy = enabled ? 1 : 0;
        }

        public static bool write_xmp_enabled() {
            if (xmp_policy >= 0) return xmp_policy == 1;
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("dev.sinty.photos", true) : null;
            if (schema == null || !schema.has_key("write-xmp")) return false;
            return new GLib.Settings("dev.sinty.photos").get_boolean("write-xmp");
        }

        public static string key_for(File file, string variant = "") {
            string uri = file.get_uri();
            if (variant != "") uri += "#" + variant;
            return Checksum.compute_for_string(ChecksumType.SHA256, uri, -1);
        }

        public static File sidecar_beside(File file, string variant = "") {
            var parent = file.get_parent() ?? File.new_for_path(Environment.get_home_dir());
            string name = "." + (file.get_basename() ?? "photo");
            if (variant != "") name += "." + variant;
            return parent.get_child(name + SIDECAR_SUFFIX);
        }

        public static File sidecar_fallback(File file, string variant = "") {
            return File.new_for_path(Path.build_filename(Environment.get_user_data_dir(),
                "singularity-photos", "edits", key_for(file, variant) + ".json"));
        }

        public static File render_cache(File file, string variant = "") {
            return File.new_for_path(Path.build_filename(Environment.get_user_cache_dir(),
                "singularity-photos", "edited", key_for(file, variant) + ".png"));
        }

        public static File? find_sidecar(File file, string variant = "") {
            var beside = sidecar_beside(file, variant);
            if (beside.query_exists()) return beside;
            var fallback = sidecar_fallback(file, variant);
            if (fallback.query_exists()) return fallback;
            return null;
        }

        public static bool has_edits(File file, string variant = "") {
            return find_sidecar(file, variant) != null;
        }

        public static EditParams? load(File file, string variant = "") {
            var sidecar = find_sidecar(file, variant);
            if (sidecar == null) return variant == "" ? load_xmp(file) : null;
            try {
                string text;
                FileUtils.get_contents(sidecar.get_path(), out text);
                return EditParams.from_json(text);
            } catch (Error e) {
                warning("Photos: cannot read %s: %s", sidecar.get_path(), e.message);
                return null;
            }
        }

        public static EditParams? load_xmp(File file, bool embedded = true) {
            if (!embedded && !XmpSidecar.exists(file)) return null;
            var packet = embedded ? XmpSidecar.load_combined(file) : XmpSidecar.load(file);
            if (!CrsMapping.has_settings(packet)) return null;
            string[] groups;
            var p = CrsMapping.read(packet, out groups);
            return p.is_identity() ? null : p;
        }

        private static bool dir_writable(File dir) {
            try {
                var info = dir.query_info(FileAttribute.ACCESS_CAN_WRITE + "," + FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NONE);
                return info.get_file_type() == FileType.DIRECTORY && info.get_attribute_boolean(FileAttribute.ACCESS_CAN_WRITE);
            } catch (Error e) {
                return false;
            }
        }

        public static File save(File file, EditParams p, string variant = "") throws Error {
            var beside = sidecar_beside(file, variant);
            var parent = beside.get_parent();
            var target = parent != null && dir_writable(parent) ? beside : sidecar_fallback(file, variant);
            DirUtils.create_with_parents(target.get_parent().get_path(), 0755);
            FileUtils.set_contents(target.get_path(), p.to_json(true));
            if (target.equal(beside)) {
                var stale = sidecar_fallback(file, variant);
                if (stale.query_exists()) FileUtils.remove(stale.get_path());
            }
            var cache = render_cache(file, variant);
            if (cache.query_exists()) FileUtils.remove(cache.get_path());
            if (variant == "" && write_xmp_enabled()) {
                try {
                    var packet = XmpSidecar.load(file);
                    CrsMapping.write(p, packet, Codecs.is_raw_name(file.get_basename() ?? ""));
                    XmpSidecar.save(file, packet, false);
                } catch (Error e) {
                    warning("Photos: cannot write XMP for %s: %s", file.get_path(), e.message);
                }
            }
            return target;
        }

        public static void revert(File file, string variant = "") {
            foreach (var f in new File[] { sidecar_beside(file, variant), sidecar_fallback(file, variant), render_cache(file, variant) }) {
                if (f.query_exists()) FileUtils.remove(f.get_path());
            }
            if (variant == "" && XmpSidecar.exists(file)) {
                try {
                    var packet = XmpSidecar.load(file);
                    if (CrsMapping.has_settings(packet)) {
                        CrsMapping.clear(packet);
                        XmpSidecar.save(file, packet, false);
                    }
                } catch (Error e) {
                    warning("Photos: cannot update XMP for %s: %s", file.get_path(), e.message);
                }
            }
        }

        public static File? valid_cache(File file, string variant = "") {
            var sidecar = find_sidecar(file, variant);
            var cache = render_cache(file, variant);
            if (sidecar == null || !cache.query_exists()) return null;
            try {
                var ci = cache.query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                var si = sidecar.query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                var oi = file.query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                var ct = ci.get_modification_date_time();
                if (ct.compare(si.get_modification_date_time()) < 0) return null;
                if (ct.compare(oi.get_modification_date_time()) < 0) return null;
                return cache;
            } catch (Error e) {
                return null;
            }
        }

        public static File copy_target(File file, string suffix) {
            var parent = file.get_parent() ?? File.new_for_path(Environment.get_home_dir());
            string name = file.get_basename() ?? "photo";
            int dot = name.last_index_of_char('.');
            string stem = dot > 0 ? name.substring(0, dot) : name;
            var candidate = parent.get_child(_("%s (Edited)").printf(stem) + suffix);
            int n = 2;
            while (candidate.query_exists()) {
                candidate = parent.get_child(_("%s (Edited %d)").printf(stem, n) + suffix);
                n++;
            }
            return candidate;
        }
    }
}
