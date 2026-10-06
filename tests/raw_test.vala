using Singularity.Apps.Photos;
using Singularity.Imaging;

private string tmp_dir;

private void near(double got, double want, double tolerance, string what = "") {
    if ((got - want).abs() > tolerance) {
        stderr.printf("%s: got %f want %f\n", what, got, want);
        assert_not_reached();
    }
}

private FloatImage scene(int w, int h) {
    var img = new FloatImage(w, h);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            double fx = (double) x / w, fy = (double) y / h;
            float r = (float) (0.15 + 0.6 * fx);
            float g = (float) (0.2 + 0.5 * fy);
            float b = (float) (0.1 + 0.4 * (1 - fx) * fy + 0.2 * Math.sin(fx * 6));
            if (x > w / 2 && y > h / 3 && y < h / 3 + h / 6) {
                r = 0.8f;
                g = 0.3f;
                b = 0.1f;
            }
            img.set_pixel(x, y, r, g, b.clamp(0, 1));
        }
    }
    return img;
}

private float[] mosaic(FloatImage img, CfaPattern p) {
    var cfa = new float[img.pixel_count()];
    for (int y = 0; y < img.height; y++)
        for (int x = 0; x < img.width; x++)
            cfa[(size_t) y * img.width + x] = img.data[img.offset(x, y) + p.at(x, y)];
    return cfa;
}

private double mean_error(FloatImage a, FloatImage b, int border) {
    double e = 0;
    int n = 0;
    for (int y = border; y < a.height - border; y++) {
        for (int x = border; x < a.width - border; x++) {
            for (int c = 0; c < 3; c++) e += (a.data[a.offset(x, y) + c] - b.data[b.offset(x, y) + c]).abs();
            n += 3;
        }
    }
    return e / n;
}

private void test_ljpeg_roundtrip() {
    foreach (int comps in new int[] { 1, 2, 3 }) {
        int w = 37, h = 23;
        var samples = new uint16[w * h * comps];
        uint32 seed = 7;
        for (int i = 0; i < samples.length; i++) {
            seed = seed * 1103515245 + 12345;
            samples[i] = (uint16) (i % 5 == 0 ? (seed >> 8) & 0xFFFF : (1000 + i * 3 + (seed >> 20) % 64));
        }
        samples[0] = 65535;
        samples[1] = 0;
        var encoded = Ljpeg.encode(samples, w, h, comps, 16);
        int dw, dh, dc;
        uint16[] decoded;
        try {
            decoded = Ljpeg.decode(encoded, 0, encoded.length, out dw, out dh, out dc);
        } catch (Error e) {
            stderr.printf("%s\n", e.message);
            assert_not_reached();
        }
        assert(dw == w && dh == h && dc == comps);
        for (int i = 0; i < samples.length; i++) assert(decoded[i] == samples[i]);
    }
}

private void test_demosaic() {
    var src = scene(96, 64);
    var pat = new CfaPattern.bayer("RGGB");
    var cfa = mosaic(src, pat);
    var bil = Demosaic.bilinear(cfa, 96, 64, pat);
    var ppg = Demosaic.run(cfa, 96, 64, pat, "ppg");
    double eb = mean_error(src, bil, 3), ep = mean_error(src, ppg, 3);
    stdout.printf("# demosaic mean error bilinear %.5f ppg %.5f\n", eb, ep);
    assert(eb < 0.02);
    assert(ep < 0.02);
    var edges = new FloatImage(96, 64);
    for (int y = 0; y < 64; y++)
        for (int x = 0; x < 96; x++) {
            double dx = x - 48.3, dy = y - 31.7;
            float l = (Math.sqrt(dx * dx + dy * dy) < 20 ? 0.8f : 0.15f) + ((x / 7) % 2 == 0 ? 0.05f : 0.0f);
            edges.set_pixel(x, y, l * 0.9f, l, l * 0.6f);
        }
    var ecfa = mosaic(edges, pat);
    double eeb = mean_error(edges, Demosaic.bilinear(ecfa, 96, 64, pat), 3);
    double eep = mean_error(edges, Demosaic.run(ecfa, 96, 64, pat, "ppg"), 3);
    stdout.printf("# demosaic edges bilinear %.5f ppg %.5f\n", eeb, eep);
    assert(eep < eeb);
    foreach (string name in new string[] { "BGGR", "GRBG", "GBRG" }) {
        var p2 = new CfaPattern.bayer(name);
        var out_img = Demosaic.run(mosaic(src, p2), 96, 64, p2, "ppg");
        assert(mean_error(src, out_img, 3) < 0.02);
    }
    var x = new CfaPattern();
    x.width = 6;
    x.height = 6;
    x.colors = { 1, 1, 0, 1, 1, 2, 1, 1, 2, 1, 1, 0, 2, 0, 1, 0, 2, 1, 1, 1, 2, 1, 1, 0, 1, 1, 0, 1, 1, 2, 0, 2, 1, 2, 0, 1 };
    var xt = Demosaic.run(mosaic(src, x), 96, 64, x, "ppg");
    assert(mean_error(src, xt, 4) < 0.03);
}

