using Gtk;
using Gdk;
using GLib;
using Gee;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public class PhotosApp : Singularity.Application {
        private Singularity.Apps.PhotosWindow main_window;
        private GLib.Settings settings;
        private GLib.ListStore photo_store;
        private GridView photo_grid;
        private string current_view = "library";
        private string search_query = "";
        private int thumb_size = 160;
        private GLib.File library_folder;
        private GLib.FileMonitor? lib_monitor = null;

        // Viewer state - class fields to avoid closure capture issues
        private Overlay? full_viewer = null;
        private Picture? viewer_picture = null;
        private Label? viewer_filename_label = null;
        private Label? viewer_info_label = null;
        private Button? viewer_fav_btn = null;
        private int viewer_index = 0;
        private int viewer_rotation = 0;
        private LiveTextSession? live_text = null;
        private Spinner? viewer_spinner = null;
        private uint viewer_load_serial = 0;
        private uint viewer_spinner_id = 0;
        private EditView? edit_view = null;
        private Box? edit_host = null;
        private Button[] edit_bubbles = {};
        private Button? revert_bubble = null;
        private Button[] zoom_bubbles = {};
        private Button[] viewer_bubbles = {};
        private SimpleAction[] edit_actions = {};
        private SimpleAction? edit_action = null;
        private bool sidebar_before_edit = true;

        // Search bar references

        // Content overlay (hosts grid + viewer)
        private Overlay content_overlay;
        private StatusPage? empty_page = null;
        private WelcomePage? welcome_page = null;
        private Gee.HashMap<string, WelcomePage> section_pages = new Gee.HashMap<string, WelcomePage>();
        private OnlinePhotos? online = null;

        private Catalog catalog;
        private LibraryIndexer indexer;
        private LibraryFilter filter = new LibraryFilter();
        private LibraryFilterBar? filter_bar = null;
        private Revealer? filter_revealer = null;
        private LibraryInfoPanel? info_panel = null;
        private Revealer? info_revealer = null;
        private MultiSelection? selection = null;
        private Box? folders_section = null;
        private Box? collections_section = null;
        private string sidebar_signature = "-";
        private uint catalog_refresh_id = 0;
        private uint index_timeout_id = 0;
        private Gee.ArrayList<PhotoRecord>? place_records = null;
        private PhotoMap? photo_map = null;
        private Box? map_page = null;
        private WelcomePage? map_intro = null;
        private Label? map_status = null;
        private PeopleView? people_view = null;
        private CompareView? compare_view = null;
        private RetouchView? retouch_view = null;
        private Box? retouch_host = null;
        private Button? _filter_bubble = null;
        private Button? _info_bubble = null;
        private Gee.HashMap<string, SimpleAction> library_actions = new Gee.HashMap<string, SimpleAction>();

        public PhotosApp() {
            GLib.Object(application_id: "dev.sinty.photos",
                        flags: ApplicationFlags.HANDLES_OPEN);
            add_main_option("favorites", 0, OptionFlags.NONE, OptionArg.NONE, _("Show your favorite photos"), null);
            add_main_option("import", 0, OptionFlags.NONE, OptionArg.NONE, _("Choose photos to import"), null);
        }

        protected override int handle_local_options(VariantDict options) {
            string? action = null;
            if (options.contains("favorites")) action = "show-favorites";
            else if (options.contains("import")) action = "import";
            if (action == null) return -1;
            try {
                register(null);
            } catch (Error e) {
                warning("photos: %s", e.message);
                return 1;
            }
            activate_action(action, null);
            return get_is_remote() ? 0 : -1;
        }

        protected override void startup() {
            base.startup();
            setup_styles();

            // Load settings, falling back to exe-relative compiled schemas in dev
            var source = SettingsSchemaSource.get_default();
            if (source.lookup("dev.sinty.photos", true) == null) {
                try {
                    string exe_path = FileUtils.read_link("/proc/self/exe");
                    var exe_dir = GLib.File.new_for_path(exe_path).get_parent();
                    var schema_file = exe_dir.get_child("data").get_child("gschemas.compiled");
                    if (schema_file.query_exists()) {
                        var compiled_source = new SettingsSchemaSource.from_directory(
                            schema_file.get_parent().get_path(), source, true);
                        var schema = compiled_source.lookup("dev.sinty.photos", true);
                        if (schema != null) {
                            settings = new GLib.Settings.full(schema, null, null);
                            message("Loaded dev schemas from %s", schema_file.get_path());
                        }
                    }
                } catch (Error e) {
                    warning("Failed to load dev schemas: %s", e.message);
                }
            }
            if (settings == null) {
                settings = new GLib.Settings("dev.sinty.photos");
            }

            var menu = new GLib.Menu();
            var file_menu = new GLib.Menu();
            var file_import = new GLib.Menu();
            file_import.append(_("Import Photos…"), "app.import");
            file_import.append(_("Import from Lightroom Catalog…"), "win.import-lrcat");
            file_import.append(_("Tethered Capture…"), "win.tether");
            file_import.append(_("Add Folder to Library…"), "win.add-folder");
            file_import.append(_("Open Library Folder"), "app.open-library");
            file_menu.append_section(null, file_import);
            var file_output = new GLib.Menu();
            file_output.append(_("Export…"), "win.export");
            file_output.append(_("Print…"), "win.print");
            file_output.append(_("Slideshow"), "win.slideshow");
            file_output.append(_("Photo Book…"), "win.book");
            if (Capabilities.has_app("dev.sinty.slides")) file_output.append(_("Create Presentation"), "win.presentation");
            if (Capabilities.has_app("dev.sinty.write")) file_output.append(_("Insert in Write"), "win.insert-write");
            file_output.append(_("Publish…"), "win.publish");
            file_output.append(_("Sync Library…"), "win.sync-library");
            file_menu.append_section(null, file_output);
            var file_meta = new GLib.Menu();
            file_meta.append(_("Save Metadata to Files"), "win.save-metadata");
            file_meta.append(_("Find Missing Photos"), "win.view::missing");
            file_menu.append_section(null, file_meta);
            var file_close = new GLib.Menu();
            file_close.append(_("Close Window"), "win.close");
            file_close.append(_("Quit"), "app.quit");
            file_menu.append_section(null, file_close);
            menu.append_submenu(_("File"), file_menu);
            var edit_menu = new GLib.Menu();
            var edit_photo = new GLib.Menu();
            edit_photo.append(_("Copy"), "win.copy");
            edit_photo.append(_("Favorite"), "win.favorite");
            edit_photo.append(_("Move to Trash"), "win.trash");
            edit_menu.append_section(null, edit_photo);
            var edit_select = new GLib.Menu();
            edit_select.append(_("Select All"), "win.select-all");
            edit_select.append(_("Select None"), "win.select-none");
            edit_menu.append_section(null, edit_select);
            var edit_settings_sync = new GLib.Menu();
            edit_settings_sync.append(_("Copy Edit Settings…"), "win.copy-settings");
            edit_settings_sync.append(_("Paste Edit Settings"), "win.paste-settings");
            edit_settings_sync.append(_("Sync Settings…"), "win.sync-settings");
            edit_settings_sync.append(_("Reset Edits"), "win.reset-edits");
            edit_menu.append_section(null, edit_settings_sync);
            var edit_find = new GLib.Menu();
            edit_find.append(_("Find"), "win.find");
            edit_find.append(_("Manage Keywords…"), "win.keywords");
            edit_menu.append_section(null, edit_find);
            var edit_settings = new GLib.Menu();
            edit_settings.append(_("Settings"), "app.settings");
            edit_menu.append_section(null, edit_settings);
            menu.append_submenu(_("Edit"), edit_menu);
            var view_menu = new GLib.Menu();
            var view_pages = new GLib.Menu();
            view_pages.append(_("Library"), "win.view::library");
            view_pages.append(_("Favorites"), "win.view::favorites");
            view_pages.append(_("Recently Added"), "win.view::recent");
            view_pages.append(_("Map"), "win.view::map");
            view_pages.append(_("People"), "win.view::people");
            view_pages.append(_("Trash"), "win.view::trash");
            view_menu.append_section(null, view_pages);
            var view_panels = new GLib.Menu();
            view_panels.append(_("Filter Bar"), "win.filter-bar");
            view_panels.append(_("Info"), "win.info-panel");
            view_panels.append(_("Compare"), "win.compare");
            view_panels.append(_("Survey"), "win.survey");
            view_menu.append_section(null, view_panels);
            var view_zoom = new GLib.Menu();
            view_zoom.append(_("Zoom In"), "win.zoom-in");
            view_zoom.append(_("Zoom Out"), "win.zoom-out");
            view_menu.append_section(null, view_zoom);
            var view_window = new GLib.Menu();
            view_window.append(_("Show Sidebar"), "app.toggle-sidebar");
            view_window.append(_("Fullscreen"), "win.fullscreen");
            view_menu.append_section(null, view_window);
            menu.append_submenu(_("View"), view_menu);
            var image_menu = new GLib.Menu();
            var image_nav = new GLib.Menu();
            image_nav.append(_("Open"), "win.open-photo");
            image_nav.append(_("Previous Photo"), "win.previous");
            image_nav.append(_("Next Photo"), "win.next");
            image_nav.append(_("Back to Photos"), "win.close-photo");
            image_menu.append_section(null, image_nav);
            var image_rotate = new GLib.Menu();
            image_rotate.append(_("Rotate Left"), "win.rotate-left");
            image_rotate.append(_("Rotate Right"), "win.rotate-right");
            image_menu.append_section(null, image_rotate);
            var image_wallpaper = new GLib.Menu();
            image_wallpaper.append(_("Set as Wallpaper"), "win.set-wallpaper");
            image_menu.append_section(null, image_wallpaper);
            var image_share = new GLib.Menu();
            image_share.append(_("Edit"), "win.edit");
            image_share.append(_("Retouch"), "win.retouch");
            image_share.append(_("Markup"), "win.markup");
            image_share.append(_("Live Text"), "win.live-text");
            image_share.append(_("Share…"), "win.share");
            image_menu.append_section(null, image_share);
            var image_org = new GLib.Menu();
            image_org.append(_("Create Virtual Copy"), "win.virtual-copy");
            image_org.append(_("Group into Stack"), "win.stack");
            image_org.append(_("Unstack"), "win.unstack");
            image_org.append(_("Expand or Collapse Stack"), "win.toggle-stack");
            image_menu.append_section(null, image_org);
            var image_merge = new GLib.Menu();
            image_merge.append(_("Merge to HDR…"), "win.merge::hdr");
            image_merge.append(_("Merge to Panorama…"), "win.merge::panorama");
            image_merge.append(_("Focus Stack…"), "win.merge::focus");
            image_merge.append(_("Super Resolution"), "win.merge::superres");
            image_menu.append_section(null, image_merge);
            menu.append_submenu(_("Image"), image_menu);
            set_menubar(menu);

            var act_open_library = new SimpleAction("open-library", null);
            act_open_library.activate.connect(() => open_library_folder());
            add_action(act_open_library);

            var act_import = new SimpleAction("import", null);
            act_import.activate.connect(() => {
                activate();
                on_import();
            });
            add_action(act_import);

            var act_favorites = new SimpleAction("show-favorites", null);
            act_favorites.activate.connect(() => {
                activate();
                main_window.activate_action_variant("win.view", new Variant.string("favorites"));
            });
            add_action(act_favorites);

            var act_place = new SimpleAction("show-place", new VariantType("(dd)"));
            act_place.activate.connect((p) => {
                double lat = p.get_child_value(0).get_double();
                double lon = p.get_child_value(1).get_double();
                activate();
                main_window.activate_action_variant("win.view", new Variant.string("map"));
                pending_place_lat = lat;
                pending_place_lon = lon;
                Idle.add(() => {
                    if (photo_map != null) {
                        photo_map.focus(lat, lon, 13);
                        pending_place_lat = double.NAN;
                    }
                    return Source.REMOVE;
                });
            });
            add_action(act_place);

            var act_settings = new SimpleAction("settings", null);
            act_settings.activate.connect(() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync(
                        BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings("dev.sinty.photos");
                } catch (Error e) {
                    warning("Failed to open settings: %s", e.message);
                }
            });
            add_action(act_settings);

            var act_quit = new SimpleAction("quit", null);
            act_quit.activate.connect(() => quit());
            add_action(act_quit);

            var act_sidebar = new SimpleAction.stateful("toggle-sidebar", null, new Variant.boolean(true));
            act_sidebar.activate.connect(() => {
                if (main_window == null || (full_viewer != null && full_viewer.visible)) return;
                main_window.set_sidebar_visible(!main_window.get_sidebar_visible());
                act_sidebar.set_state(new Variant.boolean(main_window.get_sidebar_visible()));
            });
            add_action(act_sidebar);
            set_accels_for_action("app.toggle-sidebar", { "F9" });
            set_accels_for_action("app.settings", { "<Control>comma" });
            set_accels_for_action("app.import", { "<Control>i" });
            set_accels_for_action("win.close", { "<Control>w" });
            set_accels_for_action("win.copy", { "<Control>c" });
            set_accels_for_action("win.favorite", { "<Control>d" });
            set_accels_for_action("win.trash", { "Delete" });
            set_accels_for_action("win.find", { "<Control>f" });
            set_accels_for_action("win.zoom-in", { "<Control>plus", "<Control>equal" });
            set_accels_for_action("win.zoom-out", { "<Control>minus" });
            set_accels_for_action("win.fullscreen", { "F11" });
            set_accels_for_action("win.rotate-left", { "<Control><Shift>r" });
            set_accels_for_action("win.rotate-right", { "<Control>r" });
            set_accels_for_action("win.edit", { "<Control>e" });
            set_accels_for_action("win.export", { "<Control><Shift>e" });
            set_accels_for_action("win.print", { "<Control>p" });
            set_accels_for_action("win.slideshow", { "F5" });
            set_accels_for_action("win.filter-bar", { "<Control>l" });
            set_accels_for_action("win.info-panel", { "<Control><Alt>i" });
            set_accels_for_action("win.select-all", { "<Control>a" });
            set_accels_for_action("win.select-none", { "<Control><Shift>a" });
            set_accels_for_action("win.copy-settings", { "<Control><Shift>c" });
            set_accels_for_action("win.paste-settings", { "<Control><Shift>v" });
            set_accels_for_action("win.sync-settings", { "<Control><Shift>s" });
            set_accels_for_action("win.virtual-copy", { "<Control>apostrophe" });
            set_accels_for_action("win.stack", { "<Control>g" });
            set_accels_for_action("win.unstack", { "<Control><Shift>g" });
            set_accels_for_action("win.save-metadata", { "<Control>s" });
            set_accels_for_action("win.retouch", { "<Control><Alt>e" });
            set_accels_for_action("win.keywords", { "<Control><Shift>k" });
            set_accels_for_action("win.merge::hdr", { "<Control>h" });
            set_accels_for_action("win.merge::panorama", { "<Control>m" });
        }

        protected override void activate() {
            if (main_window != null) {
                main_window.present();
                return;
            }

            string lib_name = settings.get_string("library-path");
            library_folder = GLib.File.new_for_path(
                GLib.Environment.get_home_dir() + "/" + lib_name);
            thumb_size = settings.get_int("thumbnail-size");
            current_view = settings.get_string("sidebar-view");
            catalog = Catalog.get_default();
            indexer = new LibraryIndexer(catalog);
            LibraryStyle.install();
            filter.sort_key = state_string("library-sort", "captured");
            filter.ascending = state_bool("library-sort-ascending", false);
            filter.collapse_stacks = state_bool("collapse-stacks", true);
            if (!view_is_valid(current_view)) current_view = "library";
            catalog.changed.connect(schedule_catalog_refresh);
            indexer.finished.connect(() => {
                update_empty_page();
                if (filter_bar != null) filter_bar.refresh_values();
                if (people_view != null) people_view.auto_scan();
            });

            main_window = new PhotosWindow(this);
            content_overlay = main_window.content_overlay;

            setup_sidebar(main_window.sidebar_scroll);
            setup_toolbar();
            setup_content(main_window.content_box, main_window.search_host, main_window.grid_scroll);
            setup_viewer();
            setup_drag_drop();
            setup_library_monitor();
            setup_window_actions();
            setup_library_panels();
            setup_library_actions();
            load_photos();
            indexer.scan(library_roots());

            main_window.present();
            main_window.close_request.connect(() => {
                if (lib_monitor != null) { lib_monitor.cancel(); lib_monitor = null; }
                indexer.cancel();
                return false;
            });
        }

        protected override void open(GLib.File[] files, string hint) {
            activate();
            if (files.length == 0) return;
            var target = files[0];
            var parent = target.get_parent();
            string target_path = target.get_path() ?? "";
            if (parent != null && catalog.find_path(target_path) == null) index_shallow(parent);
            var rec = catalog.find_path(target_path);
            search_query = "";
            if (rec != null && !under_roots(target_path)) {
                show_view(("folder:%" + int64.FORMAT).printf(rec.folder_id));
            } else {
                filter.reset_attributes();
                if (filter_bar != null) filter_bar.sync();
                show_view("library");
            }
            load_photos();
            for (uint i = 0; i < photo_store.get_n_items(); i++) {
                var pi = (PhotoItem) photo_store.get_item(i);
                if (pi.file.equal(target) || pi.file.get_path() == target_path) {
                    show_viewer((int) i);
                    return;
                }
            }
        }

        private void index_shallow(GLib.File dir) {
            var files = new Gee.ArrayList<IndexedFile>();
            try {
                var e = dir.enumerate_children("standard::name,standard::type,standard::size,time::modified", FileQueryInfoFlags.NONE, null);
                GLib.FileInfo? info;
                while ((info = e.next_file(null)) != null) {
                    if (info.get_file_type() != FileType.REGULAR || !LibraryIndexer.indexable(info.get_name())) continue;
                    var f = new IndexedFile();
                    f.path = dir.get_child(info.get_name()).get_path() ?? "";
                    f.size = info.get_size();
                    var dt = info.get_modification_date_time();
                    f.mtime = dt != null ? dt.to_unix() : 0;
                    f.edited = EditStore.has_edits(dir.get_child(info.get_name()));
                    files.add(f);
                }
            } catch (Error e) {
                warning("Photos: %s", e.message);
            }
            indexer.apply_files(files, {}, false);
            var metas = new Gee.ArrayList<IndexedMetadata>();
            foreach (var f in files) {
                var r = catalog.find_path(f.path);
                if (r != null && r.meta_mtime != r.mtime) metas.add(LibraryIndexer.read_metadata(r.id, r.path, r.mtime));
            }
            indexer.apply_metadata(metas);
        }

        private GLib.File[] library_roots() {
            GLib.File[] roots = { library_folder };
            if (has_setting("extra-folders")) {
                foreach (var p in settings.get_strv("extra-folders")) roots += GLib.File.new_for_path(p);
            } else {
                string? extra = catalog.get_meta("ui.extra-folders");
                if (extra != null) foreach (var p in extra.split("\n")) if (p != "") roots += GLib.File.new_for_path(p);
            }
            return roots;
        }

        private void add_library_root(string path) {
            string[] list = {};
            if (has_setting("extra-folders")) {
                list = settings.get_strv("extra-folders");
            } else {
                string? extra = catalog.get_meta("ui.extra-folders");
                if (extra != null) foreach (var p in extra.split("\n")) if (p != "") list += p;
            }
            foreach (var p in list) if (p == path) return;
            list += path;
            if (has_setting("extra-folders")) settings.set_strv("extra-folders", list);
            else catalog.set_meta("ui.extra-folders", string.joinv("\n", list));
            catalog.ensure_folder(path);
            indexer.scan(library_roots());
        }

        private bool under_roots(string path) {
            foreach (var root in library_roots()) {
                string rp = root.get_path() ?? "";
                if (rp != "" && path.has_prefix(rp + "/")) return true;
            }
            return false;
        }

        private bool has_setting(string key) {
            return settings.settings_schema != null && settings.settings_schema.has_key(key);
        }

        private bool state_bool(string key, bool fallback) {
            if (has_setting(key)) return settings.get_boolean(key);
            string? v = catalog.get_meta("ui." + key);
            return v != null ? v == "1" : fallback;
        }

        private void set_state_bool(string key, bool v) {
            if (has_setting(key)) settings.set_boolean(key, v);
            else catalog.set_meta("ui." + key, v ? "1" : "0");
        }

        private string state_string(string key, string fallback) {
            if (has_setting(key)) return settings.get_string(key);
            return catalog.get_meta("ui." + key) ?? fallback;
        }

        private void set_state_string(string key, string v) {
            if (has_setting(key)) settings.set_string(key, v);
            else catalog.set_meta("ui." + key, v);
        }

        private bool view_is_valid(string view) {
            switch (view) {
                case "library":
                case "favorites":
                case "recent":
                case "trash":
                case "map":
                case "people":
                case "missing":
                    return true;
                default:
                    break;
            }
            int64 id = view_id(view);
            if (view.has_prefix("folder:")) return catalog.folders.has_key(id);
            if (view.has_prefix("collection:")) return catalog.collections.has_key(id);
            if (view.has_prefix("person:")) return catalog.people.has_key(id);
            return false;
        }

        private static int64 view_id(string view) {
            int colon = view.index_of_char(':');
            return colon > 0 ? int64.parse(view.substring(colon + 1)) : 0;
        }

        // ── Sidebar ────────────────────────────────────────────────────────────

        private void setup_sidebar(AppSidebar sidebar_scroll) {
            var sidebar_box = sidebar_scroll.box;
            add_sidebar_section(sidebar_box, _("Library"));
            add_sidebar_item(sidebar_box, "image-x-generic-symbolic", _("Library"), "library");
            add_sidebar_item(sidebar_box, "starred-symbolic", _("Favorites"), "favorites");
            add_sidebar_item(sidebar_box, "document-new-symbolic", _("Recently Added"), "recent");
            add_sidebar_item(sidebar_box, "mark-location-symbolic", _("Map"), "map");
            add_sidebar_item(sidebar_box, "system-users-symbolic", _("People"), "people");
            folders_section = new Box(Orientation.VERTICAL, 0);
            sidebar_box.append(folders_section);
            collections_section = new Box(Orientation.VERTICAL, 0);
            sidebar_box.append(collections_section);
            add_sidebar_section(sidebar_box, _("Other"));
            add_sidebar_item(sidebar_box, "user-trash-symbolic", _("Trash"), "trash");
            rebuild_dynamic_sidebar();
        }

        private void add_sidebar_section(Box parent, string title) {
            parent.append(new Singularity.Widgets.SidebarSectionLabel(title));
        }

        private Singularity.Widgets.SidebarRow add_sidebar_item(Box parent, string icon_name, string label_text, string view_id) {
            var btn = new Singularity.Widgets.SidebarRow(icon_name, label_text);
            if (current_view == view_id) btn.set_active(true);
            btn.set_data<string>("view-id", view_id);
            sidebar_rows[view_id] = btn;
            btn.clicked.connect(() => {
                string vid = btn.get_data<string>("view-id") ?? "library";
                activate_view(vid);
            });
            parent.append(btn);
            return btn;
        }

        private void select_sidebar(string view) {
            foreach (var e in sidebar_rows.entries) {
                var row = e.value as Singularity.Widgets.SidebarRow;
                if (row != null) row.set_active(e.key == view);
                else if (e.key == view) e.value.add_css_class("sidebar-nav-active");
                else e.value.remove_css_class("sidebar-nav-active");
            }
        }

        private void activate_view(string vid) {
            if (online != null) online.clear_active();
            if (compare_view != null) close_compare();
            current_view = vid;
            place_records = null;
            if (!vid.has_prefix("person:")) settings.set_string("sidebar-view", current_view);
            if (full_viewer != null && full_viewer.visible) hide_viewer();
            load_photos();
            select_sidebar(vid);
            if (view_action != null) view_action.set_state(new Variant.string(current_view));
            update_photo_actions();
        }

        private void clear_box(Box box) {
            Widget? c;
            while ((c = box.get_first_child()) != null) {
                string? vid = c.get_data<string>("view-id");
                if (vid != null) sidebar_rows.unset(vid);
                box.remove(c);
            }
        }

        private string dynamic_signature() {
            var sb = new StringBuilder();
            foreach (var f in top_folders()) sb.append(("f%" + int64.FORMAT + ":%s;").printf(f.id, f.path));
            foreach (var c in catalog.collections.values) sb.append(("c%" + int64.FORMAT + ":%s:%s:%" + int64.FORMAT + ";").printf(c.id, c.name, c.kind, c.parent_id));
            return sb.str;
        }

        private Gee.ArrayList<FolderRecord> top_folders() {
            var list = new Gee.ArrayList<FolderRecord>();
            foreach (var root in library_roots()) {
                var rf = catalog.folder_for_path(root.get_path() ?? "");
                if (rf == null) continue;
                list.add(rf);
                var children = new Gee.ArrayList<FolderRecord>();
                foreach (var f in catalog.folders.values) if (f.parent_id == rf.id) children.add(f);
                children.sort((a, b) => a.name().collate(b.name()));
                list.add_all(children);
            }
            return list;
        }

        private void rebuild_dynamic_sidebar() {
            if (folders_section == null) return;
            string sig = dynamic_signature();
            if (sig == sidebar_signature) return;
            sidebar_signature = sig;
            clear_box(folders_section);
            clear_box(collections_section);
            var folders = top_folders();
            if (folders.size > 1 || library_roots().length > 1) {
                var head = new Singularity.Widgets.SidebarSectionLabel(_("Folders"));
                var add = new Button.from_icon_name("list-add-symbolic");
                add.add_css_class("flat");
                add.add_css_class("photos-sidebar-add");
                add.tooltip_text = _("Add Folder to Library");
                add.action_name = "win.add-folder";
                head.append(add);
                folders_section.append(head);
                var roots = new Gee.HashSet<string>();
                foreach (var r in library_roots()) roots.add(r.get_path() ?? "");
                foreach (var f in folders) {
                    bool is_root = roots.contains(f.path);
                    var row = add_sidebar_item(folders_section, is_root ? "folder-pictures-symbolic" : "folder-symbolic", f.name(), ("folder:%" + int64.FORMAT).printf(f.id));
                    if (!is_root) row.margin_start = 14;
                    var folder = f;
                    attach_row_menu(row, (menu) => {
                        menu.add_item(_("Synchronize Folder"), "view-refresh-symbolic", () => sync_folder(folder));
                        menu.add_item(_("Show in Files"), "folder-open-symbolic", () => {
                            try {
                                AppInfo.launch_default_for_uri(GLib.File.new_for_path(folder.path).get_uri(), null);
                            } catch (Error e) {
                                warning("Photos: %s", e.message);
                            }
                        });
                    });
                }
            }
            var chead = new Singularity.Widgets.SidebarSectionLabel(_("Collections"));
            var cadd = new Button.from_icon_name("list-add-symbolic");
            cadd.add_css_class("flat");
            cadd.add_css_class("photos-sidebar-add");
            cadd.tooltip_text = _("New Collection");
            cadd.clicked.connect(() => {
                var menu = new Singularity.Widgets.ContextMenu(cadd);
                menu.add_item(_("New Collection…"), "view-grid-symbolic", () => new_collection("manual"));
                menu.add_item(_("New Smart Collection…"), "edit-find-symbolic", () => new_smart_collection(null));
                menu.add_item(_("New Collection Set…"), "folder-symbolic", () => new_collection("set"));
                menu.popup();
            });
            chead.append(cadd);
            collections_section.append(chead);
            add_collection_rows(0, 0);
        }

        private void add_collection_rows(int64 parent_id, int depth) {
            foreach (var c in catalog.child_collections(parent_id)) {
                string icon = c.is_set() ? "folder-symbolic" : (c.is_smart() ? "edit-find-symbolic" : "view-grid-symbolic");
                var row = add_sidebar_item(collections_section, icon, c.name, ("collection:%" + int64.FORMAT).printf(c.id));
                row.margin_start = 14 * depth;
                var col = c;
                attach_row_menu(row, (menu) => {
                    menu.add_item(_("Rename…"), "document-edit-symbolic", () => {
                        LibraryDialogs.ask_text(main_window, _("Rename Collection"), _("Name"), col.name, _("Rename"), (name) => {
                            col.name = name;
                            catalog.update_collection(col);
                        });
                    });
                    if (col.is_smart()) menu.add_item(_("Edit Rules…"), "edit-find-symbolic", () => new_smart_collection(col));
                    if (col.is_set()) {
                        menu.add_item(_("New Collection Here…"), "view-grid-symbolic", () => {
                            CollectionDialogs.create(main_window, catalog, "manual", selected_records(), (created) => {
                                created.parent_id = col.id;
                                catalog.update_collection(created);
                            });
                        });
                    }
                    if (!col.is_set()) {
                        menu.add_item(_("Publish Collection…"), "singularity-share-upload", () => {
                            GLib.File[] files = {};
                            foreach (var r in catalog.collection_photos(col)) if (!r.missing) files += r.file();
                            if (files.length > 0) PhotoPublish.present_collection(main_window, files, col.name);
                        });
                    }
                    if (col.kind == "manual") {
                        menu.add_item(_("Add Selected Photos"), "list-add-symbolic", () => {
                            catalog.begin();
                            foreach (var r in selected_records()) catalog.add_to_collection(col, r);
                            catalog.commit();
                        });
                    }
                    menu.add_separator();
                    menu.add_item(_("Delete"), "user-trash-symbolic", () => {
                        LibraryDialogs.confirm(main_window, _("Delete Collection?"),
                            _("The photos stay in your library. Only the collection \"%s\" is removed.").printf(col.name), _("Delete"), () => {
                                if (current_view == ("collection:%" + int64.FORMAT).printf(col.id)) activate_view("library");
                                catalog.delete_collection(col);
                            });
                    });
                });
                if (c.kind == "manual") {
                    var drop = new DropTarget(typeof(Gdk.FileList), Gdk.DragAction.COPY | Gdk.DragAction.LINK);
                    drop.drop.connect((value, x, y) => {
                        var list = (Gdk.FileList) value.get_boxed();
                        if (list == null) return false;
                        catalog.begin();
                        foreach (var f in list.get_files()) {
                            var r = catalog.find_path(f.get_path() ?? "");
                            if (r != null) catalog.add_to_collection(col, r);
                        }
                        foreach (var r in selected_records()) catalog.add_to_collection(col, r);
                        catalog.commit();
                        main_window.add_toast(new Toast(_("Added to %s").printf(col.name)));
                        return true;
                    });
                    row.add_controller(drop);
                }
                if (c.is_set()) add_collection_rows(c.id, depth + 1);
            }
        }

        private delegate void MenuFiller(Singularity.Widgets.ContextMenu menu);

        private void attach_row_menu(Widget row, owned MenuFiller fill) {
            var gesture = new GestureClick();
            gesture.button = 3;
            gesture.pressed.connect((n, x, y) => {
                var menu = new Singularity.Widgets.ContextMenu(row);
                var r = Gdk.Rectangle();
                r.x = (int) x;
                r.y = (int) y;
                r.width = r.height = 1;
                menu.pointing_to = r;
                fill(menu);
                menu.popup();
            });
            row.add_controller(gesture);
        }

        private void new_collection(string kind) {
            CollectionDialogs.create(main_window, catalog, kind, selected_records(), (c) => {
                if (!c.is_set()) activate_view(("collection:%" + int64.FORMAT).printf(c.id));
            });
        }

        private void new_smart_collection(CollectionRecord? existing) {
            CollectionDialogs.edit_smart(main_window, catalog, existing, (c) => {
                activate_view(("collection:%" + int64.FORMAT).printf(c.id));
            });
        }

        private void sync_folder(FolderRecord folder) {
            var files = new Gee.ArrayList<IndexedFile>();
            var root = GLib.File.new_for_path(folder.path);
            LibraryIndexer.walk(root, files, null);
            indexer.apply_files(files, { root }, true);
            var metas = new Gee.ArrayList<IndexedMetadata>();
            foreach (var r in indexer.needing_metadata()) {
                if (r.path.has_prefix(folder.path + "/")) metas.add(LibraryIndexer.read_metadata(r.id, r.path, r.mtime));
            }
            indexer.apply_metadata(metas);
            int missing = 0;
            foreach (var r in catalog.missing_photos()) if (r.path.has_prefix(folder.path + "/")) missing++;
            main_window.add_toast(new Toast(missing > 0
                ? ngettext("Folder synchronized, %d photo is missing", "Folder synchronized, %d photos are missing", missing).printf(missing)
                : _("Folder synchronized")));
        }

        private void schedule_catalog_refresh() {
            if (catalog_refresh_id != 0) return;
            catalog_refresh_id = Timeout.add(250, () => {
                catalog_refresh_id = 0;
                rebuild_dynamic_sidebar();
                if (edit_view == null && retouch_view == null && compare_view == null) refresh_view_keep_selection();
                return Source.REMOVE;
            });
        }

        // ── Toolbar ────────────────────────────────────────────────────────────

        // Grid-only bubbles are hidden while the single-photo viewer is open.
        private Button? _sidebar_bubble = null;
        private Singularity.Widgets.SearchBubble? _search_bubble = null;
        private Button? _import_bubble  = null;
        private double  _viewer_zoom    = 1.0;

        private void setup_toolbar() {
            viewer_bubbles += main_window.add_bubble_icon("go-previous-symbolic", _("Back to Library (Esc)"), () => hide_viewer());
            _sidebar_bubble = main_window.add_bubble_icon("sidebar-show-symbolic", _("Toggle Sidebar (F9)"), () => {
                activate_action("toggle-sidebar", null);
            });
            _search_bubble = main_window.add_bubble_search(_("Search Photos"), (q) => {
                search_query = q.strip();
                load_photos();
            });
            _filter_bubble  = main_window.add_bubble_icon("view-sort-ascending-symbolic", _("Filter and Sort (Ctrl+L)"), () => toggle_filter_bar());
            _info_bubble    = main_window.add_bubble_icon("dialog-information-symbolic", _("Info (Ctrl+Alt+I)"), () => toggle_info_panel());
            zoom_bubbles += main_window.add_bubble_icon("zoom-out-symbolic", _("Zoom out"), () => adjust_zoom(-20));
            zoom_bubbles += main_window.add_bubble_icon("zoom-in-symbolic",  _("Zoom in"),  () => adjust_zoom(20));
            viewer_bubbles += main_window.add_bubble_icon("singularity-share-symbolic", _("Share"), () => main_window.activate_action_variant("win.share", null));
            foreach (var b in viewer_bubbles) b.visible = false;
            edit_bubbles += main_window.add_bubble_text(_("Cancel"), () => {
                if (edit_view != null) edit_view.cancel();
                else if (retouch_view != null) retouch_view.cancel();
            });
            revert_bubble = main_window.add_bubble_text(_("Revert to Original"), () => { if (edit_view != null) edit_view.revert(); });
            edit_bubbles += revert_bubble;
            edit_bubbles += main_window.add_bubble_text(_("Save as Copy"), () => { if (edit_view != null) edit_view.save_copy(); });
            edit_bubbles += main_window.add_bubble_suggested(_("Done"), () => {
                if (edit_view != null) edit_view.save();
                else if (retouch_view != null) retouch_view.save();
            });
            foreach (var b in edit_bubbles) b.visible = false;
            _import_bubble  = main_window.add_bubble_icon("document-save-symbolic", _("Import photos"), () => on_import());
            setup_online();
        }

        private void setup_online() {
            online = new OnlinePhotos(main_window, content_overlay);
            online.library_folder = library_folder;
            main_window.sidebar_scroll.box.append(online.section);
            online.view_requested.connect((view) => {
                if (!online.owns(view)) {
                    show_view(view);
                    return;
                }
                if (full_viewer != null && full_viewer.visible) hide_viewer();
                foreach (var row in sidebar_rows.values) row.remove_css_class("sidebar-nav-active");
                current_view = view;
                load_photos();
                update_photo_actions();
            });
            online.reload_requested.connect(() => {
                if (online.owns(current_view)) load_photos();
            });
            online.loaded.connect(() => update_empty_page());
        }

        private void show_online_photo(OnlinePhoto photo) {
            var preview = online.preview_file(photo);
            try {
                viewer_picture.set_paintable(preview != null ? Gdk.Texture.from_file(preview) : null);
            } catch (Error e) {
                viewer_picture.set_paintable(null);
            }
            online.with_full(photo, (f) => {
                if (f == null || full_viewer == null || !full_viewer.visible) return;
                if (viewer_index < 0 || viewer_index >= (int) photo_store.get_n_items()) return;
                if (photo_store.get_item(viewer_index) != photo) return;
                try {
                    viewer_picture.set_paintable(Gdk.Texture.from_file(f));
                } catch (Error e) {
                    warning("Viewer: %s", e.message);
                }
            });
        }

        private void update_bubbles_for_viewer(bool in_viewer) {
            if (_sidebar_bubble != null) _sidebar_bubble.visible = !in_viewer;
            if (_search_bubble  != null) _search_bubble.visible  = !in_viewer;
            if (_import_bubble  != null) _import_bubble.visible  = !in_viewer;
            if (_filter_bubble  != null) _filter_bubble.visible  = !in_viewer;
            if (filter_revealer != null) filter_revealer.visible = !in_viewer && filter_revealer.reveal_child;
            foreach (var b in viewer_bubbles) b.visible = in_viewer && edit_view == null && retouch_view == null;
            if (online != null) online.set_viewer_open(in_viewer);
        }

        private void adjust_zoom(int delta) {
            if (full_viewer != null && full_viewer.visible) {
                _viewer_zoom = (_viewer_zoom + delta / 100.0).clamp(0.20, 8.0);
                _apply_viewer_zoom();
                return;
            }
            thumb_size = (thumb_size + delta).clamp(80, 240);
            settings.set_int("thumbnail-size", thumb_size);
            load_photos();
        }

        private void _apply_viewer_zoom() {
            if (viewer_picture == null) return;
            // Drive zoom through the Picture's paintable size hint: at
            // 1.0 the picture fits naturally (CONTAIN); above 1.0 we
            // request a larger size so the surrounding ScrolledWindow
            // (if any) allows panning, otherwise the image scales up
            // and overflows the allocation.
            int base_w = viewer_picture.get_width();
            int base_h = viewer_picture.get_height();
            if (base_w <= 0 || base_h <= 0) return;
            viewer_picture.set_size_request(
                (int)(base_w * _viewer_zoom),
                (int)(base_h * _viewer_zoom));
        }

        private void focus_search() {
            if (_search_bubble != null) _search_bubble.grab_focus_entry();
        }

        // ── Content area ───────────────────────────────────────────────────────

        private void setup_content(Box content_box, Box search_host, ScrolledWindow scroll) {
            empty_page = new StatusPage();
            empty_page.hexpand = true;
            empty_page.vexpand = true;
            empty_page.visible = false;
            empty_page.icon_name = "image-x-generic";
            empty_page.title = _("No Results");
            empty_page.description = _("No photos match your search or filters");
            var clear_search = new Button.with_label(_("Clear Search and Filters"));
            clear_search.halign = Align.CENTER;
            clear_search.add_css_class("pill");
            clear_search.add_css_class("suggested-action");
            clear_search.clicked.connect(() => {
                if (_search_bubble != null) _search_bubble.clear();
                search_query = "";
                filter.reset_attributes();
                if (filter_bar != null) filter_bar.sync();
                load_photos();
            });
            empty_page.child = clear_search;
            main_window.content_overlay.add_overlay(empty_page);

            var favorites_page = add_section_page("favorites", "user-bookmarks", _("No Favorites"),
                _("Mark photos as favorite with Ctrl+D to find them here"));
            favorites_page.add_action("image-x-generic", _("Browse Library"),
                _("Pick the photos you love and mark them as favorite"), () => show_view("library"));
            favorites_page.add_action("document-open", _("Import Photos…"),
                _("Copy pictures from anywhere into your library"), () => on_import());

            var recent_page = add_section_page("recent", "document-open-recent", _("No Recent Photos"),
                _("Photos added in the last 30 days appear here"));
            recent_page.add_action("document-open", _("Import Photos…"),
                _("Copy pictures from anywhere into your library"), () => on_import());
            recent_page.add_action("folder-pictures", _("Open Library Folder"),
                _("Photos you put in %s show up here").printf(library_folder.get_basename()),
                () => open_library_folder());
            recent_page.add_action("image-x-generic", _("Browse Library"),
                _("See all the photos in your library"), () => show_view("library"));

            var trash_page = add_section_page("trash", "user-trash-empty", _("Trash Is Empty"),
                _("Deleted photos stay here until you remove them for good"));
            trash_page.add_action("image-x-generic", _("Browse Library"),
                _("See all the photos in your library"), () => show_view("library"));
            trash_page.add_action("user-bookmarks", _("Favorites"),
                _("The photos you marked as favorite"), () => show_view("favorites"));

            welcome_page = new WelcomePage();
            welcome_page.is_section = true;
            welcome_page.hexpand = true;
            welcome_page.vexpand = true;
            welcome_page.visible = false;
            welcome_page.app_icon_name = "dev.sinty.photos";
            welcome_page.title = _("Photos");
            welcome_page.subtitle = _("Import photos or drop them here to add them to your library");
            welcome_page.add_action("image-x-generic", _("Import Photos…"),
                _("Copy pictures from anywhere into your library"), () => on_import());
            welcome_page.add_action("folder-pictures", _("Open Library Folder"),
                _("Photos you put in %s show up here").printf(library_folder.get_basename()),
                () => open_library_folder());
            main_window.content_overlay.add_overlay(welcome_page);


            scroll.set_policy(PolicyType.NEVER, PolicyType.AUTOMATIC);

            photo_store = new GLib.ListStore(typeof(PhotoItem));
            selection = new MultiSelection(photo_store);
            selection.selection_changed.connect(() => {
                update_photo_actions();
                update_info_panel();
            });
            selection.items_changed.connect(() => update_photo_actions());

            photo_grid = new GridView(selection, new SignalListItemFactory());
            photo_grid.add_css_class("photo-grid");
            photo_grid.max_columns = 12;
            photo_grid.min_columns = 2;

            var factory = (SignalListItemFactory)photo_grid.factory;
            factory.setup.connect(on_grid_item_setup);
            factory.bind.connect(on_grid_item_bind);
            factory.unbind.connect(on_grid_item_unbind);

            photo_grid.activate.connect((pos) => show_viewer((int)pos));

            scroll.set_child(photo_grid);
            // Content is already installed by the window (wrapped in
            // HoverControls) - don't re-set it here or we'd drop the bubbles.
        }

        // ── Grid item factory ──────────────────────────────────────────────────

        private void on_grid_item_setup(GLib.Object obj) {
            var list_item = (ListItem)obj;

            var box = new Box(Orientation.VERTICAL, 4);
            box.add_css_class("photo-grid-item");
            box.halign = Align.CENTER;
            box.valign = Align.START;

            var img = new Image();
            img.pixel_size = thumb_size;
            img.add_css_class("photo-thumb");

            // Spinner overlay shown while thumbnail loads
            var spinner = new Spinner();
            spinner.halign = Align.CENTER;
            spinner.valign = Align.CENTER;
            spinner.visible = false;

            var clip = new ThumbClip(img, thumb_size, thumb_size * 3 / 4);
            var thumb_overlay = new Overlay();
            thumb_overlay.set_child(clip);
            thumb_overlay.add_overlay(spinner);

            var badges_top = new Box(Orientation.HORIZONTAL, 3);
            badges_top.add_css_class("photos-badges");
            badges_top.halign = Align.START;
            badges_top.valign = Align.START;
            badges_top.can_target = false;
            thumb_overlay.add_overlay(badges_top);
            var badges_bottom = new Box(Orientation.HORIZONTAL, 3);
            badges_bottom.add_css_class("photos-badges");
            badges_bottom.halign = Align.END;
            badges_bottom.valign = Align.END;
            badges_bottom.can_target = false;
            thumb_overlay.add_overlay(badges_bottom);
            var label_strip = new Box(Orientation.HORIZONTAL, 0);
            label_strip.add_css_class("photos-label-strip");

            var lbl = new Label("");
            lbl.ellipsize = Pango.EllipsizeMode.END;
            lbl.max_width_chars = 14;
            lbl.add_css_class("caption");

            box.append(thumb_overlay);
            box.append(label_strip);
            box.append(lbl);

            // Store refs for bind/unbind
            box.set_data<Image>("thumb-img", img);
            box.set_data<ThumbClip>("thumb-clip", clip);
            box.set_data<Spinner>("thumb-spinner", spinner);
            box.set_data<Box>("badges-top", badges_top);
            box.set_data<Box>("badges-bottom", badges_bottom);
            box.set_data<Box>("label-strip", label_strip);
            box.set_data<Label>("name-label", lbl);

            // Right-click context menu - reads photo from widget data, not closure
            var gesture = new GestureClick();
            gesture.button = 3;
            gesture.pressed.connect((n, x, y) => {
                var pi = box.get_data<PhotoItem>("photo-item");
                if (pi == null) return;
                select_for_context(pi);
                show_photo_context_menu(box, pi, x, y);
            });
            box.add_controller(gesture);

            // Drag source
            var drag_src = new DragSource();
            drag_src.actions = Gdk.DragAction.COPY | Gdk.DragAction.MOVE;
            drag_src.prepare.connect((x, y) => {
                var pi = box.get_data<PhotoItem>("photo-item");
                if (pi == null || !pi.file.query_exists()) return null;
                var bytes = new GLib.Bytes((pi.file.get_uri() + "\r\n").data);
                return new Gdk.ContentProvider.for_bytes("text/uri-list", bytes);
            });
            box.add_controller(drag_src);
            Singularity.Animation.DragLift.attach(drag_src, box);

            var pick = new GestureClick();
            pick.button = 1;
            pick.propagation_phase = PropagationPhase.CAPTURE;
            pick.pressed.connect((n, x, y) => {
                var li = box.get_data<ListItem>("list-item");
                if (li == null || selection == null || n != 1) return;
                var st = pick.get_current_event_state();
                if ((st & (Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.CONTROL_MASK)) != 0) return;
                if (!selection.is_selected(li.position)) selection.select_item(li.position, true);
                photo_grid.grab_focus();
            });
            box.add_controller(pick);

            list_item.set_child(box);
        }

        private void on_grid_item_bind(GLib.Object obj) {
            var list_item = (ListItem)obj;
            var box = (Box)list_item.get_child();
            var img = box.get_data<Image>("thumb-img");
            var spinner = box.get_data<Spinner>("thumb-spinner");
            var lbl = box.get_data<Label>("name-label");
            var photo = (PhotoItem)list_item.get_item();

            box.set_data<PhotoItem>("photo-item", photo);
            box.set_data<ListItem>("list-item", list_item);
            lbl.label = photo.name;
            update_cell_badges(box, photo);
            if (photo.record != null) bound_cells[photo.record.id] = box;
            img.pixel_size = thumb_size;
            var clip = box.get_data<ThumbClip>("thumb-clip");
            if (clip != null) clip.resize(thumb_size, thumb_size * 3 / 4);
            img.set_from_icon_name("image-loading-symbolic");
            spinner.spinning = true;
            spinner.visible = true;

            string path = photo.path;
            img.set_data<string>("thumb-for-path", path);
            if (photo is OnlinePhoto && online != null) {
                online.bind_thumbnail(img, spinner, (OnlinePhoto) photo, thumb_size);
                return;
            }
            var cached = thumb_cache_get(photo, thumb_size);
            if (cached != null) {
                img.set_from_paintable(cached);
                spinner.spinning = false;
                spinner.visible = false;
                return;
            }
            load_thumbnail_async(img, spinner, path, thumb_size, photo.variant(), photo);
        }

        private Gee.HashMap<int64?, Box> bound_cells = new Gee.HashMap<int64?, Box>(id_hash, id_equal);
        private Gee.HashMap<string, Gdk.Texture> thumb_cache = new Gee.HashMap<string, Gdk.Texture>();
        private Gee.LinkedList<string> thumb_order = new Gee.LinkedList<string>();

        private string thumb_key(PhotoItem photo, int size) {
            int64 stamp = photo.record != null ? photo.record.mtime : 0;
            return ("%s|%s|%d|%" + int64.FORMAT).printf(photo.path, photo.variant(), size, stamp);
        }

        private Gdk.Texture? thumb_cache_get(PhotoItem photo, int size) {
            if (photo is OnlinePhoto) return null;
            return thumb_cache[thumb_key(photo, size)];
        }

        private void thumb_cache_put(PhotoItem photo, int size, Gdk.Texture tex) {
            string k = thumb_key(photo, size);
            if (!thumb_cache.has_key(k)) thumb_order.add(k);
            thumb_cache[k] = tex;
            while (thumb_order.size > 1500) thumb_cache.unset(thumb_order.poll_head());
        }

        private void invalidate_thumb(PhotoItem photo) {
            var drop = new Gee.ArrayList<string>();
            foreach (var k in thumb_cache.keys) if (k.has_prefix(photo.path + "|" + photo.variant() + "|")) drop.add(k);
            foreach (var k in drop) thumb_cache.unset(k);
        }

        private Widget badge(string? icon, string? text, string? css = null) {
            var b = new Box(Orientation.HORIZONTAL, 2);
            b.add_css_class("photos-badge");
            if (css != null) b.add_css_class(css);
            if (icon != null) b.append(new Image.from_icon_name(icon));
            if (text != null) b.append(new Label(text));
            return b;
        }

        private void update_cell_badges(Box box, PhotoItem photo) {
            var top = box.get_data<Box>("badges-top");
            var bottom = box.get_data<Box>("badges-bottom");
            var strip = box.get_data<Box>("label-strip");
            if (top == null) return;
            Widget? c;
            while ((c = top.get_first_child()) != null) top.remove(c);
            while ((c = bottom.get_first_child()) != null) bottom.remove(c);
            foreach (var l in COLOR_LABELS) strip.remove_css_class("photos-label-" + l);
            box.remove_css_class("rejected");
            box.remove_css_class("missing");
            var r = photo.record;
            if (r == null) return;
            if (r.flag == PickFlag.PICK) top.append(badge("object-select-symbolic", null, "pick"));
            if (r.flag == PickFlag.REJECT) {
                top.append(badge("action-unavailable-symbolic", null, "reject"));
                box.add_css_class("rejected");
            }
            if (r.rating > 0) top.append(badge("starred-symbolic", r.rating.to_string()));
            if (r.missing) {
                bottom.append(badge("dialog-warning-symbolic", _("Missing")));
                box.add_css_class("missing");
            }
            if (r.is_virtual_copy()) bottom.append(badge("edit-copy-symbolic", null));
            if (r.stack_id != 0 && r.stack_pos == 0 && !filter.expanded_stacks.contains(r.stack_id)) {
                int n = catalog.stack_members(r.stack_id).size;
                if (n > 1) bottom.append(badge("view-app-grid-symbolic", n.to_string()));
            }
            if (r.edited) bottom.append(badge("document-edit-symbolic", null));
            if (r.kind == "raw") bottom.append(badge(null, "RAW"));
            if (r.label != "") strip.add_css_class("photos-label-" + r.label);
            top.visible = top.get_first_child() != null;
            bottom.visible = bottom.get_first_child() != null;
        }

        private void refresh_record_cell(PhotoRecord r) {
            var box = bound_cells[r.id];
            if (box == null) return;
            var photo = box.get_data<PhotoItem>("photo-item");
            if (photo != null && photo.record == r) update_cell_badges(box, photo);
        }

        private void on_grid_item_unbind(GLib.Object obj) {
            var list_item = (ListItem)obj;
            var box = (Box)list_item.get_child();
            var img = box.get_data<Image>("thumb-img");
            var spinner = box.get_data<Spinner>("thumb-spinner");
            if (img != null) img.set_data<string>("thumb-for-path", "");
            var photo = box.get_data<PhotoItem>("photo-item");
            if (photo != null && photo.record != null && bound_cells[photo.record.id] == box) bound_cells.unset(photo.record.id);
            if (spinner != null) { spinner.spinning = false; spinner.visible = false; }
        }

        private void load_thumbnail_async(Image img, Spinner? spinner, string file_path, int size, string variant = "", PhotoItem? item = null) {
            string path = file_path;
            int px = size;
            string var_id = variant;

            new GLib.Thread<void>("photo-thumb", () => {
                Gdk.Pixbuf? pb = null;
                try {
                    string source = path;
                    if (path != "") {
                        var shown = EditImageIO.display_file(GLib.File.new_for_path(path), var_id);
                        if (shown != null && shown.get_path() != null) source = shown.get_path();
                    }
                    if (LivePhoto.is_video_name(source)) {
                        var poster = VideoTools.cached_poster(GLib.File.new_for_path(source), int.max(px * 2, 256));
                        if (poster != null) source = poster.get_path();
                    }
                    pb = EditImageIO.oriented(new Gdk.Pixbuf.from_file_at_scale(source, px, px, true));
                } catch (Error e) {}
                GLib.Idle.add(() => {
                    string? expected = img.get_data<string>("thumb-for-path");
                    if (expected != null && expected == path) {
                        if (pb != null) {
                            var tex = Gdk.Texture.for_pixbuf(pb);
                            img.set_from_paintable(tex);
                            if (item != null) thumb_cache_put(item, px, tex);
                        } else
                            img.set_from_icon_name("image-x-generic-symbolic");
                        if (spinner != null) {
                            spinner.spinning = false;
                            spinner.visible = false;
                        }
                    }
                    return GLib.Source.REMOVE;
                });
            });
        }

        // ── Viewer ─────────────────────────────────────────────────────────────

        private void setup_viewer() {
            full_viewer = new Overlay();
            full_viewer.add_css_class("photo-viewer-overlay");
            full_viewer.halign = Align.FILL;
            full_viewer.valign = Align.FILL;
            full_viewer.hexpand = true;
            full_viewer.vexpand = true;
            full_viewer.visible = false;

            // Translucent background - click to close
            var bg = new Box(Orientation.VERTICAL, 0);
            bg.hexpand = true;
            bg.vexpand = true;
            var bg_click = new GestureClick();
            bg_click.button = 1;
            bg_click.pressed.connect(() => hide_viewer());
            bg.add_controller(bg_click);
            full_viewer.set_child(bg);

            // Full-screen photo display
            viewer_picture = new Picture();
            viewer_picture.halign = Align.FILL;
            viewer_picture.valign = Align.FILL;
            viewer_picture.content_fit = ContentFit.CONTAIN;
            viewer_picture.can_shrink = true;
            viewer_picture.hexpand = true;
            viewer_picture.vexpand = true;
            // Capture click so it doesn't fall through to bg
            var pic_click = new GestureClick();
            pic_click.button = 1;
            pic_click.propagation_phase = PropagationPhase.CAPTURE;
            pic_click.pressed.connect((n, x, y) => {
                pic_click.set_state(EventSequenceState.CLAIMED);
            });
            viewer_picture.add_controller(pic_click);
            full_viewer.add_overlay(viewer_picture);

            viewer_spinner = new Spinner();
            viewer_spinner.halign = Align.CENTER;
            viewer_spinner.valign = Align.CENTER;
            viewer_spinner.width_request = 48;
            viewer_spinner.height_request = 48;
            viewer_spinner.can_target = false;
            viewer_spinner.visible = false;
            full_viewer.add_overlay(viewer_spinner);

            video_view = new PhotoVideoView();
            video_view.visible = false;
            video_view.message.connect((text) => main_window.add_toast(new Toast(text)));
            apply_bubble_inset(video_view, 64, 12);
            video_view.margin_bottom = 84;
            full_viewer.add_overlay(video_view);

            live_text = new LiveTextSession();
            live_text.view.set_geometry_func((out ox, out oy, out scale) => picture_geometry(out ox, out oy, out scale));
            full_viewer.add_overlay(live_text.view);
            live_text.bar.valign = Align.START;
            apply_bubble_inset(live_text.bar, 64, 12);
            full_viewer.add_overlay(live_text.bar);
            viewer_picture.notify["paintable"].connect(() => {
                live_text.set_texture(viewer_picture.paintable as Gdk.Texture);
            });

            // Bottom controls bar
            var controls_bar = new Singularity.Widgets.ControlStrip(0, 20);
            controls_bar.add_css_class("photo-viewer-controls");
            controls_bar.halign = Align.CENTER;
            controls_bar.valign = Align.END;

            var rot_left = new Button.from_icon_name("object-rotate-left-symbolic");
            rot_left.add_css_class("flat");
            rot_left.tooltip_text = _("Rotate Left");
            rot_left.clicked.connect(() => rotate_current(-90));
            controls_bar.append(rot_left);

            var prev_btn = new Button.from_icon_name("go-previous-symbolic");
            prev_btn.add_css_class("flat");
            prev_btn.tooltip_text = _("Previous (Left)");
            prev_btn.clicked.connect(() => navigate_viewer(-1));
            controls_bar.append(prev_btn);

            viewer_fav_btn = new Button.from_icon_name("non-starred-symbolic");
            viewer_fav_btn.add_css_class("flat");
            viewer_fav_btn.tooltip_text = _("Favorite");
            viewer_fav_btn.clicked.connect(() => toggle_favorite_current());
            controls_bar.append(viewer_fav_btn);

            viewer_filename_label = new Label("");
            viewer_filename_label.add_css_class("title-4");
            viewer_filename_label.halign = Align.CENTER;
            viewer_filename_label.hexpand = true;
            viewer_filename_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            viewer_filename_label.width_chars = 14;
            controls_bar.append(viewer_filename_label);

            viewer_info_label = new Label("");
            viewer_info_label.add_css_class("caption");
            viewer_info_label.add_css_class("dim-label");
            controls_bar.append(viewer_info_label);

            var next_btn = new Button.from_icon_name("go-next-symbolic");
            next_btn.add_css_class("flat");
            next_btn.tooltip_text = _("Next (Right)");
            next_btn.clicked.connect(() => navigate_viewer(1));
            controls_bar.append(next_btn);

            var edit_btn = new Button.from_icon_name("singularity-photos-adjust-symbolic");
            edit_btn.add_css_class("flat");
            edit_btn.tooltip_text = _("Edit (Ctrl+E)");
            edit_btn.action_name = "win.edit";
            controls_bar.append(edit_btn);

            var markup_btn = new Button.from_icon_name("singularity-markup-symbolic");
            markup_btn.add_css_class("flat");
            markup_btn.tooltip_text = _("Markup");
            markup_btn.action_name = "win.markup";
            controls_bar.append(markup_btn);

            live_text.toggle.tooltip_text = _("Live Text");
            controls_bar.append(live_text.toggle);

            live_btn = new Button.with_label(_("Live"));
            live_btn.add_css_class("flat");
            live_btn.tooltip_text = _("Play the Live Photo");
            live_btn.visible = false;
            live_btn.clicked.connect(() => {
                var ph = current_photo();
                if (ph != null) play_live(ph.file);
            });
            controls_bar.append(live_btn);

            var info_btn = new Button.from_icon_name("dialog-information-symbolic");
            info_btn.add_css_class("flat");
            info_btn.tooltip_text = _("Info (Ctrl+Alt+I)");
            info_btn.action_name = "win.info-panel";
            controls_bar.append(info_btn);

            var rot_right = new Button.from_icon_name("object-rotate-right-symbolic");
            rot_right.add_css_class("flat");
            rot_right.tooltip_text = _("Rotate Right");
            rot_right.clicked.connect(() => rotate_current(90));
            controls_bar.append(rot_right);

            full_viewer.add_overlay(controls_bar);
            content_overlay.add_overlay(full_viewer);

            // Keyboard navigation (only active when viewer is open)
            var key_ctrl = new EventControllerKey();
            key_ctrl.key_pressed.connect((keyval, keycode, state) => {
                if (retouch_view != null) {
                    if (keyval == Gdk.Key.Escape) { retouch_view.cancel(); return true; }
                    return false;
                }
                if (compare_view != null) return false;
                if (edit_view == null && handle_library_key(keyval, state)) return true;
                if (full_viewer == null || !full_viewer.visible) return false;
                if (edit_view != null) {
                    if (keyval == Gdk.Key.Escape) { edit_view.cancel(); return true; }
                    return false;
                }
                if (keyval == Gdk.Key.Escape) { hide_viewer(); return true; }
                if (keyval == Gdk.Key.Left)  { navigate_viewer(-1); return true; }
                if (keyval == Gdk.Key.Right) { navigate_viewer(1);  return true; }
                return false;
            });
            ((Gtk.Widget)main_window).add_controller(key_ctrl);
            var lib_keys = new EventControllerKey();
            lib_keys.propagation_phase = PropagationPhase.CAPTURE;
            lib_keys.key_pressed.connect((keyval, keycode, state) => {
                if (retouch_view != null || compare_view != null || edit_view != null) return false;
                if ((state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK)) != 0) return false;
                if (!((keyval >= Gdk.Key.@0 && keyval <= Gdk.Key.@9) || keyval == Gdk.Key.p || keyval == Gdk.Key.x || keyval == Gdk.Key.u
                      || keyval == Gdk.Key.c || keyval == Gdk.Key.n || keyval == Gdk.Key.s)) return false;
                return handle_library_key(keyval, state);
            });
            ((Gtk.Widget)main_window).add_controller(lib_keys);
        }

        private void show_viewer(int index) {
            viewer_index = index;
            viewer_rotation = 0;
            _viewer_zoom = 1.0;
            bool was_open = full_viewer.visible;
            full_viewer.visible = true;
            update_bubbles_for_viewer(true);
            load_viewer_photo();
            update_photo_actions();
            main_window.grab_focus();
            if (!was_open) morph_viewer(false);
        }

        private PhotoVideoView? video_view = null;
        private Button? live_btn = null;
        private uint live_serial = 0;

        private void stop_video() {
            if (video_view == null || !video_view.visible) return;
            video_view.stop();
            video_view.visible = false;
            viewer_picture.visible = true;
        }

        private void play_live(File file) {
            if (video_view == null) return;
            if (video_view.visible) {
                stop_video();
                return;
            }
            if (video_view.open(file)) {
                viewer_picture.visible = false;
                video_view.visible = true;
            }
        }

        private void update_live_button(PhotoItem photo) {
            if (live_btn == null) return;
            live_btn.visible = false;
            if (photo is OnlinePhoto || (photo.record != null && photo.record.kind == "video")) return;
            uint serial = ++live_serial;
            var file = photo.file;
            new GLib.Thread<void>("photo-live", () => {
                bool has = LivePhoto.playable_for(file) != null;
                GLib.Idle.add(() => {
                    if (serial == live_serial && live_btn != null) live_btn.visible = has;
                    return Source.REMOVE;
                });
            });
        }

        private void hide_viewer() {
            stop_video();
            if (live_text != null) live_text.active = false;
            if (full_viewer != null && full_viewer.visible && !viewer_closing) {
                viewer_closing = true;
                morph_viewer(true);
                return;
            }
            finish_hide_viewer();
        }

        private bool viewer_closing = false;

        private void finish_hide_viewer() {
            viewer_closing = false;
            if (full_viewer != null) full_viewer.visible = false;
            update_bubbles_for_viewer(false);
            update_photo_actions();
        }

        private Widget? grid_cell_for(int index) {
            if (index < 0 || index >= (int) photo_store.get_n_items()) return null;
            var photo = photo_store.get_item(index) as PhotoItem;
            return find_cell(photo_grid, photo);
        }

        private Widget? find_cell(Widget root, PhotoItem? photo) {
            for (var child = root.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (child.get_data<PhotoItem>("photo-item") == photo && child.get_mapped()) return child;
                var found = find_cell(child, photo);
                if (found != null) return found;
            }
            return null;
        }

        private Graphene.Rect? viewer_content_rect() {
            var paintable = viewer_picture.paintable;
            if (paintable == null) return null;
            return Singularity.Animation.WidgetMorph.contain(viewer_picture.get_width(), viewer_picture.get_height(),
                paintable.get_intrinsic_width(), paintable.get_intrinsic_height());
        }

        private void morph_viewer(bool closing) {
            var cell = grid_cell_for(viewer_index);
            Graphene.Rect rect = Graphene.Rect();
            bool known = cell != null && cell.compute_bounds(full_viewer, out rect);
            if (closing) {
                Singularity.Motion.tween(full_viewer, "opacity", 0.0,
                    Singularity.Motion.Duration.LARGE, Singularity.Motion.Curve.EXIT).done.connect(() => {
                        full_viewer.opacity = 1.0;
                        finish_hide_viewer();
                    });
                if (known) Singularity.Animation.WidgetMorph.shrink(viewer_picture, rect, full_viewer, viewer_content_rect());
                return;
            }
            full_viewer.opacity = 0.0;
            Singularity.Motion.tween(full_viewer, "opacity", 1.0,
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
            if (!known) return;
            var clock = full_viewer.get_frame_clock();
            if (clock == null) return;
            ulong handler = 0;
            handler = clock.layout.connect_after(() => {
                clock.disconnect(handler);
                if (!full_viewer.visible || viewer_closing) return;
                Singularity.Animation.WidgetMorph.grow(viewer_picture, rect, full_viewer, viewer_content_rect());
            });
            full_viewer.queue_allocate();
        }

        private void load_viewer_photo() {
            if (full_viewer == null || viewer_picture == null) return;
            uint n = photo_store.get_n_items();
            if (n == 0) return;
            if (viewer_index < 0) viewer_index = 0;
            if (viewer_index >= (int)n) viewer_index = (int)n - 1;

            var photo = (PhotoItem)photo_store.get_item(viewer_index);

            viewer_picture.remove_css_class("rotate-90");
            viewer_picture.remove_css_class("rotate-180");
            viewer_picture.remove_css_class("rotate-270");

            if (photo is OnlinePhoto && online != null && !photo.file.query_exists()) {
                cancel_viewer_load();
                show_online_photo((OnlinePhoto) photo);
            } else {
                stop_video();
                if (photo.record != null && photo.record.kind == "video") {
                    cancel_viewer_load();
                    viewer_picture.set_paintable(null);
                    play_live(photo.file);
                } else {
                    load_viewer_texture(photo.file);
                }
                update_live_button(photo);
            }

            if (viewer_filename_label != null)
                viewer_filename_label.label = photo.name;

            if (viewer_info_label != null) {
                string info = "";
                if (photo.modified != null)
                    info = photo.modified.format("%B %d, %Y") ?? "";
                if (photo.file_size > 0) {
                    if (info != "") info += " · ";
                    info += format_size(photo.file_size);
                }
                viewer_info_label.label = info;
            }

            update_fav_button(photo);
            if (viewer_fav_btn != null) viewer_fav_btn.visible = !(photo is OnlinePhoto);
            update_info_panel();
        }

        private void cancel_viewer_load() {
            viewer_load_serial++;
            if (viewer_spinner_id != 0) {
                Source.remove(viewer_spinner_id);
                viewer_spinner_id = 0;
            }
            if (viewer_spinner != null) {
                viewer_spinner.spinning = false;
                viewer_spinner.visible = false;
            }
        }

        private void load_viewer_texture(File file) {
            cancel_viewer_load();
            uint serial = viewer_load_serial;
            viewer_spinner_id = Timeout.add(120, () => {
                viewer_spinner_id = 0;
                if (serial != viewer_load_serial) return Source.REMOVE;
                viewer_picture.set_paintable(null);
                viewer_spinner.visible = true;
                viewer_spinner.spinning = true;
                return Source.REMOVE;
            });
            new GLib.Thread<void>("photo-view", () => {
                Gdk.Texture? texture = null;
                try {
                    texture = EditImageIO.load_display_texture(file);
                } catch (Error e) {
                    warning("Viewer: %s", e.message);
                }
                GLib.Idle.add(() => {
                    if (serial != viewer_load_serial) return Source.REMOVE;
                    cancel_viewer_load();
                    viewer_picture.set_paintable(texture);
                    return Source.REMOVE;
                });
            });
        }

        private void update_fav_button(PhotoItem photo) {
            if (viewer_fav_btn == null) return;
            string[] favs = settings.get_strv("favorites");
            string uri = photo.file.get_uri();
            bool is_fav = false;
            foreach (var f in favs) {
                if (f == uri) { is_fav = true; break; }
            }
            viewer_fav_btn.icon_name = is_fav ? "starred-symbolic" : "non-starred-symbolic";
        }

        private void navigate_viewer(int delta) {
            uint n = photo_store.get_n_items();
            if (n == 0) return;
            viewer_index += delta;
            if (viewer_index < 0) viewer_index = (int)n - 1;
            if (viewer_index >= (int)n) viewer_index = 0;
            viewer_rotation = 0;
            load_viewer_photo();
            update_photo_actions();
        }

        private void rotate_current(int degrees) {
            if (viewer_picture == null) return;
            viewer_rotation = (viewer_rotation + degrees) % 360;
            if (viewer_rotation < 0) viewer_rotation += 360;
            viewer_picture.remove_css_class("rotate-90");
            viewer_picture.remove_css_class("rotate-180");
            viewer_picture.remove_css_class("rotate-270");
            if (live_text != null) {
                live_text.active = live_text.active && viewer_rotation == 0;
                live_text.toggle.sensitive = viewer_rotation == 0;
            }
            if (viewer_rotation == 90)       viewer_picture.add_css_class("rotate-90");
            else if (viewer_rotation == 180) viewer_picture.add_css_class("rotate-180");
            else if (viewer_rotation == 270) viewer_picture.add_css_class("rotate-270");
        }

        private void toggle_favorite_current() {
            uint n = photo_store.get_n_items();
            if (viewer_index < 0 || viewer_index >= (int)n) return;
            var photo = (PhotoItem)photo_store.get_item(viewer_index);
            toggle_favorite_photo(photo);
            update_fav_button(photo);
        }

        private void toggle_favorite_photo(PhotoItem photo) {
            string uri = photo.file.get_uri();
            string[] favs = settings.get_strv("favorites");
            bool was_fav = false;
            var new_favs = new GLib.Array<string>();
            foreach (var f in favs) {
                if (f == uri) was_fav = true;
                else new_favs.append_val(f);
            }
            if (!was_fav) new_favs.append_val(uri);
            settings.set_strv("favorites", new_favs.data);
            update_photo_actions();
        }

        private Gee.HashMap<string, Button> sidebar_rows = new Gee.HashMap<string, Button>();
        private SimpleAction? view_action = null;
        private SimpleAction[] photo_actions = {};
        private SimpleAction[] viewer_actions = {};
        private SimpleAction? trash_action = null;
        private SimpleAction? open_photo_action = null;
        private SimpleAction? favorite_action = null;

        private SimpleAction add_win_action(string name, owned Singularity.Widgets.Window.BubbleAction func) {
            var act = new SimpleAction(name, null);
            act.activate.connect(() => func());
            main_window.add_action(act);
            return act;
        }

        private void setup_window_actions() {
            add_win_action("close", () => main_window.close());
            add_win_action("find", () => {
                focus_search();
            });
            add_win_action("zoom-in", () => adjust_zoom(20));
            add_win_action("zoom-out", () => adjust_zoom(-20));
            view_action = new SimpleAction.stateful("view", VariantType.STRING, new Variant.string(current_view));
            view_action.activate.connect((param) => {
                if (full_viewer != null && full_viewer.visible) hide_viewer();
                activate_view(param.get_string());
            });
            main_window.add_action(view_action);
            var fullscreen = new SimpleAction.stateful("fullscreen", null, new Variant.boolean(false));
            fullscreen.activate.connect(() => {
                if (main_window.fullscreened) main_window.unfullscreen();
                else main_window.fullscreen();
            });
            main_window.notify["fullscreened"].connect(() => fullscreen.set_state(new Variant.boolean(main_window.fullscreened)));
            main_window.add_action(fullscreen);
            photo_actions += add_win_action("copy", () => {
                if (live_text != null && live_text.active && live_text.view.copy_selection()) return;
                var photo = current_photo();
                if (photo == null) return;
                if (photo is OnlinePhoto && online != null && !photo.file.query_exists()) {
                    online.with_full((OnlinePhoto) photo, (f) => {
                        if (f == null) return;
                        try {
                            Gdk.Display.get_default().get_clipboard().set_texture(Gdk.Texture.from_file(f));
                        } catch (Error e) { warning("Copy: %s", e.message); }
                    });
                    return;
                }
                try {
                    var texture = Gdk.Texture.from_file(photo.file);
                    Gdk.Display.get_default().get_clipboard().set_texture(texture);
                } catch (Error e) { warning("Copy: %s", e.message); }
            });
            favorite_action = new SimpleAction.stateful("favorite", null, new Variant.boolean(false));
            favorite_action.activate.connect(() => {
                var photo = current_photo();
                if (photo == null) return;
                toggle_favorite_photo(photo);
                update_fav_button(photo);
            });
            main_window.add_action(favorite_action);
            photo_actions += favorite_action;
            trash_action = add_win_action("trash", () => {
                var photo = current_photo();
                if (photo == null) return;
                try {
                    photo.file.trash(null);
                    if (full_viewer != null && full_viewer.visible) hide_viewer();
                    load_photos();
                } catch (Error e) { warning("Trash: %s", e.message); }
            });
            open_photo_action = add_win_action("open-photo", () => {
                int pos = first_selected_position();
                if (pos >= 0) show_viewer(pos);
            });
            photo_actions += add_win_action("set-wallpaper", () => {
                var photo = current_photo();
                if (photo == null) return;
                var desktop_settings = Singularity.Core.safe_settings(Singularity.Runtime.desktop_settings_schema);
                if (desktop_settings != null) desktop_settings.set_string("background-picture-uri", photo.file.get_uri());
            });
            photo_actions += Singularity.Share.add_action(main_window, main_window, () => {
                var photo = current_photo();
                return photo != null ? new Singularity.ShareContent.for_files({ photo.file }) : null;
            });
            viewer_actions += add_win_action("previous", () => navigate_viewer(-1));
            viewer_actions += add_win_action("next", () => navigate_viewer(1));
            viewer_actions += add_win_action("close-photo", () => hide_viewer());
            viewer_actions += add_win_action("rotate-left", () => rotate_current(-90));
            viewer_actions += add_win_action("rotate-right", () => rotate_current(90));
            viewer_actions += add_win_action("markup", () => open_markup());
            edit_action = add_win_action("edit", () => open_editor());
            viewer_actions += edit_action;
            setup_edit_actions();
            viewer_actions += add_win_action("live-text", () => {
                if (live_text != null && live_text.toggle.sensitive) live_text.active = !live_text.active;
            });
            update_photo_actions();
        }

        private bool picture_geometry(out double ox, out double oy, out double scale) {
            ox = 0;
            oy = 0;
            scale = 1;
            var paintable = viewer_picture != null ? viewer_picture.paintable : null;
            if (paintable == null || live_text == null) return false;
            Graphene.Rect bounds;
            if (!viewer_picture.compute_bounds(live_text.view, out bounds)) return false;
            double w = paintable.get_intrinsic_width(), h = paintable.get_intrinsic_height();
            if (w <= 0 || h <= 0) return false;
            scale = double.min(bounds.size.width / w, bounds.size.height / h);
            ox = bounds.origin.x + (bounds.size.width - w * scale) / 2;
            oy = bounds.origin.y + (bounds.size.height - h * scale) / 2;
            return true;
        }

        private SimpleAction edit_param_action(string name, VariantType? type, owned EditParamFunc func) {
            var act = new SimpleAction(name, type);
            act.activate.connect((param) => { if (edit_view != null) func(edit_view, param); });
            act.set_enabled(false);
            main_window.add_action(act);
            edit_actions += act;
            return act;
        }

        private delegate void EditParamFunc(EditView view, Variant? param);

        private void setup_edit_actions() {
            edit_param_action("edit-done", null, (v, p) => v.save());
            edit_param_action("edit-cancel", null, (v, p) => v.cancel());
            edit_param_action("edit-revert", null, (v, p) => v.revert());
            edit_param_action("edit-save-copy", null, (v, p) => v.save_copy());
            edit_param_action("edit-auto-enhance", null, (v, p) => v.auto_enhance());
            edit_param_action("edit-undo", null, (v, p) => v.undo());
            edit_param_action("edit-redo", null, (v, p) => v.redo());
            edit_param_action("edit-flip", null, (v, p) => v.flip());
            edit_param_action("edit-compare", VariantType.BOOLEAN, (v, p) => v.set_compare(p.get_boolean()));
            edit_param_action("edit-page", VariantType.STRING, (v, p) => v.show_page(p.get_string()));
            edit_param_action("edit-filter", VariantType.STRING, (v, p) => v.set_filter(p.get_string()));
            edit_param_action("edit-rotate", VariantType.INT32, (v, p) => v.rotate(p.get_int32()));
            edit_param_action("edit-aspect", VariantType.INT32, (v, p) => v.select_aspect(p.get_int32()));
            edit_param_action("edit-straighten", VariantType.DOUBLE, (v, p) => v.set_straighten(p.get_double()));
            edit_param_action("edit-adjust", new VariantType("(sd)"), (v, p) => {
                string key;
                double value;
                p.get("(sd)", out key, out value);
                v.set_adjustment(key, value);
            });
            edit_param_action("edit-crop", new VariantType("(dddd)"), (v, p) => {
                double x, y, w, h;
                p.get("(dddd)", out x, out y, out w, out h);
                v.set_crop(x, y, w, h);
            });
        }

        private void open_editor() {
            var photo = current_photo();
            if (photo == null || edit_view != null || photo is OnlinePhoto || !photo.file.query_exists()) return;
            if (live_text != null) live_text.active = false;
            edit_view = new EditView(photo.file, photo.variant());
            edit_host = new Box(Orientation.VERTICAL, 0);
            edit_host.add_css_class("photo-edit-host");
            edit_host.hexpand = true;
            edit_host.vexpand = true;
            edit_host.append(edit_view);
            content_overlay.add_overlay(edit_host);
            edit_view.message.connect((text) => main_window.add_toast(new Toast(text)));
            edit_view.notify["can-revert"].connect(update_edit_bubbles);
            var target = edit_view;
            edit_view.finished.connect((saved) => close_editor(target, saved));
            foreach (var b in zoom_bubbles) b.visible = false;
            foreach (var b in viewer_bubbles) b.visible = false;
            foreach (var b in edit_bubbles) b.visible = true;
            sidebar_before_edit = main_window.get_sidebar_visible();
            main_window.set_sidebar_visible(false);
            main_window.side_host.visible = false;
            update_edit_bubbles();
            foreach (var act in edit_actions) act.set_enabled(true);
            update_photo_actions();
            edit_view.grab_focus();
        }

        private void update_edit_bubbles() {
            if (revert_bubble == null) return;
            revert_bubble.visible = edit_view != null && edit_view.can_revert;
        }

        private void close_editor(EditView view, bool changed) {
            if (edit_view != view) return;
            var host = edit_host;
            edit_view = null;
            edit_host = null;
            foreach (var b in edit_bubbles) b.visible = false;
            foreach (var b in zoom_bubbles) b.visible = true;
            foreach (var b in viewer_bubbles) b.visible = full_viewer != null && full_viewer.visible;
            foreach (var act in edit_actions) act.set_enabled(false);
            main_window.set_sidebar_visible(sidebar_before_edit);
            main_window.side_host.visible = true;
            host.can_target = false;
            Singularity.Motion.conceal(host, Singularity.Motion.Preset.FADE).done.connect(() => content_overlay.remove_overlay(host));
            if (changed) {
                var photo = current_photo();
                if (photo != null && photo.record != null) {
                    invalidate_thumb(photo);
                    photo.record.edited = EditStore.has_edits(photo.file, photo.variant());
                    catalog.save(photo.record);
                }
                load_viewer_photo();
                if (EditStore.has_edits(view.file))
                    main_window.add_toast(new Toast(_("Edits saved. Use Revert to Original in Edit to undo them.")));
                refresh_thumbnails();
            }
            update_photo_actions();
        }

        private void refresh_thumbnails() {
            uint n = photo_store.get_n_items();
            if (n == 0) return;
            photo_store.items_changed(0, n, n);
        }

        private void open_markup() {
            var photo = current_photo();
            if (photo == null || !photo.file.query_exists()) return;
            var file = photo.file;
            new GLib.Thread<void>("photo-markup", () => {
                var source = EditImageIO.markup_source(file);
                GLib.Idle.add(() => {
                    present_markup(file, source);
                    return Source.REMOVE;
                });
            });
        }

        private void present_markup(File file, File source) {
            var window = source.equal(file) ? new MarkupWindow(this, file, false) : new MarkupWindow.for_rendition(this, file, source);
            window.transient_for = main_window;
            window.saved.connect((target) => {
                main_window.add_toast(new Toast(_("Saved as %s").printf(target.get_basename())));
            });
            window.present();
        }

        private PhotoItem? current_photo() {
            if (full_viewer != null && full_viewer.visible) {
                if (viewer_index < 0 || viewer_index >= (int) photo_store.get_n_items()) return null;
                return (PhotoItem) photo_store.get_item(viewer_index);
            }
            int pos = first_selected_position();
            return pos >= 0 ? (PhotoItem) photo_store.get_item(pos) : null;
        }

        private int first_selected_position() {
            if (selection == null) return -1;
            var bits = selection.get_selection();
            if (bits.is_empty()) return -1;
            uint pos = bits.get_minimum();
            return pos < photo_store.get_n_items() ? (int) pos : -1;
        }

        private void update_photo_actions() {
            if (trash_action == null) return;
            bool in_viewer = full_viewer != null && full_viewer.visible;
            bool has_photo = current_photo() != null;
            foreach (var act in photo_actions) act.set_enabled(has_photo);
            foreach (var act in viewer_actions) act.set_enabled(in_viewer);
            if (edit_action != null) {
                var photo = in_viewer ? current_photo() : null;
                edit_action.set_enabled(photo != null && !(photo is OnlinePhoto) && edit_view == null);
            }
            trash_action.set_enabled(has_photo && current_view != "trash");
            open_photo_action.set_enabled(has_photo && !in_viewer);
            bool is_fav = false;
            if (has_photo) {
                string uri = current_photo().file.get_uri();
                foreach (var f in settings.get_strv("favorites")) { if (f == uri) { is_fav = true; break; } }
            }
            favorite_action.set_state(new Variant.boolean(is_fav));
            int nsel = selected_records().size;
            bool local = !(online != null && online.owns(current_view)) && current_view != "trash";
            foreach (var e in library_actions.entries) {
                switch (e.key) {
                    case "stack":
                    case "compare":
                    case "survey":
                    case "sync-settings":
                        e.value.set_enabled(local && nsel >= 2);
                        break;
                    case "merge":
                        e.value.set_enabled(local && nsel >= 1);
                        break;
                    case "paste-settings":
                        e.value.set_enabled(local && nsel >= 1 && SettingsClipboard.has_content());
                        break;
                    case "export":
                    case "print":
                    case "copy-settings":
                    case "reset-edits":
                    case "virtual-copy":
                    case "unstack":
                    case "toggle-stack":
                    case "save-metadata":
                    case "retouch":
                    case "book":
                    case "publish":
                        e.value.set_enabled(local && nsel >= 1);
                        break;
                    default:
                        e.value.set_enabled(true);
                        break;
                }
            }
            if (library_actions.has_key("retouch")) {
                var ph = current_photo();
                library_actions["retouch"].set_enabled(local && ph != null && ph.record != null && edit_view == null && retouch_view == null);
            }
            if (online != null && online.owns(current_view)) {
                trash_action.set_enabled(false);
                favorite_action.set_enabled(false);
                var wallpaper = main_window.lookup_action("set-wallpaper") as SimpleAction;
                if (wallpaper != null) wallpaper.set_enabled(false);
            }
        }

        // ── Context menu ───────────────────────────────────────────────────────

        private void show_photo_context_menu(Widget parent_widget, PhotoItem photo, double x, double y) {
            if (photo is OnlinePhoto && online != null) {
                online.show_context_menu(parent_widget, (OnlinePhoto) photo, x, y);
                return;
            }
            var menu = new Singularity.Widgets.ContextMenu(parent_widget);
            var r = new Gdk.Rectangle();
            r.x = (int)x; r.y = (int)y; r.width = 1; r.height = 1;
            menu.pointing_to = r;

            menu.add_item("Open", "document-open-symbolic", () => {
                try {
                    AppInfo.launch_default_for_uri(photo.file.get_uri(), null);
                } catch (Error e) { warning("Open: %s", e.message); }
            });
            menu.add_separator();

            string[] favs = settings.get_strv("favorites");
            bool is_fav = false;
            string check_uri = photo.file.get_uri();
            foreach (var f in favs) { if (f == check_uri) { is_fav = true; break; } }
            menu.add_item(is_fav ? "Unfavorite" : "Add to Favorites",
                          is_fav ? "non-starred-symbolic" : "starred-symbolic",
                          () => toggle_favorite_photo(photo));

            menu.add_separator();
            menu.add_item("Copy to Clipboard", "edit-copy-symbolic", () => {
                try {
                    var texture = Gdk.Texture.from_file(photo.file);
                    Gdk.Display.get_default().get_clipboard().set_texture(texture);
                } catch (Error e) { warning("Copy: %s", e.message); }
            });
            menu.add_item(_("Share…"), "singularity-share-symbolic", () => {
                Singularity.Share.files(main_window, { photo.file });
            });
            menu.add_separator();
            menu.add_item("Move to Trash", "user-trash-symbolic", () => {
                try {
                    photo.file.trash(null);
                    load_photos();
                } catch (Error e) { warning("Trash: %s", e.message); }
            });
            if (online != null) online.add_upload_items(menu, photo.file);
            if (photo.record != null) add_library_menu_items(menu, photo);

            menu.popup();
        }

        // ── Library loading ────────────────────────────────────────────────────

        private void load_photos() {
            if (online != null && online.owns(current_view)) {
                online.load(current_view, photo_store, search_query);
                update_empty_page();
                update_special_pages();
                return;
            }
            string? viewing = null;
            string viewing_variant = "";
            if (full_viewer != null && full_viewer.visible && viewer_index >= 0 && viewer_index < (int) photo_store.get_n_items()) {
                var cur = (PhotoItem) photo_store.get_item(viewer_index);
                viewing = cur.path;
                viewing_variant = cur.variant();
            }

            var items = new Gee.ArrayList<PhotoItem>();
            if (current_view == "trash") {
                var collected = new Gee.ArrayList<PhotoItem>();
                var trash_dir = GLib.File.new_for_path(
                    GLib.Environment.get_home_dir() + "/.local/share/Trash/files");
                enumerate_photos_recursive(trash_dir, collected);
                collected.sort((a, b) => {
                    if (a.modified == null && b.modified == null) return 0;
                    if (a.modified == null) return 1;
                    if (b.modified == null) return -1;
                    return b.modified.compare(a.modified);
                });
                foreach (var pi in collected) {
                    if (search_query != "" && !pi.name.down().contains(search_query.down())) continue;
                    items.add(pi);
                }
            } else {
                foreach (var r in query_view()) items.add(new PhotoItem.from_record(r));
            }

            bool same = items.size == (int) photo_store.get_n_items();
            if (same) {
                for (int i = 0; i < items.size; i++) {
                    var old = (PhotoItem) photo_store.get_item(i);
                    var fresh = items[i];
                    if (old.record != fresh.record || old.path != fresh.path) {
                        same = false;
                        break;
                    }
                }
            }
            if (!same) {
                var arr = new GLib.Object[items.size];
                for (int i = 0; i < items.size; i++) arr[i] = items[i];
                photo_store.splice(0, photo_store.get_n_items(), arr);
            } else {
                for (int i = 0; i < items.size; i++) {
                    var old = (PhotoItem) photo_store.get_item(i);
                    if (old.record != null) refresh_record_cell(old.record);
                }
            }
            if (viewing != null) {
                for (int i = 0; i < items.size; i++) {
                    if (items[i].path == viewing && items[i].variant() == viewing_variant) {
                        viewer_index = i;
                        break;
                    }
                }
            }
            update_empty_page();
            update_special_pages();
            update_info_panel();
        }

        private void refresh_view_keep_selection() {
            var keep = new Gee.HashSet<int64?>(id_hash, id_equal);
            foreach (var r in selected_records()) keep.add(r.id);
            load_photos();
            if (keep.size == 0 || selection == null) return;
            var bits = new Gtk.Bitset.empty();
            for (uint i = 0; i < photo_store.get_n_items(); i++) {
                var pi = (PhotoItem) photo_store.get_item(i);
                if (pi.record != null && keep.contains(pi.record.id)) bits.add(i);
            }
            var mask = new Gtk.Bitset.range(0, photo_store.get_n_items());
            selection.set_selection(bits, mask);
        }

        private Gee.ArrayList<PhotoRecord> query_view() {
            var list = new Gee.ArrayList<PhotoRecord>();
            if (current_view == "map" || current_view == "people") return list;
            string[] favs = settings.get_strv("favorites");
            var fav_set = new Gee.HashSet<string>();
            foreach (var f in favs) fav_set.add(f);
            int64 now = get_real_time() / 1000000;
            int64 folder_before = filter.folder_id;
            filter.folder_id = current_view.has_prefix("folder:") ? view_id(current_view) : 0;
            filter.hide_missing = current_view != "missing";
            Gee.Collection<PhotoRecord> source;
            if (place_records != null) {
                source = place_records;
            } else if (current_view.has_prefix("collection:")) {
                var c = catalog.collections[view_id(current_view)];
                source = c != null ? catalog.collection_photos(c) : new Gee.ArrayList<PhotoRecord>();
            } else if (current_view.has_prefix("person:")) {
                var ids = new Gee.HashSet<int64?>(id_hash, id_equal);
                int64 pid = view_id(current_view);
                foreach (var f in catalog.faces.values) if (f.person_id == pid) ids.add(f.photo_id);
                var l = new Gee.ArrayList<PhotoRecord>();
                foreach (var id in ids) if (catalog.photos.has_key(id)) l.add(catalog.photos[id]);
                source = l;
            } else if (current_view == "missing") {
                source = catalog.missing_photos();
            } else {
                source = catalog.photos.values;
            }
            bool scoped = place_records != null || current_view.has_prefix("collection:") || current_view.has_prefix("person:");
            bool collapse = filter.collapse_stacks;
            if (scoped) filter.collapse_stacks = false;
            foreach (var r in source) {
                if (!scoped && !current_view.has_prefix("folder:") && current_view != "missing" && !under_roots(r.path)) continue;
                if (current_view == "favorites" && !fav_set.contains(GLib.File.new_for_path(r.path).get_uri())) continue;
                if (current_view == "recent" && now - r.mtime > 86400 * 30) continue;
                if (!filter.matches(r, catalog)) continue;
                if (search_query != "" && !LibraryFilter.text_matches(r, catalog, search_query)) continue;
                list.add(r);
            }
            filter.collapse_stacks = collapse;
            filter.folder_id = folder_before;
            filter.sort(list);
            return list;
        }

        private void update_empty_page() {
            if (empty_page == null) return;
            bool empty = photo_store.get_n_items() == 0;
            bool special = current_view == "map" || current_view == "people";
            bool filtering = search_query != "" || filter.is_active();
            bool loading = empty && indexer != null && indexer.running && catalog.photos.size == 0;
            bool start = empty && current_view == "library" && !filtering && !loading;
            welcome_page.visible = start;
            empty_page.visible = empty && filtering && !special;
            foreach (var entry in section_pages.entries) {
                entry.value.visible = empty && !filtering && entry.key == current_view;
            }
            if (online != null) online.update_page(empty, search_query != "");
        }

        private WelcomePage add_section_page(string view_id, string icon, string title, string subtitle) {
            var page = new WelcomePage();
            page.is_section = true;
            page.hexpand = true;
            page.vexpand = true;
            page.visible = false;
            page.app_icon_name = icon;
            page.title = title;
            page.subtitle = subtitle;
            section_pages[view_id] = page;
            main_window.content_overlay.add_overlay(page);
            return page;
        }

        private void show_view(string view_id) {
            main_window.activate_action_variant("win.view", new Variant.string(view_id));
        }

        private void enumerate_photos_recursive(GLib.File folder, Gee.ArrayList<PhotoItem> result) {
            try {
                var enumerator = folder.enumerate_children(
                    "standard::name,standard::type,time::modified,standard::size",
                    FileQueryInfoFlags.NONE, null);
                GLib.FileInfo? info;
                while ((info = enumerator.next_file(null)) != null) {
                    var child = folder.get_child(info.get_name());
                    if (info.get_file_type() == FileType.DIRECTORY) {
                        enumerate_photos_recursive(child, result);
                    } else if (info.get_file_type() == FileType.REGULAR) {
                        if (is_image_file(info.get_name())) {
                            result.add(new PhotoItem(child, info));
                        }
                    }
                }
            } catch (Error e) {}
        }

        private bool is_image_file(string name) {
            if (LibraryIndexer.indexable(name)) return true;
            string n = name.down();
            return n.has_suffix(".jpg")  || n.has_suffix(".jpeg") ||
                   n.has_suffix(".png")  || n.has_suffix(".gif")  ||
                   n.has_suffix(".webp") || n.has_suffix(".bmp")  ||
                   n.has_suffix(".tiff") || n.has_suffix(".tif")  ||
                   n.has_suffix(".heic");
        }

        private void setup_library_monitor() {
            try {
                if (lib_monitor != null) lib_monitor.cancel();
                lib_monitor = library_folder.monitor_directory(FileMonitorFlags.NONE, null);
                lib_monitor.changed.connect((src, dest, event) => {
                    if (event == FileMonitorEvent.CREATED ||
                        event == FileMonitorEvent.DELETED ||
                        event == FileMonitorEvent.MOVED_IN ||
                        event == FileMonitorEvent.MOVED_OUT) {
                        schedule_reindex();
                    }
                });
            } catch (Error e) {
                warning("Cannot monitor library: %s", e.message);
            }
        }

        // ── Import ─────────────────────────────────────────────────────────────

        private void on_import() {
            var dlg = new ImportDialog(main_window, catalog, library_folder);
            dlg.imported.connect((result) => {
                string msg = ngettext("%d photo imported", "%d photos imported", result.imported).printf(result.imported);
                if (result.skipped_duplicates > 0)
                    msg += ", " + ngettext("%d duplicate skipped", "%d duplicates skipped", result.skipped_duplicates).printf(result.skipped_duplicates);
                if (result.failed > 0) msg += ", " + ngettext("%d failed", "%d failed", result.failed).printf(result.failed);
                main_window.add_toast(new Toast(msg));
                if (result.imported > 0) {
                    foreach (var r in result.records) if (!under_roots(r.path)) add_library_root(Path.get_dirname(r.path));
                    activate_view("library");
                }
            });
            dlg.present();
        }

        private void schedule_reindex() {
            if (index_timeout_id != 0) Source.remove(index_timeout_id);
            index_timeout_id = Timeout.add(600, () => {
                index_timeout_id = 0;
                indexer.scan(library_roots());
                return Source.REMOVE;
            });
        }

        private void open_library_folder() {
            try {
                library_folder.make_directory_with_parents(null);
            } catch (Error e) {}
            try {
                AppInfo.launch_default_for_uri(library_folder.get_uri(), null);
            } catch (Error e) {
                warning("Open library folder: %s", e.message);
            }
        }

        private void import_files(GLib.ListModel files) {
            try {
                library_folder.make_directory_with_parents(null);
            } catch (Error e) {}

            uint n = files.get_n_items();
            for (uint i = 0; i < n; i++) {
                var file = (GLib.File)files.get_item(i);
                var dest = library_folder.get_child(file.get_basename());
                try {
                    file.copy(dest, FileCopyFlags.NONE, null, null);
                } catch (Error e) {
                    warning("Import: %s", e.message);
                }
            }
            schedule_reindex();
        }

        // ── Drag & drop ────────────────────────────────────────────────────────

        private void setup_drag_drop() {
            var drop_target = new DropTarget(GLib.Type.STRING, Gdk.DragAction.COPY);
            drop_target.drop.connect(on_drop);
            ((Gtk.Widget)main_window).add_controller(drop_target);
        }

        private bool on_drop(GLib.Value value, double x, double y) {
            string? text = value.get_string();
            if (text == null) return false;
            foreach (var uri in text.split("\n")) {
                string clean = uri.strip().replace("\r", "");
                if (clean == "") continue;
                try {
                    var file = GLib.File.new_for_uri(clean);
                    var info = file.query_info("standard::name", FileQueryInfoFlags.NONE, null);
                    if (is_image_file(info.get_name())) {
                        file.copy(library_folder.get_child(info.get_name()),
                                  FileCopyFlags.NONE, null, null);
                    }
                } catch (Error e) {}
            }
            schedule_reindex();
            return true;
        }

        // ── Library panels and actions ─────────────────────────────────────────

        private void setup_library_panels() {
            filter_bar = new LibraryFilterBar(filter, catalog);
            filter_bar.changed.connect(() => {
                set_state_string("library-sort", filter.sort_key);
                set_state_bool("library-sort-ascending", filter.ascending);
                load_photos();
            });
            filter_revealer = new Revealer();
            filter_revealer.transition_type = RevealerTransitionType.SLIDE_DOWN;
            filter_revealer.child = filter_bar;
            apply_bubble_inset(filter_bar, 52, 0);
            main_window.search_host.append(filter_revealer);
            filter_revealer.reveal_child = state_bool("show-filter-bar", false);
            filter_revealer.visible = filter_revealer.reveal_child;
            filter_revealer.notify["child-revealed"].connect(() => {
                if (!filter_revealer.reveal_child && !filter_revealer.child_revealed) filter_revealer.visible = false;
            });
            filter_revealer.notify["visible"].connect(() => sync_grid_inset());
            filter_revealer.notify["reveal-child"].connect(() => sync_grid_inset());
            sync_grid_inset();

            info_panel = new LibraryInfoPanel(catalog);
            info_panel.records_changed.connect((recs) => persist_records(recs));
            info_revealer = new Revealer();
            info_revealer.transition_type = RevealerTransitionType.SLIDE_LEFT;
            info_revealer.child = info_panel;
            main_window.side_host.append(info_revealer);
            info_revealer.reveal_child = state_bool("show-info-panel", false);
            info_revealer.visible = info_revealer.reveal_child;
            info_revealer.notify["child-revealed"].connect(() => {
                if (!info_revealer.reveal_child && !info_revealer.child_revealed) info_revealer.visible = false;
            });

            catalog.photo_changed.connect((r) => refresh_record_cell(r));

            map_page = new Box(Orientation.VERTICAL, 0);
            map_page.hexpand = true;
            map_page.vexpand = true;
            map_page.visible = false;
            map_page.add_css_class("photo-edit-host");
            content_overlay.add_overlay(map_page);

            people_view = new PeopleView(catalog);
            people_view.visible = false;
            people_view.add_css_class("photo-edit-host");
            people_view.person_activated.connect((p) => activate_view(("person:%" + int64.FORMAT).printf(p.id)));
            people_view.message.connect((t) => main_window.add_toast(new Toast(t)));
            people_view.collection_created.connect((c) => activate_view(("collection:%" + int64.FORMAT).printf(c.id)));
            content_overlay.add_overlay(people_view);
        }

        private void build_map_page() {
            Widget? c;
            while ((c = map_page.get_first_child()) != null) map_page.remove(c);
            if (!state_bool("map-enabled", false)) {
                map_intro = new WelcomePage();
                map_intro.is_section = true;
                map_intro.hexpand = true;
                map_intro.vexpand = true;
                map_intro.app_icon_name = "dev.sinty.photos";
                map_intro.title = _("Map");
                map_intro.subtitle = _("See where your photos were taken. The map is drawn with OpenStreetMap tiles, downloaded only while the map is open.");
                map_intro.add_action("mark-location", _("Show Map"), _("Download map tiles when needed"), () => {
                    set_state_bool("map-enabled", true);
                    build_map_page();
                });
                map_page.append(map_intro);
                return;
            }
            var bar = new Box(Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 16;
            apply_bubble_inset(bar, 56, 8);
            bar.margin_bottom = 8;
            map_status = new Label("");
            map_status.add_css_class("dim-label");
            map_status.hexpand = true;
            map_status.xalign = 0;
            map_status.wrap = true;
            bar.append(map_status);
            var gpx = new Button.with_label(_("Tag with GPX Track…"));
            gpx.clicked.connect(() => tag_with_gpx());
            bar.append(gpx);
            var fit = new Button.with_label(_("Show All"));
            fit.clicked.connect(() => photo_map.fit());
            bar.append(fit);
            map_page.append(bar);
            photo_map = new PhotoMap();
            photo_map.cluster_activated.connect((recs) => {
                place_records = new Gee.ArrayList<PhotoRecord>();
                place_records.add_all(recs);
                current_view = "place";
                select_sidebar("");
                load_photos();
                main_window.add_toast(new Toast(ngettext("%d photo taken here", "%d photos taken here", recs.size).printf(recs.size)));
            });
            photo_map.dropped.connect((files, lat, lon) => {
                var recs = new Gee.ArrayList<PhotoRecord>();
                foreach (var f in files) {
                    var r = catalog.find_path(f.get_path() ?? "");
                    if (r != null) recs.add(r);
                }
                foreach (var r in selected_records()) if (!recs.contains(r)) recs.add(r);
                catalog.begin();
                foreach (var r in recs) {
                    r.has_gps = true;
                    r.latitude = lat;
                    r.longitude = lon;
                    catalog.save(r);
                }
                catalog.commit();
                persist_records(recs);
                refresh_map();
                main_window.add_toast(new Toast(ngettext("Location set for %d photo", "Location set for %d photos", recs.size).printf(recs.size)));
            });
            map_page.append(photo_map);
            refresh_map();
            Idle.add(() => {
                if (photo_map != null) {
                    if (!pending_place_lat.is_nan()) {
                        photo_map.focus(pending_place_lat, pending_place_lon, 13);
                        pending_place_lat = double.NAN;
                    } else {
                        photo_map.fit();
                    }
                }
                return Source.REMOVE;
            });
        }

        private double pending_place_lat = double.NAN;
        private double pending_place_lon = double.NAN;

        private void refresh_map() {
            if (photo_map == null) return;
            var all = new Gee.ArrayList<PhotoRecord>();
            int without = 0;
            foreach (var r in catalog.photos.values) {
                if (r.master_id != 0 || r.missing || !under_roots(r.path)) continue;
                if (r.has_gps) all.add(r);
                else without++;
            }
            photo_map.set_photos(all);
            if (map_status != null) map_status.label = _("%d photos with a location, %d without. Drag photos from the library onto the map to place them.").printf(all.size, without);
        }

        private void tag_with_gpx() {
            var fd = new FileDialog();
            fd.title = _("Choose a GPX Track");
            var gf = new FileFilter();
            gf.name = _("GPX Tracks");
            gf.add_pattern("*.gpx");
            gf.add_pattern("*.GPX");
            var filters = new GLib.ListStore(typeof(FileFilter));
            filters.append(gf);
            fd.filters = filters;
            fd.open.begin(main_window, null, (obj, res) => {
                try {
                    var f = fd.open.end(res);
                    if (f == null) return;
                    string text;
                    FileUtils.get_contents(f.get_path(), out text);
                    var track = GpxTrack.parse(text);
                    var dlg = LibraryDialogs.make(main_window, _("Tag with GPX Track"), 420);
                    var box = LibraryDialogs.body(dlg);
                    var group = new PreferencesGroup(_("Camera Clock"));
                    var offset = new SpinRow(_("Offset from UTC (hours)"), _("Difference between the camera clock and UTC"), -14, 14, 0.5,
                        new GLib.TimeZone.local().get_offset(0) / 3600.0);
                    group.add_row(offset);
                    box.append(group);
                    var targets = selected_records();
                    string scope = targets.size > 0 ? ngettext("%d selected photo", "%d selected photos", targets.size).printf(targets.size) : _("all photos without a location");
                    var note = new Label(_("Photos to tag: %s. Track points: %d").printf(scope, track.points.length));
                    note.wrap = true;
                    note.xalign = 0;
                    box.append(note);
                    LibraryDialogs.footer(dlg, _("Tag Photos"), () => {
                        var list = new Gee.ArrayList<PhotoRecord>();
                        if (targets.size > 0) list.add_all(targets);
                        else foreach (var r in catalog.photos.values) if (!r.has_gps && r.master_id == 0) list.add(r);
                        int64 off = (int64) (-offset.value * 3600) + new GLib.TimeZone.local().get_offset(0);
                        int n = track.tag(catalog, list, off, 300);
                        persist_records(list);
                        if (photo_map != null) photo_map.track = track;
                        refresh_map();
                        main_window.add_toast(new Toast(ngettext("%d photo tagged", "%d photos tagged", n).printf(n)));
                    });
                    dlg.open_dialog();
                } catch (Error e) {
                    if (!(e is Gtk.DialogError)) main_window.add_toast(new Toast(_("Cannot read the track: %s").printf(e.message)));
                }
            });
        }

        private void update_special_pages() {
            if (map_page == null) return;
            bool map = current_view == "map";
            bool people = current_view == "people";
            if (map && map_page.get_first_child() == null) build_map_page();
            if (map) refresh_map();
            map_page.visible = map;
            people_view.visible = people;
            if (compare_view == null && edit_view == null && retouch_view == null) main_window.side_host.visible = !map && !people;
            if (people) {
                people_view.refresh();
                people_view.auto_scan();
            }
            if (filter_revealer != null) filter_revealer.visible = filter_revealer.reveal_child && !map && !people && !(full_viewer != null && full_viewer.visible);
        }

        private void sync_grid_inset() {
            if (photo_grid == null || filter_revealer == null) return;
            if (filter_revealer.visible && filter_revealer.reveal_child) photo_grid.add_css_class("photos-filtered");
            else photo_grid.remove_css_class("photos-filtered");
        }

        private void toggle_filter_bar() {
            if (filter_revealer == null) return;
            bool show = !filter_revealer.reveal_child;
            if (show) filter_revealer.visible = true;
            filter_revealer.reveal_child = show;
            set_state_bool("show-filter-bar", filter_revealer.reveal_child);
            if (filter_revealer.reveal_child) {
                filter_bar.refresh_values();
                filter_bar.focus_text();
            }
        }

        private void toggle_info_panel() {
            if (info_revealer == null) return;
            bool show = !info_revealer.reveal_child;
            if (show) info_revealer.visible = true;
            info_revealer.reveal_child = show;
            set_state_bool("show-info-panel", info_revealer.reveal_child);
            update_info_panel();
        }

        private void update_info_panel() {
            if (info_panel == null || info_revealer == null || !info_revealer.reveal_child) return;
            var list = new Gee.ArrayList<PhotoRecord>();
            if (full_viewer != null && full_viewer.visible) {
                var p = current_photo();
                if (p != null && p.record != null) list.add(p.record);
            } else {
                list.add_all(selected_records());
            }
            info_panel.set_records(list);
        }

        private Gee.ArrayList<PhotoRecord> selected_records() {
            var list = new Gee.ArrayList<PhotoRecord>();
            if (full_viewer != null && full_viewer.visible) {
                var p = current_photo();
                if (p != null && p.record != null) list.add(p.record);
                return list;
            }
            if (selection == null) return list;
            var bits = selection.get_selection();
            if (bits.is_empty()) return list;
            uint last = uint.min(bits.get_maximum(), photo_store.get_n_items() - 1);
            for (uint pos = bits.get_minimum(); pos <= last; pos++) {
                if (!bits.contains(pos)) continue;
                var pi = (PhotoItem) photo_store.get_item(pos);
                if (pi.record != null) list.add(pi.record);
            }
            return list;
        }

        private void select_for_context(PhotoItem item) {
            if (selection == null) return;
            for (uint i = 0; i < photo_store.get_n_items(); i++) {
                if (photo_store.get_item(i) == item) {
                    if (!selection.is_selected(i)) selection.select_item(i, true);
                    return;
                }
            }
        }

        private void persist_records(Gee.List<PhotoRecord> recs) {
            if (CatalogXmp.automatic()) foreach (var r in recs) CatalogXmp.write(r, catalog);
            foreach (var r in recs) refresh_record_cell(r);
            update_info_panel();
        }

        private void apply_to_selection(owned RecordFunc f) {
            var recs = selected_records();
            if (recs.size == 0) return;
            catalog.begin();
            foreach (var r in recs) f(r);
            catalog.commit();
            persist_records(recs);
        }

        private delegate void RecordFunc(PhotoRecord r);

        private bool handle_library_key(uint keyval, Gdk.ModifierType state) {
            var focus = main_window.get_focus();
            if (focus is Gtk.Editable || focus is Gtk.Text) return false;
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            bool alt = (state & Gdk.ModifierType.ALT_MASK) != 0;
            if (alt) return false;
            if (online != null && online.owns(current_view)) return false;
            if (current_view == "trash" || current_view == "map" || current_view == "people") return false;
            if (ctrl) {
                if (keyval == Gdk.Key.bracketleft || keyval == Gdk.Key.bracketright) {
                    int turns = keyval == Gdk.Key.bracketleft ? -1 : 1;
                    var recs = selected_records();
                    EditSync.rotate(recs, turns, catalog);
                    after_edit_change(recs);
                    return true;
                }
                return false;
            }
            if (keyval >= Gdk.Key.@0 && keyval <= Gdk.Key.@5) {
                int n = (int) (keyval - Gdk.Key.@0);
                apply_to_selection((r) => catalog.set_rating(r, n));
                return true;
            }
            if (keyval >= Gdk.Key.@6 && keyval <= Gdk.Key.@9) {
                string l = COLOR_LABELS[keyval - Gdk.Key.@6];
                apply_to_selection((r) => catalog.set_label(r, l));
                return true;
            }
            switch (keyval) {
                case Gdk.Key.p:
                case Gdk.Key.P:
                    apply_to_selection((r) => catalog.set_flag(r, PickFlag.PICK));
                    return true;
                case Gdk.Key.x:
                case Gdk.Key.X:
                    apply_to_selection((r) => catalog.set_flag(r, PickFlag.REJECT));
                    return true;
                case Gdk.Key.u:
                case Gdk.Key.U:
                    apply_to_selection((r) => catalog.set_flag(r, PickFlag.NONE));
                    return true;
                default:
                    break;
            }
            if (full_viewer != null && full_viewer.visible) return false;
            switch (keyval) {
                case Gdk.Key.c:
                    open_compare(false);
                    return true;
                case Gdk.Key.n:
                    open_compare(true);
                    return true;
                case Gdk.Key.s:
                    toggle_stack();
                    return true;
                default:
                    return false;
            }
        }

        private void after_edit_change(Gee.List<PhotoRecord> recs) {
            for (uint i = 0; i < photo_store.get_n_items(); i++) {
                var pi = (PhotoItem) photo_store.get_item(i);
                if (pi.record != null && recs.contains(pi.record)) {
                    invalidate_thumb(pi);
                    photo_store.items_changed(i, 1, 1);
                }
            }
            if (full_viewer != null && full_viewer.visible) load_viewer_photo();
        }

        private SimpleAction lib_action(string name, owned Singularity.Widgets.Window.BubbleAction func, VariantType? type = null) {
            var act = new SimpleAction(name, type);
            act.activate.connect(() => func());
            main_window.add_action(act);
            library_actions[name] = act;
            return act;
        }

        private GLib.File[] selected_files() {
            GLib.File[] files = {};
            foreach (var r in selected_records()) if (!r.missing) files += r.file();
            return files;
        }

        private void setup_library_actions() {
            lib_action("select-all", () => { if (selection != null && !(full_viewer != null && full_viewer.visible)) selection.select_all(); });
            lib_action("select-none", () => { if (selection != null) selection.unselect_all(); });
            lib_action("filter-bar", () => toggle_filter_bar());
            lib_action("info-panel", () => toggle_info_panel());
            lib_action("compare", () => open_compare(false));
            lib_action("survey", () => open_compare(true));
            lib_action("add-folder", () => {
                var fd = new FileDialog();
                fd.title = _("Add Folder to Library");
                fd.select_folder.begin(main_window, null, (obj, res) => {
                    try {
                        var f = fd.select_folder.end(res);
                        if (f != null && f.get_path() != null) {
                            add_library_root(f.get_path());
                            main_window.add_toast(new Toast(_("%s added to the library").printf(f.get_basename())));
                        }
                    } catch (Error e) {
                    }
                });
            });
            lib_action("import-lrcat", () => import_lrcat());
            lib_action("tether", () => Tether.present(main_window, library_folder));
            lib_action("export", () => {
                var files = selected_files();
                if (files.length > 0) PhotoExport.show_dialog(main_window, files);
            });
            lib_action("print", () => {
                var files = selected_files();
                if (files.length > 0) PhotoPrint.run(main_window, files);
            });
            lib_action("slideshow", () => {
                var files = selected_files();
                if (files.length < 2) {
                    files = {};
                    for (uint i = 0; i < photo_store.get_n_items(); i++) {
                        var pi = (PhotoItem) photo_store.get_item(i);
                        if (pi.record != null && !pi.record.missing) files += pi.file;
                    }
                }
                if (files.length > 0) Slideshow.present(main_window, files);
            });
            lib_action("presentation", () => {
                var files = selected_files();
                if (files.length < 2) {
                    files = {};
                    for (uint i = 0; i < photo_store.get_n_items(); i++) {
                        var pi = (PhotoItem) photo_store.get_item(i);
                        if (pi.record != null && !pi.record.missing) files += pi.file;
                    }
                }
                if (files.length == 0) return;
                string[] uris = {};
                foreach (var f in files) uris += f.get_uri();
                Singularity.ShareTargets.activate_app_action.begin("dev.sinty.slides", "new-from-images",
                    new Variant("(s^as)", _("Photos"), uris));
            });
            lib_action("insert-write", () => {
                var files = selected_files();
                if (files.length < 2) {
                    files = {};
                    for (uint i = 0; i < photo_store.get_n_items(); i++) {
                        var pi = (PhotoItem) photo_store.get_item(i);
                        if (pi.record != null && !pi.record.missing) files += pi.file;
                    }
                }
                if (files.length == 0) return;
                var html = new StringBuilder("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>%s</title></head><body><table style=\"width:100%%\">".printf(Markup.escape_text(_("Photos"))));
                for (int i = 0; i < files.length; i++) {
                    if (i % 2 == 0) html.append("<tr>");
                    html.append("<td style=\"width:50%%;padding:4px\"><img src=\"%s\" width=\"290\"><br>%s</td>".printf(Markup.escape_text(files[i].get_uri()), Markup.escape_text(files[i].get_basename())));
                    if (i % 2 == 1 || i == files.length - 1) html.append("</tr>");
                }
                html.append("</table></body></html>");
                string dir = Path.build_filename(Environment.get_user_cache_dir(), "singularity", "photos-to-write");
                DirUtils.create_with_parents(dir, 0700);
                string path = Path.build_filename(dir, _("Photos %s.html").printf(new DateTime.now_local().format("%Y-%m-%d %H-%M")));
                try {
                    FileUtils.set_contents(path, html.str);
                    var write = new DesktopAppInfo("dev.sinty.write.desktop");
                    var list = new GLib.List<File>();
                    list.append(File.new_for_path(path));
                    if (write != null) write.launch(list, Gdk.Display.get_default().get_app_launch_context());
                } catch (Error e) {
                    main_window.add_toast(new Toast(e.message));
                }
            });
            lib_action("publish", () => {
                var files = selected_files();
                if (files.length > 0) PhotoPublish.present(main_window, files);
            });
            lib_action("sync-library", () => PhotoSync.present(main_window, library_folder));
            lib_action("book", () => {
                var files = selected_files();
                if (files.length > 0) PhotoBook.present(main_window, files);
            });
            lib_action("save-metadata", () => {
                int n = 0;
                foreach (var r in selected_records()) if (CatalogXmp.write(r, catalog)) n++;
                main_window.add_toast(new Toast(ngettext("Metadata saved to %d file", "Metadata saved to %d files", n).printf(n)));
            });
            lib_action("copy-settings", () => {
                var recs = selected_records();
                if (recs.size == 0) return;
                var src = recs[0];
                EditSync.choose_groups(main_window, _("Copy Edit Settings"), _("Copy"), (groups) => {
                    SettingsClipboard.copy(EditSync.load(src), groups);
                    update_photo_actions();
                    main_window.add_toast(new Toast(_("Edit settings copied")));
                });
            });
            lib_action("paste-settings", () => {
                var recs = selected_records();
                if (recs.size == 0 || !SettingsClipboard.has_content()) return;
                catalog.begin();
                foreach (var r in recs) {
                    var p = EditSync.load(r);
                    SettingsClipboard.paste(p);
                    EditSync.store(r, p, catalog);
                }
                catalog.commit();
                after_edit_change(recs);
                main_window.add_toast(new Toast(ngettext("Settings pasted to %d photo", "Settings pasted to %d photos", recs.size).printf(recs.size)));
            });
            lib_action("sync-settings", () => {
                var recs = selected_records();
                if (recs.size < 2) return;
                var src = current_photo()?.record ?? recs[0];
                EditSync.choose_groups(main_window, _("Sync Settings"), _("Synchronize"), (groups) => {
                    var targets = new Gee.ArrayList<PhotoRecord>();
                    foreach (var r in recs) if (r != src) targets.add(r);
                    int n = EditSync.apply(targets, EditSync.load(src), groups, catalog);
                    after_edit_change(targets);
                    main_window.add_toast(new Toast(ngettext("Settings synchronized to %d photo", "Settings synchronized to %d photos", n).printf(n)));
                });
            });
            lib_action("reset-edits", () => {
                var recs = selected_records();
                EditSync.reset(recs, catalog);
                after_edit_change(recs);
            });
            lib_action("virtual-copy", () => {
                var recs = selected_records();
                if (recs.size == 0) return;
                var vc = catalog.create_virtual_copy(recs[0]);
                filter.expanded_stacks.add(vc.stack_id);
                load_photos();
                main_window.add_toast(new Toast(_("Virtual copy created")));
            });
            lib_action("stack", () => {
                var recs = selected_records();
                if (recs.size < 2) return;
                catalog.stack(recs.to_array());
            });
            lib_action("unstack", () => {
                var ids = new Gee.HashSet<int64?>(id_hash, id_equal);
                foreach (var r in selected_records()) if (r.stack_id != 0) ids.add(r.stack_id);
                foreach (var id in ids) catalog.unstack(id);
            });
            lib_action("toggle-stack", () => toggle_stack());
            lib_action("keywords", () => {
                var km = new KeywordManager(main_window, catalog, (k) => {
                    filter.reset_attributes();
                    filter.keyword_id = k.id;
                    if (filter_bar != null) {
                        filter_bar.refresh_values();
                        filter_bar.sync();
                        if (!filter_revealer.reveal_child) toggle_filter_bar();
                    }
                    activate_view("library");
                });
                km.present();
            });
            lib_action("retouch", () => open_retouch());
            var merge = new SimpleAction("merge", VariantType.STRING);
            merge.activate.connect((param) => run_merge(param.get_string()));
            main_window.add_action(merge);
            library_actions["merge"] = merge;
            update_photo_actions();
        }

        private void toggle_stack() {
            var ids = new Gee.HashSet<int64?>(id_hash, id_equal);
            foreach (var r in selected_records()) if (r.stack_id != 0) ids.add(r.stack_id);
            foreach (var id in ids) {
                if (filter.expanded_stacks.contains(id)) filter.expanded_stacks.remove(id);
                else filter.expanded_stacks.add(id);
            }
            if (ids.size > 0) refresh_view_keep_selection();
        }

        private void add_library_menu_items(Singularity.Widgets.ContextMenu menu, PhotoItem photo) {
            var recs = selected_records();
            menu.add_separator();
            var rating = menu.add_submenu(_("Rating"), "starred-symbolic");
            for (int i = 0; i <= 5; i++) {
                int n = i;
                rating.add_item(n == 0 ? _("No Rating") : ngettext("%d Star", "%d Stars", n).printf(n), null, () => apply_to_selection((r) => catalog.set_rating(r, n)));
            }
            var flag = menu.add_submenu(_("Flag"), "object-select-symbolic");
            flag.add_item(_("Pick"), "object-select-symbolic", () => apply_to_selection((r) => catalog.set_flag(r, PickFlag.PICK)));
            flag.add_item(_("Reject"), "action-unavailable-symbolic", () => apply_to_selection((r) => catalog.set_flag(r, PickFlag.REJECT)));
            flag.add_item(_("Unflagged"), null, () => apply_to_selection((r) => catalog.set_flag(r, PickFlag.NONE)));
            var label = menu.add_submenu(_("Color Label"), null);
            foreach (var l in COLOR_LABELS) {
                string id = l;
                label.add_item(color_label_title(l), null, () => apply_to_selection((r) => {
                    r.label = id;
                    catalog.save(r);
                }));
            }
            label.add_item(_("None"), null, () => apply_to_selection((r) => {
                r.label = "";
                catalog.save(r);
            }));
            var manual = new Gee.ArrayList<CollectionRecord>();
            foreach (var c in catalog.collections.values) if (c.kind == "manual") manual.add(c);
            manual.sort((a, b) => a.name.collate(b.name));
            var coll = menu.add_submenu(_("Add to Collection"), "view-grid-symbolic");
            foreach (var c in manual) {
                var col = c;
                coll.add_item(c.name, null, () => {
                    catalog.begin();
                    foreach (var r in recs) catalog.add_to_collection(col, r);
                    catalog.commit();
                    main_window.add_toast(new Toast(_("Added to %s").printf(col.name)));
                });
            }
            coll.add_item(_("New Collection…"), "list-add-symbolic", () => new_collection("manual"));
            if (current_view.has_prefix("collection:")) {
                var cur = catalog.collections[view_id(current_view)];
                if (cur != null && cur.kind == "manual") {
                    menu.add_item(_("Remove from Collection"), "list-remove-symbolic", () => {
                        catalog.begin();
                        foreach (var r in recs) catalog.remove_from_collection(cur, r);
                        catalog.commit();
                    });
                }
            }
            menu.add_separator();
            var presets = DevelopPresets.all();
            if (presets.size > 0) {
                var pm = menu.add_submenu(_("Apply Preset"), "singularity-photos-filters-symbolic");
                foreach (var p in presets) {
                    var preset = p;
                    pm.add_item(p.name, null, () => {
                        int n = EditSync.apply_preset(recs, preset, catalog);
                        after_edit_change(recs);
                        main_window.add_toast(new Toast(ngettext("%s applied to %d photo", "%s applied to %d photos", n).printf(preset.name, n)));
                    });
                }
            }
            menu.add_item(_("Copy Edit Settings…"), "edit-copy-symbolic", () => activate_win("copy-settings"));
            if (SettingsClipboard.has_content()) menu.add_item(_("Paste Edit Settings"), "edit-paste-symbolic", () => activate_win("paste-settings"));
            if (recs.size >= 2) menu.add_item(_("Sync Settings…"), null, () => activate_win("sync-settings"));
            if (recs.size >= 2) {
                menu.add_item(_("Compare"), "view-dual-symbolic", () => open_compare(false));
                menu.add_item(_("Survey"), "view-grid-symbolic", () => open_compare(true));
                menu.add_item(_("Group into Stack"), "view-app-grid-symbolic", () => activate_win("stack"));
            }
            if (photo.record.stack_id != 0) {
                menu.add_item(filter.expanded_stacks.contains(photo.record.stack_id) ? _("Collapse Stack") : _("Expand Stack"), null, () => toggle_stack());
                var top_rec = photo.record;
                menu.add_item(_("Move to Top of Stack"), null, () => catalog.set_stack_top(top_rec));
                menu.add_item(_("Unstack"), null, () => activate_win("unstack"));
            }
            menu.add_item(_("Create Virtual Copy"), "edit-copy-symbolic", () => activate_win("virtual-copy"));
            menu.add_separator();
            menu.add_item(_("Export…"), "document-save-symbolic", () => activate_win("export"));
            menu.add_item(_("Print…"), "document-print-symbolic", () => activate_win("print"));
            if (Capabilities.has_app("dev.sinty.slides")) menu.add_item(_("Create Presentation"), "x-office-presentation-symbolic", () => activate_win("presentation"));
            if (Capabilities.has_app("dev.sinty.write")) menu.add_item(_("Insert in Write"), "x-office-document-symbolic", () => activate_win("insert-write"));
            if (photo.record.missing) {
                var missing = photo.record;
                menu.add_item(_("Locate Missing Photo…"), "find-location-symbolic", () => relink(missing));
            }
            if (photo.record.is_virtual_copy()) {
                var vc = photo.record;
                menu.add_item(_("Remove Virtual Copy"), "list-remove-symbolic", () => {
                    EditStore.revert(vc.file(), vc.variant());
                    catalog.remove_photo(vc);
                });
            }
        }

        private void activate_win(string name) {
            main_window.activate_action(name, null);
        }

        private void relink(PhotoRecord r) {
            var fd = new FileDialog();
            fd.title = _("Locate %s").printf(r.name());
            fd.open.begin(main_window, null, (obj, res) => {
                try {
                    var f = fd.open.end(res);
                    if (f == null || f.get_path() == null) return;
                    var old_dir = Path.get_dirname(r.path);
                    var new_dir = Path.get_dirname(f.get_path());
                    catalog.relink(r, f.get_path());
                    int more = 0;
                    catalog.begin();
                    foreach (var m in catalog.missing_photos()) {
                        if (Path.get_dirname(m.path) != old_dir) continue;
                        string candidate = Path.build_filename(new_dir, m.name());
                        if (FileUtils.test(candidate, FileTest.EXISTS)) {
                            catalog.relink(m, candidate);
                            more++;
                        }
                    }
                    catalog.commit();
                    main_window.add_toast(new Toast(more > 0 ? ngettext("Photo found, %d more from the same folder", "Photo found, %d more from the same folder", more).printf(more) : _("Photo found")));
                } catch (Error e) {
                }
            });
        }

        private void import_lrcat() {
            var fd = new FileDialog();
            fd.title = _("Import from Lightroom Catalog");
            var lf = new FileFilter();
            lf.name = _("Lightroom Catalogs");
            lf.add_pattern("*.lrcat");
            var filters = new GLib.ListStore(typeof(FileFilter));
            filters.append(lf);
            fd.filters = filters;
            fd.open.begin(main_window, null, (obj, res) => {
                try {
                    var f = fd.open.end(res);
                    if (f == null) return;
                    var report = new LrcatImporter(catalog).import_catalog(f.get_path());
                    var roots = new Gee.HashSet<string>();
                    foreach (var fo in catalog.folders.values) {
                        if (fo.parent_id == 0 && !under_roots(fo.path + "/x") && fo.path != library_folder.get_path()) roots.add(fo.path);
                    }
                    foreach (var root in roots) add_library_root(root);
                    main_window.add_toast(new Toast(_("Imported %d photos, %d collections, %d keywords from Lightroom").printf(report.photos, report.collections + report.smart_collections, report.keywords)));
                    rebuild_dynamic_sidebar();
                    load_photos();
                } catch (Error e) {
                    if (!(e is Gtk.DialogError)) main_window.add_toast(new Toast(e.message));
                }
            });
        }

        private void open_compare(bool survey) {
            var recs = selected_records();
            if (recs.size < 2 || compare_view != null || edit_view != null) {
                if (recs.size < 2) main_window.add_toast(new Toast(_("Select at least two photos")));
                return;
            }
            if (full_viewer != null && full_viewer.visible) hide_viewer();
            compare_view = new CompareView(catalog, recs, survey);
            main_window.side_host.visible = false;
            if (filter_revealer != null) filter_revealer.visible = false;
            compare_view.finished.connect(() => close_compare());
            compare_view.records_changed.connect(() => persist_records(recs));
            content_overlay.add_overlay(compare_view);
            update_bubbles_for_viewer(true);
            if (_info_bubble != null) _info_bubble.visible = false;
            compare_view.grab_focus();
        }

        private void close_compare() {
            if (compare_view == null) return;
            var v = compare_view;
            compare_view = null;
            content_overlay.remove_overlay(v);
            main_window.side_host.visible = true;
            if (filter_revealer != null) filter_revealer.visible = filter_revealer.reveal_child;
            update_bubbles_for_viewer(false);
            if (_info_bubble != null) _info_bubble.visible = true;
            refresh_view_keep_selection();
        }

        private void open_retouch() {
            var photo = current_photo();
            if (photo == null || photo.record == null || retouch_view != null || edit_view != null || !photo.file.query_exists()) return;
            if (live_text != null) live_text.active = false;
            retouch_view = new RetouchView(photo.file);
            retouch_host = new Box(Orientation.VERTICAL, 0);
            retouch_host.add_css_class("photo-edit-host");
            retouch_host.hexpand = true;
            retouch_host.vexpand = true;
            retouch_host.append(retouch_view);
            content_overlay.add_overlay(retouch_host);
            retouch_view.message.connect((text) => main_window.add_toast(new Toast(text)));
            var target = retouch_view;
            retouch_view.finished.connect((saved) => close_retouch(target, saved));
            foreach (var b in zoom_bubbles) b.visible = false;
            foreach (var b in viewer_bubbles) b.visible = false;
            foreach (var b in edit_bubbles) b.visible = true;
            if (revert_bubble != null) revert_bubble.visible = false;
            update_bubbles_for_viewer(true);
            sidebar_before_edit = main_window.get_sidebar_visible();
            main_window.set_sidebar_visible(false);
            main_window.side_host.visible = false;
            update_photo_actions();
            retouch_view.grab_focus();
        }

        private void close_retouch(RetouchView view, bool saved) {
            if (retouch_view != view) return;
            var host = retouch_host;
            retouch_view = null;
            retouch_host = null;
            foreach (var b in edit_bubbles) b.visible = false;
            foreach (var b in zoom_bubbles) b.visible = true;
            main_window.set_sidebar_visible(sidebar_before_edit);
            main_window.side_host.visible = true;
            update_bubbles_for_viewer(full_viewer != null && full_viewer.visible);
            host.can_target = false;
            Singularity.Motion.conceal(host, Singularity.Motion.Preset.FADE).done.connect(() => content_overlay.remove_overlay(host));
            if (saved) schedule_reindex();
            update_photo_actions();
        }

        private void run_merge(string kind) {
            var recs = selected_records();
            int need = kind == "superres" ? 1 : 2;
            if (recs.size < need) {
                main_window.add_toast(new Toast(need == 1 ? _("Select a photo") : _("Select at least two photos")));
                return;
            }
            if (kind == "superres") {
                var one = new Gee.ArrayList<PhotoRecord>();
                one.add(recs[0]);
                recs = one;
            }
            var toast = new Toast(_("Merging %s…").printf(MergeRunner.title(kind)));
            main_window.add_toast(toast);
            MergeRunner.run(kind, recs, "cylindrical", (frac, stage) => {
            }, (result, err) => {
                if (err != null) {
                    main_window.add_toast(new Toast(err));
                    return;
                }
                if (result == null) return;
                var parent = result.get_parent();
                if (parent != null) index_shallow(parent);
                var r = catalog.find_path(result.get_path() ?? "");
                if (r != null && recs.size > 0) {
                    foreach (var k in recs[0].keywords) catalog.assign_keyword(r, k);
                    if (!under_roots(r.path)) add_library_root(Path.get_dirname(r.path));
                }
                load_photos();
                main_window.add_toast(new Toast(_("%s saved as %s").printf(MergeRunner.title(kind), result.get_basename())));
            });
        }

        // ── Helpers ────────────────────────────────────────────────────────────

        private string format_size(int64 sz) {
            if (sz < 1024) return sz.to_string() + " B";
            if (sz < 1024 * 1024) return "%.1f KB".printf((double)sz / 1024.0);
            if (sz < 1024 * 1024 * 1024) return "%.1f MB".printf((double)sz / (1024.0 * 1024.0));
            return "%.1f GB".printf((double)sz / (1024.0 * 1024.0 * 1024.0));
        }

        private void setup_styles() {
            Singularity.Application.add_app_css(PHOTOS_CSS);
        }

        private const string PHOTOS_CSS = """
.sx-inspector {
    border-left: 1px solid alpha(@window_fg_color, 0.08);
}

.sx-inspector-header {
    margin: 0 14px 10px 14px;
}

.photo-grid {
    padding: 8px;
}

.singularity-app:not(.static-titlebar) .photo-grid:not(.photos-filtered) {
    padding-top: 52px;
}

.photo-grid-item {
    border-radius: 8px;
    padding: 6px;
}

.photo-grid-item:hover {
    background-color: alpha(@text_color, 0.08);
}

.photo-grid-item:selected {
    background-color: alpha(@accent_color, 0.3);
}

.photo-grid-item image {
    border-radius: 6px;
}

.photo-month-header {
    font-weight: bold;
    font-size: 13px;
    margin: 12px 8px 4px 8px;
}

.photo-viewer-overlay {
    background-color: @surface_scrim_heavy;
}

.photo-viewer-controls {
    background-color: alpha(@shadow_color, 0.6);
    border-radius: 12px;
    padding: 8px 16px;
}


.photo-thumb {
    border-radius: 6px;
}

/* Viewer rotation helpers */
.rotate-90 {
    transform: rotate(90deg);
}

.rotate-180 {
    transform: rotate(180deg);
}

.rotate-270 {
    transform: rotate(270deg);
}
""";
    }
}
