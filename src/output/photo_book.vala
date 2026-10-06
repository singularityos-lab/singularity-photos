using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class BookPage : Object {
        public string template;
        public PrintCell[] cells = {};
        public string title = "";

        public BookPage(string template) {
            this.template = template;
        }
    }

    public class PhotoBookDocument : Object {
        public const string[] SIZES = { "square-8", "landscape-10x8", "portrait-letter", "a4" };
        public const string[] TEMPLATES = { "auto", "full", "single", "two", "three", "four" };
        public const double DPI = 300.0;

        public string size { get; set; default = "square-8"; }
        public string template { get; set; default = "auto"; }
        public string title { get; set; default = ""; }
        public bool captions { get; set; default = false; }
        public double margin { get; set; default = 36.0; }
        public double gap { get; set; default = 12.0; }

        private File[] files;
        private Gee.ArrayList<BookPage> pages = new Gee.ArrayList<BookPage>();
        private Gee.HashMap<string, Cairo.ImageSurface> surfaces = new Gee.HashMap<string, Cairo.ImageSurface>();
        private Gee.HashMap<int, double?> aspects = new Gee.HashMap<int, double?>();

        public PhotoBookDocument(File[] files) {
            this.files = files;
        }

        public static string size_label(string id) {
            switch (id) {
                case "landscape-10x8": return _("Landscape 10×8 in");
                case "portrait-letter": return _("Portrait 8.5×11 in");
                case "a4": return _("A4 Portrait");
                default: return _("Square 8×8 in");
            }
        }

        public static string template_label(string id) {
            switch (id) {
                case "full": return _("Full Bleed");
                case "single": return _("One Photo");
                case "two": return _("Two Photos");
                case "three": return _("Three Photos");
                case "four": return _("Four Photos");
                default: return _("Automatic");
            }
        }

        public void page_size(out double w, out double h) {
            switch (size) {
                case "landscape-10x8": w = 720; h = 576; break;
                case "portrait-letter": w = 612; h = 792; break;
                case "a4": w = 595.3; h = 841.9; break;
                default: w = 576; h = 576; break;
            }
        }

        public int page_count {
            get { return pages.size; }
        }

        public BookPage page(int i) {
            return pages[i];
        }

        private int per_page(string t) {
            switch (t) {
                case "two": return 2;
                case "three": return 3;
                case "four": return 4;
                default: return 1;
            }
        }

        private double aspect(int photo) {
            if (aspects.has_key(photo)) return aspects[photo];
            double a = 1.5;
            try {
                var head = Codecs.load(files[photo], 64);
                a = (double) head.image.width / int.max(1, head.image.height);
            } catch (Error e) {
            }
            aspects[photo] = a;
            return a;
        }

        private PrintCell cell(double x, double y, double w, double h, int photo) {
            return PrintCell() { x = x, y = y, width = w, height = h, photo = photo, rotate = false };
        }

        private BookPage make_page(string t, int start, int n) {
            double pw, ph;
            page_size(out pw, out ph);
            var p = new BookPage(t);
            double m = margin, g = gap;
            double cap = captions ? 16 : 0;
            double cw = pw - 2 * m, ch = ph - 2 * m - cap;
            switch (t) {
                case "full":
                    p.cells = { cell(0, 0, pw, ph, start) };
                    break;
                case "two":
                    if (cw >= ch) p.cells = { cell(m, m, (cw - g) / 2, ch, start), cell(m + (cw + g) / 2, m, (cw - g) / 2, ch, start + 1) };
                    else p.cells = { cell(m, m, cw, (ch - g) / 2, start), cell(m, m + (ch + g) / 2, cw, (ch - g) / 2, start + 1) };
                    break;
                case "three":
                    double big = (cw - g) * 0.62;
                    double small_w = cw - g - big;
                    p.cells = { cell(m, m, big, ch, start), cell(m + big + g, m, small_w, (ch - g) / 2, start + 1), cell(m + big + g, m + (ch + g) / 2, small_w, (ch - g) / 2, start + 2) };
                    break;
                case "four":
                    double qw = (cw - g) / 2, qh = (ch - g) / 2;
                    p.cells = { cell(m, m, qw, qh, start), cell(m + qw + g, m, qw, qh, start + 1), cell(m, m + qh + g, qw, qh, start + 2), cell(m + qw + g, m + qh + g, qw, qh, start + 3) };
                    break;
                default:
                    p.cells = { cell(m, m, cw, ch, start) };
                    break;
            }
            PrintCell[] kept = {};
            foreach (var c in p.cells) if (c.photo < start + n) kept += c;
            p.cells = kept;
            return p;
        }

        private string auto_template(int index, int remaining) {
            if (remaining >= 3 && index % 3 == 2) return "three";
            if (remaining >= 2 && index % 2 == 1) {
                bool landscape = aspect(files.length - remaining) >= 1.0;
                return landscape && remaining >= 4 && index % 4 == 3 ? "four" : "two";
            }
            return index == 0 ? "full" : "single";
        }

        public void layout() {
            pages.clear();
            if (title.strip() != "") {
                var cover = new BookPage("cover");
                cover.title = title.strip();
                if (files.length > 0) {
                    double pw, ph;
                    page_size(out pw, out ph);
                    cover.cells = { cell(margin, margin, pw - 2 * margin, (ph - 2 * margin) * 0.72, 0) };
                }
                pages.add(cover);
            }
            int i = title.strip() != "" && files.length > 0 ? 1 : 0;
            int index = 0;
            while (i < files.length) {
                string t = template == "auto" ? auto_template(index, files.length - i) : template;
                int n = int.min(per_page(t), files.length - i);
                pages.add(make_page(t, i, n));
                i += n;
                index++;
            }
        }

        private Cairo.ImageSurface? surface_for(int photo, double w_pt, double h_pt) {
            int side = ((int) Math.ceil(double.max(w_pt, h_pt) / 72.0 * DPI)).clamp(64, 8000);
            string key = "%d:%d".printf(photo, side);
            if (surfaces.has_key(key)) return surfaces[key];
            try {
                var r = OutputRender.render(files[photo], side);
                var s = PhotoPrintSource.to_surface(WorkingSpace.to_srgb_encoded(r.image.scaled_to_fit(side)));
                surfaces[key] = s;
                return s;
            } catch (Error e) {
                warning("Photos: book skipped %s: %s", files[photo].get_path(), e.message);
                return null;
            }
        }

        public void render_page(Cairo.Context cr, int index) {
            if (index < 0 || index >= pages.size) return;
            double pw, ph;
            page_size(out pw, out ph);
            cr.save();
            cr.set_source_rgb(1, 1, 1);
            cr.rectangle(0, 0, pw, ph);
            cr.fill();
            var p = pages[index];
            foreach (var c in p.cells) {
                if (c.photo < 0 || c.photo >= files.length) continue;
                var s = surface_for(c.photo, c.width, c.height);
                if (s == null) continue;
                double x, y, w, h;
                PrintLayout.fit_rect(s.get_width(), s.get_height(), c, p.template == "full" || p.template == "four" || p.template == "three", out x, out y, out w, out h);
                cr.save();
                cr.rectangle(c.x, c.y, c.width, c.height);
                cr.clip();
                cr.translate(x, y);
                cr.scale(w / s.get_width(), h / s.get_height());
                cr.set_source_surface(s, 0, 0);
                ((Cairo.Pattern) cr.get_source()).set_filter(Cairo.Filter.GOOD);
                cr.paint();
                cr.restore();
                if (captions && p.template != "full" && p.template != "cover") {
                    draw_text(cr, files[c.photo].get_basename() ?? "", c.x, c.y + c.height + 3, c.width, 8, 0.35);
                }
            }
            if (p.template == "cover") {
                double top = p.cells.length > 0 ? p.cells[0].y + p.cells[0].height + 18 : ph / 2 - 20;
                draw_text(cr, p.title, margin, top, pw - 2 * margin, 26, 0.1);
            }
            cr.restore();
        }

        private void draw_text(Cairo.Context cr, string text, double x, double y, double w, double size, double grey) {
            var pl = Pango.cairo_create_layout(cr);
            var font = Pango.FontDescription.from_string("Serif");
            font.set_absolute_size(size * Pango.SCALE);
            pl.set_font_description(font);
            pl.set_width((int) (w * Pango.SCALE));
            pl.set_alignment(Pango.Alignment.CENTER);
            pl.set_ellipsize(Pango.EllipsizeMode.END);
            pl.set_text(text, -1);
            cr.move_to(x, y);
            cr.set_source_rgb(grey, grey, grey);
            Pango.cairo_show_layout(cr, pl);
        }

        public void save_pdf(string path) throws Error {
            double pw, ph;
            page_size(out pw, out ph);
            var surface = new Cairo.PdfSurface(path, pw, ph);
            surface.set_metadata(Cairo.PdfMetadata.TITLE, title != "" ? title : _("Photo Book"));
            surface.set_metadata(Cairo.PdfMetadata.CREATOR, "Singularity Photos");
            var cr = new Cairo.Context(surface);
            for (int i = 0; i < pages.size; i++) {
                render_page(cr, i);
                cr.show_page();
            }
            surface.finish();
            if (surface.status() != Cairo.Status.SUCCESS) throw new IOError.FAILED(_("The PDF could not be written"));
        }

        private static string n(double v) {
            var buffer = new char[double.DTOSTR_BUF_SIZE];
            return v.format(buffer, "%.2f");
        }

        private static string attr(string s) {
            return Markup.escape_text(s).replace("\"", "&quot;");
        }

        public string save_publish(string path) throws Error {
            double pw, ph;
            page_size(out pw, out ph);
            string dir = Path.get_dirname(path);
            string stem = Path.get_basename(path);
            if (stem.has_suffix(".sla")) stem = stem.substring(0, stem.length - 4);
            string media = Path.build_filename(dir, stem + " " + _("Photos"));
            DirUtils.create_with_parents(media, 0755);
            var s = new ExportSettings();
            s.format = "jpeg";
            s.quality = 92;
            s.destination = "folder";
            s.folder = media;
            s.conflict = "overwrite";
            s.naming = "{seq:3}-{name}";
            s.metadata = "copyright";
            var exported = new Gee.HashMap<int, string>();
            var b = new StringBuilder();
            b.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<SCRIBUSUTF8NEW Version=\"1.6.0\">\n");
            b.append_printf(" <DOCUMENT ANZPAGES=\"%d\" PAGEWIDTH=\"%s\" PAGEHEIGHT=\"%s\" BORDERLEFT=\"%s\" BORDERRIGHT=\"%s\" BORDERTOP=\"%s\" BORDERBOTTOM=\"%s\" UNITS=\"2\" BOOK=\"0\" TITLE=\"%s\" AUTHOR=\"\">\n",
                pages.size, n(pw), n(ph), n(margin), n(margin), n(margin), n(margin), attr(title));
            double y = 20;
            for (int i = 0; i < pages.size; i++) {
                b.append_printf("  <PAGE NUM=\"%d\" PAGEXPOS=\"100\" PAGEYPOS=\"%s\" PAGEWIDTH=\"%s\" PAGEHEIGHT=\"%s\" MNAM=\"Normal\"/>\n", i, n(y), n(pw), n(ph));
                y += ph + 40;
            }
            y = 20;
            int item = 0;
            for (int i = 0; i < pages.size; i++) {
                var p = pages[i];
                foreach (var c in p.cells) {
                    if (c.photo < 0 || c.photo >= files.length) continue;
                    if (!exported.has_key(c.photo)) {
                        var r = ExportEngine.export_one(files[c.photo], s, c.photo + 1, files.length);
                        if (!r.ok) throw new IOError.FAILED(r.error);
                        exported[c.photo] = r.target.get_path();
                    }
                    b.append_printf("  <PAGEOBJECT OwnPage=\"%d\" ItemID=\"%d\" PTYPE=\"2\" XPOS=\"%s\" YPOS=\"%s\" WIDTH=\"%s\" HEIGHT=\"%s\" ROT=\"0\" SCALETYPE=\"0\" RATIO=\"1\" PFILE=\"%s\" ANNAME=\"%s\"/>\n",
                        i, ++item, n(100 + c.x), n(y + c.y), n(c.width), n(c.height), attr(exported[c.photo]), attr(files[c.photo].get_basename() ?? ""));
                }
                if (p.template == "cover" && p.title != "") {
                    double top = p.cells.length > 0 ? p.cells[0].y + p.cells[0].height + 18 : ph / 2 - 20;
                    b.append_printf("  <PAGEOBJECT OwnPage=\"%d\" ItemID=\"%d\" PTYPE=\"4\" XPOS=\"%s\" YPOS=\"%s\" WIDTH=\"%s\" HEIGHT=\"40\" ROT=\"0\"><StoryText><DefaultStyle ALIGN=\"1\" FONTSIZE=\"26\"/><ITEXT CH=\"%s\"/><trail ALIGN=\"1\"/></StoryText></PAGEOBJECT>\n",
                        i, ++item, n(100 + margin), n(y + top), n(pw - 2 * margin), attr(p.title));
                }
                y += ph + 40;
            }
            b.append(" </DOCUMENT>\n</SCRIBUSUTF8NEW>\n");
            FileUtils.set_contents(path, b.str);
            return media;
        }
    }

    public class PhotoBookSource : Singularity.Print.PageSource {
        private PhotoBookDocument book;

        public PhotoBookSource(PhotoBookDocument book) {
            this.book = book;
            title = book.title != "" ? book.title : _("Photo Book");
        }

        public override async int paginate(Singularity.Print.PageFormat format) throws Error {
            double w, h;
            book.page_size(out w, out h);
            page_width = w;
            page_height = h;
            document_pages = book.page_count;
            return book.page_count;
        }

        public override void render_page(Cairo.Context cr, int index) {
            book.render_page(cr, index);
        }
    }
}