private void test_white_balance() {
    var raw = new DngRawData(new FloatImage(4, 4));
    raw.color_matrix1 = Matrix3.invert(Primaries.rec709().to_xyz());
    raw.temperature1 = 6504;
    raw.xyz_to_camera = raw.color_matrix1;
    double r, g, b;
    double d65t, d65tint;
    RawColor.temperature_for(raw, 1, 1, 1, out d65t, out d65tint);
    stdout.printf("# D65 neutral reads as %.0f K tint %.1f\n", d65t, d65tint);
    near(d65t, 6504, 150, "D65 temperature");
    assert(d65tint > 0 && d65tint < 20);
    RawColor.multipliers_at(raw, d65t, d65tint, out r, out g, out b);
    near(r, 1, 0.01, "D65 r");
    near(b, 1, 0.01, "D65 b");
    double r3, g3, b3, r8, g8, b8;
    RawColor.multipliers_at(raw, 3000, 0, out r3, out g3, out b3);
    RawColor.multipliers_at(raw, 8000, 0, out r8, out g8, out b8);
    assert(b3 > b8);
    assert(r3 < r8);
    double rm, gm, bm;
    RawColor.multipliers_at(raw, 5000, 30, out rm, out gm, out bm);
    double rn, gn, bn;
    RawColor.multipliers_at(raw, 5000, 0, out rn, out gn, out bn);
    assert(rm / gm > rn / gn);
    foreach (double t in new double[] { 2500, 3200, 4300, 5500, 7000, 9500, 15000 }) {
        foreach (double tint in new double[] { -40, 0, 25 }) {
            RawColor.multipliers_at(raw, t, tint, out r, out g, out b);
            double et, etint;
            RawColor.temperature_for(raw, r, g, b, out et, out etint);
            near(et, t, t * 0.02, "temperature");
            near(etint, tint, 2.0, "tint");
        }
    }
    raw.as_shot_multipliers = { 2.0, 1.0, 1.5 };
    RawColor.multipliers_for(raw, "as-shot", 0, 0, out r, out g, out b);
    near(r, 2.0, 1e-9);
    near(b, 1.5, 1e-9);
    RawColor.multipliers_for(raw, "tungsten", 0, 0, out r, out g, out b);
    RawColor.multipliers_at(raw, 2850, 0, out r3, out g3, out b3);
    near(r, r3, 1e-9);
}

private void test_develop_neutral() {
    var camera = new FloatImage.filled(8, 8, 0.25f, 0.5f, 0.4f);
    var raw = new DngRawData(camera);
    raw.color_matrix1 = Matrix3.invert(Primaries.rec709().to_xyz());
    raw.temperature1 = 6504;
    raw.xyz_to_camera = raw.color_matrix1;
    var img = RawColor.develop(raw, 2.0, 1.0, 1.25, "clip");
    float cr, cg, cb, ca;
    img.get_pixel(3, 3, out cr, out cg, out cb, out ca);
    near(cr, cg, 1e-3, "neutral r");
    near(cb, cg, 1e-3, "neutral b");
    near(cg, 0.5, 0.02, "neutral level");
}

