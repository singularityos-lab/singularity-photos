[CCode (cheader_filename = "libraw_shim.h")]
namespace LibRawShim {
    [CCode (cname = "sinty_libraw_available")]
    public int available();
    [CCode (cname = "sinty_libraw_version")]
    public unowned string version();
    [CCode (cname = "sinty_libraw_decode")]
    public int decode(string path, int demosaic, out uint16* pixels, out int width, out int height,
        [CCode (array_length = false)] float[] cam_mul, [CCode (array_length = false)] float[] pre_mul,
        [CCode (array_length = false)] float[] rgb_cam, [CCode (array_length = false)] char[] make,
        [CCode (array_length = false)] char[] model, out string? error);
}
