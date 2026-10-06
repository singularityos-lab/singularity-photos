using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class LibRawDecoder : Object, PhotoDecoder {
        public string id { get { return "libraw"; } }

        public static bool available() {
            return LibRawShim.available() != 0;
        }

        public static string version() {
            return available() ? LibRawShim.version() : "";
        }

        public bool handles(string lower_name, uint8[] head) {
            return Codecs.is_raw_name(lower_name);
        }

        public DecodedPhoto decode(File file, int max_side) throws Error {
            if (!available()) throw new IOError.NOT_SUPPORTED(_("RAW files cannot be opened on this system because LibRaw is not installed"));
            string? path = file.get_path();
            if (path == null) throw new IOError.NOT_SUPPORTED(_("Only local files can be opened"));
            uint16* pixels;
            int w, h;
            var cam_mul = new float[4];
            var pre_mul = new float[4];
            var rgb_cam = new float[12];
            var make = new char[64];
            var model = new char[64];
            string? error;
            int demosaic = max_side > 0 && max_side <= 2048 ? 0 : 3;
            int rc = LibRawShim.decode(path, demosaic, out pixels, out w, out h, cam_mul, pre_mul, rgb_cam, make, model, out error);
            if (rc != 0 || pixels == null) throw new IOError.FAILED(_("Cannot decode this RAW file: %s").printf(error ?? rc.to_string()));
            var camera = new FloatImage(w, h);
            size_t n = (size_t) w * h;
            for (size_t i = 0; i < n; i++) {
                camera.data[i * 4] = pixels[i * 3] / 65535.0f;
                camera.data[i * 4 + 1] = pixels[i * 3 + 1] / 65535.0f;
                camera.data[i * 4 + 2] = pixels[i * 3 + 2] / 65535.0f;
                camera.data[i * 4 + 3] = 1;
            }
            free(pixels);
            int full_w = w, full_h = h;
            if (max_side > 0) camera = camera.scaled_to_fit(max_side);
            var raw = new DngRawData(camera);
            raw.decoder = "libraw";
            string mk = ((string) make).strip(), md = ((string) model).strip();
            raw.camera_model = (mk + " " + md).strip();
            fill_color(raw, cam_mul, pre_mul, rgb_cam);
            var working = RawColor.develop(raw, raw.as_shot_multipliers[0], raw.as_shot_multipliers[1], raw.as_shot_multipliers[2], "reconstruct");
            var photo = new DecodedPhoto(working);
            photo.raw = raw;
            photo.format = Codecs.extension(file.get_basename() ?? "");
            photo.full_width = full_w;
            photo.full_height = full_h;
            photo.meta = MetadataReader.read(file);
            if (photo.meta.make == "") photo.meta.make = mk;
            if (photo.meta.model == "") photo.meta.model = md;
            photo.meta.width = full_w;
            photo.meta.height = full_h;
            photo.meta.orientation = 1;
            return photo;
        }

        public static void fill_color(DngRawData raw, float[] cam_mul, float[] pre_mul, float[] rgb_cam) {
            double[] rc = new double[9];
            bool valid = false;
            for (int i = 0; i < 3; i++)
                for (int j = 0; j < 3; j++) {
                    rc[i * 3 + j] = rgb_cam[i * 4 + j];
                    if (rgb_cam[i * 4 + j] != 0 && i != j) valid = true;
                }
            double pr = pre_mul[0] > 0 ? pre_mul[0] : 1, pg = pre_mul[1] > 0 ? pre_mul[1] : 1, pb = pre_mul[2] > 0 ? pre_mul[2] : 1;
            if (valid) {
                double[] p = { pr / pg, 0, 0, 0, 1, 0, 0, 0, pb / pg };
                var to_xyz = Matrix3.multiply(Primaries.rec709().to_xyz(), Matrix3.multiply(rc, p));
                raw.color_matrix1 = Matrix3.invert(to_xyz);
            } else {
                raw.color_matrix1 = Matrix3.invert(Primaries.rec709().to_xyz());
            }
            raw.temperature1 = 6504;
            raw.xyz_to_camera = raw.color_matrix1;
            var inv = Matrix3.invert(raw.color_matrix1);
            var white = Chromaticity.mul(inv, { 1, 1, 1 });
            if (white[1] > 1e-9) {
                for (int i = 0; i < 9; i++) inv[i] /= white[1];
                raw.camera_to_xyz = inv;
            }
            if (cam_mul[0] > 0 && cam_mul[1] > 0 && cam_mul[2] > 0) {
                raw.as_shot_multipliers = { cam_mul[0] / cam_mul[1], 1.0, cam_mul[2] / cam_mul[1] };
            } else {
                raw.as_shot_multipliers = { pr / pg, 1.0, pb / pg };
            }
            double t, tint;
            RawColor.temperature_for(raw, raw.as_shot_multipliers[0], 1.0, raw.as_shot_multipliers[2], out t, out tint);
            raw.as_shot_temperature = t;
            raw.as_shot_tint = tint;
        }
    }
}
