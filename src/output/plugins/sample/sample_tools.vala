[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(PhotosPlugin.ImageFilter), typeof(PhotosSampleTools.WarmFilm));
    objmodule.register_extension_type(typeof(PhotosPlugin.ExportDestination), typeof(PhotosSampleTools.CopyToFolder));
    objmodule.register_extension_type(typeof(PhotosPlugin.MetadataProvider), typeof(PhotosSampleTools.FileFacts));
}

namespace PhotosSampleTools {

    public class WarmFilm : Object, PhotosPlugin.ImageFilter {
        public string id { owned get { return "sample-warm-film"; } }
        public string title { owned get { return _("Warm Film"); } }

        public void apply(float[] rgba, int width, int height, double amount) {
            float k = (float) amount.clamp(0, 1);
            size_t n = (size_t) width * height;
            for (size_t i = 0; i < n; i++) {
                float r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
                float l = 0.2627f * r + 0.678f * g + 0.0593f * b;
                rgba[i * 4] = r + k * (l * 1.12f - r) * 0.5f;
                rgba[i * 4 + 1] = g + k * (l * 1.0f - g) * 0.5f;
                rgba[i * 4 + 2] = b + k * (l * 0.82f - b) * 0.5f;
            }
        }
    }

    public class CopyToFolder : Object, PhotosPlugin.ExportDestination {
        public string id { owned get { return "sample-copy-folder"; } }
        public string title { owned get { return _("Copy to Exported Photos"); } }

        public static string folder() {
            string? forced = Environment.get_variable("PHOTOS_SAMPLE_EXPORT_DIR");
            if (forced != null && forced != "") return forced;
            string pictures = Environment.get_user_special_dir(UserDirectory.PICTURES) ?? Environment.get_home_dir();
            return Path.build_filename(pictures, _("Exported Photos"));
        }

        public async void deliver(File[] files, Cancellable? cancellable) throws Error {
            var dir = File.new_for_path(folder());
            DirUtils.create_with_parents(dir.get_path(), 0755);
            foreach (var f in files) {
                yield f.copy_async(dir.get_child(f.get_basename()), FileCopyFlags.OVERWRITE, Priority.DEFAULT, cancellable, null);
            }
        }
    }

    public class FileFacts : Object, PhotosPlugin.MetadataProvider {
        public string id { owned get { return "sample-file-facts"; } }
        public string title { owned get { return _("File Facts"); } }

        public string[] fields() {
            return { "size", "extension" };
        }

        public string field_title(string field) {
            return field == "size" ? _("File Size") : _("Extension");
        }

        public string? read(File file, string field) {
            if (field == "extension") {
                string name = file.get_basename() ?? "";
                int dot = name.last_index_of_char('.');
                return dot >= 0 ? name.substring(dot + 1).down() : "";
            }
            try {
                var info = file.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                return format_size(info.get_size());
            } catch (Error e) {
                return null;
            }
        }
    }
}
