using Gtk;

namespace Singularity.Apps.Photos {

    namespace PhotoExport {

        public void show_dialog(Gtk.Window parent, File[] files) {
            if (files.length == 0) return;
            new ExportDialog(parent, files).open_dialog();
        }
    }

    namespace PhotoPrint {

        public void run(Gtk.Window parent, File[] files) {
            if (files.length == 0) return;
            Singularity.Print.run_source.begin(parent, new PhotoPrintSource(files));
        }
    }

    namespace PhotoPublish {

        public void present(Gtk.Window parent, File[] files) {
            if (files.length == 0) return;
            new PublishDialog(parent, files).open_dialog();
        }

        public void present_collection(Gtk.Window parent, File[] files, string collection) {
            if (files.length == 0) return;
            new PublishDialog(parent, files, collection).open_dialog();
        }
    }

    namespace Slideshow {

        public void present(Gtk.Window parent, File[] files) {
            if (files.length == 0) return;
            if (!Gst.is_initialized()) {
                unowned string[]? none = null;
                Gst.init(ref none);
            }
            new SlideshowWindow(parent, files).present();
        }
    }

    namespace PhotoBook {

        public void present(Gtk.Window parent, File[] files) {
            if (files.length == 0) return;
            new BookDialog(parent, files).open_dialog();
        }
    }

    namespace PhotoSync {

        public void present(Gtk.Window parent, File library_folder) {
            new SyncDialog(parent, library_folder).open_dialog();
        }
    }

    namespace Tether {

        public void present(Gtk.Window parent, File target_folder) {
            new TetherDialog(parent, target_folder).open_dialog();
        }
    }
}
