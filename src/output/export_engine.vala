using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class ExportResult : Object {
        public File source { get; construct; }
        public File? target { get; set; }
        public string error { get; set; default = ""; }
        public bool skipped { get; set; default = false; }

        public ExportResult(File source) {
            Object(source: source);
        }

        public bool ok {
            get { return error == "" && target != null; }
        }
    }

    public delegate void ExportProgress(int done, int total, File current);

    namespace ExportEngine {

        public void target_size(ExportSettings s, int w, int h, out int nw, out int nh) {
            double f = 1.0;
            switch (s.resize) {
                case "long":
                    f = (double) s.resize_width / int.max(w, h);
                    break;
                case "short":
                    f = (double) s.resize_width / int.min(w, h);
                    break;
                case "megapixels":
                    f = Math.sqrt(s.megapixels * 1000000.0 / ((double) w * h));
                    break;
                case "percent":
                    f = s.percent / 100.0;
                    break;
                case "dimensions":
                    f = double.min((double) s.resize_width / w, (double) s.resize_height / h);
                    break;
                default:
                    f = 1.0;
                    break;
            }
            if (s.no_enlarge && f > 1.0) f = 1.0;
            nw = int.max(1, (int) Math.round(w * f));
            nh = int.max(1, (int) Math.round(h * f));
        }

        public void sharpen(FloatImage img, string target, string amount, int ppi) {
            if (target == "none") return;
            double sigma;
            double k;
            switch (amount) {
                case "low": k = 0.35; break;
                case "high": k = 1.0; break;
                default: k = 0.6; break;
            }
            switch (target) {
                case "matte":
                    sigma = double.max(0.6, ppi / 300.0 * 1.1);
                    k *= 1.3;
                    break;
                case "glossy":
                    sigma = double.max(0.5, ppi / 300.0 * 0.8);
                    break;
                default:
                    sigma = 0.6;
                    break;
            }
            int w = img.width;
            var lum = new float[img.pixel_count()];
            for (size_t i = 0; i < lum.length; i++) {
                float y = WorkingSpace.luminance(img.data[i * 4], img.data[i * 4 + 1], img.data[i * 4 + 2]);
                lum[i] = Transfer.linear_to_srgb(float.max(y, 0));
            }
            var blur = Filters.gaussian_plane(lum, w, img.height, sigma);
            float amount_f = (float) k;
            Parallel.range(img.height, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    float e = lum[i];
                    float sharp = (e + amount_f * (e - blur[i])).clamp(0.0f, 1.0f);
                    float lin_old = Transfer.srgb_to_linear(e);
                    float lin_new = Transfer.srgb_to_linear(sharp);
                    float ratio = lin_old > 1e-5f ? lin_new / lin_old : 1.0f;
                    ratio = ratio.clamp(0.0f, 4.0f);
                    for (int c = 0; c < 3; c++) img.data[i * 4 + c] *= ratio;
                }
            });
        }

        public FloatImage? watermark_layer(ExportSettings s, int width, int height) {
            if (!s.watermark) return null;
            int target_w = int.max(8, (int) (width * s.watermark_scale));
            Cairo.ImageSurface surface;
            if (s.watermark_kind == "image" && s.watermark_image != "") {
                Gdk.Pixbuf pb;
                try {
                    pb = new Gdk.Pixbuf.from_file_at_scale(s.watermark_image, target_w, -1, true);
                } catch (Error e) {
                    return null;
                }
                surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, pb.width, pb.height);
                var cr = new Cairo.Context(surface);
                Gdk.cairo_set_source_pixbuf(cr, pb, 0, 0);
                cr.paint();
            } else {
                string text = s.watermark_text.strip();
                if (text == "") return null;
                var probe = new Cairo.ImageSurface(Cairo.Format.ARGB32, 1, 1);
                var layout = Pango.cairo_create_layout(new Cairo.Context(probe));
                var font = Pango.FontDescription.from_string("Sans Semi-Bold");
                font.set_absolute_size(64 * Pango.SCALE);
                layout.set_font_description(font);
                layout.set_text(text, -1);
                int lw, lh;
                layout.get_pixel_size(out lw, out lh);
                double scale = (double) target_w / int.max(1, lw);
                int sw = int.max(1, (int) Math.ceil(lw * scale)) + 4;
                int sh = int.max(1, (int) Math.ceil(lh * scale)) + 4;
                surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, sw, sh);
                var cr = new Cairo.Context(surface);
                cr.scale(scale, scale);
                var real = Pango.cairo_create_layout(cr);
                real.set_font_description(font);
                real.set_text(text, -1);
                cr.move_to(2 / scale, 2 / scale);
                cr.set_source_rgba(0, 0, 0, 0.45);
                Pango.cairo_show_layout(cr, real);
                cr.move_to(0, 0);
                cr.set_source_rgba(1, 1, 1, 1);
                Pango.cairo_show_layout(cr, real);
            }
            surface.flush();
            int w = surface.get_width(), h = surface.get_height();
            int stride = surface.get_stride();
            unowned uint8[] px = surface.get_data();
            var img = new FloatImage(w, h);
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int o = y * stride + x * 4;
                    float a = px[o + 3] / 255.0f;
                    size_t d = img.offset(x, y);
                    if (a <= 0) {
                        img.data[d + 3] = 0;
                        continue;
                    }
                    img.data[d] = Transfer.srgb_to_linear(px[o + 2] / 255.0f / a);
                    img.data[d + 1] = Transfer.srgb_to_linear(px[o + 1] / 255.0f / a);
                    img.data[d + 2] = Transfer.srgb_to_linear(px[o] / 255.0f / a);
                    img.data[d + 3] = a;
                }
            }
            WorkingSpace.from_linear_srgb(img);
            return img;
        }

        public void apply_watermark(FloatImage img, ExportSettings s) {
            var mark = watermark_layer(s, img.width, img.height);
            if (mark == null) return;
            int margin = int.max(4, (int) (int.min(img.width, img.height) * 0.03));
            int x, y;
            string pos = s.watermark_position;
            if (pos.has_suffix("left")) x = margin;
            else if (pos.has_suffix("right")) x = img.width - mark.width - margin;
            else x = (img.width - mark.width) / 2;
            if (pos.has_prefix("top")) y = margin;
            else if (pos.has_prefix("bottom")) y = img.height - mark.height - margin;
            else y = (img.height - mark.height) / 2;
            Blend.composite(img, mark, x, y, BlendMode.NORMAL, (float) s.watermark_opacity, null, true);
        }

        public IccProfile output_profile(ExportSettings s) throws Error {
            if (s.color_space == "custom" && s.icc_path != "") return IccProfile.from_file(s.icc_path);
            return IccProfile.builtin(s.color_space) ?? IccProfile.srgb();
        }

        public RenderingIntent intent_of(string name) {
            switch (name) {
                case "relative": return RenderingIntent.RELATIVE_COLORIMETRIC;
                case "saturation": return RenderingIntent.SATURATION;
                case "absolute": return RenderingIntent.ABSOLUTE_COLORIMETRIC;
                default: return RenderingIntent.PERCEPTUAL;
            }
        }

        public WriteRequest prepare(RenderedPhoto photo, ExportSettings s) throws Error {
            var img = photo.image;
            int nw, nh;
            target_size(s, img.width, img.height, out nw, out nh);
            if (nw != img.width || nh != img.height) img = img.resized(nw, nh);
            else img = img.copy();
            if (s.filter != "") PhotosPluginHost.get_default().apply_filter(s.filter, img, s.filter_amount);
            sharpen(img, s.sharpen, s.sharpen_amount, s.resolution);
            apply_watermark(img, s);
            var fmt = s.format_info();
            var r = new WriteRequest(img);
            r.format = s.format;
            r.bit_depth = s.effective_depth();
            r.quality = s.quality;
            r.lossless = s.lossless && fmt != null && fmt.can_lossless;
            r.compress = s.compress;
            r.ppi = s.resolution;
            if (s.format == "dng") {
                r.pixels = img;
                r.meta = s.metadata == "none" ? null : photo.meta;
            } else if (fmt != null && fmt.linear) {
                bool wide = s.color_space == "rec2020" || s.color_space == "linear-rec2020";
                var prim = wide ? Primaries.rec2020() : Primaries.rec709();
                var pixels = img.copy();
                Matrix3.apply_image(Primaries.conversion(WorkingSpace.primaries(), prim), pixels);
                r.pixels = pixels;
                r.primaries = prim;
            } else {
                var profile = output_profile(s);
                r.pixels = WorkingSpace.to_profile(img, profile, intent_of(s.intent));
                r.icc = profile.to_data();
            }
            var meta = EmbeddedMetadata.build(photo.meta, s.metadata, nw, nh, s.resolution);
            r.exif = meta.exif_tiff;
            r.xmp = meta.xmp;
            return r;
        }

        private string clean(string s) {
            var b = new StringBuilder();
            unichar c;
            int i = 0;
            while (s.get_next_char(ref i, out c)) {
                if (c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|' || c < 32) b.append_c('_');
                else b.append_unichar(c);
            }
            return b.str.strip();
        }

        public string expand_name(string template, File source, PhotoMetadata meta, int sequence, int total) {
            string name = source.get_basename() ?? "photo";
            int dot = name.last_index_of_char('.');
            string stem = dot > 0 ? name.substring(0, dot) : name;
            var date = meta.date_taken ?? new DateTime.now_local();
            int digits = int.max(2, total.to_string().length);
            var b = new StringBuilder();
            int i = 0;
            while (i < template.length) {
                if (template[i] == '{') {
                    int close = template.index_of_char('}', i);
                    if (close > i) {
                        string token = template.substring(i + 1, close - i - 1);
                        string arg = "";
                        int colon = token.index_of_char(':');
                        if (colon > 0) {
                            arg = token.substring(colon + 1);
                            token = token.substring(0, colon);
                        }
                        switch (token) {
                            case "name": b.append(stem); break;
                            case "seq":
                                int width = arg != "" ? int.parse(arg) : digits;
                                b.append("%0*d".printf(width, sequence));
                                break;
                            case "date": b.append(date.format("%Y-%m-%d")); break;
                            case "time": b.append(date.format("%H%M%S")); break;
                            case "year": b.append(date.format("%Y")); break;
                            case "month": b.append(date.format("%m")); break;
                            case "day": b.append(date.format("%d")); break;
                            case "camera": b.append(meta.camera_label()); break;
                            case "title": b.append(meta.title != "" ? meta.title : stem); break;
                            case "rating": b.append(meta.rating.to_string()); break;
                            case "ext": b.append(dot > 0 ? name.substring(dot + 1) : ""); break;
                            default: b.append(template.substring(i, close - i + 1)); break;
                        }
                        i = close + 1;
                        continue;
                    }
                }
                b.append_c(template[i]);
                i++;
            }
            string result = clean(b.str);
            return result == "" ? stem : result;
        }

        public File destination_dir(ExportSettings s, File source) {
            File dir;
            if (s.destination == "folder" && s.folder != "") dir = File.new_for_path(s.folder);
            else dir = source.get_parent() ?? File.new_for_path(Environment.get_home_dir());
            if (s.subfolder.strip() != "") dir = dir.get_child(clean(s.subfolder));
            return dir;
        }

        public File? resolve_target(File dir, string stem, string ext, string conflict) {
            var target = dir.get_child(stem + "." + ext);
            if (!target.query_exists()) return target;
            if (conflict == "overwrite") return target;
            if (conflict == "skip") return null;
            for (int n = 2; n < 10000; n++) {
                target = dir.get_child("%s-%d.%s".printf(stem, n, ext));
                if (!target.query_exists()) return target;
            }
            return null;
        }

        public ExportResult export_one(File source, ExportSettings s, int sequence, int total) {
            var result = new ExportResult(source);
            try {
                var photo = OutputRender.render(source, 0);
                var request = prepare(photo, s);
                var dir = destination_dir(s, source);
                DirUtils.create_with_parents(dir.get_path(), 0755);
                string stem = expand_name(s.naming, source, photo.meta, sequence, total);
                var target = resolve_target(dir, stem, s.extension(), s.conflict);
                if (target == null) {
                    result.skipped = true;
                    return result;
                }
                string partial = target.get_path() + ".part";
                ImageWriters.write(request, partial);
                if (FileUtils.rename(partial, target.get_path()) != 0) {
                    FileUtils.remove(partial);
                    throw new IOError.FAILED(_("Cannot write %s").printf(target.get_basename()));
                }
                result.target = target;
            } catch (Error e) {
                result.error = e.message;
            }
            return result;
        }

        public Gee.List<ExportResult> run(File[] files, ExportSettings s, Cancellable? cancellable = null, ExportProgress? progress = null) {
            var results = new Gee.ArrayList<ExportResult>();
            for (int i = 0; i < files.length; i++) {
                if (cancellable != null && cancellable.is_cancelled()) break;
                if (progress != null) progress(i, files.length, files[i]);
                results.add(export_one(files[i], s, s.sequence_start + i, files.length));
            }
            if (progress != null && files.length > 0) progress(files.length, files.length, files[files.length - 1]);
            return results;
        }
    }
}
