using Singularity.Apps.Photos;
using Singularity.Imaging;

private string tmp_dir;

private void near(double got, double want, double tolerance, string what = "") {
    if ((got - want).abs() > tolerance) {
        stderr.printf("%s: got %f want %f\n", what, got, want);
        assert_not_reached();
    }
}

private FloatImage gradient(int w, int h, bool alpha = false) {
    var img = new FloatImage(w, h);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            img.set_pixel(x, y, (float) x / (w - 1), (float) y / (h - 1), (float) ((x + y) % 7) / 6.0f, alpha ? (float) (x % 4) / 3.0f : 1.0f);
        }
    }
    return img;
}

private string path(string name) {
    return Path.build_filename(tmp_dir, name);
}

private uint16 le16(uint8[] d, int at) {
    return (uint16) (d[at] | (d[at + 1] << 8));
}

private uint32 le32(uint8[] d, int at) {
    return (uint32) d[at] | ((uint32) d[at + 1] << 8) | ((uint32) d[at + 2] << 16) | ((uint32) d[at + 3] << 24);
}

private string? exif_ascii(uint8[] tiff, uint32 ifd, uint16 tag) {
    int n = le16(tiff, (int) ifd);
    for (int i = 0; i < n; i++) {
        int e = (int) ifd + 2 + i * 12;
        if (le16(tiff, e) != tag) continue;
        uint32 count = le32(tiff, e + 4);
        int at = count <= 4 ? e + 8 : (int) le32(tiff, e + 8);
        return (string) tiff[at:at + count - 1];
    }
    return null;
}

private uint32 exif_long(uint8[] tiff, uint32 ifd, uint16 tag) {
    int n = le16(tiff, (int) ifd);
    for (int i = 0; i < n; i++) {
        int e = (int) ifd + 2 + i * 12;
        if (le16(tiff, e) != tag) continue;
        uint16 type = le16(tiff, e + 2);
        return type == 3 ? le16(tiff, e + 8) : le32(tiff, e + 8);
    }
    return 0;
}

private void exif_rational(uint8[] tiff, uint32 ifd, uint16 tag, out uint32 num, out uint32 den) {
    num = 0;
    den = 0;
    int n = le16(tiff, (int) ifd);
    for (int i = 0; i < n; i++) {
        int e = (int) ifd + 2 + i * 12;
        if (le16(tiff, e) != tag) continue;
        int at = (int) le32(tiff, e + 8);
        num = le32(tiff, at);
        den = le32(tiff, at + 4);
    }
}

private PhotoMetadata sample_meta() {
    var m = new PhotoMetadata();
    m.make = "Canon";
    m.model = "Canon EOS R5";
    m.lens = "RF 24-70mm F2.8";
    m.exposure_time = 1.0 / 250;
    m.aperture = 2.8;
    m.iso = 400;
    m.focal_length = 35;
    m.creator = "Ada Lovelace";
    m.copyright = "(c) 2026 Ada";
    m.title = "Harbour";
    m.keywords = { "sea", "boat" };
    m.has_gps = true;
    m.latitude = 45.4642;
    m.longitude = -9.19;
    m.altitude = 120;
    m.date_taken = new DateTime.local(2026, 5, 17, 10, 30, 0);
    return m;
}

private void test_exif_builder() {
    var m = sample_meta();
    var tiff = new ExifBuilder.from_metadata(m, 640, 480, 300, true, true, true).build_tiff();
    assert(tiff[0] == 'I' && tiff[1] == 'I' && tiff[2] == 42);
    uint32 ifd0 = le32(tiff, 4);
    assert(exif_ascii(tiff, ifd0, 0x010F) == "Canon");
    assert(exif_ascii(tiff, ifd0, 0x0110) == "Canon EOS R5");
    assert(exif_ascii(tiff, ifd0, 0x8298) == "(c) 2026 Ada");
    assert(exif_long(tiff, ifd0, 0x0112) == 1);
    uint32 sub = exif_long(tiff, ifd0, 0x8769);
    assert(sub > 0);
    uint32 num, den;
    exif_rational(tiff, sub, 0x829A, out num, out den);
    assert(num == 1 && den == 250);
    exif_rational(tiff, sub, 0x829D, out num, out den);
    near((double) num / den, 2.8, 1e-9, "fnumber");
    assert(exif_long(tiff, sub, 0x8827) == 400);
    assert(exif_ascii(tiff, sub, 0x9003) == "2026:05:17 10:30:00");
    assert(exif_ascii(tiff, sub, 0xA434) == "RF 24-70mm F2.8");
    assert(exif_long(tiff, sub, 0xA002) == 640);
    uint32 gps = exif_long(tiff, ifd0, 0x8825);
    assert(gps > 0);
    assert(exif_ascii(tiff, gps, 0x0001) == "N");
    assert(exif_ascii(tiff, gps, 0x0003) == "W");
    var bare = new ExifBuilder.from_metadata(m, 10, 10, 72, false, false, true).build_tiff();
    uint32 b0 = le32(bare, 4);
    assert(exif_ascii(bare, b0, 0x010F) == null);
    assert(exif_long(bare, b0, 0x8825) == 0);
    assert(exif_ascii(bare, b0, 0x8298) == "(c) 2026 Ada");
    var none = EmbeddedMetadata.build(m, "none", 10, 10, 72);
    assert(none.exif_tiff.length == 0 && none.xmp == "");
}

