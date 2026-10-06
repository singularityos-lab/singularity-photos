using Gtk;
using GLib;
using Singularity.Accounts;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public class OnlinePhotos : GLib.Object {
        private class ViewRef : GLib.Object {
            public string account_id = "";
            public string album = "";
            public string title = "";
        }

        public delegate void FileReady(GLib.File? file);

        public Box section { get; private set; }
        public Box page_holder { get; private set; }
        public string active_view { get; private set; default = ""; }
        public GLib.File library_folder { get; set; }

        public signal void view_requested(string view_id);
        public signal void reload_requested();
        public signal void loaded();

        private unowned Singularity.Widgets.Window window;
        private Manager manager;
        private Gee.HashMap<string, PhotoSource> sources = new Gee.HashMap<string, PhotoSource>();
        private Gee.HashMap<string, ViewRef> views = new Gee.HashMap<string, ViewRef>();
        private Gee.HashMap<string, SidebarRow> rows = new Gee.HashMap<string, SidebarRow>();
        private Gee.HashMap<string, Gee.List<OnlinePhoto>> cache = new Gee.HashMap<string, Gee.List<OnlinePhoto>>();
        private Gee.HashMap<string, Gee.List<PhotoAlbum>> albums = new Gee.HashMap<string, Gee.List<PhotoAlbum>>();
        private Gee.HashSet<string> albums_loading = new Gee.HashSet<string>();
        private Gee.HashSet<string> in_flight = new Gee.HashSet<string>();
        private GLib.Cancellable? cancellable = null;
        private GLib.Cancellable? pick_cancel = null;
        private uint generation = 0;
        private string state = "";
        private GLib.Error? last_error = null;
        private Button? pick_bubble = null;
        private Button? upload_bubble = null;
        private Button? refresh_bubble = null;
        private bool viewer_open = false;

        public OnlinePhotos(Singularity.Widgets.Window window, Overlay content_overlay) {
            this.window = window;
            section = new Box(Orientation.VERTICAL, 2);
            section.visible = false;

            page_holder = new Box(Orientation.VERTICAL, 0);
            page_holder.hexpand = true;
            page_holder.vexpand = true;
            page_holder.visible = false;
            content_overlay.add_overlay(page_holder);

            pick_bubble = window.add_bubble_icon("list-add-symbolic", _("Add from Google Photos"), () => start_pick());
            upload_bubble = window.add_bubble_icon("document-send-symbolic", _("Upload Photos"), () => choose_upload());
            refresh_bubble = window.add_bubble_icon("view-refresh-symbolic", _("Refresh"), () => refresh());
            update_bubbles();

            manager = Manager.get_default();
            manager.account_added.connect(() => rebuild());
            manager.account_removed.connect(() => rebuild());
            manager.account_changed.connect((a) => {
                sources.unset(a.id);
                rebuild();
            });
            manager.needs_attention.connect(() => rebuild());
            manager.reloaded.connect(() => rebuild());
            manager.load.begin((obj, res) => {
                manager.load.end(res);
                rebuild();
            });
        }

        public bool owns(string view) {
            return view.has_prefix("online:");
        }

        public bool is_loading {
            get { return state == "loading" || state == "picking"; }
        }

        private static string short_key(string text) {
            return GLib.Checksum.compute_for_string(GLib.ChecksumType.SHA1, text).substring(0, 12);
        }

        private PhotoSource? source_of(string view) {
            var v = views[view];
            if (v == null) return null;
            return sources[v.account_id];
        }

        private string label_for(Account account, PhotoSource source) {
            int same = 0;
            foreach (var other in manager.get_accounts_for(Capability.PHOTOS)) {
                var s = sources[other.id];
                if (s != null && s.title == source.title) same++;
            }
            return same > 1 ? "%s (%s)".printf(source.title, account.display_name) : source.title;
        }

        private void rebuild() {
            Widget? child;
            while ((child = section.get_first_child()) != null) section.remove(child);
            rows.clear();
            views.clear();
            var accounts = manager.get_accounts_for(Capability.PHOTOS);
            foreach (var account in accounts) {
                if (!sources.has_key(account.id)) {
                    var s = PhotoSource.for_account(account);
                    if (s != null) sources[account.id] = s;
                }
            }
            foreach (var id in sources.keys.to_array()) {
                bool alive = false;
                foreach (var account in accounts) if (account.id == id) alive = true;
                if (!alive) sources.unset(id);
            }
            if (sources.size > 0) {
                section.append(new SidebarSectionLabel(_("Online Accounts")));
            }
            foreach (var account in accounts) {
                var source = sources[account.id];
                if (source == null) continue;
                string view = "online:" + account.id;
                var root = new ViewRef();
                root.account_id = account.id;
                root.title = label_for(account, source);
                views[view] = root;
                var row = add_row(view, account.symbolic_icon_name, root.title, 0);
                row.tooltip_text = account.healthy
                    ? account.display_name
                    : _("%s, sign in again in Settings").printf(account.display_name);
                if (!account.healthy) {
                    var box = row.get_child() as Box;
                    if (box != null) {
                        var warn = new Image.from_icon_name("dialog-warning-symbolic");
                        warn.pixel_size = 16;
                        warn.add_css_class("warning");
                        box.append(warn);
                    }
                }
                foreach (var fixed in source.fixed_views()) add_album_row(account, fixed, "camera-photo-symbolic");
                var list = albums[account.id];
                if (list != null) {
                    foreach (var album in list) add_album_row(account, album, "folder-pictures-symbolic");
                } else if (source.has_albums && account.healthy) {
                    load_albums(account.id);
                }
            }
            section.visible = rows.size > 0;
            if (active_view != "" && !views.has_key(active_view)) {
                active_view = "";
                view_requested("library");
            } else if (active_view != "") {
                var row = rows[active_view];
                if (row != null) row.set_active(true);
                update_bubbles();
            }
        }

        private void add_album_row(Account account, PhotoAlbum album, string icon) {
            string view = "online:" + account.id + ":" + short_key(album.id);
            var v = new ViewRef();
            v.account_id = account.id;
            v.album = album.id;
            v.title = album.title;
            views[view] = v;
            var row = add_row(view, icon, album.title, 16);
            if (album.count >= 0) row.tooltip_text = ngettext("%d photo", "%d photos", album.count).printf(album.count);
        }

        private SidebarRow add_row(string view, string icon, string label, int indent) {
            var row = new SidebarRow(icon, label);
            row.margin_start = indent;
            row.clicked.connect(() => select(view));
            row.set_active(view == active_view);
            rows[view] = row;
            section.append(row);
            return row;
        }

        private void load_albums(string account_id) {
            var source = sources[account_id];
            if (source == null || albums_loading.contains(account_id)) return;
            albums_loading.add(account_id);
            source.albums.begin(null, (obj, res) => {
                albums_loading.remove(account_id);
                try {
                    albums[account_id] = source.albums.end(res);
                } catch (GLib.Error e) {
                    albums[account_id] = new Gee.ArrayList<PhotoAlbum>();
                    debug("photos: albums of %s: %s", source.account.display_name, e.message);
                }
                rebuild();
            });
        }

        public void select(string view) {
            foreach (var entry in rows.entries) entry.value.set_active(entry.key == view);
            active_view = view;
            update_bubbles();
            view_requested(view);
        }

        public void clear_active() {
            foreach (var row in rows.values) row.set_active(false);
            active_view = "";
            if (cancellable != null) cancellable.cancel();
            state = "";
            page_holder.visible = false;
            update_bubbles();
        }

        public void set_viewer_open(bool open) {
            viewer_open = open;
            update_bubbles();
        }

        private void update_bubbles() {
            var source = active_view != "" ? source_of(active_view) : null;
            var v = active_view != "" ? views[active_view] : null;
            bool on = source != null && !viewer_open;
            if (pick_bubble != null) pick_bubble.visible = on && source.can_pick && v != null && v.album == "";
            if (upload_bubble != null) upload_bubble.visible = on;
            if (refresh_bubble != null) refresh_bubble.visible = on;
        }

        private static int newest_first(OnlinePhoto a, OnlinePhoto b) {
            if (a.modified == null && b.modified == null) return a.name.collate(b.name);
            if (a.modified == null) return 1;
            if (b.modified == null) return -1;
            return b.modified.compare(a.modified);
        }

        private void fill(GLib.ListStore store, Gee.List<OnlinePhoto> items, string query) {
            store.remove_all();
            string q = query.down();
            foreach (var p in items) {
                if (q != "" && !p.name.down().contains(q)) continue;
                store.append(p);
            }
        }

        public void load(string view, GLib.ListStore store, string query) {
            if (cancellable != null) cancellable.cancel();
            active_view = view;
            update_bubbles();
            var source = source_of(view);
            var v = views[view];
            if (source == null || v == null) {
                store.remove_all();
                state = "missing";
                show_state();
                return;
            }
            uint gen = ++generation;
            var cached = cache[view];
            if (cached != null) {
                fill(store, cached, query);
                state = "";
                show_state();
                return;
            }
            store.remove_all();
            if (!source.account.healthy) {
                state = "reauth";
                show_state();
                return;
            }
            state = "loading";
            show_state();
            var c = new GLib.Cancellable();
            cancellable = c;
            source.list.begin(v.album, c, (obj, res) => {
                Gee.List<OnlinePhoto> items;
                try {
                    items = source.list.end(res);
                } catch (GLib.Error e) {
                    if (gen != generation || e is AccountsError.CANCELLED || e is GLib.IOError.CANCELLED) return;
                    last_error = e;
                    state = classify(source, e);
                    show_state();
                    loaded();
                    return;
                }
                if (gen != generation) return;
                items.sort(newest_first);
                cache[view] = items;
                fill(store, items, query);
                state = "";
                show_state();
                loaded();
            });
        }

        private string classify(PhotoSource source, GLib.Error e) {
            if (e is AccountsError.NEEDS_REAUTH || !source.account.healthy) return "reauth";
            if (e is AccountsError.AUTH_FAILED) return source.can_pick ? "scope" : "denied";
            if (e is AccountsError.NETWORK) return "offline";
            return "error";
        }

        public void refresh() {
            var source = source_of(active_view);
            if (source == null) return;
            foreach (var key in cache.keys.to_array()) {
                var v = views[key];
                if (v != null && v.account_id == source.account.id) cache.unset(key);
            }
            albums.unset(source.account.id);
            rebuild();
            reload_requested();
        }

        private void invalidate(PhotoSource source) {
            foreach (var key in cache.keys.to_array()) {
                var v = views[key];
                if (v == null || v.account_id == source.account.id) cache.unset(key);
            }
            if (source.has_albums) {
                albums.unset(source.account.id);
                rebuild();
            }
        }

        public void update_page(bool empty, bool searching) {
            if (active_view == "") {
                page_holder.visible = false;
                return;
            }
            if (state == "" && !(empty && !searching)) {
                page_holder.visible = false;
                return;
            }
            if (state == "" && empty && !searching) {
                show_empty();
                return;
            }
            show_state();
        }

        private void set_page(Widget page) {
            Widget? old;
            while ((old = page_holder.get_first_child()) != null) page_holder.remove(old);
            page.hexpand = true;
            page.vexpand = true;
            page_holder.append(page);
            Singularity.Motion.cancel(page_holder, "opacity");
            page_holder.opacity = 1.0;
            page_holder.visible = true;
        }

        private Button pill(string label, bool suggested) {
            var btn = new Button.with_label(label);
            btn.halign = Align.CENTER;
            btn.add_css_class("pill");
            if (suggested) btn.add_css_class("suggested-action");
            return btn;
        }

        private void status(string icon, string title, string description, Widget? child) {
            var page = new StatusPage();
            page.icon_name = icon;
            page.title = title;
            page.description = description;
            if (child != null) page.child = child;
            set_page(page);
        }

        private void show_state() {
            var source = source_of(active_view);
            if (state == "" ) {
                var first = page_holder.get_first_child();
                if (page_holder.visible && first != null && first.has_css_class("photos-skeleton")) {
                    var fade = Singularity.Motion.tween(page_holder, "opacity", 0.0,
                        Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.EXIT);
                    fade.done.connect(() => {
                        if (state != "") return;
                        page_holder.visible = false;
                        page_holder.opacity = 1.0;
                    });
                    return;
                }
                page_holder.visible = false;
                return;
            }
            if (source == null) {
                status("singularity-account-generic", _("Online Account Unavailable"),
                    _("This account was removed or no longer shows photos."), null);
                return;
            }
            var account = source.account;
            switch (state) {
                case "loading": {
                    var grid = Singularity.Widgets.Skeleton.grid(12, 150, 150, false);
                    grid.add_css_class("photos-skeleton");
                    grid.update_property(AccessibleProperty.LABEL, _("Getting the photos of %s").printf(account.display_name), -1);
                    set_page(grid);
                    return;
                }
                case "picking": {
                    var box = new Box(Orientation.VERTICAL, 18);
                    box.halign = Align.CENTER;
                    var spinner = new Spinner();
                    spinner.spinning = true;
                    spinner.width_request = 32;
                    spinner.height_request = 32;
                    box.append(spinner);
                    var cancel = pill(_("Cancel"), false);
                    cancel.clicked.connect(() => {
                        if (pick_cancel != null) pick_cancel.cancel();
                    });
                    box.append(cancel);
                    status(account.icon_name, _("Choose in Your Browser"),
                        _("Pick photos on the Google Photos page that opened in your browser. They appear here when you are done."), box);
                    return;
                }
                case "reauth": {
                    var open = pill(_("Open Settings"), true);
                    open.clicked.connect(open_settings);
                    status(account.icon_name, _("Sign In Again"),
                        _("%s needs you to sign in again in Settings before its photos can be shown.").printf(account.display_name), open);
                    return;
                }
                case "scope": {
                    var open = pill(_("Open Settings"), true);
                    open.clicked.connect(open_settings);
                    status(account.icon_name, _("Allow Access to Google Photos"),
                        _("Sign in to %s again in Settings and allow Google Photos, so Photos can show and upload pictures.").printf(account.display_name), open);
                    return;
                }
                case "offline": {
                    var retry = pill(_("Try Again"), true);
                    retry.clicked.connect(() => refresh());
                    status("network-error", _("Could Not Reach the Server"),
                        _("Check the connection and try again."), retry);
                    return;
                }
                default: {
                    var retry = pill(_("Try Again"), true);
                    retry.clicked.connect(() => refresh());
                    status("network-error", _("Could Not Load Photos"),
                        last_error != null ? last_error.message : _("Something went wrong while talking to the server."), retry);
                    return;
                }
            }
        }

        private void show_empty() {
            var source = source_of(active_view);
            var v = views[active_view];
            if (source == null || v == null) return;
            var page = new WelcomePage();
            page.is_section = true;
            page.app_icon_name = source.account.icon_name;
            if (v.album != "") {
                page.title = _("This Album Is Empty");
                page.subtitle = _("Photos added to %s show up here").printf(v.title);
            } else {
                page.title = source.empty_title;
                page.subtitle = source.empty_subtitle;
            }
            if (source.can_pick && v.album == "") {
                page.add_action(source.account.icon_name, _("Add from Google Photos…"),
                    _("Pick photos in your browser and keep a copy on this computer"), () => start_pick());
            }
            page.add_action("folder-remote", _("Upload Photos…"),
                _("Send pictures from this computer to %s").printf(source.title), () => choose_upload());
            page.add_action("image-x-generic", _("Browse Library"),
                _("See the photos on this computer"), () => view_requested("library"));
            set_page(page);
        }

        private void open_settings() {
            try {
                Singularity.Shell.ShellService shell = Bus.get_proxy_sync(
                    BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                shell.open_settings("accounts");
            } catch (GLib.Error e) {
                toast(_("Settings are not available: %s").printf(e.message));
            }
        }

        private void toast(string text) {
            window.add_toast(new Toast(text));
        }

        public void start_pick() {
            var source = source_of(active_view);
            if (source == null || !source.can_pick || state == "picking") return;
            pick_cancel = new GLib.Cancellable();
            string previous = state;
            state = "picking";
            show_state();
            var c = pick_cancel;
            source.pick.begin(c, (obj, res) => {
                try {
                    int added = source.pick.end(res);
                    state = "";
                    invalidate(source);
                    toast(added > 0
                        ? ngettext("Added %d photo from Google Photos", "Added %d photos from Google Photos", added).printf(added)
                        : _("No new photos were chosen"));
                    reload_requested();
                } catch (GLib.Error e) {
                    if (e is AccountsError.CANCELLED || e is GLib.IOError.CANCELLED) {
                        state = previous;
                        reload_requested();
                        return;
                    }
                    last_error = e;
                    state = classify(source, e);
                    show_state();
                    loaded();
                }
            });
        }

        private void choose_upload() {
            var source = source_of(active_view);
            if (source == null) return;
            var dialog = new FileDialog();
            dialog.title = _("Upload Photos");
            dialog.accept_label = _("Upload");
            var filter = new FileFilter();
            filter.name = _("Image Files");
            filter.add_mime_type("image/*");
            var filters = new GLib.ListStore(typeof(FileFilter));
            filters.append(filter);
            dialog.filters = filters;
            dialog.open_multiple.begin(window, null, (obj, res) => {
                try {
                    var model = dialog.open_multiple.end(res);
                    var files = new Gee.ArrayList<GLib.File>();
                    for (uint i = 0; i < model.get_n_items(); i++) files.add((GLib.File) model.get_item(i));
                    if (files.size > 0) upload_files.begin(source, files);
                } catch (GLib.Error e) {
                }
            });
        }

        public async void upload_files(PhotoSource source, Gee.List<GLib.File> files) {
            int done = 0;
            string? failure = null;
            foreach (var f in files) {
                try {
                    yield source.upload(f, null);
                    done++;
                } catch (GLib.Error e) {
                    failure = e.message;
                    if (e is AccountsError.AUTH_FAILED && source.can_pick) {
                        last_error = e;
                        break;
                    }
                }
            }
            invalidate(source);
            if (done > 0) {
                toast(ngettext("Uploaded %d photo to %s", "Uploaded %d photos to %s", done).printf(done, source.title));
            }
            if (failure != null) toast(_("Could not upload to %s: %s").printf(source.title, failure));
            var v = active_view != "" ? views[active_view] : null;
            if (v != null && v.account_id == source.account.id) reload_requested();
        }

        public void add_upload_items(ContextMenu menu, GLib.File file) {
            bool first = true;
            foreach (var account in manager.get_accounts_for(Capability.PHOTOS)) {
                var source = sources[account.id];
                if (source == null) continue;
                if (first) {
                    menu.add_separator();
                    first = false;
                }
                string label = _("Upload to %s").printf(label_for(account, source));
                menu.add_item(label, "document-send-symbolic", () => {
                    var files = new Gee.ArrayList<GLib.File>();
                    files.add(file);
                    upload_files.begin(source, files);
                });
            }
        }

        public void bind_thumbnail(Image img, Spinner? spinner, OnlinePhoto photo, int size) {
            string key = photo.path;
            string flight = photo.source.thumb_file(photo).get_path();
            if (in_flight.contains(flight)) {
                GLib.Timeout.add(250, () => {
                    if (img.get_data<string>("thumb-for-path") == key) bind_thumbnail(img, spinner, photo, size);
                    return GLib.Source.REMOVE;
                });
                return;
            }
            in_flight.add(flight);
            photo.source.ensure_thumbnail.begin(photo, 256, null, (obj, res) => {
                in_flight.remove(flight);
                GLib.File? thumb = null;
                try {
                    thumb = photo.source.ensure_thumbnail.end(res);
                } catch (GLib.Error e) {
                    debug("photos: thumbnail of %s: %s", photo.name, e.message);
                }
                if (img.get_data<string>("thumb-for-path") != key) return;
                if (thumb == null) {
                    img.set_from_icon_name("image-x-generic-symbolic");
                    if (spinner != null) {
                        spinner.spinning = false;
                        spinner.visible = false;
                    }
                    return;
                }
                string path = thumb.get_path();
                int px = size;
                new GLib.Thread<void>("online-thumb", () => {
                    Gdk.Pixbuf? pb = null;
                    try {
                        pb = new Gdk.Pixbuf.from_file_at_scale(path, px, px, true);
                    } catch (GLib.Error e) {
                    }
                    GLib.Idle.add(() => {
                        if (img.get_data<string>("thumb-for-path") == key) {
                            if (pb != null) img.set_from_paintable(Gdk.Texture.for_pixbuf(pb));
                            else img.set_from_icon_name("image-x-generic-symbolic");
                            if (spinner != null) {
                                spinner.spinning = false;
                                spinner.visible = false;
                            }
                        }
                        return GLib.Source.REMOVE;
                    });
                });
            });
        }

        public void with_full(OnlinePhoto photo, owned FileReady done) {
            photo.source.ensure_full.begin(photo, null, (obj, res) => {
                try {
                    done(photo.source.ensure_full.end(res));
                } catch (GLib.Error e) {
                    toast(_("Could not download %s: %s").printf(photo.name, e.message));
                    done(null);
                }
            });
        }

        public GLib.File? preview_file(OnlinePhoto photo) {
            var f = photo.source.thumb_file(photo);
            return f.query_exists() ? f : null;
        }

        public void show_context_menu(Widget parent_widget, OnlinePhoto photo, double x, double y) {
            var menu = new ContextMenu(parent_widget);
            var r = Gdk.Rectangle();
            r.x = (int) x;
            r.y = (int) y;
            r.width = 1;
            r.height = 1;
            menu.pointing_to = r;
            menu.add_item(_("Open"), "document-open-symbolic", () => {
                with_full(photo, (f) => {
                    if (f == null) return;
                    try {
                        AppInfo.launch_default_for_uri(f.get_uri(), null);
                    } catch (GLib.Error e) {
                        warning("Open: %s", e.message);
                    }
                });
            });
            menu.add_item(_("Save to Library"), "folder-download-symbolic", () => save_to_library(photo));
            menu.add_separator();
            menu.add_item(_("Copy to Clipboard"), "edit-copy-symbolic", () => {
                with_full(photo, (f) => {
                    if (f == null) return;
                    try {
                        Gdk.Display.get_default().get_clipboard().set_texture(Gdk.Texture.from_file(f));
                    } catch (GLib.Error e) {
                        warning("Copy: %s", e.message);
                    }
                });
            });
            menu.add_item(_("Share…"), "singularity-share-symbolic", () => {
                with_full(photo, (f) => {
                    if (f != null) Singularity.Share.files(window, { f });
                });
            });
            if (photo.picked) {
                menu.add_separator();
                menu.add_item(_("Remove from This Computer"), "user-trash-symbolic", () => {
                    photo.source.forget(photo);
                    invalidate(photo.source);
                    reload_requested();
                });
            }
            menu.popup();
        }

        private void save_to_library(OnlinePhoto photo) {
            with_full(photo, (f) => {
                if (f == null || library_folder == null) return;
                try {
                    library_folder.make_directory_with_parents(null);
                } catch (GLib.Error e) {
                }
                var dest = library_folder.get_child(photo.name);
                int n = 1;
                string stem = photo.name;
                string ext = "";
                int dot = photo.name.last_index_of(".");
                if (dot > 0) {
                    stem = photo.name.substring(0, dot);
                    ext = photo.name.substring(dot);
                }
                while (dest.query_exists() && n < 100) {
                    dest = library_folder.get_child("%s (%d)%s".printf(stem, n, ext));
                    n++;
                }
                try {
                    f.copy(dest, GLib.FileCopyFlags.NONE, null, null);
                    toast(_("Saved %s to %s").printf(dest.get_basename(), library_folder.get_basename()));
                } catch (GLib.Error e) {
                    toast(_("Could not save %s: %s").printf(photo.name, e.message));
                }
            });
        }
    }
}
