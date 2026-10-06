using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace WorkingSpace {

        private double[]? srgb_to_working_m = null;
        private double[]? working_to_srgb_m = null;
        private IccProfile? working_profile = null;

        public Primaries primaries() {
            return Primaries.rec2020();
        }

        public unowned double[] from_srgb_matrix() {
            if (srgb_to_working_m == null) srgb_to_working_m = Primaries.conversion(Primaries.rec709(), primaries());
            return srgb_to_working_m;
        }

        public unowned double[] to_srgb_matrix() {
            if (working_to_srgb_m == null) working_to_srgb_m = Primaries.conversion(primaries(), Primaries.rec709());
            return working_to_srgb_m;
        }

        public IccProfile profile() {
            if (working_profile == null) working_profile = IccProfile.linear_rec2020();
            return working_profile;
        }

        public void from_linear_srgb(FloatImage img) {
            Matrix3.apply_image(from_srgb_matrix(), img);
        }

        public void to_linear_srgb(FloatImage img) {
            Matrix3.apply_image(to_srgb_matrix(), img);
        }

        public FloatImage from_srgb8(uint8[] rgba, int width, int height, int stride, bool has_alpha) {
            var img = FloatImage.from_rgba8(rgba, width, height, stride, has_alpha, true);
            from_linear_srgb(img);
            return img;
        }

        public FloatImage from_profile(FloatImage encoded, IccProfile source) {
            var t = new ColorTransform(source, profile(), RenderingIntent.PERCEPTUAL, false);
            if (!t.valid()) {
                var img = encoded.copy();
                linearize(img);
                from_linear_srgb(img);
                return img;
            }
            var img = encoded.copy();
            t.apply(img);
            return img;
        }

        public void linearize(FloatImage img) {
            int w = img.width;
            Parallel.range(img.height, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++)
                    for (int c = 0; c < 3; c++) img.data[i * 4 + c] = Transfer.srgb_to_linear(img.data[i * 4 + c]);
            });
        }

        public void encode_srgb(FloatImage img) {
            int w = img.width;
            Parallel.range(img.height, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++)
                    for (int c = 0; c < 3; c++) img.data[i * 4 + c] = Transfer.linear_to_srgb(img.data[i * 4 + c]);
            });
        }

        public FloatImage to_srgb_encoded(FloatImage working) {
            var img = working.copy();
            to_linear_srgb(img);
            encode_srgb(img);
            return img;
        }

        public FloatImage to_profile(FloatImage working, IccProfile target, RenderingIntent intent = RenderingIntent.PERCEPTUAL) {
            if (target.id == "srgb") return to_srgb_encoded(working);
            var img = working.copy();
            var t = new ColorTransform(profile(), target, intent, true);
            if (t.valid()) t.apply(img);
            return img;
        }

        public Gdk.Texture to_display_texture(FloatImage working, ColorTransform? display = null) {
            if (display != null && display.valid()) {
                var img = working.copy();
                display.apply(img);
                return img.to_texture(false);
            }
            var img = working.copy();
            to_linear_srgb(img);
            return img.to_texture(true);
        }

        public float luminance(float r, float g, float b) {
            return 0.2627f * r + 0.6780f * g + 0.0593f * b;
        }
    }
}
