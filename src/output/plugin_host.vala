using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class PhotosPluginHost : Object {
        private static PhotosPluginHost? instance = null;
        private Peas.Engine engine;
        private Gee.ArrayList<PhotosPlugin.ExportDestination> destinations = new Gee.ArrayList<PhotosPlugin.ExportDestination>();
        private Gee.ArrayList<PhotosPlugin.ImageFilter> filter_list = new Gee.ArrayList<PhotosPlugin.ImageFilter>();
        private Gee.ArrayList<PhotosPlugin.MetadataProvider> providers = new Gee.ArrayList<PhotosPlugin.MetadataProvider>();
        public Gee.ArrayList<string> loaded_modules = new Gee.ArrayList<string>();

        public static PhotosPluginHost get_default() {
            if (instance == null) instance = new PhotosPluginHost();
            return instance;
        }

        public static string[] search_dirs() {
            string[] dirs = {};
            string? env = Environment.get_variable("SINGULARITY_PHOTOS_PLUGIN_PATH");
            if (env != null) foreach (var p in env.split(":")) if (p != "") dirs += p;
            try {
                string exe = FileUtils.read_link("/proc/self/exe");
                string prefix = Path.get_dirname(Path.get_dirname(exe));
                foreach (string libdir in new string[] { "lib", "lib64", "lib/x86_64-linux-gnu", "lib/aarch64-linux-gnu" })
                    dirs += Path.build_filename(prefix, libdir, "singularity-photos", "plugins");
            } catch (Error e) {
            }
            dirs += Path.build_filename(Environment.get_user_data_dir(), "singularity-photos", "plugins");
            return dirs;
        }

        private PhotosPluginHost() {
            engine = new Peas.Engine();
            foreach (var d in search_dirs()) {
                if (!FileUtils.test(d, FileTest.IS_DIR)) continue;
                engine.add_search_path(d, d);
                try {
                    var dir = Dir.open(d);
                    string? name;
                    while ((name = dir.read_name()) != null) {
                        string sub = Path.build_filename(d, name);
                        if (FileUtils.test(sub, FileTest.IS_DIR)) engine.add_search_path(sub, sub);
                    }
                } catch (Error e) {
                }
            }
            engine.rescan_plugins();
            var model = (ListModel) engine;
            for (uint i = 0; i < model.get_n_items(); i++) {
                var info = (Peas.PluginInfo) model.get_item(i);
                try {
                    if (!info.is_loaded()) engine.load_plugin(info);
                    if (!info.is_loaded()) continue;
                    loaded_modules.add(info.get_module_name());
                    add_extension(info, typeof(PhotosPlugin.ExportDestination));
                    add_extension(info, typeof(PhotosPlugin.ImageFilter));
                    add_extension(info, typeof(PhotosPlugin.MetadataProvider));
                } catch (Error e) {
                    warning("Photos: plugin %s failed: %s", info.get_module_name(), e.message);
                }
            }
        }

        private void add_extension(Peas.PluginInfo info, Type type) {
            if (!engine.provides_extension(info, type)) return;
            string[] names = {};
            Value[] values = {};
            var ext = engine.create_extension_with_properties(info, type, names, values);
            if (ext is PhotosPlugin.ExportDestination) destinations.add((PhotosPlugin.ExportDestination) ext);
            else if (ext is PhotosPlugin.ImageFilter) filter_list.add((PhotosPlugin.ImageFilter) ext);
            else if (ext is PhotosPlugin.MetadataProvider) providers.add((PhotosPlugin.MetadataProvider) ext);
        }

        public Gee.List<PhotosPlugin.ExportDestination> export_destinations() {
            return destinations.read_only_view;
        }

        public Gee.List<PhotosPlugin.ImageFilter> filters() {
            return filter_list.read_only_view;
        }

        public Gee.List<PhotosPlugin.MetadataProvider> metadata_providers() {
            return providers.read_only_view;
        }

        public PhotosPlugin.ImageFilter? find_filter(string id) {
            foreach (var f in filter_list) if (f.id == id) return f;
            return null;
        }

        public PhotosPlugin.ExportDestination? find_destination(string id) {
            foreach (var d in destinations) if (d.id == id) return d;
            return null;
        }

        public void apply_filter(string id, FloatImage img, double amount) {
            var f = find_filter(id);
            if (f != null) f.apply(img.data, img.width, img.height, amount);
        }
    }
}
