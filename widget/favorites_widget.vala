using Gtk;
using GLib;
using Singularity;

namespace SingularityPhotosWidget {

    public class FavoritesProvider : Object, OverviewWidgetProvider {
        public string id           { get { return "photos.favorites"; } }
        public string provider_id  { get { return "dev.sinty.photos"; } }
        public string display_name { get { return "Photos"; } }
        public string icon_name    { get { return "image-x-generic-symbolic"; } }
        public WidgetSize[] supported_sizes {
            get {
                if (_sizes == null) {
                    _sizes = new WidgetSize[6];
                    _sizes[0] = WidgetSize(1, 1);
                    _sizes[1] = WidgetSize(1, 2);
                    _sizes[2] = WidgetSize(2, 2);
                    _sizes[3] = WidgetSize(4, 2);
                    _sizes[4] = WidgetSize(4, 4);
                    _sizes[5] = WidgetSize(6, 4);
                }
                return _sizes;
            }
        }
        private WidgetSize[] _sizes;
        public Gtk.Widget create_instance(string instance_id, WidgetSize size, Variant? config) {
            return new FavoritesInstance(size);
        }
    }

    /**
     * Slideshow of favorite photos (max 5) with a dot indicator strip.
     * Auto-rotates every 5s, pauses on hover. Favorites come from the
     * photos app gsettings (`dev.sinty.photos`, key `favorites`).
     */
    public class FavoritesInstance : Gtk.Box {
        private Singularity.Widgets.Carousel? carousel = null;
        private Gtk.Label empty_lbl;
        private GLib.Settings? settings = null;
        private uint rotate_id = 0;
        private bool hovered = false;
        private string[] last_favs = new string[0];
        private int cover_w;
        private int cover_h;

        public FavoritesInstance(WidgetSize size) {
            Object(orientation: Orientation.VERTICAL, spacing: 4);
            add_css_class("overview-photos");
            overflow = Overflow.HIDDEN;
            // Approximate pixel size from grid cells (1 cell ≈ 110px).
            cover_w = size.w * 110;
            cover_h = size.h * 110;

            try {
                settings = new GLib.Settings("dev.sinty.photos");
                settings.changed["favorites"].connect(refresh);
            } catch (Error e) {
                warning("photos widget: schema missing: %s", e.message);
            }

            empty_lbl = new Gtk.Label("No favorite photos yet -\nright-click a photo to mark it.");
            empty_lbl.add_css_class("dim-label");
            empty_lbl.justify = Justification.CENTER;
            empty_lbl.halign = Align.CENTER;
            empty_lbl.valign = Align.CENTER;
            empty_lbl.hexpand = true; empty_lbl.vexpand = true;
            append(empty_lbl);

            refresh();

            var hover = new EventControllerMotion();
            hover.enter.connect((x, y) => { hovered = true;  });
            hover.leave.connect(()     => { hovered = false; });
            add_controller(hover);

            destroy.connect(() => {
                if (rotate_id != 0) { GLib.Source.remove(rotate_id); rotate_id = 0; }
            });
        }

        private void refresh() {
            string[] favs = (settings != null) ? settings.get_strv("favorites") : new string[0];
            // Up to 5 - carousels get unwieldy with more dots than that.
            if (favs.length > 5) favs = favs[0:5];

            // Rebuild only if the list changed; rebuilding cancels any
            // in-flight scroll which is annoying.
            if (string_list_equal(favs, last_favs)) return;
            last_favs = favs;

            if (carousel != null) { remove(carousel); carousel = null; }

            if (favs.length == 0) {
                empty_lbl.visible = true;
                if (rotate_id != 0) { GLib.Source.remove(rotate_id); rotate_id = 0; }
                return;
            }
            empty_lbl.visible = false;

            carousel = new Singularity.Widgets.Carousel();
            carousel.hexpand = true; carousel.vexpand = true;
            foreach (var path in favs) carousel.append_page(new_photo_page(path));
            append(carousel);

            if (rotate_id != 0) GLib.Source.remove(rotate_id);
            rotate_id = GLib.Timeout.add(5000, () => {
                if (carousel == null) return GLib.Source.REMOVE;
                if (hovered) return GLib.Source.CONTINUE;
                uint n = carousel.n_pages;
                if (n <= 1) return GLib.Source.CONTINUE;
                uint next = (carousel.position + 1) % n;
                carousel.scroll_to_index(next, true);
                return GLib.Source.CONTINUE;
            });
        }

        private Gtk.Widget new_photo_page(string uri_or_path) {
            // Photos app stores favorites as file:// URIs. Accept both
            // forms so manually-set paths in dconf still work.
            string fs_path = uri_or_path.has_prefix("file://")
                ? GLib.File.new_for_uri(uri_or_path).get_path()
                : uri_or_path;
            string uri = uri_or_path.has_prefix("file://")
                ? uri_or_path
                : GLib.File.new_for_path(uri_or_path).get_uri();

            var pic = new Gtk.Picture();
            pic.content_fit = ContentFit.COVER;
            pic.can_shrink = true;
            pic.overflow = Overflow.HIDDEN;
            pic.add_css_class("overview-photo");
            pic.hexpand = true; pic.vexpand = true;
            // Decode off the main thread: doing it inline blocked the overview's
            // first open for >1s when several favourites were set. The picture
            // starts empty and fills in when the worker finishes.
            int dw = int.max(64, cover_w);
            int dh = int.max(64, cover_h);
            new GLib.Thread<void>("photo-fav-decode", () => {
                Gdk.Pixbuf? pb = null;
                if (fs_path != null && FileUtils.test(fs_path, FileTest.EXISTS)) {
                    try {
                        pb = new Gdk.Pixbuf.from_file_at_scale(fs_path, dw, dh, true);
                    } catch (Error e) {
                        warning("photos widget: cannot load %s: %s", uri_or_path, e.message);
                    }
                }
                Gdk.Pixbuf? ready = pb;
                GLib.Idle.add(() => {
                    if (ready != null) pic.set_paintable(Gdk.Texture.for_pixbuf(ready));
                    return GLib.Source.REMOVE;
                });
            });
            var click = new GestureClick();
            click.pressed.connect((n, x, y) => {
                try {
                    GLib.AppInfo.launch_default_for_uri(uri, null);
                } catch (Error e) {}
            });
            pic.add_controller(click);
            return pic;
        }

        private bool string_list_equal(string[] a, string[] b) {
            if (a.length != b.length) return false;
            for (int i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
            return true;
        }
    }

    [CCode (cname = "singularity_photos_widget_new")]
    public static Object singularity_photos_widget_new() {
        return new FavoritesProvider();
    }
}
