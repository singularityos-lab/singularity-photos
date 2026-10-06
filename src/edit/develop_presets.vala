namespace Singularity.Apps.Photos {

    public class DevelopPreset : Object {
        public string id = "";
        public string name = "";
        public string group = "";
        public bool builtin = false;
        public EditParams params = new EditParams();
        public string[] groups = {};

        public string to_json() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("name");
            b.add_string_value(name);
            b.set_member_name("group");
            b.add_string_value(group);
            b.set_member_name("groups");
            b.begin_array();
            foreach (var g in groups) b.add_string_value(g);
            b.end_array();
            b.set_member_name("params");
            b.add_string_value(params.to_json());
            b.end_object();
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.set_root(b.get_root());
            return gen.to_data(null);
        }

        public static DevelopPreset from_json(string id, string text) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(text);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA(_("Not a preset"));
            var o = root.get_object();
            var p = new DevelopPreset();
            p.id = id;
            p.name = o.has_member("name") ? o.get_string_member("name") : id;
            p.group = o.has_member("group") ? o.get_string_member("group") : _("User Presets");
            string[] groups = {};
            if (o.has_member("groups")) o.get_array_member("groups").foreach_element((a, i, e) => groups += e.get_string());
            p.groups = groups.length > 0 ? groups : SettingsClipboard.GROUPS;
            p.params = EditParams.from_json(o.has_member("params") ? o.get_string_member("params") : "{}");
            return p;
        }
    }

    namespace DevelopPresets {

        private Gee.ArrayList<DevelopPreset>? builtins = null;

        public string user_dir() {
            return Path.build_filename(Environment.get_user_data_dir(), "singularity-photos", "presets");
        }

        private DevelopPreset make(string id, string name, string group, string[] groups) {
            var p = new DevelopPreset();
            p.id = id;
            p.name = name;
            p.group = group;
            p.builtin = true;
            p.groups = groups;
            return p;
        }

        private unowned Gee.ArrayList<DevelopPreset> builtin_list() {
            if (builtins != null) return builtins;
            var list = new Gee.ArrayList<DevelopPreset>();
            string color = _("Color");
            string bw = _("Black and White");
            string style = _("Style");
            string detail = _("Detail");

            var p = make("builtin-clean", _("Clean"), color, { "light", "presence" });
            p.params.set_value(Adjustment.CONTRAST, 0.1);
            p.params.set_value(Adjustment.HIGHLIGHTS, -0.3);
            p.params.set_value(Adjustment.SHADOWS, 0.25);
            p.params.set_value(Adjustment.WHITES, 0.1);
            p.params.set_value(Adjustment.BLACKS, -0.1);
            p.params.set_value(Adjustment.VIBRANCE, 0.15);
            p.params.set_value(Adjustment.CLARITY, 0.1);
            list.add(p);

            p = make("builtin-landscape", _("Punchy Landscape"), color, { "light", "presence", "hsl" });
            p.params.set_value(Adjustment.CONTRAST, 0.2);
            p.params.set_value(Adjustment.HIGHLIGHTS, -0.5);
            p.params.set_value(Adjustment.SHADOWS, 0.3);
            p.params.set_value(Adjustment.CLARITY, 0.25);
            p.params.set_value(Adjustment.DEHAZE, 0.15);
            p.params.set_value(Adjustment.VIBRANCE, 0.3);
            p.params.develop.set("hsl.sat.blue", 0.15);
            p.params.develop.set("hsl.lum.blue", -0.15);
            p.params.develop.set("hsl.sat.green", 0.1);
            list.add(p);

            p = make("builtin-portrait", _("Soft Portrait"), color, { "light", "presence", "hsl" });
            p.params.set_value(Adjustment.CONTRAST, -0.1);
            p.params.set_value(Adjustment.TEXTURE, -0.2);
            p.params.set_value(Adjustment.CLARITY, -0.1);
            p.params.set_value(Adjustment.SHADOWS, 0.15);
            p.params.develop.set("hsl.sat.orange", -0.1);
            p.params.develop.set("hsl.lum.orange", 0.1);
            list.add(p);

            p = make("builtin-matte", _("Matte Film"), style, { "light", "presence", "curve", "grading" });
            p.params.set_value(Adjustment.CONTRAST, -0.15);
            p.params.set_value(Adjustment.SATURATION, -0.15);
            p.params.develop.curve("master").set_points({ 0.0, 0.25, 0.75, 1.0 }, { 0.08, 0.24, 0.78, 0.96 });
            p.params.develop.set("grading.shadows.hue", 200);
            p.params.develop.set("grading.shadows.sat", 0.15);
            p.params.develop.set("grading.highlights.hue", 40);
            p.params.develop.set("grading.highlights.sat", 0.12);
            list.add(p);

            p = make("builtin-warm-film", _("Warm Film"), style, { "color", "curve", "grading", "effects" });
            p.params.set_value(Adjustment.WARMTH, 0.2);
            p.params.develop.set("tone.shadows", 0.2);
            p.params.develop.set("tone.highlights", -0.1);
            p.params.develop.set("grading.midtones.hue", 35);
            p.params.develop.set("grading.midtones.sat", 0.1);
            p.params.develop.set("effects.grain.amount", 0.2);
            list.add(p);

            p = make("builtin-teal-orange", _("Teal and Orange"), style, { "grading", "hsl" });
            p.params.develop.set("grading.shadows.hue", 190);
            p.params.develop.set("grading.shadows.sat", 0.3);
            p.params.develop.set("grading.highlights.hue", 30);
            p.params.develop.set("grading.highlights.sat", 0.25);
            p.params.develop.set("hsl.hue.aqua", 0.2);
            list.add(p);

            p = make("builtin-bw-classic", _("Classic"), bw, { "color", "light", "hsl" });
            p.params.develop.set_string("treatment", "bw");
            p.params.set_value(Adjustment.CONTRAST, 0.2);
            p.params.develop.set("bw.blue", -0.2);
            p.params.develop.set("bw.orange", 0.1);
            list.add(p);

            p = make("builtin-bw-high-contrast", _("High Contrast"), bw, { "color", "light", "presence", "effects" });
            p.params.develop.set_string("treatment", "bw");
            p.params.set_value(Adjustment.CONTRAST, 0.5);
            p.params.set_value(Adjustment.CLARITY, 0.3);
            p.params.set_value(Adjustment.BLACKS, -0.3);
            p.params.set_value(Adjustment.VIGNETTE, 0.3);
            list.add(p);

            p = make("builtin-bw-sepia", _("Sepia"), bw, { "color", "grading" });
            p.params.develop.set_string("treatment", "bw");
            p.params.develop.set("grading.global.hue", 35);
            p.params.develop.set("grading.global.sat", 0.25);
            list.add(p);

            p = make("builtin-sharpen-screen", _("Sharpen for Screen"), detail, { "detail" });
            p.params.set_value(Adjustment.SHARPNESS, 0.4);
            p.params.develop.set("detail.sharpen.radius", 0.8);
            p.params.develop.set("detail.sharpen.detail", 0.3);
            p.params.develop.set("detail.sharpen.masking", 0.2);
            list.add(p);

            p = make("builtin-high-iso", _("High ISO Clean Up"), detail, { "detail" });
            p.params.develop.set("detail.noise.amount", 0.4);
            p.params.develop.set("detail.color.amount", 0.5);
            p.params.set_value(Adjustment.SHARPNESS, 0.25);
            p.params.develop.set("detail.sharpen.masking", 0.4);
            list.add(p);

            builtins = list;
            return builtins;
        }

        public Gee.List<DevelopPreset> user() {
            var list = new Gee.ArrayList<DevelopPreset>();
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
                        list.add(DevelopPreset.from_json(name.substring(0, name.length - 5), text));
                    } catch (Error err) {
                        warning("Photos: cannot read preset %s: %s", name, err.message);
                    }
                }
            } catch (Error e) {
            }
            list.sort((a, b) => a.name.collate(b.name));
            return list;
        }

        public Gee.List<DevelopPreset> all() {
            var list = new Gee.ArrayList<DevelopPreset>();
            list.add_all(builtin_list());
            list.add_all(user());
            return list;
        }

        public DevelopPreset? find(string id) {
            foreach (var p in all()) if (p.id == id) return p;
            return null;
        }

        public DevelopPreset save_user(string name, string group, EditParams source, string[] groups) throws Error {
            var p = new DevelopPreset();
            p.name = name;
            p.group = group == "" ? _("User Presets") : group;
            p.groups = groups;
            var clean = new EditParams();
            EditParamsGroups.transfer(source, clean, groups);
            p.params = clean;
            string base_id = name.down().replace(" ", "-").replace("/", "-");
            if (base_id == "") base_id = "preset";
            DirUtils.create_with_parents(user_dir(), 0755);
            string id = base_id;
            int n = 2;
            while (FileUtils.test(Path.build_filename(user_dir(), id + ".json"), FileTest.EXISTS)) id = "%s-%d".printf(base_id, n++);
            p.id = id;
            FileUtils.set_contents(Path.build_filename(user_dir(), id + ".json"), p.to_json());
            return p;
        }

        public void remove_user(DevelopPreset p) {
            if (p.builtin) return;
            FileUtils.remove(Path.build_filename(user_dir(), p.id + ".json"));
        }

        public DevelopPreset import_xmp(File file) throws Error {
            string text;
            FileUtils.get_contents(file.get_path(), out text);
            var packet = XmpPacket.parse(text);
            if (!CrsMapping.has_settings(packet)) throw new IOError.INVALID_DATA(_("This file has no develop settings"));
            string[] groups;
            var params = CrsMapping.read(packet, out groups);
            string name = packet.get_lang_alt(XmpPacket.NS_CRS, "Name") ?? packet.get_simple(XmpPacket.NS_CRS, "PresetName") ?? "";
            if (name == "") {
                name = file.get_basename() ?? _("Imported Preset");
                if (name.down().has_suffix(".xmp")) name = name.substring(0, name.length - 4);
            }
            string group = packet.get_lang_alt(XmpPacket.NS_CRS, "Group") ?? _("Imported");
            return save_user(name, group, params, groups);
        }

        public void apply(EditParams target, DevelopPreset preset, double amount = 1.0) {
            if (amount >= 1.0 - 1e-9) {
                EditParamsGroups.transfer(preset.params, target, preset.groups);
                return;
            }
            var mixed = target.copy();
            EditParamsGroups.transfer(preset.params, mixed, preset.groups);
            for (int i = 0; i < Adjustment.COUNT; i++) {
                double a = target.values[i], b = mixed.values[i];
                target.values[i] = a + (b - a) * amount;
            }
            foreach (var k in DevelopSettings.keys()) {
                double a = target.develop.get(k.name), b = mixed.develop.get(k.name);
                if ((a - b).abs() > 1e-12) target.develop.set(k.name, a + (b - a) * amount);
            }
            if (amount >= 0.5) {
                foreach (var e in mixed.develop.strings.entries) target.develop.strings[e.key] = e.value;
                foreach (var e in mixed.develop.curves.entries) target.develop.curves[e.key] = e.value.copy();
                target.filter = mixed.filter;
            }
        }
    }

    namespace SettingsClipboard {

        public const string[] GROUPS = { "light", "presence", "color", "curve", "hsl", "grading", "detail", "optics", "geometry", "effects", "calibration", "masks", "spots", "crop" };

        private EditParams? stored = null;
        private string[]? stored_groups = null;

        public string label(string group) {
            switch (group) {
                case "light": return _("Light");
                case "presence": return _("Presence");
                case "color": return _("White Balance and Treatment");
                case "curve": return _("Tone Curve");
                case "hsl": return _("Color Mixer");
                case "grading": return _("Color Grading");
                case "detail": return _("Detail");
                case "optics": return _("Lens Corrections");
                case "geometry": return _("Geometry");
                case "effects": return _("Effects");
                case "calibration": return _("Calibration");
                case "masks": return _("Masks");
                case "spots": return _("Spot Removal");
                default: return _("Crop and Orientation");
            }
        }

        public void copy(EditParams source, string[] groups) {
            stored = source.copy();
            stored_groups = groups;
        }

        public bool has_content() {
            return stored != null;
        }

        public void paste(EditParams target) {
            if (stored == null) return;
            EditParamsGroups.transfer(stored, target, stored_groups ?? GROUPS);
        }
    }

    namespace EditParamsGroups {

        public string group_of(string target) {
            string key = target.has_prefix("adj:") || target.has_prefix("dev:") ? target.substring(4) : target;
            switch (key) {
                case "exposure":
                case "contrast":
                case "highlights":
                case "shadows":
                case "whites":
                case "blacks":
                case "brightness":
                    return "light";
                case "texture":
                case "clarity":
                case "dehaze":
                case "vibrance":
                case "saturation":
                    return "presence";
                case "warmth":
                case "tint":
                    return "color";
                case "sharpness":
                    return "detail";
                case "vignette":
                    return "effects";
                default:
                    break;
            }
            if (key.has_prefix("wb.") || key == "treatment" || key == "profile" || key == "camera.profile" || key == "lut" || key.has_prefix("profile.") || key.has_prefix("lut.")) return "color";
            if (key.has_prefix("tone.") || key.has_prefix("curve")) return "curve";
            if (key.has_prefix("hsl.") || key.has_prefix("bw.")) return "hsl";
            if (key.has_prefix("grading.")) return "grading";
            if (key.has_prefix("detail.")) return "detail";
            if (key.has_prefix("lens.")) return "optics";
            if (key.has_prefix("transform.") || key.has_prefix("upright")) return "geometry";
            if (key.has_prefix("effects.")) return "effects";
            if (key.has_prefix("calibration.")) return "calibration";
            return "other";
        }

        private bool has(string[] groups, string g) {
            foreach (var x in groups) if (x == g) return true;
            return false;
        }

        public void transfer(EditParams source, EditParams target, string[] groups) {
            for (int i = 0; i < Adjustment.COUNT; i++) {
                if (has(groups, group_of(((Adjustment) i).key()))) target.values[i] = source.values[i];
            }
            foreach (var k in DevelopSettings.keys()) {
                if (has(groups, group_of(k.name))) target.develop.set(k.name, source.develop.get(k.name));
            }
            foreach (var key in new string[] { "wb.mode", "treatment", "profile", "camera.profile", "lut", "upright", "upright.guides", "lens.profile.id" }) {
                if (has(groups, group_of(key))) target.develop.set_string(key, source.develop.get_string(key));
            }
            if (has(groups, "curve")) {
                target.develop.curves.clear();
                foreach (var e in source.develop.curves.entries) target.develop.curves[e.key] = e.value.copy();
            }
            if (has(groups, "color")) target.filter = source.filter;
            if (has(groups, "light")) {
                target.black_point = source.black_point;
                target.white_point = source.white_point;
            }
            if (has(groups, "masks")) {
                target.locals.clear();
                foreach (var l in source.locals) target.locals.add(l.copy());
            }
            if (has(groups, "spots")) {
                target.spots.clear();
                foreach (var s in source.spots) target.spots.add(s.copy());
            }
            if (has(groups, "crop")) {
                target.quarter_turns = source.quarter_turns;
                target.flip = source.flip;
                target.straighten = source.straighten;
                target.set_crop(source.crop_x, source.crop_y, source.crop_w, source.crop_h);
            }
        }
    }
}
