using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public struct PrintCell {
        public double x;
        public double y;
        public double width;
        public double height;
        public int photo;
        public bool rotate;
    }

    public class PrintPackage : Object {
        public string id { get; construct; }
        public string label { get; construct; }
        public double[] sizes;

        public PrintPackage(string id, string label, double[] sizes) {
            Object(id: id, label: label);
            this.sizes = sizes;
        }

        private static PrintPackage[]? all_packages = null;

        public static unowned PrintPackage[] all() {
            if (all_packages == null) {
                all_packages = {
                    new PrintPackage("2x5x7", _("Two 5×7 in"), { 5, 7, 5, 7 }),
                    new PrintPackage("2x4x6", _("Two 4×6 in"), { 4, 6, 4, 6 }),
                    new PrintPackage("4x3.5x5", _("Four 3.5×5 in"), { 3.5, 5, 3.5, 5, 3.5, 5, 3.5, 5 }),
                    new PrintPackage("5x7-4wallet", _("One 5×7 in and Four Wallets"), { 5, 7, 2.5, 3.5, 2.5, 3.5, 2.5, 3.5, 2.5, 3.5 }),
                    new PrintPackage("8wallet", _("Eight Wallets"), { 2.5, 3.5, 2.5, 3.5, 2.5, 3.5, 2.5, 3.5, 2.5, 3.5, 2.5, 3.5, 2.5, 3.5, 2.5, 3.5 }),
                    new PrintPackage("9square", _("Nine 2.5 in Squares"), { 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5 })
                };
            }
            return all_packages;
        }

        public static PrintPackage find(string id) {
            foreach (unowned PrintPackage p in all()) if (p.id == id) return p;
            return all()[0];
        }
    }

    namespace PrintLayout {

        public const double GAP = 9.0;

        public PrintCell[] contact_cells(double x0, double y0, double w, double h, int columns, int count, double caption) {
            PrintCell[] cells = {};
            columns = columns.clamp(1, 20);
            double cell = (w - GAP * (columns - 1)) / columns;
            double row_h = cell + caption;
            int rows = int.max(1, (int) Math.floor((h + GAP) / (row_h + GAP)));
            int per_page = columns * rows;
            for (int i = 0; i < int.min(count, per_page); i++) {
                int c = i % columns, r = i / columns;
                cells += PrintCell() { x = x0 + c * (cell + GAP), y = y0 + r * (row_h + GAP), width = cell, height = cell, photo = i, rotate = false };
            }
            return cells;
        }

        public int contact_per_page(double w, double h, int columns, double caption) {
            columns = columns.clamp(1, 20);
            double cell = (w - GAP * (columns - 1)) / columns;
            int rows = int.max(1, (int) Math.floor((h + GAP) / (cell + caption + GAP)));
            return columns * rows;
        }

        public PrintCell[] package_cells(double x0, double y0, double w, double h, double[] sizes_in) {
            int wanted = sizes_in.length / 2;
            PrintCell[] best = {};
            for (double scale = 1.0; scale > 0.2; scale -= 0.02) {
                var scaled = new double[sizes_in.length];
                for (int i = 0; i < sizes_in.length; i++) scaled[i] = sizes_in[i] * scale;
                var tall = pack(x0, y0, w, h, scaled, false);
                var wide = pack(x0, y0, w, h, scaled, true);
                var pick = wide.length > tall.length ? wide : tall;
                if (pick.length > best.length) best = pick;
                if (best.length >= wanted) break;
            }
            return best;
        }

        private PrintCell[] pack(double x0, double y0, double w, double h, double[] sizes_in, bool landscape) {
            PrintCell[] cells = {};
            double shelf_y = 0, shelf_h = 0, cursor = 0;
            for (int i = 0; i + 1 < sizes_in.length; i += 2) {
                double a = sizes_in[i] * 72.0, b = sizes_in[i + 1] * 72.0;
                if (landscape) {
                    double t = a;
                    a = b;
                    b = t;
                }
                bool placed = false;
                for (int attempt = 0; attempt < 2 && !placed; attempt++) {
                    double cw = attempt == 0 ? a : b, ch = attempt == 0 ? b : a;
                    if (cw > w + 0.5 || ch > h + 0.5) continue;
                    if (cursor + cw <= w + 0.5 && shelf_y + ch <= h + 0.5 && (ch <= shelf_h + 0.5 || cursor == 0)) {
                        cells += PrintCell() { x = x0 + cursor, y = y0 + shelf_y, width = cw, height = ch, photo = 0, rotate = false };
                        cursor += cw + GAP;
                        shelf_h = double.max(shelf_h, ch);
                        placed = true;
                    }
                }
                if (placed) continue;
                double ny = shelf_y + shelf_h + GAP;
                for (int attempt = 0; attempt < 2 && !placed; attempt++) {
                    double cw = attempt == 0 ? a : b, ch = attempt == 0 ? b : a;
                    if (cw <= w + 0.5 && ny + ch <= h + 0.5) {
                        shelf_y = ny;
                        shelf_h = ch;
                        cells += PrintCell() { x = x0, y = y0 + shelf_y, width = cw, height = ch, photo = 0, rotate = false };
                        cursor = cw + GAP;
                        placed = true;
                    }
                }
            }
            return cells;
        }

        public void fit_rect(double iw, double ih, PrintCell cell, bool fill, out double x, out double y, out double w, out double h) {
            double s = fill ? double.max(cell.width / iw, cell.height / ih) : double.min(cell.width / iw, cell.height / ih);
            w = iw * s;
            h = ih * s;
            x = cell.x + (cell.width - w) / 2;
            y = cell.y + (cell.height - h) / 2;
        }
    }

    public class PhotoPrintSource : Singularity.Print.PageSource {
        public const double PRINT_DPI = 300.0;

        private File[] files;
        private Singularity.Print.PageFormat format = new Singularity.Print.PageFormat();
        private Gee.HashMap<string, Cairo.ImageSurface> print_cache = new Gee.HashMap<string, Cairo.ImageSurface>();
        private Gee.HashMap<string, Cairo.ImageSurface> proof_cache = new Gee.HashMap<string, Cairo.ImageSurface>();
        private Gee.HashMap<int, PhotoMetadata> metas = new Gee.HashMap<int, PhotoMetadata>();
        private Gee.ArrayList<string> profile_ids = new Gee.ArrayList<string>();
        private Gee.ArrayList<string> profile_paths = new Gee.ArrayList<string>();
        public bool force_proof = false;
        public bool rendering_for_print = false;

        public PhotoPrintSource(File[] files) {
            this.files = files;
            title = files.length == 1 ? (files[0].get_basename() ?? _("Photo")) : _("%d Photos").printf(files.length);
            build_options();
        }

        public static string[] profile_dirs() {
            string[] dirs = {
                Path.build_filename(Environment.get_user_data_dir(), "icc"),
                Path.build_filename(Environment.get_home_dir(), ".color", "icc")
            };
            foreach (var d in Environment.get_system_data_dirs()) dirs += Path.build_filename(d, "color", "icc");
            return dirs;
        }

        private void scan_profiles() {
            profile_ids.add("none");
            profile_paths.add("");
            foreach (var dir in profile_dirs()) scan_dir(File.new_for_path(dir), 0);
        }

        private void scan_dir(File dir, int depth) {
            if (depth > 2 || profile_ids.size > 40) return;
            try {
                var e = dir.enumerate_children(FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NONE);
                FileInfo? info;
                while ((info = e.next_file()) != null) {
                    var child = dir.get_child(info.get_name());
                    if (info.get_file_type() == FileType.DIRECTORY) {
                        scan_dir(child, depth + 1);
                        continue;
                    }
                    string n = info.get_name().down();
                    if (!n.has_suffix(".icc") && !n.has_suffix(".icm")) continue;
                    if (child.get_path() in profile_paths) continue;
                    profile_ids.add("file:" + child.get_path());
                    profile_paths.add(child.get_path());
                }
            } catch (Error e) {
            }
        }

        private void build_options() {
            scan_profiles();
            var o = new Singularity.Print.ExtraOptions(_("Photo Layout"));
            o.add_choice("layout", _("Layout"), { "single", "contact", "package" }, { _("One Photo per Page"), _("Contact Sheet"), _("Picture Package") }, "single");
            o.add_choice("fit", _("Photo Size"), { "fit", "fill" }, { _("Fit Whole Photo"), _("Fill the Page") }, "fit");
            o.show_when("fit", "layout", { "single" });
            o.add_number("border", _("Border"), _("Points of white space around the photo"), 0, 144, 1, 0);
            o.show_when("border", "layout", { "single" });
            o.add_number("columns", _("Columns"), null, 2, 12, 1, 4);
            o.show_when("columns", "layout", { "contact" });
            string[] pkg_ids = {}, pkg_labels = {};
            foreach (unowned PrintPackage p in PrintPackage.all()) {
                pkg_ids += p.id;
                pkg_labels += p.label;
            }
            o.add_choice("package", _("Package"), pkg_ids, pkg_labels, pkg_ids[0]);
            o.show_when("package", "layout", { "package" });
            o.add_choice("caption", _("Caption"), { "none", "filename", "title", "exposure" }, { _("None"), _("File Name"), _("Title"), _("Exposure") }, "none");
            string[] labels = {};
            foreach (var id in profile_ids) {
                if (id == "none") {
                    labels += _("Managed by Printer");
                    continue;
                }
                string label = Path.get_basename(id.substring(5));
                try {
                    label = IccProfile.from_file(id.substring(5)).description;
                } catch (Error e) {
                }
                labels += label;
            }
            o.add_choice("profile", _("Printer Profile"), profile_ids.to_array(), labels, "none");
            o.add_choice("intent", _("Rendering Intent"), { "perceptual", "relative" }, { _("Perceptual"), _("Relative Colorimetric") }, "perceptual");
            o.show_when("intent", "profile", profile_ids.to_array()[1:profile_ids.size]);
            var proof = o.add_switch("proof", _("Soft Proof Preview"), _("Show how the printer profile renders the colors"), true);
            proof.reflow = false;
            o.show_when("proof", "profile", profile_ids.to_array()[1:profile_ids.size]);
            var gamut = o.add_switch("gamut", _("Mark Out-of-Gamut Colors"), null, false);
            gamut.reflow = false;
            o.show_when("gamut", "proof", { "true" });
            o.changed.connect((key, reflow) => {
                if (key == "profile" || key == "intent" || key == "gamut" || key == "proof") {
                    print_cache.clear();
                    proof_cache.clear();
                }
            });
            extra_options = o;
        }

        public void add_profile(string path) {
            if (path in profile_paths) return;
            profile_ids.add("file:" + path);
            profile_paths.add(path);
            build_options();
        }

        private string layout() {
            return extra_options.get_choice("layout");
        }

        private double caption_height() {
            return extra_options.get_choice("caption") == "none" ? 0 : 14;
        }

        public override async int paginate(Singularity.Print.PageFormat f) throws Error {
            format = f;
            page_width = f.width;
            page_height = f.height;
            int pages;
            switch (layout()) {
                case "contact":
                    int per = PrintLayout.contact_per_page(f.content_width, f.content_height, (int) extra_options.get_number("columns"), caption_height());
                    pages = int.max(1, (files.length + per - 1) / per);
                    break;
                default:
                    pages = files.length;
                    break;
            }
            document_pages = pages;
            return pages;
        }

        public PrintCell[] cells_for(int page) {
            double x0 = format.margin_left, y0 = format.margin_top, w = format.content_width, h = format.content_height;
            switch (layout()) {
                case "contact":
                    int columns = (int) extra_options.get_number("columns");
                    int per = PrintLayout.contact_per_page(w, h, columns, caption_height());
                    int start = page * per;
                    var cells = PrintLayout.contact_cells(x0, y0, w, h, columns, int.min(per, files.length - start), caption_height());
                    for (int i = 0; i < cells.length; i++) cells[i].photo = start + i;
                    return cells;
                case "package":
                    var cells = PrintLayout.package_cells(x0, y0, w, h, PrintPackage.find(extra_options.get_choice("package")).sizes);
                    for (int i = 0; i < cells.length; i++) cells[i].photo = page;
                    return cells;
                default:
                    double b = extra_options.get_number("border");
                    double cap = caption_height();
                    return { PrintCell() { x = x0 + b, y = y0 + b, width = double.max(1, w - 2 * b), height = double.max(1, h - 2 * b - cap), photo = page, rotate = false } };
            }
        }

        private IccProfile? printer_profile() {
            string id = extra_options.get_choice("profile");
            if (!id.has_prefix("file:")) return null;
            try {
                return IccProfile.from_file(id.substring(5));
            } catch (Error e) {
                return null;
            }
        }

        private RenderingIntent intent() {
            return extra_options.get_choice("intent") == "relative" ? RenderingIntent.RELATIVE_COLORIMETRIC : RenderingIntent.PERCEPTUAL;
        }

        public static Cairo.ImageSurface to_surface(FloatImage encoded) {
            int w = encoded.width, h = encoded.height;
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, w, h);
            surface.flush();
            unowned uint8[] px = surface.get_data();
            int stride = surface.get_stride();
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    size_t s = encoded.offset(x, y);
                    float a = encoded.data[s + 3].clamp(0.0f, 1.0f);
                    int o = y * stride + x * 4;
                    px[o] = (uint8) (encoded.data[s + 2].clamp(0.0f, 1.0f) * a * 255.0f + 0.5f);
                    px[o + 1] = (uint8) (encoded.data[s + 1].clamp(0.0f, 1.0f) * a * 255.0f + 0.5f);
                    px[o + 2] = (uint8) (encoded.data[s].clamp(0.0f, 1.0f) * a * 255.0f + 0.5f);
                    px[o + 3] = (uint8) (a * 255.0f + 0.5f);
                }
            }
            surface.mark_dirty();
            return surface;
        }

        private FloatImage? working_for(int photo, int max_side) {
            try {
                var r = OutputRender.render(files[photo], max_side);
                metas[photo] = r.meta;
                return r.image.scaled_to_fit(max_side);
            } catch (Error e) {
                warning("Photos: cannot print %s: %s", files[photo].get_path(), e.message);
                return null;
            }
        }

        private Cairo.ImageSurface? surface_for(int photo, PrintCell cell, bool proof) {
            int max_side = (int) Math.ceil(double.max(cell.width, cell.height) / 72.0 * PRINT_DPI);
            max_side = max_side.clamp(64, 12000);
            string key = "%d:%d".printf(photo, max_side);
            var cache = proof ? proof_cache : print_cache;
            if (cache.has_key(key)) return cache[key];
            var working = working_for(photo, max_side);
            if (working == null) return null;
            var printer = printer_profile();
            FloatImage encoded;
            if (printer == null) {
                encoded = WorkingSpace.to_profile(working, IccProfile.srgb());
            } else if (proof) {
                var t = new ColorTransform.proofing(WorkingSpace.profile(), IccProfile.srgb(), printer, intent(), extra_options.get_bool("gamut"));
                encoded = working.copy();
                t.apply(encoded);
            } else {
                encoded = WorkingSpace.to_profile(working, printer, intent());
            }
            var surface = to_surface(encoded);
            cache[key] = surface;
            return surface;
        }

        private string caption_for(int photo) {
            var m = metas.has_key(photo) ? metas[photo] : null;
            switch (extra_options.get_choice("caption")) {
                case "filename": return files[photo].get_basename() ?? "";
                case "title": return m != null && m.title != "" ? m.title : (files[photo].get_basename() ?? "");
                case "exposure": return m != null ? m.summary() : "";
                default: return "";
            }
        }

        private bool is_preview(Cairo.Context cr) {
            if (force_proof) return true;
            if (rendering_for_print) return false;
            var type = cr.get_target().get_type();
            return type == Cairo.SurfaceType.IMAGE || type == Cairo.SurfaceType.RECORDING;
        }

        public override void render_page(Cairo.Context cr, int index) {
            if (index < 0 || index >= document_pages) return;
            bool proof = is_preview(cr) && extra_options.get_bool("proof") && printer_profile() != null;
            bool fill = layout() == "package" || (layout() == "single" && extra_options.get_choice("fit") == "fill");
            if (layout() == "contact") fill = false;
            double cap = caption_height();
            foreach (var cell in cells_for(index)) {
                if (cell.photo < 0 || cell.photo >= files.length) continue;
                var surface = surface_for(cell.photo, cell, proof);
                if (surface == null) continue;
                double x, y, w, h;
                PrintLayout.fit_rect(surface.get_width(), surface.get_height(), cell, fill, out x, out y, out w, out h);
                cr.save();
                cr.rectangle(cell.x, cell.y, cell.width, cell.height);
                cr.clip();
                cr.translate(x, y);
                cr.scale(w / surface.get_width(), h / surface.get_height());
                cr.set_source_surface(surface, 0, 0);
                ((Cairo.Pattern) cr.get_source()).set_filter(Cairo.Filter.GOOD);
                cr.paint();
                cr.restore();
                if (cap > 0 && layout() != "package") {
                    string text = caption_for(cell.photo);
                    if (text != "") {
                        var pl = Pango.cairo_create_layout(cr);
                        var font = Pango.FontDescription.from_string("Sans");
                        font.set_absolute_size((layout() == "contact" ? 7 : 9) * Pango.SCALE);
                        pl.set_font_description(font);
                        pl.set_width((int) (cell.width * Pango.SCALE));
                        pl.set_ellipsize(Pango.EllipsizeMode.MIDDLE);
                        pl.set_alignment(Pango.Alignment.CENTER);
                        pl.set_text(text, -1);
                        double top = layout() == "contact" ? cell.y + cell.height + 2 : y + h + 3;
                        cr.move_to(cell.x, top);
                        cr.set_source_rgb(0.2, 0.2, 0.2);
                        Pango.cairo_show_layout(cr, pl);
                    }
                }
            }
        }
    }
}