private void test_half() {
    float[] values = { 0.0f, 1.0f, -2.5f, 0.1f, 65504.0f, 1e-5f, 0.333f };
    foreach (float v in values) {
        float back = Exr.half_to_float(Exr.float_to_half(v));
        near(back, v, double.max(v.abs() * 0.001, 1e-7), "half");
    }
}

private void test_exr_roundtrip() {
    var img = gradient(37, 29, true);
    img.set_pixel(3, 3, 12.5f, 0.001f, 250.0f, 1.0f);
    int[] compressions = { Exr.COMPRESSION_NONE, Exr.COMPRESSION_ZIP, Exr.COMPRESSION_ZIPS };
    foreach (int comp in compressions) {
        foreach (bool half in new bool[] { true, false }) {
            string p = path("rt-%d-%s.exr".printf(comp, half ? "h" : "f"));
            try {
                Exr.write(img, p, half, comp, Primaries.rec2020());
                var back = Exr.read(p);
                assert(back.image.width == 37 && back.image.height == 29);
                assert(back.has_chromaticities);
                near(back.primaries.rx, 0.708, 1e-5, "chroma");
                for (size_t i = 0; i < img.data.length; i++) {
                    double want = img.data[i];
                    near(back.image.data[i], want, half ? double.max(want.abs() * 0.001, 1e-4) : 1e-7, "exr");
                }
            } catch (Error e) {
                stderr.printf("%s\n", e.message);
                assert_not_reached();
            }
        }
    }
    var texture_check = new ExrDecoder();
    assert(texture_check.handles("x.exr", new uint8[] { 0x76, 0x2F, 0x31, 0x01 }));
}

private void test_png() {
    var img = gradient(40, 30);
    var icc = IccProfile.display_p3().to_data();
    var exif = new ExifBuilder.from_metadata(sample_meta(), 40, 30, 300, true, false, true).build_tiff();
    foreach (int depth in new int[] { 8, 16 }) {
        var data = ImageWriters.encode_png(img, depth, icc, exif, "", 300);
        string p = path("rt-%d.png".printf(depth));
        try {
            FileUtils.set_data(p, data);
            var tex = Gdk.Texture.from_filename(p);
            assert(tex.get_width() == 40 && tex.get_height() == 30);
            var back = FloatImage.from_texture(tex, false);
            double tol = depth == 8 ? 0.5 / 255.0 + 1e-6 : 1.0 / 65535.0 + 1e-6;
            for (int y = 0; y < 30; y++) for (int x = 0; x < 40; x++) {
                float r, g, b, a, r2, g2, b2, a2;
                img.get_pixel(x, y, out r, out g, out b, out a);
                back.get_pixel(x, y, out r2, out g2, out b2, out a2);
                near(r2, r, tol, "png r");
                near(g2, g, tol, "png g");
                near(b2, b, tol, "png b");
            }
            var got_icc = IccExtract.from_png(data);
            assert(got_icc != null && got_icc.length == icc.length);
            assert(Memory.cmp(got_icc, icc, icc.length) == 0);
            bool has_exif = false;
            for (int i = 0; i + 4 < data.length; i++) if (data[i] == 'e' && data[i + 1] == 'X' && data[i + 2] == 'I' && data[i + 3] == 'f') has_exif = true;
            assert(has_exif);
        } catch (Error e) {
            stderr.printf("%s\n", e.message);
            assert_not_reached();
        }
    }
}

