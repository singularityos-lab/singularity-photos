[CCode (cheader_filename = "output_codecs.h")]
namespace SintyCodecs {
    [CCode (cname = "sinty_webp_encode")]
    public bool webp_encode([CCode (array_length = false)] uint8[] rgba, int width, int height, float quality, bool lossless, uint8[] icc, uint8[] exif, uint8[] xmp, out uint8[] encoded);
    [CCode (cname = "sinty_webp_decode")]
    public bool webp_decode(uint8[] data, out int width, out int height, out uint8[] rgba, out uint8[] icc);
    [CCode (cname = "sinty_tiff_write")]
    public bool tiff_write(string path, void* pixels, int width, int height, int channels, int bits, bool is_float, uint8[] icc, uint8[] xmp, bool compress, out string? error);
    [CCode (cname = "sinty_tiff_read")]
    public bool tiff_read(string path, out int width, out int height, out int bits, out bool is_float, out float[] rgba, out uint8[] icc);
    [CCode (cname = "sinty_heif_can_encode")]
    public bool heif_can_encode(bool avif);
    [CCode (cname = "sinty_heif_can_decode")]
    public bool heif_can_decode(bool avif);
    [CCode (cname = "sinty_heif_encode")]
    public bool heif_encode(string path, [CCode (array_length = false)] uint16[] rgba, int width, int height, int bit_depth, bool avif, int quality, bool lossless, uint8[] icc, uint8[] exif, uint8[] xmp, out string? error);
    [CCode (cname = "sinty_heif_decode")]
    public bool heif_decode(string path, out int width, out int height, out float[] rgba, out uint8[] icc, out string? error);
    [CCode (cname = "sinty_jxl_available")]
    public bool jxl_available();
    [CCode (cname = "sinty_jxl_encode")]
    public bool jxl_encode(string path, [CCode (array_length = false)] float[] rgba, int width, int height, int bits, float distance, bool lossless, uint8[] icc, uint8[] exif, uint8[] xmp, out string? error);
    [CCode (cname = "sinty_jxl_decode")]
    public bool jxl_decode(string path, out int width, out int height, out float[] rgba, out uint8[] icc, out string? error);
}
