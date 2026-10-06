namespace Singularity.Apps.Photos {

    public enum PublishState {
        NEW,
        CHANGED,
        PUBLISHED
    }

    public class PublishLedger : Object {
        public string service_id { get; construct; }
        private Json.Object entries = new Json.Object();

        public PublishLedger(string service_id) {
            Object(service_id: service_id);
            load();
        }

        public static string dir() {
            string? forced = Environment.get_variable("SINGULARITY_PHOTOS_PUBLISH_DIR");
            if (forced != null && forced != "") return forced;
            return Path.build_filename(Environment.get_user_data_dir(), "singularity-photos", "publish");
        }

        private string path() {
            return Path.build_filename(dir(), Checksum.compute_for_string(ChecksumType.SHA1, service_id).substring(0, 16) + ".json");
        }

        private void load() {
            try {
                string text;
                FileUtils.get_contents(path(), out text);
                var parser = new Json.Parser();
                parser.load_from_data(text);
                var root = parser.get_root();
                if (root != null && root.get_node_type() == Json.NodeType.OBJECT) entries = root.get_object();
            } catch (Error e) {
            }
        }

        public void save() throws Error {
            DirUtils.create_with_parents(dir(), 0755);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(entries);
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.set_root(node);
            string target = path();
            FileUtils.set_contents(target + ".part", gen.to_data(null));
            FileUtils.rename(target + ".part", target);
        }

        public static string fingerprint(File file, ExportSettings settings) {
            var b = new StringBuilder();
            try {
                var info = file.query_info(FileAttribute.TIME_MODIFIED + "," + FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                b.append_printf("%lld:%s;", info.get_size(), info.get_modification_date_time().format_iso8601());
            } catch (Error e) {
                b.append("missing;");
            }
            var sidecar = EditStore.find_sidecar(file);
            if (sidecar != null) {
                try {
                    string text;
                    FileUtils.get_contents(sidecar.get_path(), out text);
                    b.append(text);
                } catch (Error e) {
                }
            }
            b.append(settings.to_json());
            return Checksum.compute_for_string(ChecksumType.SHA256, b.str);
        }

        public PublishState state(File file, ExportSettings settings) {
            string key = file.get_path() ?? file.get_uri();
            if (!entries.has_member(key)) return PublishState.NEW;
            var o = entries.get_object_member(key);
            return o.get_string_member_with_default("fingerprint", "") == fingerprint(file, settings) ? PublishState.PUBLISHED : PublishState.CHANGED;
        }

        public string? remote_name(File file) {
            string key = file.get_path() ?? file.get_uri();
            if (!entries.has_member(key)) return null;
            return entries.get_object_member(key).get_string_member_with_default("remote", "");
        }

        public void record(File file, ExportSettings settings, string remote) {
            var o = new Json.Object();
            o.set_string_member("fingerprint", fingerprint(file, settings));
            o.set_string_member("remote", remote);
            o.set_int_member("time", get_real_time() / 1000000);
            entries.set_object_member(file.get_path() ?? file.get_uri(), o);
        }

        public void forget(File file) {
            string key = file.get_path() ?? file.get_uri();
            if (entries.has_member(key)) entries.remove_member(key);
        }

        public string[] files() {
            string[] out_list = {};
            foreach (var m in entries.get_members()) out_list += m;
            return out_list;
        }

        public int count() {
            return (int) entries.get_size();
        }
    }
}
