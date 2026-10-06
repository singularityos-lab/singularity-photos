namespace Singularity.Apps.Photos {

    namespace EditImageIO {

        public EditImage from_pixbuf(Gdk.Pixbuf pixbuf) {
            unowned uint8[] pixels = pixbuf.get_pixels_with_length();
            return new EditImage.from_rgba(pixbuf.width, pixbuf.height, pixels, pixbuf.rowstride, pixbuf.has_alpha);
        }

        public EditImage load(File file) throws Error {
            var pixbuf = new Gdk.Pixbuf.from_file(file.get_path());
            var oriented = pixbuf.apply_embedded_orientation() ?? pixbuf;
            return from_pixbuf(oriented);
        }

        public Gdk.Pixbuf to_pixbuf(EditImage img) {
            var bytes = new Bytes(img.data);
            return new Gdk.Pixbuf.from_bytes(bytes, Gdk.Colorspace.RGB, true, 8, img.width, img.height, img.width * 4);
        }

        public Gdk.Texture to_texture(EditImage img) {
            var bytes = new Bytes(img.data);
            return new Gdk.MemoryTexture(img.width, img.height, Gdk.MemoryFormat.R8G8B8A8, bytes, img.width * 4);
        }

        public bool is_opaque(EditImage img) {
            for (int i = 3; i < img.data.length; i += 4) if (img.data[i] != 255) return false;
            return true;
        }

        public string format_for(File file) {
            string name = (file.get_basename() ?? "").down();
            if (name.has_suffix(".jpg") || name.has_suffix(".jpeg")) return "jpeg";
            return "png";
        }

        public void save(EditImage img, File target) throws Error {
            string format = format_for(target);
            if (format == "jpeg") {
                var rgb = new uint8[(size_t) img.width * img.height * 3];
                int n = img.width * img.height;
                for (int i = 0; i < n; i++) {
                    int a = img.data[i * 4 + 3];
                    for (int c = 0; c < 3; c++)
                        rgb[i * 3 + c] = (uint8) ((img.data[i * 4 + c] * a + 255 * (255 - a) + 127) / 255);
                }
                var flat = new Gdk.Pixbuf.from_bytes(new Bytes(rgb), Gdk.Colorspace.RGB, false, 8, img.width, img.height, img.width * 3);
                flat.savev(target.get_path(), "jpeg", { "quality" }, { "95" });
            } else {
                to_pixbuf(img).savev(target.get_path(), "png", {}, {});
            }
        }

        public const int DISPLAY_SIDE = 3072;

        public Singularity.Imaging.FloatImage render_file(File original, EditParams? p, int max_side, RenderOptions? options = null) throws Error {
            var photo = Codecs.load(original, max_side > 0 ? (int) (max_side * 1.25) : 0);
            var o = options ?? new RenderOptions();
            o.max_side = max_side;
            return DevelopPipeline.render(photo, p ?? new EditParams(), o);
        }

        public void save_working(Singularity.Imaging.FloatImage working, File target) throws Error {
            var encoded = WorkingSpace.to_srgb_encoded(working);
            var img = new EditImage.from_rgba(encoded.width, encoded.height, encoded.to_rgba8(false), encoded.width * 4, true);
            save(img, target);
        }

        private bool newer_than(File cache, File other) {
            try {
                var ci = cache.query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                var oi = other.query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                return ci.get_modification_date_time().compare(oi.get_modification_date_time()) >= 0;
            } catch (Error e) {
                return false;
            }
        }

        public File? render_to_cache(File original, EditParams? p, string variant = "") {
            try {
                var img = render_file(original, p, DISPLAY_SIDE);
                var cache = EditStore.render_cache(original, variant);
                DirUtils.create_with_parents(cache.get_parent().get_path(), 0755);
                string partial = "%s.%u.part".printf(cache.get_path(), Random.next_int());
                var encoded = WorkingSpace.to_srgb_encoded(img);
                var tex = encoded.to_texture(false);
                tex.save_to_png(partial);
                if (FileUtils.rename(partial, cache.get_path()) != 0) {
                    FileUtils.remove(partial);
                    return null;
                }
                return cache;
            } catch (Error e) {
                warning("Photos: cannot render %s: %s", original.get_path(), e.message);
                return null;
            }
        }

        public Gdk.Pixbuf oriented(Gdk.Pixbuf pixbuf) {
            return pixbuf.apply_embedded_orientation() ?? pixbuf;
        }

        public bool has_orientation(Gdk.Pixbuf pixbuf) {
            string? tag = pixbuf.get_option("orientation");
            return tag != null && tag != "1";
        }

        public Gdk.Texture texture_from_pixbuf(Gdk.Pixbuf pixbuf) {
            var format = pixbuf.has_alpha ? Gdk.MemoryFormat.R8G8B8A8 : Gdk.MemoryFormat.R8G8B8;
            return new Gdk.MemoryTexture(pixbuf.width, pixbuf.height, format, pixbuf.read_pixel_bytes(), pixbuf.rowstride);
        }

        private bool may_carry_orientation(File file) {
            var format = Gdk.Pixbuf.get_file_info(file.get_path(), null, null);
            return format != null && format.get_name() != "png";
        }

        public Gdk.Texture load_display_texture(File original) throws Error {
            var shown = display_file(original) ?? original;
            if (may_carry_orientation(shown)) {
                try {
                    return texture_from_pixbuf(oriented(new Gdk.Pixbuf.from_file(shown.get_path())));
                } catch (Error e) {
                }
            }
            return Gdk.Texture.from_file(shown);
        }

        public File markup_cache(File file) {
            return File.new_for_path(Path.build_filename(Environment.get_user_cache_dir(),
                "singularity-photos", "markup", EditStore.key_for(file) + ".png"));
        }

        public File markup_source(File original) {
            if (EditStore.has_edits(original)) return display_file(original) ?? original;
            if (!may_carry_orientation(original)) return original;
            try {
                var pixbuf = new Gdk.Pixbuf.from_file(original.get_path());
                if (!has_orientation(pixbuf)) return original;
                var target = markup_cache(original);
                DirUtils.create_with_parents(target.get_parent().get_path(), 0755);
                string partial = "%s.%u.part".printf(target.get_path(), Random.next_int());
                oriented(pixbuf).savev(partial, "png", {}, {});
                if (FileUtils.rename(partial, target.get_path()) != 0) {
                    FileUtils.remove(partial);
                    return original;
                }
                return target;
            } catch (Error e) {
                return original;
            }
        }

        public File? display_file(File original, string variant = "") {
            bool raw = Codecs.is_raw_name(original.get_basename() ?? "");
            bool other = !raw && needs_render(original);
            if (!EditStore.has_edits(original, variant)) {
                var sidecar_params = variant == "" ? EditStore.load_xmp(original, false) : null;
                if (sidecar_params != null) {
                    var cache = EditStore.render_cache(original, variant);
                    if (cache.query_exists() && newer_than(cache, original) && newer_than(cache, XmpSidecar.find(original) ?? original)) return cache;
                    return render_to_cache(original, sidecar_params, variant) ?? original;
                }
                if (!raw && !other) return original;
                var cache = EditStore.render_cache(original, variant);
                if (cache.query_exists() && newer_than(cache, original)) return cache;
                return render_to_cache(original, null, variant) ?? original;
            }
            var cache = EditStore.valid_cache(original, variant);
            if (cache != null) return cache;
            var p = EditStore.load(original, variant);
            if (p == null) return original;
            return render_to_cache(original, p, variant) ?? original;
        }

        public bool needs_render(File original) {
            string name = (original.get_basename() ?? "").down();
            return name.has_suffix(".psd") || name.has_suffix(".ora") || name.has_suffix(".exr") || name.has_suffix(".heic") || name.has_suffix(".heif") || name.has_suffix(".avif");
        }
    }
}
