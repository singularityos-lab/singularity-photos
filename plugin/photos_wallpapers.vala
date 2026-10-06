using Gee;

[ModuleInit]
public void peas_register_types (GLib.TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Singularity.Plugin), typeof (PhotosWallpapersPlugin));
}

namespace PhotosWallpapers {

    public class FavoritesCollection : GLib.Object {
        public const string ID = "photos-favorites";

        private GLib.Settings? settings = null;
        private string dir;
        private string manifest;

        public FavoritesCollection () {
            string base_dir = GLib.Path.build_filename (GLib.Environment.get_user_data_dir (), "singularity");
            dir = GLib.Path.build_filename (base_dir, "photos-favorites");
            manifest = GLib.Path.build_filename (base_dir, "wallpaper-collections", ID + ".collection");
            var source = GLib.SettingsSchemaSource.get_default ();
            if (source != null && source.lookup ("dev.sinty.photos", true) != null) {
                settings = new GLib.Settings ("dev.sinty.photos");
                settings.changed["favorites"].connect (() => {
                    sync ();
                });
            }
        }

        public string[] paths () {
            string[] result = {};
            if (settings == null) return result;
            foreach (var entry in settings.get_strv ("favorites")) {
                var file = entry.has_prefix ("/") ? GLib.File.new_for_path (entry) : GLib.File.new_for_uri (entry);
                string? path = file.get_path ();
                if (path == null || !GLib.FileUtils.test (path, GLib.FileTest.IS_REGULAR)) continue;
                result += path;
            }
            return result;
        }

        public void sync () {
            var wanted = new HashMap<string, string> ();
            foreach (var path in paths ()) {
                string name = GLib.Path.get_basename (path);
                int n = 2;
                while (wanted.has_key (name)) {
                    string stem = GLib.Path.get_basename (path);
                    int dot = stem.last_index_of_char ('.');
                    name = dot > 0 ? "%s %d%s".printf (stem.substring (0, dot), n, stem.substring (dot)) : "%s %d".printf (stem, n);
                    n++;
                }
                wanted[name] = path;
            }
            try {
                GLib.DirUtils.create_with_parents (dir, 0755);
                var en = GLib.File.new_for_path (dir).enumerate_children ("standard::name,standard::is-symlink,standard::symlink-target",
                    GLib.FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                GLib.FileInfo? info;
                while ((info = en.next_file ()) != null) {
                    string name = info.get_name ();
                    if (!info.get_is_symlink ()) continue;
                    if (wanted.has_key (name) && wanted[name] == info.get_symlink_target ()) {
                        wanted.unset (name);
                        continue;
                    }
                    GLib.FileUtils.unlink (GLib.Path.build_filename (dir, name));
                }
                foreach (var e in wanted.entries)
                    GLib.FileUtils.symlink (e.value, GLib.Path.build_filename (dir, e.key));
                write_manifest ();
                Singularity.LocalWallpaper.fall_back_if_missing ();
            } catch (GLib.Error e) {
                warning ("photos wallpapers: %s", e.message);
            }
        }

        private void write_manifest () throws GLib.Error {
            var kf = new GLib.KeyFile ();
            kf.set_string ("Collection", "Id", ID);
            kf.set_string ("Collection", "Name", _("Photos Favorites"));
            kf.set_string ("Collection", "Dir", dir);
            kf.set_string ("Collection", "Type", "static");
            GLib.DirUtils.create_with_parents (GLib.Path.get_dirname (manifest), 0755);
            string data = kf.to_data ();
            string current = "";
            if (GLib.FileUtils.test (manifest, GLib.FileTest.EXISTS)) GLib.FileUtils.get_contents (manifest, out current);
            if (current != data) GLib.FileUtils.set_contents (manifest, data);
        }

        public void remove () {
            GLib.FileUtils.unlink (manifest);
        }
    }

    public class FavoritesProvider : GLib.Object, Singularity.WallpaperProvider {
        private FavoritesCollection collection;

        public FavoritesProvider (FavoritesCollection collection) {
            this.collection = collection;
        }

        public string id { get { return FavoritesCollection.ID; } }
        public string display_name { owned get { return _("Photos Favorites"); } }
        public bool requires_credentials { get { return false; } }
        public bool supports_search { get { return false; } }

        public async ArrayList<Singularity.WallpaperProviderChoice> choices (string category_index, GLib.Cancellable? cancel) throws GLib.Error {
            var list = new ArrayList<Singularity.WallpaperProviderChoice> ();
            list.add (new Singularity.WallpaperProviderChoice ("favorites", _("Favorites")));
            return list;
        }

        public async Singularity.WallpaperProviderResult browse (string choice_id, string query, int page,
                                                                  bool force_refresh, GLib.Cancellable? cancel) throws GLib.Error {
            var result = new Singularity.WallpaperProviderResult ();
            foreach (var path in collection.paths ()) {
                var item = new Singularity.WallpaperItem ();
                item.owner_id = FavoritesCollection.ID;
                item.provider_id = FavoritesCollection.ID;
                item.id = GLib.Checksum.compute_for_string (GLib.ChecksumType.SHA256, path);
                item.name = GLib.Path.get_basename (path);
                item.thumbnail_path = path;
                item.local_path = path;
                result.items.add (item);
            }
            return result;
        }

        public async string import_item (Singularity.WallpaperItem item, GLib.Cancellable? cancel) throws GLib.Error {
            if (!Singularity.LocalWallpaper.apply (item.local_path))
                throw new GLib.IOError.NOT_FOUND (_("This photo is no longer available."));
            return item.local_path;
        }
    }
}

public class PhotosWallpapersPlugin : GLib.Object, Singularity.Plugin {
    private Singularity.PluginContext? context = null;
    private PhotosWallpapers.FavoritesCollection? collection = null;
    private PhotosWallpapers.FavoritesProvider? provider = null;

    public void activate (Singularity.PluginContext context) {
        this.context = context;
        collection = new PhotosWallpapers.FavoritesCollection ();
        collection.sync ();
        provider = new PhotosWallpapers.FavoritesProvider (collection);
        context.add_wallpaper_provider (provider);
    }

    public void deactivate () {
        if (provider != null && context != null) context.remove_wallpaper_provider (provider);
        provider = null;
        if (collection != null) collection.remove ();
        collection = null;
        context = null;
    }

    public Gtk.Widget? get_settings_widget () {
        return null;
    }
}
