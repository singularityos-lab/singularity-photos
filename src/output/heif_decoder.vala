using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class HeifDecoder : Object, PhotoDecoder {
        public string id { get { return "heif"; } }

        private static bool is_heif(string name, uint8[] head) {
            if (name.has_suffix(".heic") || name.has_suffix(".heif") || name.has_suffix(".avif") || name.has_suffix(".hif")) return true;
            if (head.length >= 12 && head[4] == 'f' && head[5] == 't' && head[6] == 'y' && head[7] == 'p') {
                string brand = "%c%c%c%c".printf(head[8], head[9], head[10], head[11]);
                return brand in new string[] { "heic", "heix", "mif1", "msf1", "avif", "avis", "hevc", "heim", "heis" };
            }
            return false;
        }

        private static bool is_jxl(string name, uint8[] head) {
            if (name.has_suffix(".jxl")) return true;
            if (head.length >= 2 && head[0] == 0xFF && head[1] == 0x0A) return true;
            return head.length >= 12 && head[4] == 'J' && head[5] == 'X' && head[6] == 'L' && head[7] == ' ';
        }

        private static bool is_webp(string name, uint8[] head) {
            if (head.length >= 12 && head[0] == 'R' && head[1] == 'I' && head[2] == 'F' && head[3] == 'F'
                && head[8] == 'W' && head[9] == 'E' && head[10] == 'B' && head[11] == 'P') return true;
            return name.has_suffix(".webp");
        }

        public bool handles(string lower_name, uint8[] head) {
            if (is_webp(lower_name, head)) return true;
            if (is_jxl(lower_name, head)) return SintyCodecs.jxl_available();
            if (is_heif(lower_name, head)) return SintyCodecs.heif_can_decode(lower_name.has_suffix(".avif")) || SintyCodecs.heif_can_decode(true);
            return false;
        }

        public DecodedPhoto decode(File file, int max_side) throws Error {
            string name = (file.get_basename() ?? "").down();
            var head = Codecs.read_head(file);
            int w, h;
            float[] rgba;
            uint8[] icc;
            string? error = null;
            string format;
            if (is_webp(name, head)) {
                uint8[] data;
                FileUtils.get_data(file.get_path(), out data);
                uint8[] px;
                if (!SintyCodecs.webp_decode(data, out w, out h, out px, out icc)) throw new IOError.INVALID_DATA(_("This WebP file is damaged"));
                var enc = FloatImage.from_rgba8(px, w, h, w * 4, true, false);
                return finish(file, enc, icc, "webp", max_side);
            } else if (is_jxl(name, head)) {
                if (!SintyCodecs.jxl_decode(file.get_path(), out w, out h, out rgba, out icc, out error))
                    throw new IOError.INVALID_DATA(error ?? _("This JPEG XL file cannot be read"));
                format = "jxl";
            } else {
                if (!SintyCodecs.heif_decode(file.get_path(), out w, out h, out rgba, out icc, out error))
                    throw new IOError.INVALID_DATA(error ?? _("This HEIF file cannot be read"));
                format = name.has_suffix(".avif") ? "avif" : "heif";
            }
            if (rgba.length < w * h * 4) throw new IOError.INVALID_DATA(_("The image data is incomplete"));
            var enc = new FloatImage.from_data(w, h, (owned) rgba);
            return finish(file, enc, icc, format, max_side);
        }

        private DecodedPhoto finish(File file, FloatImage encoded, uint8[] icc, string format, int max_side) {
            int fw = encoded.width, fh = encoded.height;
            var img = max_side > 0 ? encoded.scaled_to_fit(max_side) : encoded;
            IccProfile? profile = null;
            if (icc.length > 0) {
                try {
                    profile = IccProfile.from_data(icc);
                    if (!profile.is_rgb()) profile = null;
                } catch (Error e) {
                    profile = null;
                }
            }
            FloatImage working;
            if (profile != null) {
                working = WorkingSpace.from_profile(img, profile);
            } else {
                working = img == encoded ? img.copy() : img;
                WorkingSpace.linearize(working);
                WorkingSpace.from_linear_srgb(working);
            }
            var photo = new DecodedPhoto(working);
            photo.profile = profile;
            photo.full_width = fw;
            photo.full_height = fh;
            photo.format = format;
            photo.meta = MetadataReader.read(file);
            if (photo.meta.width == 0) {
                photo.meta.width = fw;
                photo.meta.height = fh;
            }
            return photo;
        }
    }
}
