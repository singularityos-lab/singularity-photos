using Gtk;
using Gdk;
using GLib;
using Gee;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public class PhotoItem : GLib.Object {
        public GLib.File file { get; set; }
        public string path { get; set; }
        public string name { get; set; }
        public GLib.DateTime? modified { get; set; }
        public int64 file_size { get; set; }
        public PhotoRecord? record = null;

        public PhotoItem(GLib.File f, GLib.FileInfo info) {
            file = f;
            path = f.get_path() ?? "";
            name = info.get_name();
            modified = info.get_modification_date_time();
            file_size = info.get_size();
        }

        public PhotoItem.from_record(PhotoRecord r) {
            record = r;
            file = r.file();
            path = r.path;
            name = r.is_virtual_copy() ? "%s (%s)".printf(r.name(), r.copy_name) : r.name();
            modified = r.captured_time() ?? (r.mtime > 0 ? new GLib.DateTime.from_unix_local(r.mtime) : null);
            file_size = r.size;
        }

        public string variant() {
            return record != null ? record.variant() : "";
        }
    }
}