private void test_highlights() {
    var camera = new FloatImage.filled(64, 64, 0.2f, 0.4f, 0.3f);
    for (int y = 20; y < 40; y++)
        for (int x = 20; x < 40; x++)
            camera.set_pixel(x, y, 0.5f, 1.0f, 0.75f);
    var img = camera.copy();
    RawColor.reconstruct_highlights(img, { 1.0f, 1.0f, 1.0f }, "reconstruct");
    float r, g, b, a;
    img.get_pixel(30, 30, out r, out g, out b, out a);
    assert(g >= 1.0f);
    near(r / g, 0.5, 0.05, "recovered ratio r");
    near(b / g, 0.75, 0.05, "recovered ratio b");
    var clip = camera.copy();
    RawColor.reconstruct_highlights(clip, { 0.9f, 1.0f, 1.0f }, "clip");
    clip.get_pixel(30, 30, out r, out g, out b, out a);
    near(g, 0.9, 1e-6);
    var blend = camera.copy();
    RawColor.reconstruct_highlights(blend, { 1.0f, 1.0f, 1.0f }, "blend");
    blend.get_pixel(30, 30, out r, out g, out b, out a);
    assert(r > 0.5f && b > 0.75f);
}

private string write_fixture(string name, uint8[] data) {
    string path = Path.build_filename(tmp_dir, name);
    try {
        FileUtils.set_data(path, data);
    } catch (Error e) {
        assert_not_reached();
    }
    return path;
}

