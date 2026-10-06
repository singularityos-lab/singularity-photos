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
        public Box             side_host;
        public Box             stage_row;
        public Photos.MediaBin media_bin;

        public PhotosWindow(Gtk.Application app) {
            Object(application: app);
            set_title(_("Photos"));
            set_default_size(1100, 700);

            sidebar_scroll = new AppSidebar();
            set_sidebar(sidebar_scroll);
            set_sidebar_visible(true);

            content_box = new Box(Orientation.VERTICAL, 0);
            content_box.hexpand = true;
            content_box.vexpand = true;

            media_bin = new Photos.MediaBin();
            search_host = media_bin.filter_host;
            content_overlay = media_bin.overlay;
            grid_scroll = media_bin.scroller;
            stage_row = new Box(Orientation.HORIZONTAL, 0);
            stage_row.hexpand = true;
            stage_row.vexpand = true;
            stage_row.append(media_bin);
            side_host = new Box(Orientation.HORIZONTAL, 0);
            stage_row.append(side_host);
            content_box.append(stage_row);

            set_content(content_box);
        }
    }
}
