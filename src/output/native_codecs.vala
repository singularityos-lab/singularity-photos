namespace Singularity.Apps.Photos {

    namespace NativeCodecs {

        public bool webp_decode(uint8[] data, out int width, out int height, out uint8[] rgba, out uint8[] icc) {
            return SintyCodecs.webp_decode(data, out width, out height, out rgba, out icc);
        }

        public bool tiff_read(string path, out int width, out int height, out int bits, out bool is_float, out float[] rgba, out uint8[] icc) {
            return SintyCodecs.tiff_read(path, out width, out height, out bits, out is_float, out rgba, out icc);
        }

        public bool heif_can_encode(bool avif) {
            return SintyCodecs.heif_can_encode(avif);
        }

        public bool heif_can_decode(bool avif) {
            return SintyCodecs.heif_can_decode(avif);
        }

        public bool heif_decode(string path, out int width, out int height, out float[] rgba, out uint8[] icc, out string? error) {
            return SintyCodecs.heif_decode(path, out width, out height, out rgba, out icc, out error);
        }

        public bool jxl_available() {
            return SintyCodecs.jxl_available();
        }

        public bool jxl_decode(string path, out int width, out int height, out float[] rgba, out uint8[] icc, out string? error) {
            return SintyCodecs.jxl_decode(path, out width, out height, out rgba, out icc, out error);
        }
    }
}
