namespace Singularity.Apps.Photos {

    public class ExportFormat : Object {
        public string id { get; construct; }
        public string label { get; construct; }
        public string extension { get; construct; }
        public int[] depths;
        public bool has_quality { get; construct; }
        public bool can_lossless { get; construct; }
        public bool linear { get; construct; }

        public ExportFormat(string id, string label, string extension, int[] depths, bool has_quality, bool can_lossless, bool linear = false) {
            Object(id: id, label: label, extension: extension, has_quality: has_quality, can_lossless: can_lossless, linear: linear);
            this.depths = depths;
        }

        public bool available() {
            switch (id) {
                case "heif": return SintyCodecs.heif_can_encode(false);
                case "avif": return SintyCodecs.heif_can_encode(true);
                case "jxl": return SintyCodecs.jxl_available();
                default: return true;
            }
        }

        private static ExportFormat[]? formats = null;

        public static unowned ExportFormat[] all() {
            if (formats == null) {
                formats = {
                    new ExportFormat("jpeg", "JPEG", "jpg", { 8 }, true, false),
                    new ExportFormat("png", "PNG", "png", { 8, 16 }, false, false),
                    new ExportFormat("tiff", "TIFF", "tif", { 8, 16, 32 }, false, false),
                    new ExportFormat("webp", "WebP", "webp", { 8 }, true, true),
                    new ExportFormat("avif", "AVIF", "avif", { 8, 10, 12 }, true, true),
                    new ExportFormat("heif", "HEIF", "heic", { 8, 10 }, true, true),
                    new ExportFormat("jxl", "JPEG XL", "jxl", { 8, 16, 32 }, true, true),
                    new ExportFormat("exr", "OpenEXR", "exr", { 16, 32 }, false, false, true),
                    new ExportFormat("dng", "DNG", "dng", { 32, 16 }, false, false, true)
                };
            }
            return formats;
        }

        public static ExportFormat? find(string id) {
            foreach (unowned ExportFormat f in all()) if (f.id == id) return f;
            return null;
        }
    }

    public class ExportSettings : Object {
        public string name { get; set; default = ""; }
        public string format { get; set; default = "jpeg"; }
        public int quality { get; set; default = 90; }
        public int bit_depth { get; set; default = 8; }
        public bool lossless { get; set; default = false; }
        public bool compress { get; set; default = true; }
        public string color_space { get; set; default = "srgb"; }
        public string icc_path { get; set; default = ""; }
        public string intent { get; set; default = "perceptual"; }
        public string resize { get; set; default = "none"; }
        public int resize_width { get; set; default = 2048; }
        public int resize_height { get; set; default = 2048; }
        public double megapixels { get; set; default = 12.0; }
        public double percent { get; set; default = 50.0; }
        public bool no_enlarge { get; set; default = true; }
        public int resolution { get; set; default = 300; }
        public string sharpen { get; set; default = "none"; }
        public string sharpen_amount { get; set; default = "standard"; }
        public string metadata { get; set; default = "all"; }
        public bool watermark { get; set; default = false; }
        public string watermark_kind { get; set; default = "text"; }
        public string watermark_text { get; set; default = ""; }
        public string watermark_image { get; set; default = ""; }
        public string watermark_position { get; set; default = "bottom-right"; }
        public double watermark_opacity { get; set; default = 0.6; }
        public double watermark_scale { get; set; default = 0.25; }
        public string naming { get; set; default = "{name}"; }
        public int sequence_start { get; set; default = 1; }
        public string destination { get; set; default = "same"; }
        public string folder { get; set; default = ""; }
        public string subfolder { get; set; default = ""; }
        public string conflict { get; set; default = "unique"; }
        public string filter { get; set; default = ""; }
        public double filter_amount { get; set; default = 1.0; }
        public string plugin_destination { get; set; default = ""; }

        public ExportFormat? format_info() {
            return ExportFormat.find(format);
        }

        public int effective_depth() {
            var f = format_info();
            if (f == null) return 8;
            foreach (int d in f.depths) if (d == bit_depth) return d;
            return f.depths[0];
        }

        public string extension() {
            var f = format_info();
            return f != null ? f.extension : "jpg";
        }

        public ExportSettings copy() {
            try {
                return from_json(to_json());
            } catch (Error e) {
                return new ExportSettings();
            }
        }

        public string to_json() {
            var node = Json.gobject_serialize(this);
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.set_root(node);
            return gen.to_data(null);
        }

