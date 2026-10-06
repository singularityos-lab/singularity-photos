using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public class BookDialog : AppDialog {
        private PhotoBookDocument book;
        private Picture preview;
        private Label page_label;
        private Spinner spinner;
        private int current = 0;
        private uint render_serial = 0;
        private IndexChoiceRow size_dd;
        private IndexChoiceRow template_dd;
        private EntryRow title_row;
        private SwitchRow caption_row;

        public BookDialog(Gtk.Window parent, File[] files) {
            base(parent.application, true, false);
            transient_for = parent;
            set_title(_("Photo Book"));
            set_default_size(940, 640);
            book = new PhotoBookDocument(files);
            build();
            relayout();
        }

        private void build() {
            var body = new Box(Gtk.Orientation.HORIZONTAL, 18);
            body.margin_start = body.margin_end = 18;
            body.margin_top = 6;
            body.vexpand = true;
            var left = new Box(Gtk.Orientation.VERTICAL, 8);
            left.hexpand = true;
            var overlay = new Overlay();
            overlay.vexpand = true;
            preview = new Picture();
            preview.content_fit = ContentFit.CONTAIN;
            preview.can_shrink = true;
            overlay.child = preview;
            spinner = new Spinner();
            spinner.halign = Align.CENTER;
            spinner.valign = Align.CENTER;
            overlay.add_overlay(spinner);
            left.append(overlay);
            var nav = new Box(Gtk.Orientation.HORIZONTAL, 6);
            nav.halign = Align.CENTER;
            var prev = new Button.from_icon_name("go-previous-symbolic");
            prev.add_css_class("flat");
            prev.tooltip_text = _("Previous Page");
            prev.clicked.connect(() => show_page(current - 1));
            page_label = new Label("");
            page_label.add_css_class("numeric");
            var next = new Button.from_icon_name("go-next-symbolic");
            next.add_css_class("flat");
            next.tooltip_text = _("Next Page");
            next.clicked.connect(() => show_page(current + 1));
            nav.append(prev);
            nav.append(page_label);
            nav.append(next);
            left.append(nav);
            body.append(left);

            var group = new PreferencesGroup(_("Book"));
            group.width_request = 320;
            group.valign = Align.START;
            string[] size_labels = {};
            foreach (var id in PhotoBookDocument.SIZES) size_labels += PhotoBookDocument.size_label(id);
            group.add_row(OutputRows.choice(_("Size"), size_labels, 0, out size_dd));
            string[] template_labels = {};
            foreach (var id in PhotoBookDocument.TEMPLATES) template_labels += PhotoBookDocument.template_label(id);
            group.add_row(OutputRows.choice(_("Page Layout"), template_labels, 0, out template_dd));
            title_row = new EntryRow(_("Cover Title"));
            group.add_row(title_row);
            caption_row = new SwitchRow(_("File Names Under Photos"));
            group.add_row(caption_row);
            size_dd.notify["selected-index"].connect(() => relayout());
            template_dd.notify["selected-index"].connect(() => relayout());
            title_row.notify["text"].connect(() => relayout());
            caption_row.switch_btn.notify["active"].connect(() => relayout());
            body.append(group);
            content_box.append(body);

            var bar = new Box(Gtk.Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 18;
            bar.margin_bottom = 16;
            bar.margin_top = 8;
            var publish = new Button.with_label(_("Save as Scribus Document"));
            publish.clicked.connect(() => open_in_publish());
            bar.append(publish);
            var spacer = new Box(Gtk.Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            bar.append(spacer);
            bar.append(add_cancel_button(_("Close")));
            var pdf = new Button.with_label(_("Save as PDF…"));
            pdf.clicked.connect(() => save_pdf());
            bar.append(pdf);
            var print = new Button.with_label(_("Print…"));
            print.add_css_class("suggested-action");
            print.clicked.connect(() => Singularity.Print.run_source.begin(this, new PhotoBookSource(book)));
            bar.append(print);
            content_box.append(bar);
        }

        private void relayout() {
            book.size = PhotoBookDocument.SIZES[((int) size_dd.selected_index).clamp(0, PhotoBookDocument.SIZES.length - 1)];
            book.template = PhotoBookDocument.TEMPLATES[((int) template_dd.selected_index).clamp(0, PhotoBookDocument.TEMPLATES.length - 1)];
            book.title = title_row.text;
            book.captions = caption_row.active;
            lock (book) {
                book.layout();
            }
            show_page(current);
        }

        private void show_page(int index) {
            if (book.page_count == 0) return;
            current = index.clamp(0, book.page_count - 1);
            page_label.label = _("Page %d of %d").printf(current + 1, book.page_count);
            uint serial = ++render_serial;
            spinner.spinning = true;
            int page = current;
            double pw, ph;
            book.page_size(out pw, out ph);
            new Thread<void>("photos-book-page", () => {
                double scale = 900.0 / double.max(pw, ph);
                var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, (int) (pw * scale), (int) (ph * scale));
                var cr = new Cairo.Context(surface);
                cr.scale(scale, scale);
                lock (book) {
                    book.render_page(cr, page);
                }
                surface.flush();
                unowned uint8[] px = surface.get_data();
                var bytes = new Bytes(px[0:surface.get_stride() * surface.get_height()]);
                var texture = new Gdk.MemoryTexture(surface.get_width(), surface.get_height(), Gdk.MemoryFormat.B8G8R8X8, bytes, surface.get_stride());
                Idle.add(() => {
                    if (serial != render_serial) return Source.REMOVE;
                    spinner.spinning = false;
                    preview.paintable = texture;
                    return Source.REMOVE;
                });
            });
        }

        private void save_pdf() {
            var chooser = new FileDialog();
            chooser.title = _("Save Photo Book");
            chooser.initial_name = (book.title != "" ? book.title : _("Photo Book")) + ".pdf";
            chooser.save.begin(this, null, (o, res) => {
                File? f = null;
                try {
                    f = chooser.save.end(res);
                } catch (Error e) {
                    return;
                }
                if (f == null) return;
                try {
                    lock (book) {
                        book.save_pdf(f.get_path());
                    }
                    OutputRows.toast(transient_for, _("Saved %s").printf(f.get_basename()));
                } catch (Error e) {
                    OutputRows.toast(transient_for, _("Could not save the book: %s").printf(e.message));
                }
            });
        }

        private void open_in_publish() {
            var chooser = new FileDialog();
            chooser.title = _("Save Book as Scribus Document");
            chooser.initial_name = (book.title != "" ? book.title : _("Photo Book")) + ".sla";
            chooser.save.begin(this, null, (o, res) => {
                File? f = null;
                try {
                    f = chooser.save.end(res);
                } catch (Error e) {
                    return;
                }
                if (f == null) return;
                try {
                    string path = f.get_path();
                    if (!path.has_suffix(".sla")) path += ".sla";
                    lock (book) {
                        book.save_publish(path);
                    }
                    AppInfo.launch_default_for_uri(Filename.to_uri(path), null);
                } catch (Error e) {
                    OutputRows.toast(transient_for, _("Could not open the book: %s").printf(e.message));
                }
            });
        }
    }
}