private void test_dng_cfa(bool ljpeg) {
    int w = 128, h = 96;
    var src = scene(w, h);
    var pat = new CfaPattern.bayer("RGGB");
    var cfa = mosaic(src, pat);
    double[] cm = Matrix3.invert(Primaries.rec709().to_xyz());
    var meta = new PhotoMetadata();
    meta.make = "Singularity";
    meta.model = "Test Body";
    var bytes = DngWriter.cfa_bytes(cfa, w, h, "RGGB", cm, { 0.5, 1.0, 0.8 }, ljpeg, meta, 512, 16383);
    string path = write_fixture(ljpeg ? "cfa-ljpeg.dng" : "cfa.dng", bytes);
    var dec = new DngDecoder();
    assert(dec.handles("cfa.dng", bytes[0:8]));
    DecodedPhoto photo;
    try {
        photo = dec.decode(File.new_for_path(path), 0);
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    assert(photo.is_raw());
    assert(photo.image.width == w && photo.image.height == h);
    var raw = (DngRawData) photo.raw;
    near(raw.as_shot_multipliers[0], 2.0, 1e-6);
    near(raw.as_shot_multipliers[2], 1.25, 1e-6);
    assert(raw.cfa_pattern == "RGGB");
    assert(raw.camera_model == "Singularity Test CFA");
    double err = mean_error(src, raw.camera, 3);
    stdout.printf("# dng %s camera error %.5f\n", ljpeg ? "ljpeg" : "plain", err);
    assert(err < 0.02);
    assert(photo.meta.make == "Singularity");
    DecodedPhoto half;
    try {
        half = dec.decode(File.new_for_path(path), 48);
    } catch (Error e) {
        assert_not_reached();
    }
    assert(int.max(half.image.width, half.image.height) <= 48);
    assert(half.full_width == w);
    if (LibRawDecoder.available()) {
        DecodedPhoto lr;
        try {
            lr = new LibRawDecoder().decode(File.new_for_path(path), 0);
        } catch (Error e) {
            stderr.printf("libraw: %s\n", e.message);
            assert_not_reached();
        }
        var lraw = (DngRawData) lr.raw;
        stdout.printf("# libraw %s size %dx%d mul %.3f %.3f\n", LibRawDecoder.version(), lraw.camera.width, lraw.camera.height, lraw.as_shot_multipliers[0], lraw.as_shot_multipliers[2]);
        assert(lraw.camera.width == w && lraw.camera.height == h);
        near(lraw.as_shot_multipliers[0], 2.0, 0.01, "libraw r mul");
        near(lraw.as_shot_multipliers[2], 1.25, 0.01, "libraw b mul");
        double le = mean_error(raw.camera, lraw.camera, 4);
        stdout.printf("# libraw vs own camera error %.5f\n", le);
        assert(le < 0.02);
        double we = mean_error(photo.image, lr.image, 4);
        stdout.printf("# libraw vs own working error %.5f\n", we);
        assert(we < 0.03);
    } else {
        stdout.printf("# libraw not available, skipped comparison\n");
    }
}

private void test_dng_cfa_plain() {
    test_dng_cfa(false);
}

private void test_dng_cfa_ljpeg() {
    test_dng_cfa(true);
}

private void test_dng_linear() {
    var src = scene(40, 30);
    src.set_pixel(5, 5, 3.5f, 2.0f, 0.25f);
    foreach (bool f32 in new bool[] { true, false }) {
        var bytes = DngWriter.linear_bytes(src, null, f32);
        string path = write_fixture(f32 ? "linear32.dng" : "linear16.dng", bytes);
        DecodedPhoto photo;
        try {
            photo = new DngDecoder().decode(File.new_for_path(path), 0);
        } catch (Error e) {
            stderr.printf("%s\n", e.message);
            assert_not_reached();
        }
        assert(photo.raw.cfa_pattern == "linear");
        double err = mean_error(src, photo.image, 0);
        stdout.printf("# linear dng %s error %.6f\n", f32 ? "float" : "16-bit", err);
        if (f32) {
            assert(err < 2e-4);
            float r, g, b, a;
            photo.image.get_pixel(5, 5, out r, out g, out b, out a);
            near(r, 3.5, 2e-3, "hdr value survives");
        } else {
            assert(err < 3e-3);
        }
        if (LibRawDecoder.available() && !f32) {
            try {
                var lr = new LibRawDecoder().decode(File.new_for_path(path), 0);
                double le = mean_error(photo.raw.camera, lr.raw.camera, 0);
                stdout.printf("# libraw linear dng error %.5f\n", le);
                assert(le < 0.01);
            } catch (Error e) {
                stdout.printf("# libraw linear dng: %s\n", e.message);
            }
        }
    }
}

private void put_be32(ByteArray b, uint32 v) {
    b.append({ (uint8) (v >> 24), (uint8) (v >> 16), (uint8) (v >> 8), (uint8) v });
}

private void put_be64(ByteArray b, double d) {
    uint64 bits = *((uint64*) (&d));
    put_be32(b, (uint32) (bits >> 32));
    put_be32(b, (uint32) bits);
}

private void test_dng_opcode_vignette() {
    int w = 41, h = 31;
    var t = new TiffWriter();
    t.set_long(254, { 0 });
    t.set_byte(50706, { 1, 4, 0, 0 });
    t.set_long(256, { (uint32) w });
    t.set_long(257, { (uint32) h });
    t.set_short(258, { 16, 16, 16 });
    t.set_short(259, { 1 });
    t.set_short(262, { 34892 });
    t.set_short(277, { 3 });
    var buf = new uint8[w * h * 6];
    for (int i = 0; i < w * h * 3; i++) {
        buf[i * 2] = 0xFF;
        buf[i * 2 + 1] = 0x7F;
    }
    t.set_strip((owned) buf);
    t.set_long(50717, { 65535 });
    t.set_srational(50721, DngWriter.xyz_to_working());
    t.set_rational(50728, { 1.0, 1.0, 1.0 });
    var ops = new ByteArray();
    put_be32(ops, 1);
    put_be32(ops, 3);
    put_be32(ops, 0x01030000);
    put_be32(ops, 0);
    put_be32(ops, 56);
    foreach (double k in new double[] { -0.5, 0, 0, 0, 0, 0.5, 0.5 }) put_be64(ops, k);
    t.set_undefined(51022, ops.steal());
    string path = write_fixture("opcode.dng", t.build());
    DecodedPhoto photo;
    try {
        photo = new DngDecoder().decode(File.new_for_path(path), 0);
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    float r, g, b, a, cr, cg, cb, ca;
    photo.raw.camera.get_pixel(20, 15, out cr, out cg, out cb, out ca);
    photo.raw.camera.get_pixel(0, 0, out r, out g, out b, out a);
    near(cg, 0.5, 0.01, "center unchanged");
    near(g, 0.5 * (1 - 0.5 * 0.95), 0.03, "corner gain");
}

private void test_codecs_dispatch() {
    var bytes = DngWriter.linear_bytes(scene(8, 8), null, true);
    string path = write_fixture("dispatch.dng", bytes);
    try {
        var photo = Codecs.load(File.new_for_path(path));
        assert(photo.format == "dng");
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    assert(Codecs.is_raw_name("IMG_0001.CR3"));
    var lr = new LibRawDecoder();
    assert(lr.handles("a.nef", new uint8[0]));
    if (!LibRawDecoder.available()) {
        try {
            lr.decode(File.new_for_path(path), 0);
            assert_not_reached();
        } catch (Error e) {
        }
    }
}

private void test_lens() {
    var m = new LensModel();
    near(m.distort(0.7), 0.7, 1e-12);
    m.distortion_model = "poly3";
    m.distortion = { 0.05 };
    near(m.distort(1.0), 1.0, 1e-12);
    assert(m.distort(0.5) < 0.5);
    string xml = """<lensdatabase version="1">
<lens><maker>Canon</maker><model>Canon EF-S 18-135mm f/3.5-5.6 IS STM</model><mount>Canon EF-S</mount><cropfactor>1.611</cropfactor>
<calibration>
<distortion model="ptlens" focal="18" a="0.01" b="-0.05" c="0"/>
<distortion model="ptlens" focal="135" a="0" b="0.01" c="0"/>
<tca model="linear" focal="18" kr="1.0003" kb="0.9998"/>
<vignetting model="pa" focal="18" aperture="3.5" distance="10" k1="-0.5" k2="0.1" k3="0"/>
<vignetting model="pa" focal="18" aperture="8" distance="10" k1="-0.2" k2="0" k3="0"/>
</calibration></lens></lensdatabase>""";
    var list = LensDatabase.parse(xml);
    assert(list.size == 1);
    LensDatabase.add_profiles(list);
    var found = LensDatabase.find("EF-S18-135mm f/3.5-5.6 IS STM", "Canon");
    assert(found != null);
    var d = found.interpolate("distortion", 76.5);
    near(d[1], (-0.05 + 0.01) / 2, 1e-9);
    var v = found.interpolate("vignetting", 18, 8);
    near(v[0], -0.2, 1e-9);
    var img = new FloatImage(81, 61);
    var vm = new LensModel();
    vm.vignetting = { -0.5, 0.1, 0 };
    double cx = 40.5, cy = 30.5, hd = Math.sqrt(cx * cx + cy * cy);
    for (int y = 0; y < 61; y++)
        for (int x = 0; x < 81; x++) {
            double dx = (x + 0.5 - cx) / hd, dy = (y + 0.5 - cy) / hd;
            double r2 = dx * dx + dy * dy;
            float c = (float) (0.5 * (1 - 0.5 * r2 + 0.1 * r2 * r2));
            img.set_pixel(x, y, c, c, c);
        }
    var fixed = LensCorrection.apply_model(img, vm);
    float r, g, b, a;
    fixed.get_pixel(0, 0, out r, out g, out b, out a);
    near(r, 0.5, 1e-3, "vignetting corner");
    var meta = new PhotoMetadata();
    meta.make = "Canon";
    meta.lens = "EF-S18-135mm f/3.5-5.6 IS STM";
    meta.focal_length = 18;
    meta.aperture = 3.5;
    var settings = new DevelopSettings();
    assert(!LensCorrection.needed(settings));
    settings.set("lens.profile", 1);
    assert(LensCorrection.needed(settings));
    var model = LensCorrection.model_for(settings, meta);
    assert(model.distortion_model == "ptlens");
    near(model.vignetting[0], -0.5, 1e-9);
    var ids = LensCorrection.find_profiles(meta);
    assert(ids.length >= 1 && ids[0] == found.id());
    var grid = new FloatImage.filled(64, 64, 0.5f, 0.5f, 0.5f);
    settings.set("lens.ca.red", 1.0);
    var ca = LensCorrection.apply(grid, settings, meta);
    assert(ca.width == 64);
}

private void test_dcp() {
    var t = new TiffWriter();
    t.set_ascii(50708, "Test Body");
    t.set_srational(50721, Matrix3.invert(Primaries.rec709().to_xyz()));
    t.set_short(50778, { 21 });
    t.set_ascii(50936, "Test Standard");
    var bytes = t.build();
    bytes[2] = 0x52;
    bytes[3] = 0x43;
    DcpProfile p;
    try {
        p = DcpProfile.parse(bytes);
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    assert(p.name == "Test Standard");
    assert(p.camera_model == "Test Body");
    near(p.temperature1, 6504, 1);
    assert(p.hue_sat_map1 == null);
}

private void test_dcp_float_map() {
    var fb = new ByteArray();
    for (int i = 0; i < 12; i++) {
        foreach (float f in new float[] { 30.0f, 1.0f, 1.0f }) {
            uint32 bits = *((uint32*) (&f));
            fb.append({ (uint8) bits, (uint8) (bits >> 8), (uint8) (bits >> 16), (uint8) (bits >> 24) });
        }
    }
    var data = fb.steal();
    var tagged = new TiffWriterFloat(data);
    DcpProfile p;
    try {
        p = DcpProfile.parse(tagged.bytes());
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    assert(p.hue_sat_map1 != null);
    var img = new FloatImage(1, 1);
    img.set_pixel(0, 0, 0.6f, 0.1f, 0.1f);
    var to_working = Primaries.conversion(Primaries.prophoto(), Primaries.rec2020());
    Matrix3.apply_image(to_working, img);
    p.apply_looks(img);
    Matrix3.apply_image(Matrix3.invert(to_working), img);
    float rr, gg, bb, aa;
    img.get_pixel(0, 0, out rr, out gg, out bb, out aa);
    assert(gg > 0.3f);
    near(bb, 0.1, 0.01, "hue shift keeps blue");
}

public class TiffWriterFloat : Object {
    private uint8[] map;

    public TiffWriterFloat(uint8[] map) {
        this.map = map;
    }

    private static void put16(ByteArray b, uint16 v) {
        b.append({ (uint8) v, (uint8) (v >> 8) });
    }

    private static void put32(ByteArray b, uint32 v) {
        b.append({ (uint8) v, (uint8) (v >> 8), (uint8) (v >> 16), (uint8) (v >> 24) });
    }

    public uint8[] bytes() {
        var matrix = Matrix3.invert(Primaries.rec709().to_xyz());
        var out_b = new ByteArray();
        out_b.append({ 'I', 'I', 0x52, 0x43 });
        put32(out_b, 8);
        int n = 3;
        uint32 data_start = 8 + 2 + n * 12 + 4;
        put16(out_b, (uint16) n);
        put16(out_b, 50721);
        put16(out_b, 10);
        put32(out_b, 9);
        put32(out_b, data_start);
        put16(out_b, 50937);
        put16(out_b, 4);
        put32(out_b, 3);
        put32(out_b, data_start + 72);
        put16(out_b, 50938);
        put16(out_b, 11);
        put32(out_b, map.length / 4);
        put32(out_b, data_start + 84);
        put32(out_b, 0);
        foreach (var v in matrix) {
            put32(out_b, (uint32) (int32) Math.round(v * 1000000));
            put32(out_b, 1000000);
        }
        put32(out_b, 6);
        put32(out_b, 2);
        put32(out_b, 1);
        out_b.append(map);
        return out_b.steal();
    }
}

int main(string[] args) {
    Test.init(ref args);
    try {
        tmp_dir = DirUtils.make_tmp("photos-raw-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Test.add_func("/raw/ljpeg", test_ljpeg_roundtrip);
    Test.add_func("/raw/demosaic", test_demosaic);
    Test.add_func("/raw/white-balance", test_white_balance);
    Test.add_func("/raw/develop-neutral", test_develop_neutral);
    Test.add_func("/raw/highlights", test_highlights);
    Test.add_func("/raw/dng-cfa", test_dng_cfa_plain);
    Test.add_func("/raw/dng-cfa-ljpeg", test_dng_cfa_ljpeg);
    Test.add_func("/raw/dng-linear", test_dng_linear);
    Test.add_func("/raw/codecs", test_codecs_dispatch);
    Test.add_func("/raw/dng-opcodes", test_dng_opcode_vignette);
    Test.add_func("/raw/lens", test_lens);
    Test.add_func("/raw/dcp", test_dcp);
    Test.add_func("/raw/dcp-map", test_dcp_float_map);
    int rc = Test.run();
    try {
        var dir = Dir.open(tmp_dir);
        string? name;
        while ((name = dir.read_name()) != null) FileUtils.remove(Path.build_filename(tmp_dir, name));
        DirUtils.remove(tmp_dir);
    } catch (Error e) {
    }
    return rc;
}