        public static ExportSettings from_json(string text) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(text);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA("Not an export preset");
            var s = (ExportSettings) Json.gobject_deserialize(typeof(ExportSettings), root);
            s.quality = s.quality.clamp(1, 100);
            s.watermark_opacity = s.watermark_opacity.clamp(0.0, 1.0);
            s.watermark_scale = s.watermark_scale.clamp(0.02, 1.0);
            s.percent = s.percent.clamp(1.0, 1000.0);
            if (s.format_info() == null) s.format = "jpeg";
            return s;
        }
    }

    public class ExportPreset : Object {
        public string id { get; construct; }
        public bool builtin { get; construct; }
        public ExportSettings settings { get; construct; }

        public ExportPreset(string id, bool builtin, ExportSettings settings) {
            Object(id: id, builtin: builtin, settings: settings);
        }
    }

    namespace ExportPresets {

        public string user_dir() {
            string? forced = Environment.get_variable("SINGULARITY_PHOTOS_PRESET_DIR");
            if (forced != null && forced != "") return Path.build_filename(forced, "export");
            return Path.build_filename(Environment.get_user_config_dir(), "singularity-photos", "export-presets");
        }

        private ExportSettings make(string name, string format, int depth, string space, string resize, int size, int quality) {
            var s = new ExportSettings();
            s.name = name;
            s.format = format;
            s.bit_depth = depth;
            s.color_space = space;
            s.resize = resize;
            s.resize_width = size;
            s.resize_height = size;
            s.quality = quality;
            return s;
        }

        public Gee.List<ExportPreset> builtin() {
            var list = new Gee.ArrayList<ExportPreset>();
            var web = make(_("Web"), "jpeg", 8, "srgb", "long", 2048, 85);
            web.sharpen = "screen";
            web.metadata = "copyright";
            list.add(new ExportPreset("web", true, web));
            list.add(new ExportPreset("full-jpeg", true, make(_("Full Size JPEG"), "jpeg", 8, "srgb", "none", 0, 92)));
            var email = make(_("Email"), "jpeg", 8, "srgb", "long", 1280, 80);
            email.metadata = "all-but-camera-location";
            list.add(new ExportPreset("email", true, email));
            var archive = make(_("Archive TIFF"), "tiff", 16, "prophoto", "none", 0, 100);
            list.add(new ExportPreset("archive-tiff", true, archive));
            list.add(new ExportPreset("png16", true, make(_("PNG 16-bit"), "png", 16, "display-p3", "none", 0, 100)));
            var avif = make(_("AVIF for the Web"), "avif", 10, "display-p3", "long", 2560, 70);
            avif.sharpen = "screen";
            list.add(new ExportPreset("avif-web", true, avif));
            var exr = make(_("HDR OpenEXR"), "exr", 16, "linear-rec2020", "none", 0, 100);
            exr.metadata = "none";
            list.add(new ExportPreset("exr", true, exr));
            var print = make(_("Print"), "tiff", 16, "adobe-rgb", "none", 0, 100);
            print.sharpen = "glossy";
            list.add(new ExportPreset("print", true, print));
            return list;
        }

        public Gee.List<ExportPreset> user() {
            var list = new Gee.ArrayList<ExportPreset>();
            var dir = File.new_for_path(user_dir());
            try {
                var e = dir.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);
                FileInfo? info;
                while ((info = e.next_file()) != null) {
                    string name = info.get_name();
                    if (!name.has_suffix(".json")) continue;
                    try {
                        string text;
                        FileUtils.get_contents(dir.get_child(name).get_path(), out text);
                        list.add(new ExportPreset(name.substring(0, name.length - 5), false, ExportSettings.from_json(text)));
                    } catch (Error err) {
                        warning("Photos: cannot read export preset %s: %s", name, err.message);
                    }
                }
            } catch (Error e) {
            }
            list.sort((a, b) => strcmp(a.settings.name.collate_key(), b.settings.name.collate_key()));
            return list;
        }

        public Gee.List<ExportPreset> all() {
            var list = builtin();
            list.add_all(user());
            return list;
        }

        public ExportPreset? find(string id) {
            foreach (var p in all()) if (p.id == id) return p;
            return null;
        }

        private string slug(string name) {
            var b = new StringBuilder();
            string ascii = name.down().to_ascii();
            for (int i = 0; i < ascii.length; i++) {
                char c = ascii[i];
                if (c.isalnum()) b.append_c(c);
                else if (b.len > 0 && b.str[b.len - 1] != '-') b.append_c('-');
            }
            string s = b.str.strip();
            while (s.has_suffix("-")) s = s.substring(0, s.length - 1);
            return s == "" ? "preset" : s;
        }

        public ExportPreset save(ExportSettings settings) throws Error {
            DirUtils.create_with_parents(user_dir(), 0755);
            string id = "user-" + slug(settings.name);
            FileUtils.set_contents(Path.build_filename(user_dir(), id + ".json"), settings.to_json());
            return new ExportPreset(id, false, settings.copy());
        }

        public void remove(string id) {
            if (!id.has_prefix("user-")) return;
            string path = Path.build_filename(user_dir(), id + ".json");
            if (FileUtils.test(path, FileTest.EXISTS)) FileUtils.remove(path);
        }
    }
}
