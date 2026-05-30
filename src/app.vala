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

        // Search bar references
        private Singularity.Widgets.OverlaySearch? search_overlay = null;

        // Content overlay (hosts grid + viewer)
        private Overlay content_overlay;

        public PhotosApp() {
            GLib.Object(application_id: "dev.sinty.photos",
                        flags: ApplicationFlags.HANDLES_OPEN);
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
            file_menu.append("Import Photos…", "app.import");
            file_menu.append("Quit", "app.quit");
            menu.append_submenu("File", file_menu);
            set_menubar(menu);

            var act_import = new SimpleAction("import", null);
            act_import.activate.connect(() => on_import());
            add_action(act_import);

            var act_quit = new SimpleAction("quit", null);
            act_quit.activate.connect(() => quit());
            add_action(act_quit);
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

            main_window = new PhotosWindow(this);
            content_overlay = main_window.content_overlay;

            setup_sidebar(main_window.sidebar_scroll);
            setup_toolbar();
            setup_content(main_window.content_box, main_window.search_host, main_window.grid_scroll);
            setup_viewer();
            setup_drag_drop();
            setup_library_monitor();
            load_photos();

            main_window.present();
            main_window.close_request.connect(() => {
                if (lib_monitor != null) { lib_monitor.cancel(); lib_monitor = null; }
                return false;
            });
        }

        protected override void open(GLib.File[] files, string hint) {
            activate();
            if (files.length == 0) return;
            var parent = files[0].get_parent();
            if (parent != null) library_folder = parent;
            load_photos();
            for (uint i = 0; i < photo_store.get_n_items(); i++) {
                var pi = (PhotoItem) photo_store.get_item(i);
                if (pi.file.equal(files[0])) {
                    show_viewer((int) i);
                    return;
                }
            }
        }

        // ── Sidebar ────────────────────────────────────────────────────────────

        private void setup_sidebar(AppSidebar sidebar_scroll) {
            var sidebar_box = sidebar_scroll.box;
            add_sidebar_section(sidebar_box, "Library");
            add_sidebar_item(sidebar_box, "image-x-generic-symbolic", "Library", "library");
            add_sidebar_item(sidebar_box, "starred-symbolic", "Favorites", "favorites");
            add_sidebar_item(sidebar_box, "document-new-symbolic", "Recently Added", "recent");
            add_sidebar_section(sidebar_box, "Other");
            add_sidebar_item(sidebar_box, "user-trash-symbolic", "Trash", "trash");
            // The window already installed the sidebar via set_sidebar().
        }

        private void add_sidebar_section(Box parent, string title) {
            var lbl = new Label(title);
            lbl.add_css_class("caption");
            lbl.add_css_class("dim-label");
            lbl.halign = Align.START;
            lbl.margin_top = 12;
            lbl.margin_start = 4;
            parent.append(lbl);
        }

        // Store view_id on the button widget so the closure reads it safely

        private void add_sidebar_item(Box parent, string icon_name, string label_text, string view_id) {
            var btn = new Button();
            btn.add_css_class("flat");
            btn.halign = Align.FILL;

            var row = new Box(Orientation.HORIZONTAL, 8);
            row.margin_start  = 4;
            row.margin_end    = 4;
            row.margin_top    = 3;
            row.margin_bottom = 3;
            var img = new Image.from_icon_name(icon_name);
            img.pixel_size = 16;
            var lbl = new Label(label_text);
            lbl.halign = Align.START;
            lbl.hexpand = true;
            row.append(img);
            row.append(lbl);
            btn.set_child(row);

            if (current_view == view_id) {
                btn.add_css_class("sidebar-nav-active");
            }

            btn.set_data<string>("view-id", view_id);

            btn.clicked.connect(() => {
                string vid = btn.get_data<string>("view-id") ?? "library";
                current_view = vid;
                settings.set_string("sidebar-view", current_view);
                load_photos();

                var sib = parent.get_first_child();
                while (sib != null) {
                    if (sib is Button) ((Button)sib).remove_css_class("sidebar-nav-active");
                    sib = sib.get_next_sibling();
                }
                btn.add_css_class("sidebar-nav-active");
            });

            parent.append(btn);
        }

        // ── Toolbar ────────────────────────────────────────────────────────────

        // Floating bubble controls (Leafs-style) instead of a toolbar:
        // settings · search-toggle · zoom − / + · import · close.
        private void setup_toolbar() {
            var hover = main_window.hover;

            // Drag grip to move the window (Leafs / browser style).
            var grip_btn = new Button.from_icon_name("list-drag-handle-symbolic");
            grip_btn.tooltip_text = "Drag Window";
            var grip_drag = new Gtk.GestureDrag();
            grip_drag.drag_begin.connect((x, y) => {
                var surface = main_window.get_surface();
                if (surface is Gdk.Toplevel) {
                    ((Gdk.Toplevel) surface).begin_move(
                        grip_drag.get_device(), 1, x, y, Gdk.CURRENT_TIME);
                }
            });
            grip_btn.add_controller(grip_drag);
            hover.add_control(grip_btn);

            // Toggle the sidebar (Store style).
            var sidebar_btn = new Button.from_icon_name("sidebar-show-symbolic");
            sidebar_btn.tooltip_text = "Toggle Sidebar";
            sidebar_btn.clicked.connect(() => {
                main_window.set_sidebar_visible(!main_window.get_sidebar_visible());
            });
            hover.add_control(sidebar_btn);

            hover.add_separator();

            var search_btn = new Button.from_icon_name("system-search-symbolic");
            search_btn.tooltip_text = "Search";
            search_btn.clicked.connect(() => toggle_search());
            hover.add_control(search_btn);

            hover.add_separator();

            var zoom_out = new Button.from_icon_name("zoom-out-symbolic");
            zoom_out.tooltip_text = "Smaller thumbnails";
            zoom_out.clicked.connect(() => adjust_zoom(-20));
            hover.add_control(zoom_out);

            var zoom_in = new Button.from_icon_name("zoom-in-symbolic");
            zoom_in.tooltip_text = "Larger thumbnails";
            zoom_in.clicked.connect(() => adjust_zoom(20));
            hover.add_control(zoom_in);

            hover.add_separator();

            var import_btn = new Button.from_icon_name("document-save-symbolic");
            import_btn.tooltip_text = "Import photos";
            import_btn.clicked.connect(() => on_import());
            hover.add_control(import_btn);

            hover.add_separator();

            var close_btn = new Button.from_icon_name("window-close-symbolic");
            close_btn.tooltip_text = "Close";
            close_btn.clicked.connect(() => main_window.close());
            hover.add_control(close_btn);
        }

        private void adjust_zoom(int delta) {
            thumb_size = (thumb_size + delta).clamp(80, 240);
            settings.set_int("thumbnail-size", thumb_size);
            load_photos();
        }

        private void toggle_search() {
            if (search_overlay == null) return;
            if (search_overlay.visible) search_overlay.close();
            else                       search_overlay.open();
        }

        // ── Content area ───────────────────────────────────────────────────────

        private void setup_content(Box content_box, Box search_host, ScrolledWindow scroll) {
            search_overlay = new Singularity.Widgets.OverlaySearch();
            search_overlay.placeholder      = "Search photos…";
            search_overlay.show_list        = false;
            search_overlay.internal_filter  = false;
            search_overlay.query_changed.connect((q) => {
                search_query = q;
                load_photos();
            });
            search_overlay.close_requested.connect(() => search_overlay.close());
            main_window.content_overlay.add_overlay(search_overlay);

            scroll.set_policy(PolicyType.NEVER, PolicyType.AUTOMATIC);

            photo_store = new GLib.ListStore(typeof(PhotoItem));
            var selection = new SingleSelection(photo_store);

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

            var thumb_overlay = new Overlay();
            thumb_overlay.set_child(img);
            thumb_overlay.add_overlay(spinner);

            var lbl = new Label("");
            lbl.ellipsize = Pango.EllipsizeMode.END;
            lbl.max_width_chars = 14;
            lbl.add_css_class("caption");

            box.append(thumb_overlay);
            box.append(lbl);

            // Store refs for bind/unbind
            box.set_data<Image>("thumb-img", img);
            box.set_data<Spinner>("thumb-spinner", spinner);

            // Right-click context menu - reads photo from widget data, not closure
            var gesture = new GestureClick();
            gesture.button = 3;
            gesture.pressed.connect((n, x, y) => {
                var pi = box.get_data<PhotoItem>("photo-item");
                if (pi != null) show_photo_context_menu(box, pi, x, y);
            });
            box.add_controller(gesture);

            // Drag source
            var drag_src = new DragSource();
            drag_src.actions = Gdk.DragAction.COPY | Gdk.DragAction.MOVE;
            drag_src.prepare.connect((x, y) => {
                var pi = box.get_data<PhotoItem>("photo-item");
                if (pi == null) return null;
                var bytes = new GLib.Bytes((pi.file.get_uri() + "\r\n").data);
                return new Gdk.ContentProvider.for_bytes("text/uri-list", bytes);
            });
            box.add_controller(drag_src);

            list_item.set_child(box);
        }

        private void on_grid_item_bind(GLib.Object obj) {
            var list_item = (ListItem)obj;
            var box = (Box)list_item.get_child();
            var img = box.get_data<Image>("thumb-img");
            var spinner = box.get_data<Spinner>("thumb-spinner");
            var thumb_overlay = (Overlay)box.get_first_child();
            var lbl = (Label)thumb_overlay.get_next_sibling();
            var photo = (PhotoItem)list_item.get_item();

            box.set_data<PhotoItem>("photo-item", photo);
            lbl.label = photo.name;
            img.pixel_size = thumb_size;
            img.set_from_icon_name("image-loading-symbolic");
            spinner.spinning = true;
            spinner.visible = true;

            string path = photo.path;
            img.set_data<string>("thumb-for-path", path);
            load_thumbnail_async(img, spinner, path, thumb_size);
        }

        private void on_grid_item_unbind(GLib.Object obj) {
            var list_item = (ListItem)obj;
            var box = (Box)list_item.get_child();
            var img = box.get_data<Image>("thumb-img");
            var spinner = box.get_data<Spinner>("thumb-spinner");
            if (img != null) img.set_data<string>("thumb-for-path", "");
            if (spinner != null) { spinner.spinning = false; spinner.visible = false; }
        }

        private void load_thumbnail_async(Image img, Spinner? spinner, string file_path, int size) {
            string path = file_path;
            int px = size;

            new GLib.Thread<void>("photo-thumb", () => {
                Gdk.Pixbuf? pb = null;
                try {
                    pb = new Gdk.Pixbuf.from_file_at_scale(path, px, px, true);
                } catch (Error e) {}
                GLib.Idle.add(() => {
                    string? expected = img.get_data<string>("thumb-for-path");
                    if (expected != null && expected == path) {
                        if (pb != null)
                            img.set_from_pixbuf(pb);
                        else
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

            // Close button (top-right)
            var close_btn = new Button.from_icon_name("window-close-symbolic");
            close_btn.add_css_class("circular");
            close_btn.add_css_class("osd");
            close_btn.halign = Align.END;
            close_btn.valign = Align.START;
            close_btn.margin_top = 12;
            close_btn.margin_end = 12;
            close_btn.clicked.connect(() => hide_viewer());
            full_viewer.add_overlay(close_btn);

            // Bottom controls bar
            var controls_bar = new Box(Orientation.HORIZONTAL, 8);
            controls_bar.add_css_class("photo-viewer-controls");
            controls_bar.halign = Align.CENTER;
            controls_bar.valign = Align.END;
            controls_bar.margin_bottom = 20;

            var rot_left = new Button.from_icon_name("object-rotate-left-symbolic");
            rot_left.add_css_class("flat");
            rot_left.tooltip_text = "Rotate Left";
            rot_left.clicked.connect(() => rotate_current(-90));
            controls_bar.append(rot_left);

            var prev_btn = new Button.from_icon_name("go-previous-symbolic");
            prev_btn.add_css_class("flat");
            prev_btn.tooltip_text = "Previous (Left)";
            prev_btn.clicked.connect(() => navigate_viewer(-1));
            controls_bar.append(prev_btn);

            viewer_fav_btn = new Button.from_icon_name("non-starred-symbolic");
            viewer_fav_btn.add_css_class("flat");
            viewer_fav_btn.tooltip_text = "Favorite";
            viewer_fav_btn.clicked.connect(() => toggle_favorite_current());
            controls_bar.append(viewer_fav_btn);

            viewer_filename_label = new Label("");
            viewer_filename_label.add_css_class("title-4");
            viewer_filename_label.halign = Align.CENTER;
            viewer_filename_label.hexpand = true;
            viewer_filename_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            controls_bar.append(viewer_filename_label);

            viewer_info_label = new Label("");
            viewer_info_label.add_css_class("caption");
            viewer_info_label.add_css_class("dim-label");
            controls_bar.append(viewer_info_label);

            var next_btn = new Button.from_icon_name("go-next-symbolic");
            next_btn.add_css_class("flat");
            next_btn.tooltip_text = "Next (Right)";
            next_btn.clicked.connect(() => navigate_viewer(1));
            controls_bar.append(next_btn);

            var rot_right = new Button.from_icon_name("object-rotate-right-symbolic");
            rot_right.add_css_class("flat");
            rot_right.tooltip_text = "Rotate Right";
            rot_right.clicked.connect(() => rotate_current(90));
            controls_bar.append(rot_right);

            full_viewer.add_overlay(controls_bar);
            content_overlay.add_overlay(full_viewer);

            // Keyboard navigation (only active when viewer is open)
            var key_ctrl = new EventControllerKey();
            key_ctrl.key_pressed.connect((keyval, keycode, state) => {
                if (full_viewer == null || !full_viewer.visible) return false;
                if (keyval == Gdk.Key.Escape) { hide_viewer(); return true; }
                if (keyval == Gdk.Key.Left)  { navigate_viewer(-1); return true; }
                if (keyval == Gdk.Key.Right) { navigate_viewer(1);  return true; }
                return false;
            });
            ((Gtk.Widget)main_window).add_controller(key_ctrl);
        }

        private void show_viewer(int index) {
            viewer_index = index;
            viewer_rotation = 0;
            full_viewer.visible = true;
            load_viewer_photo();
            main_window.grab_focus();
        }

        private void hide_viewer() {
            if (full_viewer != null) full_viewer.visible = false;
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

            try {
                var texture = Gdk.Texture.from_file(photo.file);
                viewer_picture.set_paintable(texture);
            } catch (Error e) {
                viewer_picture.set_paintable(null);
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
        }

        private void rotate_current(int degrees) {
            if (viewer_picture == null) return;
            viewer_rotation = (viewer_rotation + degrees) % 360;
            if (viewer_rotation < 0) viewer_rotation += 360;
            viewer_picture.remove_css_class("rotate-90");
            viewer_picture.remove_css_class("rotate-180");
            viewer_picture.remove_css_class("rotate-270");
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
        }

        // ── Context menu ───────────────────────────────────────────────────────

        private void show_photo_context_menu(Widget parent_widget, PhotoItem photo, double x, double y) {
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
            menu.add_separator();
            menu.add_item("Move to Trash", "user-trash-symbolic", () => {
                try {
                    photo.file.trash(null);
                    load_photos();
                } catch (Error e) { warning("Trash: %s", e.message); }
            });

            menu.popup();
        }

        // ── Library loading ────────────────────────────────────────────────────

        private void load_photos() {
            photo_store.remove_all();

            var collected = new Gee.ArrayList<PhotoItem>();

            if (current_view == "trash") {
                var trash_dir = GLib.File.new_for_path(
                    GLib.Environment.get_home_dir() + "/.local/share/Trash/files");
                enumerate_photos_recursive(trash_dir, collected);
            } else {
                enumerate_photos_recursive(library_folder, collected);
            }

            // Sort by modification date, newest first
            collected.sort((a, b) => {
                if (a.modified == null && b.modified == null) return 0;
                if (a.modified == null) return 1;
                if (b.modified == null) return -1;
                return b.modified.compare(a.modified);
            });

            string[] favs = settings.get_strv("favorites");
            var now = new GLib.DateTime.now_local();

            foreach (var pi in collected) {
                if (current_view == "favorites") {
                    bool found = false;
                    string pi_uri = pi.file.get_uri();
                    foreach (var f in favs) { if (f == pi_uri) { found = true; break; } }
                    if (!found) continue;
                } else if (current_view == "recent") {
                    if (pi.modified == null) continue;
                    GLib.TimeSpan diff = now.difference(pi.modified);
                    if (diff > GLib.TimeSpan.DAY * 30) continue;
                }

                if (search_query != "" && !pi.name.down().contains(search_query.down()))
                    continue;

                photo_store.append(pi);
            }
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
                        load_photos();
                    }
                });
            } catch (Error e) {
                warning("Cannot monitor library: %s", e.message);
            }
        }

        // ── Import ─────────────────────────────────────────────────────────────

        private void on_import() {
            var chooser = new FileChooserNative(
                "Import Photos", main_window,
                FileChooserAction.OPEN, "Import", "Cancel");
            chooser.select_multiple = true;

            var filter = new FileFilter();
            filter.name = "Image Files";
            filter.add_mime_type("image/jpeg");
            filter.add_mime_type("image/png");
            filter.add_mime_type("image/gif");
            filter.add_mime_type("image/webp");
            filter.add_mime_type("image/bmp");
            filter.add_mime_type("image/tiff");
            chooser.add_filter(filter);

            chooser.response.connect((response) => {
                if (response == ResponseType.ACCEPT) {
                    import_files(chooser.get_files());
                }
            });
            chooser.show();
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
            load_photos();
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
            load_photos();
            return true;
        }

        // ── Helpers ────────────────────────────────────────────────────────────

        private string format_size(int64 sz) {
            if (sz < 1024) return sz.to_string() + " B";
            if (sz < 1024 * 1024) return "%.1f KB".printf((double)sz / 1024.0);
            if (sz < 1024 * 1024 * 1024) return "%.1f MB".printf((double)sz / (1024.0 * 1024.0));
            return "%.1f GB".printf((double)sz / (1024.0 * 1024.0 * 1024.0));
        }

        private void setup_styles() {
            var provider = new Gtk.CssProvider();
            provider.load_from_data(PHOTOS_CSS.data);
            Gtk.StyleContext.add_provider_for_display(
                Gdk.Display.get_default(), provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        private const string PHOTOS_CSS = """
/* Photos App */
.photo-grid {
    padding: 8px;
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
