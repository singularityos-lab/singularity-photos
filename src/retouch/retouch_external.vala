using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class RetouchExternal : Object {
        public const string DRAW_ID = "dev.sinty.draw";

        public string app_name { get; private set; default = ""; }
        public File? file { get; private set; default = null; }

        public signal void returned(FloatImage image);

        private FileMonitor? monitor = null;
        private uint debounce = 0;
        private int width;
        private int height;
        private bool vector = false;

        public static AppInfo? find_app(string id) {
            foreach (var info in AppInfo.get_all()) {
                if (info.get_id() == id + ".desktop") return info;
            }
            string? path = Environment.find_program_in_path("singularity-draw");
            if (path == null) return null;
            try {
                return AppInfo.create_from_commandline(path, "Draw", AppInfoCreateFlags.NONE);
            } catch (Error e) {
                return null;
            }
        }

        public static bool available(string id) {
            return find_app(id) != null;
        }

        public static string svg_with_image(FloatImage working, string title) throws Error {
            var png = RetouchColor.to_texture8(working).save_to_png_bytes();
            string b64 = Base64.encode(png.get_data());
            var sb = new StringBuilder();
            sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
            sb.append_printf("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">\n", working.width, working.height, working.width, working.height);
            sb.append_printf("  <title>%s</title>\n", Markup.escape_text(title));
            sb.append_printf("  <image x=\"0\" y=\"0\" width=\"%d\" height=\"%d\" xlink:href=\"data:image/png;base64,%s\"/>\n", working.width, working.height, b64);
            sb.append("</svg>\n");
            return sb.str;
        }

        public void send(RetouchDocument doc, string target, string stem) throws Error {
            var app = find_app(target);
            if (app == null) throw new IOError.NOT_FOUND(_("No app is available to open this image"));
            prepare(doc, target, stem, null);
            app_name = app.get_display_name();
            var files = new List<File>();
            files.append(file);
            app.launch(files, null);
        }

        public File prepare(RetouchDocument doc, string target, string stem, string? folder) throws Error {
            stop();
            vector = false;
            app_name = _("Draw");
            width = doc.width;
            height = doc.height;
            string dir = folder ?? Path.build_filename(Environment.get_user_cache_dir(), "singularity-photos", "external", Uuid.string_random());
            DirUtils.create_with_parents(dir, 0700);
            if (vector) {
                file = File.new_for_path(Path.build_filename(dir, stem + ".svg"));
                FileUtils.set_contents(file.get_path(), svg_with_image(doc.composite, stem));
            } else {
                file = File.new_for_path(Path.build_filename(dir, stem + ".ora"));
                FileUtils.set_data(file.get_path(), RetouchOra.save(doc));
            }
            last_stamp = stamp();
            monitor = file.get_parent().monitor_directory(FileMonitorFlags.WATCH_MOVES, null);
            monitor.changed.connect((f, other, ev) => {
                bool ours = f.get_basename() == file.get_basename() || (other != null && other.get_basename() == file.get_basename());
                if (!ours) return;
                if (ev != FileMonitorEvent.CHANGES_DONE_HINT && ev != FileMonitorEvent.CHANGED && ev != FileMonitorEvent.CREATED && ev != FileMonitorEvent.RENAMED && ev != FileMonitorEvent.MOVED_IN) return;
                if (debounce != 0) Source.remove(debounce);
                debounce = Timeout.add(700, () => {
                    debounce = 0;
                    string now = stamp();
                    if (now == last_stamp) return Source.REMOVE;
                    last_stamp = now;
                    reload();
                    return Source.REMOVE;
                });
            });
            return file;
        }

        private string last_stamp = "";

        private string stamp() {
            try {
                var info = file.query_info(FileAttribute.TIME_MODIFIED + "," + FileAttribute.TIME_MODIFIED_USEC + "," + FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                return "%s:%lld".printf(info.get_modification_date_time().format_iso8601(), info.get_size());
            } catch (Error e) {
                return "";
            }
        }

        public FloatImage load_result() throws Error {
            if (vector || file.get_basename().has_suffix(".svg")) {
                var tex = Gdk.Texture.from_file(file);
                var img = RetouchColor.from_texture(tex);
                if (img.width != width || img.height != height) img = img.resized(width, height);
                return img;
            }
            uint8[] data;
            FileUtils.get_data(file.get_path(), out data);
            return RetouchOra.merged(data);
        }

        private void reload() {
            try {
                returned(load_result());
            } catch (Error e) {
                warning("Retouch: cannot read the edited file: %s", e.message);
            }
        }

        public void stop() {
            if (monitor != null) monitor.cancel();
            monitor = null;
            if (debounce != 0) Source.remove(debounce);
            debounce = 0;
        }
    }
}