private void test_jpeg() {
    var img = gradient(64, 48);
    var icc = IccProfile.adobe_rgb().to_data();
    var meta = EmbeddedMetadata.build(sample_meta(), "all", 64, 48, 240);
    try {
        var data = ImageWriters.encode_jpeg(img, 95, icc, meta.exif_tiff, meta.xmp, 240);
        assert(data[0] == 0xFF && data[1] == 0xD8);
        string p = path("rt.jpg");
        FileUtils.set_data(p, data);
        var back = FloatImage.from_texture(Gdk.Texture.from_filename(p), false);
        double err = 0;
        for (size_t i = 0; i < back.pixel_count(); i++) for (int c = 0; c < 3; c++) err += (back.data[i * 4 + c] - img.data[i * 4 + c]).abs();
        err /= back.pixel_count() * 3;
        assert(err < 0.02);
        var got_icc = IccExtract.from_jpeg(data);
        assert(got_icc != null && got_icc.length == icc.length);
        int app1 = -1;
        for (int i = 2; i + 10 < data.length; i++) {
            if (data[i] == 0xFF && data[i + 1] == 0xE1 && data[i + 4] == 'E' && data[i + 5] == 'x' && data[i + 6] == 'i' && data[i + 7] == 'f') {
                app1 = i;
                break;
            }
        }
        assert(app1 > 0);
        uint8[] tiff = data[app1 + 10:data.length];
        assert(exif_ascii(tiff, le32(tiff, 4), 0x0110) == "Canon EOS R5");
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
}

private void test_tiff() {
    var img = gradient(33, 21, true);
    img.set_pixel(1, 1, 3.5f, -0.25f, 0.5f, 1.0f);
    var icc = IccProfile.prophoto().to_data();
    foreach (int depth in new int[] { 8, 16, 32 }) {
        var r = new WriteRequest(img);
        r.format = "tiff";
        r.bit_depth = depth;
        r.icc = icc;
        r.xmp = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>";
        string p = path("rt-%d.tif".printf(depth));
        try {
            ImageWriters.write(r, p);
        } catch (Error e) {
            stderr.printf("%s\n", e.message);
            assert_not_reached();
        }
        int w, h, bits;
        bool is_float;
        float[] px;
        uint8[] got_icc;
        assert(NativeCodecs.tiff_read(p, out w, out h, out bits, out is_float, out px, out got_icc));
        assert(w == 33 && h == 21 && bits == depth && is_float == (depth == 32));
        assert(got_icc.length == icc.length);
        double tol = depth == 8 ? 0.5 / 255 + 1e-6 : depth == 16 ? 0.5 / 65535 + 1e-6 : 1e-7;
        for (size_t i = 0; i < img.data.length; i++) {
            double want = depth == 32 ? img.data[i] : img.data[i].clamp(0, 1);
            near(px[i], want, tol, "tiff");
        }
    }
}

private void test_webp() {
    var img = gradient(30, 20, true);
    var r = new WriteRequest(img);
    r.format = "webp";
    r.lossless = true;
    r.icc = IccProfile.srgb().to_data();
    r.exif = new ExifBuilder.from_metadata(sample_meta(), 30, 20, 72, true, true, true).build_tiff();
    string p = path("rt.webp");
    try {
        ImageWriters.write(r, p);
        uint8[] data;
        FileUtils.get_data(p, out data);
        int w, h;
        uint8[] px, icc;
        assert(NativeCodecs.webp_decode(data, out w, out h, out px, out icc));
        assert(w == 30 && h == 20 && icc.length == r.icc.length);
        var expect = img.to_rgba8(false);
        for (int i = 0; i < expect.length; i++) assert(((int) px[i] - (int) expect[i]).abs() <= 1 || expect[(i / 4) * 4 + 3] == 0);
        var photo = Codecs.load(File.new_for_path(p));
        assert(photo.format == "webp" && photo.image.width == 30);
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
}

private FloatImage smooth(int w, int h) {
    var img = new FloatImage(w, h);
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            img.set_pixel(x, y, 0.2f + 0.6f * x / w, 0.3f + 0.4f * y / h, 0.5f, 1.0f);
    return img;
}

private void test_avif_heic() {
    var img = smooth(64, 48);
    foreach (string fmt in new string[] { "avif", "heif" }) {
        bool avif = fmt == "avif";
        if (!NativeCodecs.heif_can_encode(avif)) {
            stdout.printf("# %s encoder not available on this system\n", fmt);
            assert(ExportFormat.find(fmt).available() == false);
            continue;
        }
        var r = new WriteRequest(img);
        r.format = fmt;
        r.bit_depth = 10;
        r.quality = 95;
        r.icc = IccProfile.display_p3().to_data();
        string p = path("rt." + (avif ? "avif" : "heic"));
        try {
            ImageWriters.write(r, p);
            int w, h;
            float[] px;
            uint8[] icc;
            string? error;
            assert(NativeCodecs.heif_decode(p, out w, out h, out px, out icc, out error));
            assert(w == 64 && h == 48);
            assert(icc.length == r.icc.length);
            double err = 0;
            for (size_t i = 0; i < img.pixel_count(); i++) for (int c = 0; c < 3; c++) err += (px[i * 4 + c] - img.data[i * 4 + c]).abs();
            err /= img.pixel_count() * 3;
            stdout.printf("# %s mean error %f\n", fmt, err);
            assert(err < 0.02);
            var photo = Codecs.load(File.new_for_path(p));
            assert(photo.image.width == 64);
        } catch (Error e) {
            stderr.printf("%s\n", e.message);
            assert_not_reached();
        }
    }
}

private void test_jxl() {
    if (!NativeCodecs.jxl_available()) {
        stdout.printf("# libjxl not available on this system\n");
        return;
    }
    var img = gradient(40, 24, true);
    var r = new WriteRequest(img);
    r.format = "jxl";
    r.bit_depth = 16;
    r.lossless = true;
    r.icc = IccProfile.srgb().to_data();
    string p = path("rt.jxl");
    try {
        ImageWriters.write(r, p);
        int w, h;
        float[] px;
        uint8[] icc;
        string? error;
        assert(NativeCodecs.jxl_decode(p, out w, out h, out px, out icc, out error));
        assert(w == 40 && h == 24);
        assert(icc.length > 0);
        for (size_t i = 0; i < img.data.length; i++) near(px[i], img.data[i], 1.0 / 65535 + 1e-5, "jxl");
        r.lossless = false;
        r.quality = 90;
        r.bit_depth = 8;
        ImageWriters.write(r, path("lossy.jxl"));
        assert(NativeCodecs.jxl_decode(path("lossy.jxl"), out w, out h, out px, out icc, out error));
        assert(w == 40);
        var photo = Codecs.load(File.new_for_path(p));
        assert(photo.format == "jxl");
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
}

private void test_settings_json() {
    var s = new ExportSettings();
    s.name = "Mine";
    s.format = "tiff";
    s.bit_depth = 16;
    s.watermark = true;
    s.watermark_text = "© Ada";
    s.resize = "megapixels";
    s.megapixels = 6.5;
    try {
        var back = ExportSettings.from_json(s.to_json());
        assert(back.format == "tiff" && back.bit_depth == 16 && back.watermark && back.watermark_text == "© Ada");
        near(back.megapixels, 6.5, 1e-9);
        Environment.set_variable("SINGULARITY_PHOTOS_PRESET_DIR", path("presets"), true);
        var saved = ExportPresets.save(s);
        assert(saved.id == "user-mine");
        var found = ExportPresets.find("user-mine");
        assert(found != null && found.settings.bit_depth == 16);
        assert(ExportPresets.find("web") != null && ExportPresets.find("web").builtin);
        ExportPresets.remove("user-mine");
        assert(ExportPresets.find("user-mine") == null);
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
}

private void test_sizes_and_names() {
    var s = new ExportSettings();
    int w, h;
    s.resize = "long";
    s.resize_width = 1000;
    ExportEngine.target_size(s, 4000, 3000, out w, out h);
    assert(w == 1000 && h == 750);
    s.resize = "short";
    ExportEngine.target_size(s, 4000, 3000, out w, out h);
    assert(w == 1333 && h == 1000);
    s.resize = "megapixels";
    s.megapixels = 3;
    ExportEngine.target_size(s, 4000, 3000, out w, out h);
    assert(w == 2000 && h == 1500);
    s.resize = "percent";
    s.percent = 200;
    ExportEngine.target_size(s, 400, 300, out w, out h);
    assert(w == 400 && h == 300);
    s.no_enlarge = false;
    ExportEngine.target_size(s, 400, 300, out w, out h);
    assert(w == 800 && h == 600);
    s.resize = "dimensions";
    s.resize_width = 500;
    s.resize_height = 500;
    ExportEngine.target_size(s, 4000, 3000, out w, out h);
    assert(w == 500 && h == 375);
    var m = sample_meta();
    string n = ExportEngine.expand_name("{date}_{camera}_{seq:4}_{name}", File.new_for_path("/x/IMG_1.CR3"), m, 7, 20);
    assert(n == "2026-05-17_Canon EOS R5_0007_IMG_1");
    assert(ExportEngine.expand_name("a/b:{name}", File.new_for_path("/x/p.jpg"), m, 1, 1) == "a_b_p");
}

private void test_export_engine() {
    var src = gradient(200, 100);
    string source_path = path("source.png");
    try {
        FileUtils.set_data(source_path, ImageWriters.encode_png(src, 8, new uint8[0], new uint8[0], "", 72));
    } catch (Error e) {
        assert_not_reached();
    }
    var s = new ExportSettings();
    s.format = "jpeg";
    s.resize = "long";
    s.resize_width = 80;
    s.sharpen = "screen";
    s.watermark = true;
    s.watermark_text = "Photos";
    s.naming = "{name}-web";
    s.destination = "folder";
    s.folder = path("out");
    s.subfolder = "2026";
    int calls = 0;
    var files = new File[] { File.new_for_path(source_path) };
    var results = ExportEngine.run(files, s, null, (d, t, f) => calls++);
    assert(results.size == 1 && results[0].ok);
    assert(results[0].target.get_path() == path("out/2026/source-web.jpg"));
    assert(calls >= 2);
    try {
        var tex = Gdk.Texture.from_file(results[0].target);
        assert(tex.get_width() == 80 && tex.get_height() == 40);
    } catch (Error e) {
        assert_not_reached();
    }
    var again = ExportEngine.run(files, s);
    assert(again[0].ok && again[0].target.get_basename() == "source-web-2.jpg");
    s.conflict = "skip";
    var skipped = ExportEngine.run(files, s);
    assert(skipped[0].skipped && !skipped[0].ok);
    s.conflict = "overwrite";
    s.format = "exr";
    s.bit_depth = 32;
    s.color_space = "linear-rec2020";
    s.watermark = false;
    s.sharpen = "none";
    s.resize = "none";
    var exr = ExportEngine.run(files, s);
    assert(exr[0].ok);
    try {
        var photo = Codecs.load(exr[0].target);
        var direct = Codecs.load(File.new_for_path(source_path));
        assert(photo.image.width == 200);
        for (size_t i = 0; i < photo.image.data.length; i += 97) near(photo.image.data[i], direct.image.data[i], 1e-4, "exr export");
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    s.format = "dng";
    s.bit_depth = 32;
    var dng = ExportEngine.run(files, s);
    assert(dng[0].ok && dng[0].target.get_basename().has_suffix(".dng"));
    try {
        var photo = Codecs.load(dng[0].target);
        var direct = Codecs.load(File.new_for_path(source_path));
        assert(photo.image.width == 200 && photo.image.height == 100);
        double err = 0;
        for (size_t i = 0; i < photo.image.pixel_count(); i++) for (int c = 0; c < 3; c++) err += (photo.image.data[i * 4 + c] - direct.image.data[i * 4 + c]).abs();
        err /= photo.image.pixel_count() * 3;
        stdout.printf("# dng mean error %f\n", err);
        assert(err < 0.01);
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    var bad = ExportEngine.run(new File[] { File.new_for_path(path("missing.png")) }, s);
    assert(!bad[0].ok && bad[0].error != "");
}

int main(string[] args) {
    Test.init(ref args);
    try {
        tmp_dir = DirUtils.make_tmp("photos-output-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Test.add_func("/output/exif", test_exif_builder);
    Test.add_func("/output/half", test_half);
    Test.add_func("/output/exr", test_exr_roundtrip);
    Test.add_func("/output/png", test_png);
    Test.add_func("/output/jpeg", test_jpeg);
    Test.add_func("/output/tiff", test_tiff);
    Test.add_func("/output/webp", test_webp);
    Test.add_func("/output/heif", test_avif_heic);
    Test.add_func("/output/jxl", test_jxl);
    Test.add_func("/output/settings", test_settings_json);
    Test.add_func("/output/names", test_sizes_and_names);
    Test.add_func("/output/export", test_export_engine);
    return Test.run();
}
