using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace RetouchColor {

        public void working_to_encoded(FloatImage img, int x0 = 0, int y0 = 0, int w = -1, int h = -1) {
            if (w < 0) w = img.width;
            if (h < 0) h = img.height;
            unowned double[] m = WorkingSpace.to_srgb_matrix();
            float m0 = (float) m[0], m1 = (float) m[1], m2 = (float) m[2], m3 = (float) m[3], m4 = (float) m[4];
            float m5 = (float) m[5], m6 = (float) m[6], m7 = (float) m[7], m8 = (float) m[8];
            Parallel.range(h, (start, end) => {
                for (int y = y0 + start; y < y0 + end; y++) {
                    for (int x = x0; x < x0 + w; x++) {
                        size_t i = img.offset(x, y);
                        float r = img.data[i], g = img.data[i + 1], b = img.data[i + 2];
                        img.data[i] = Transfer.linear_to_srgb(m0 * r + m1 * g + m2 * b);
                        img.data[i + 1] = Transfer.linear_to_srgb(m3 * r + m4 * g + m5 * b);
                        img.data[i + 2] = Transfer.linear_to_srgb(m6 * r + m7 * g + m8 * b);
                    }
                }
            });
        }

        public void encoded_to_working(FloatImage img, int x0 = 0, int y0 = 0, int w = -1, int h = -1) {
            if (w < 0) w = img.width;
            if (h < 0) h = img.height;
            unowned double[] m = WorkingSpace.from_srgb_matrix();
            float m0 = (float) m[0], m1 = (float) m[1], m2 = (float) m[2], m3 = (float) m[3], m4 = (float) m[4];
            float m5 = (float) m[5], m6 = (float) m[6], m7 = (float) m[7], m8 = (float) m[8];
            Parallel.range(h, (start, end) => {
                for (int y = y0 + start; y < y0 + end; y++) {
                    for (int x = x0; x < x0 + w; x++) {
                        size_t i = img.offset(x, y);
                        float r = Transfer.srgb_to_linear(img.data[i]);
                        float g = Transfer.srgb_to_linear(img.data[i + 1]);
                        float b = Transfer.srgb_to_linear(img.data[i + 2]);
                        img.data[i] = m0 * r + m1 * g + m2 * b;
                        img.data[i + 1] = m3 * r + m4 * g + m5 * b;
                        img.data[i + 2] = m6 * r + m7 * g + m8 * b;
                    }
                }
            });
        }

        public void pixel_to_encoded(float r, float g, float b, out float er, out float eg, out float eb) {
            unowned double[] m = WorkingSpace.to_srgb_matrix();
            er = Transfer.linear_to_srgb((float) (m[0] * r + m[1] * g + m[2] * b));
            eg = Transfer.linear_to_srgb((float) (m[3] * r + m[4] * g + m[5] * b));
            eb = Transfer.linear_to_srgb((float) (m[6] * r + m[7] * g + m[8] * b));
        }

        public void pixel_to_working(float er, float eg, float eb, out float r, out float g, out float b) {
            unowned double[] m = WorkingSpace.from_srgb_matrix();
            float lr = Transfer.srgb_to_linear(er), lg = Transfer.srgb_to_linear(eg), lb = Transfer.srgb_to_linear(eb);
            r = (float) (m[0] * lr + m[1] * lg + m[2] * lb);
            g = (float) (m[3] * lr + m[4] * lg + m[5] * lb);
            b = (float) (m[6] * lr + m[7] * lg + m[8] * lb);
        }

        public FloatImage from_texture(Gdk.Texture texture) {
            var img = FloatImage.from_texture(texture, true);
            WorkingSpace.from_linear_srgb(img);
            return img;
        }

        public Gdk.Texture to_texture16(FloatImage working) {
            var img = working.copy();
            WorkingSpace.to_linear_srgb(img);
            return img.to_texture16(true);
        }

        public Gdk.Texture to_texture8(FloatImage working) {
            var img = working.copy();
            WorkingSpace.to_linear_srgb(img);
            return img.to_texture(true);
        }

        public float luma_encoded(float er, float eg, float eb) {
            return 0.2126f * er + 0.7152f * eg + 0.0722f * eb;
        }

        public void rgb_to_hsl(float r, float g, float b, out float h, out float s, out float l) {
            float mx = float.max(r, float.max(g, b)), mn = float.min(r, float.min(g, b));
            l = (mx + mn) / 2;
            float d = mx - mn;
            if (d < 1e-6f) {
                h = 0;
                s = 0;
                return;
            }
            s = l > 0.5f ? d / (2 - mx - mn) : d / (mx + mn);
            if (mx == r) h = (g - b) / d + (g < b ? 6 : 0);
            else if (mx == g) h = (b - r) / d + 2;
            else h = (r - g) / d + 4;
            h *= 60;
        }

        private float hue_channel(float p, float q, float t) {
            if (t < 0) t += 1;
            if (t > 1) t -= 1;
            if (t < 1.0f / 6) return p + (q - p) * 6 * t;
            if (t < 0.5f) return q;
            if (t < 2.0f / 3) return p + (q - p) * (2.0f / 3 - t) * 6;
            return p;
        }

        public void hsl_to_rgb(float h, float s, float l, out float r, out float g, out float b) {
            if (s <= 1e-6f) {
                r = g = b = l;
                return;
            }
            float hh = ((h % 360) + 360) % 360 / 360.0f;
            float q = l < 0.5f ? l * (1 + s) : l + s - l * s;
            float p = 2 * l - q;
            r = hue_channel(p, q, hh + 1.0f / 3);
            g = hue_channel(p, q, hh);
            b = hue_channel(p, q, hh - 1.0f / 3);
        }
    }
}
