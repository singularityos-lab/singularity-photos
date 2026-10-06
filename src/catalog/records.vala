namespace Singularity.Apps.Photos {

    public enum PickFlag {
        NONE = 0,
        PICK = 1,
        REJECT = -1
    }

    public uint id_hash(int64? v) {
        int64 x = v;
        return (uint) (x ^ (x >> 32));
    }

    public bool id_equal(int64? a, int64? b) {
        return (int64) a == (int64) b;
    }

    public const string[] COLOR_LABELS = { "red", "yellow", "green", "blue", "purple" };

    public string color_label_title(string label) {
        switch (label) {
            case "red": return _("Red");
            case "yellow": return _("Yellow");
            case "green": return _("Green");
            case "blue": return _("Blue");
            case "purple": return _("Purple");
            default: return _("None");
        }
    }

    public string color_label_css(string label) {
        switch (label) {
            case "red": return "#e5484d";
            case "yellow": return "#f5c518";
            case "green": return "#30a46c";
            case "blue": return "#3e8ef7";
            case "purple": return "#8e4ec6";
            default: return "transparent";
        }
    }

    public class PhotoRecord : Object {
        public int64 id = 0;
        public string path = "";
        public int64 master_id = 0;
        public string copy_name = "";
        public int64 folder_id = 0;
        public int64 size = 0;
        public int64 mtime = 0;
        public string hash = "";
        public int rating = 0;
        public int flag = 0;
        public string label = "";
        public string kind = "photo";
        public int64 captured = 0;
        public int64 added = 0;
        public bool edited = false;
        public bool missing = false;
        public int64 stack_id = 0;
        public int stack_pos = 0;
        public string camera = "";
        public string lens = "";
        public int iso = 0;
        public double aperture = 0;
        public double exposure = 0;
        public double focal = 0;
        public bool has_gps = false;
        public double latitude = 0;
        public double longitude = 0;
        public string title = "";
        public string caption = "";
        public string creator = "";
        public string copyright = "";
        public string location = "";
        public string city = "";
        public string country = "";
        public string meta_json = "";
        public int64 meta_mtime = 0;
        public Gee.HashSet<int64?> keywords = new Gee.HashSet<int64?>(id_hash, id_equal);

        public bool is_virtual_copy() {
            return master_id != 0;
        }

        public string variant() {
            return master_id != 0 ? ("vc%" + int64.FORMAT).printf(id) : "";
        }

        public string name() {
            return Path.get_basename(path);
        }

        public File file() {
            return File.new_for_path(path);
        }

        public DateTime? captured_time() {
            if (captured <= 0) return null;
            return new DateTime.from_unix_local(captured);
        }

        public PhotoMetadata metadata() {
            if (meta_json == "") return new PhotoMetadata();
            try {
                var parser = new Json.Parser();
                parser.load_from_data(meta_json);
                return PhotoMetadata.from_json(parser.get_root());
            } catch (Error e) {
                return new PhotoMetadata();
            }
        }

        public void apply_metadata(PhotoMetadata m) {
            camera = m.camera_label();
            lens = m.lens;
            iso = m.iso;
            aperture = m.aperture;
            exposure = m.exposure_time;
            focal = m.focal_length;
            has_gps = m.has_gps;
            latitude = m.latitude;
            longitude = m.longitude;
            title = m.title;
            caption = m.caption;
            creator = m.creator;
            copyright = m.copyright;
            location = m.location;
            city = m.city;
            country = m.country;
            if (m.date_taken != null) captured = m.date_taken.to_unix();
            var gen = new Json.Generator();
            gen.set_root(m.to_json());
            meta_json = gen.to_data(null);
        }
    }

    public class FolderRecord : Object {
        public int64 id = 0;
        public string path = "";
        public int64 parent_id = 0;

        public string name() {
            return Path.get_basename(path);
        }
    }

    public class CollectionRecord : Object {
        public int64 id = 0;
        public string name = "";
        public string kind = "manual";
        public int64 parent_id = 0;
        public string rules = "";
        public int position = 0;

        public bool is_smart() {
            return kind == "smart";
        }

        public bool is_set() {
            return kind == "set";
        }
    }

    public class KeywordRecord : Object {
        public int64 id = 0;
        public string name = "";
        public int64 parent_id = 0;
        public string synonyms = "";
    }

    public class KeywordSet : Object {
        public int64 id = 0;
        public string name = "";
        public string[] keywords = {};
    }

    public class FaceRecord : Object {
        public int64 id = 0;
        public int64 photo_id = 0;
        public double x = 0;
        public double y = 0;
        public double width = 0;
        public double height = 0;
        public float[] descriptor = {};
        public int64 person_id = 0;
        public int state = 0;

        public bool confirmed() {
            return state == 1;
        }

        public bool rejected() {
            return state == -1;
        }
    }

    public class PersonRecord : Object {
        public int64 id = 0;
        public string name = "";
    }
}
