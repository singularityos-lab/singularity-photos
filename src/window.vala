using Gtk;
using Gdk;
using GLib;
using Gee;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps {

    /**
     * Photos window. Built entirely in code (no GtkTemplate) so it uses the
     * base Singularity.Widgets.Window structure correctly: the sidebar goes
     * into the base `sidebar_area` via set_sidebar(), and the content (a
     * HoverControls wrapping the grid) goes into the content area. The
     * toolbar is hidden (`flat`) - controls live in floating bubbles à la
     * Leafs.
     */
    public class PhotosWindow : Singularity.Widgets.Window {
        public AppSidebar      sidebar_scroll;
        public Box             content_box;
        public Box             search_host;
        public Overlay         content_overlay;
        public ScrolledWindow  grid_scroll;
        public HoverControls   hover;

        public PhotosWindow(Gtk.Application app) {
            Object(application: app);
            set_title("Photos");
            set_default_size(1100, 700);

            // No toolbar - bubble controls instead. We supply our own close
            // bubble, so suppress the base flat close button.
            flat = true;
            show_close = false;

            // Sidebar (populated by the app), placed in the base window's
            // sidebar slot.
            sidebar_scroll = new AppSidebar();
            set_sidebar(sidebar_scroll);
            set_sidebar_visible(true);

            // Content column: search bar host on top, photo grid below.
            content_box = new Box(Orientation.VERTICAL, 0);
            content_box.hexpand = true;
            content_box.vexpand = true;

            search_host = new Box(Orientation.VERTICAL, 0);
            content_box.append(search_host);

            content_overlay = new Overlay();
            content_overlay.hexpand = true;
            content_overlay.vexpand = true;

            grid_scroll = new ScrolledWindow();
            grid_scroll.hexpand = true;
            grid_scroll.vexpand = true;
            content_overlay.set_child(grid_scroll);
            content_box.append(content_overlay);

            // Floating bubble controls over the content.
            hover = new HoverControls();
            hover.set_content(content_box);
            set_content(hover);
        }
    }
}
