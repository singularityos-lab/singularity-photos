using Singularity.Apps.Photos;
using Singularity.Imaging;

private void near(double got, double want, double tolerance) {
    if ((got - want).abs() > tolerance) {
        stderr.printf("got %f want %f (tolerance %f)\n", got, want, tolerance);
        assert_not_reached();
    }
}

private DecodedPhoto photo_from_srgb(int w, int h, uint8 r, uint8 g, uint8 b) {
    var px = new uint8[w * h * 4];
    for (int i = 0; i < w * h; i++) {
        px[i * 4] = r;
        px[i * 4 + 1] = g;
        px[i * 4 + 2] = b;
        px[i * 4 + 3] = 255;
    }
    return new DecodedPhoto(WorkingSpace.from_srgb8(px, w, h, w * 4, true));
}

private DecodedPhoto gradient_photo(int w, int h) {
    var px = new uint8[w * h * 4];
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int i = (y * w + x) * 4;
            px[i] = (uint8) ((x * 255) / int.max(1, w - 1));
            px[i + 1] = (uint8) ((y * 255) / int.max(1, h - 1));
            px[i + 2] = (uint8) (((x + y) * 97) % 256);
            px[i + 3] = 255;
        }
    }
    return new DecodedPhoto(WorkingSpace.from_srgb8(px, w, h, w * 4, true));
}

private void srgb_at(FloatImage working, int x, int y, out int r, out int g, out int b) {
    var enc = WorkingSpace.to_srgb_encoded(working.cropped(x, y, 1, 1));
    r = (int) Math.round(enc.data[0].clamp(0, 1) * 255);
    g = (int) Math.round(enc.data[1].clamp(0, 1) * 255);
    b = (int) Math.round(enc.data[2].clamp(0, 1) * 255);
}

private void test_identity() {
    var src = gradient_photo(37, 23);
    var out_img = DevelopPipeline.render(src, new EditParams(), new RenderOptions());
    assert(out_img.width == 37 && out_img.height == 23);
    for (int y = 0; y < 23; y += 3) {
        for (int x = 0; x < 37; x += 5) {
            int r, g, b, r0, g0, b0;
            srgb_at(out_img, x, y, out r, out g, out b);
            srgb_at(src.image, x, y, out r0, out g0, out b0);
            near(r, r0, 1);
            near(g, g0, 1);
            near(b, b0, 1);
        }
    }
}

private void test_exposure_linear() {
    var src = photo_from_srgb(4, 4, 100, 60, 30);
    var p = new EditParams();
    p.set_value(Adjustment.EXPOSURE, 0.5);
    var out_img = DevelopPipeline.render(src, p, new RenderOptions());
    for (int c = 0; c < 3; c++) near(out_img.data[c], src.image.data[c] * 2.0, 1e-4);
    p.set_value(Adjustment.EXPOSURE, 2.5);
    assert(p.get_value(Adjustment.EXPOSURE) == 2.5);
    p.set_value(Adjustment.EXPOSURE, 9);
    assert(p.get_value(Adjustment.EXPOSURE) == 2.5);
}

private void test_geometry() {
    var src = gradient_photo(40, 20);
    var p = new EditParams();
    p.rotate(1);
    var out_img = DevelopPipeline.render(src, p, new RenderOptions());
    assert(out_img.width == 20 && out_img.height == 40);
    var old_img = new EditImage(40, 20);
    for (int y = 0; y < 20; y++) for (int x = 0; x < 40; x++) old_img.set_pixel(x, y, (uint8) x, (uint8) y, 0);
    double sx, sy;
    var g = new GeometryMap(p, 40, 20, 0, true);
    g.map(3.5, 7.5, out sx, out sy);
    double ox, oy;
    EditPipeline.map_point(p, 40, 20, 3.5, 7.5, out ox, out oy);
    near(sx, ox, 1e-9);
    near(sy, oy, 1e-9);
    double bx, by;
    g.source_to_output(sx, sy, out bx, out by);
    near(bx, 3.5, 1e-6);
    near(by, 7.5, 1e-6);
    p = new EditParams();
    p.set_crop(0.25, 0.5, 0.5, 0.5);
    p.straighten = 5;
    out_img = DevelopPipeline.render(src, p, new RenderOptions());
    assert(out_img.width == 20 && out_img.height == 10);
    var preview = DevelopPipeline.render(src, p, new RenderOptions.preview(8));
    assert(preview.width == 8 && preview.height == 4);
    var g2 = new GeometryMap(p, 40, 20, 0, true);
    g2.map(4.2, 3.3, out sx, out sy);
    g2.source_to_output(sx, sy, out bx, out by);
    near(bx, 4.2, 1e-6);
    near(by, 3.3, 1e-6);
}

private void test_transform_homography() {
    var d = new DevelopSettings();
    assert(Matrix3Util.is_identity(DevelopPipeline.transform_homography(d, 100, 50)));
    d.set("transform.vertical", 0.5);
    var hm = DevelopPipeline.transform_homography(d, 100, 50);
    assert(!Matrix3Util.is_identity(hm));
    var fw = Upright.forward(0.5, 0, 0, 0, 1, 0, 0, 100, 50);
    double px = 30, py = 10;
    double fz = fw[6] * px + fw[7] * py + fw[8];
    double ox = (fw[0] * px + fw[1] * py + fw[2]) / fz, oy = (fw[3] * px + fw[4] * py + fw[5]) / fz;
    double bz = hm[6] * ox + hm[7] * oy + hm[8];
    near((hm[0] * ox + hm[1] * oy + hm[2]) / bz, px, 1e-6);
    near((hm[3] * ox + hm[4] * oy + hm[5]) / bz, py, 1e-6);
    double wt = hm[6] * 0 + hm[7] * 0 + hm[8];
    double wb = hm[6] * 0 + hm[7] * 50 + hm[8];
    assert(wt != wb);
    var p = new EditParams();
    p.develop.set("transform.rotate", 3);
    assert(p.has_geometry());
    var src = gradient_photo(30, 20);
    var out_img = DevelopPipeline.render(src, p, new RenderOptions());
    assert(out_img.width == 30 && out_img.height == 20);
}

private void test_curves() {
    var c = new CurvePoints();
    assert(c.is_identity());
    var lut = c.lut(256);
    near(lut[128], 128.0 / 255, 1e-6);
    c.add(0.25, 0.15);
    c.add(0.75, 0.85);
    lut = c.lut(1024);
    near(lut[(int) (0.25 * 1023)], 0.15, 0.01);
    near(lut[(int) (0.75 * 1023)], 0.85, 0.01);
    for (int i = 1; i < 1024; i++) assert(lut[i] >= lut[i - 1] - 1e-6);
    var d = new DevelopSettings();
    d.set("tone.shadows", 1);
    var pl = Tone.parametric_lut(d);
    assert(pl[100] > 100.0f / 1023);
    near(pl[0], 0, 1e-6);
    near(pl[1023], 1, 1e-6);
    for (int i = 1; i < 1024; i++) assert(pl[i] >= pl[i - 1]);
    for (int i = 1; i < 100; i++) {
        float e = i / 100.0f;
        assert(Tone.contrast_curve(e, 1) >= Tone.contrast_curve((i - 1) / 100.0f, 1));
        assert(Tone.contrast_curve(e, -1) >= Tone.contrast_curve((i - 1) / 100.0f, -1));
    }
    near(Tone.contrast_curve(0.5f, 1), 0.5, 1e-6);
    assert(Tone.contrast_curve(0.2f, 1) < 0.2f);
    assert(Tone.contrast_curve(0.2f, -1) > 0.2f);
}

private void test_hsl() {
    float h, s, l, r, g, b;
    Tone.rgb_to_hsl(1, 0.5f, 0, out h, out s, out l);
    near(h, 30, 1e-4);
    Tone.hsl_to_rgb(h, s, l, out r, out g, out b);
    near(r, 1, 1e-5);
    near(g, 0.5, 1e-5);
    near(b, 0, 1e-5);
    var weights = new float[8];
    Tone.band_weights(0, weights);
    near(weights[0], 1, 1e-5);
    Tone.band_weights(15, weights);
    near(weights[0] + weights[1], 1, 1e-5);
    near(weights[0], 0.5, 1e-5);
    var src = photo_from_srgb(2, 2, 220, 40, 40);
    var p = new EditParams();
    p.develop.set("hsl.hue.red", 1);
    var out_img = DevelopPipeline.render(src, p, new RenderOptions());
    int rr, gg, bb;
    srgb_at(out_img, 0, 0, out rr, out gg, out bb);
    float oh, os, ol;
    Tone.rgb_to_hsl(rr / 255.0f, gg / 255.0f, bb / 255.0f, out oh, out os, out ol);
    assert(oh > 15 && oh < 45);
    p = new EditParams();
    p.develop.set("hsl.sat.red", -1);
    out_img = DevelopPipeline.render(src, p, new RenderOptions());
    srgb_at(out_img, 0, 0, out rr, out gg, out bb);
    assert((rr - gg).abs() < (220 - 40) / 3);
    var gray = photo_from_srgb(2, 2, 128, 128, 128);
    p = new EditParams();
    p.develop.set("hsl.lum.red", 1);
    out_img = DevelopPipeline.render(gray, p, new RenderOptions());
    srgb_at(out_img, 0, 0, out rr, out gg, out bb);
    near(rr, 128, 1);
}

private void test_white_balance_and_grading() {
    var src = photo_from_srgb(2, 2, 128, 128, 128);
    var p = new EditParams();
    p.set_value(Adjustment.WARMTH, 0.6);
    var out_img = DevelopPipeline.render(src, p, new RenderOptions());
    int r, g, b;
    srgb_at(out_img, 0, 0, out r, out g, out b);
    assert(r > g && g > b);
    p = new EditParams();
    p.develop.set("grading.shadows.hue", 220);
    p.develop.set("grading.shadows.sat", 1);
    var dark = photo_from_srgb(2, 2, 40, 40, 40);
    out_img = DevelopPipeline.render(dark, p, new RenderOptions());
    srgb_at(out_img, 0, 0, out r, out g, out b);
    assert(b > r);
    var bright = photo_from_srgb(2, 2, 240, 240, 240);
    out_img = DevelopPipeline.render(bright, p, new RenderOptions());
    srgb_at(out_img, 0, 0, out r, out g, out b);
    near(b, r, 3);
}

private void test_masks() {
    var src = gradient_photo(64, 32);
    var p = new EditParams();
    var result = DevelopPipeline.render_full(src, p, new RenderOptions());
    var cache = new DevelopCache();
    var lin = new MaskComponent("linear");
    lin.s("x0", 0.0);
    lin.s("y0", 0.5);
    lin.s("x1", 1.0);
    lin.s("y1", 0.5);
    var m = Masks.component(lin, result.image, result.coords, result.geometry, cache);
    assert(m[16 * 64 + 1] > 0.95f);
    assert(m[16 * 64 + 62] < 0.05f);
    near(m[16 * 64 + 32], 0.5, 0.06);
    var rad = new MaskComponent("radial");
    rad.s("cx", 0.5);
    rad.s("cy", 0.5);
    rad.s("rx", 0.25);
    rad.s("ry", 0.25);
    rad.s("feather", 0.2);
    m = Masks.component(rad, result.image, result.coords, result.geometry, cache);
    assert(m[16 * 64 + 32] > 0.99f);
    assert(m[0] < 0.01f);
    rad.invert = true;
    m = Masks.component(rad, result.image, result.coords, result.geometry, cache);
    assert(m[16 * 64 + 32] < 0.01f);
    var brush = new MaskComponent("brush");
    var st = new BrushStroke();
    st.radius = 0.05;
    st.feather = 0;
    st.add_point(0.1, 0.5);
    st.add_point(0.9, 0.5);
    brush.strokes.add(st);
    m = Masks.component(brush, result.image, result.coords, result.geometry, cache);
    assert(m[16 * 64 + 32] > 0.9f);
    assert(m[2 * 64 + 32] < 0.1f);
    var lum = new MaskComponent("luminance");
    lum.s("low", 0.6);
    lum.s("high", 1.0);
    lum.s("feather", 0.05);
    m = Masks.component(lum, result.image, result.coords, result.geometry, cache);
    assert(m[0] < 0.05f);
    var local = new LocalAdjustment();
    local.components.add(rad.copy());
    local.components[0].invert = false;
    local.set("exposure", 1);
    p.locals.add(local);
    var out_img = DevelopPipeline.render(src, p, new RenderOptions());
    size_t center = out_img.offset(32, 16), corner = out_img.offset(0, 0);
    near(out_img.data[center] / src.image.data[center], 2.0, 0.05);
    near(out_img.data[corner + 1], src.image.data[corner + 1], 1e-5);
    var sub = new MaskComponent("all");
    sub.mode = "subtract";
    local.components.add(sub);
    out_img = DevelopPipeline.render(src, p, new RenderOptions());
    near(out_img.data[center], src.image.data[center], 1e-5);
}

private void test_rotated_mask_follows_image() {
    var src = gradient_photo(60, 40);
    var p = new EditParams();
    var local = new LocalAdjustment();
    var rad = new MaskComponent("radial");
    rad.s("cx", 0.25);
    rad.s("cy", 0.25);
    rad.s("rx", 0.08);
    rad.s("ry", 0.08);
    rad.s("feather", 0.1);
    local.components.add(rad);
    local.set("exposure", 1);
    p.locals.add(local);
    p.rotate(1);
    var res = DevelopPipeline.render_full(src, p, new RenderOptions());
    double ox, oy;
    res.geometry.source_to_output(0.25 * 60, 0.25 * 40, out ox, out oy);
    int x = (int) ox, y = (int) oy;
    var plain = DevelopPipeline.render(src, rotated_only(), new RenderOptions());
    size_t i = res.image.offset(x, y);
    near(res.image.data[i + 1] / plain.data[i + 1], 2.0, 0.08);
}

private EditParams rotated_only() {
    var p = new EditParams();
    p.rotate(1);
    return p;
}

private void test_json_v2() {
    var p = new EditParams();
    p.set_value(Adjustment.CLARITY, 0.4);
    p.develop.set("hsl.sat.blue", -0.3);
    p.develop.set_string("treatment", "bw");
    p.develop.curve("master").add(0.3, 0.2);
    var l = new LocalAdjustment();
    l.name = "Sky";
    l.set("exposure", -0.7);
    var c = new MaskComponent("linear");
    c.s("x0", 0.1);
    l.components.add(c);
    var bc = new MaskComponent("brush");
    var st = new BrushStroke();
    st.add_point(0.2, 0.3);
    bc.strokes.add(st);
    l.components.add(bc);
    p.locals.add(l);
    var sp = new SpotEdit();
    sp.x = 0.3;
    sp.mode = "clone";
    p.spots.add(sp);
    p.snapshots.add(new EditSnapshot("Before sky", p));
    string json = p.to_json(true);
    EditParams q;
    try {
        q = EditParams.from_json(json);
    } catch (Error e) {
        assert_not_reached();
    }
    assert(q.equals(p));
    assert(q.snapshots.size == 1 && q.snapshots[0].name == "Before sky");
    assert(q.snapshots[0].restore() != null);
    assert(q.locals[0].components[1].strokes[0].points.length == 2);
    assert(q.develop.get_string("treatment") == "bw");
    q.develop.set("hsl.sat.blue", 0);
    assert(!q.equals(p));
    try {
        var v1 = EditParams.from_json("{\"version\":1,\"rotation\":90,\"adjust\":{\"exposure\":0.25},\"filter\":\"vivid\"}");
        assert(v1.quarter_turns == 1);
        near(v1.get_value(Adjustment.EXPOSURE), 0.25, 1e-9);
        assert(v1.filter == "vivid");
    } catch (Error e) {
        assert_not_reached();
    }
    try {
        EditParams.from_json("{\"version\":99}");
        assert_not_reached();
    } catch (Error e) {
    }
}

private void test_lut3d() {
    var sb = new StringBuilder("TITLE \"identity\"\nLUT_3D_SIZE 2\n");
    for (int b = 0; b < 2; b++) for (int g = 0; g < 2; g++) for (int r = 0; r < 2; r++) sb.append_printf("%d %d %d\n", r, g, b);
    Lut3D lut;
    try {
        lut = Lut3D.parse(sb.str);
    } catch (Error e) {
        assert_not_reached();
    }
    float r, g, b;
    lut.apply(0.3f, 0.6f, 0.9f, out r, out g, out b);
    near(r, 0.3, 1e-5);
    near(g, 0.6, 1e-5);
    near(b, 0.9, 1e-5);
    assert(lut.title == "identity");
    try {
        Lut3D.parse("LUT_3D_SIZE 3\n0 0 0\n");
        assert_not_reached();
    } catch (Error e) {
    }
}

private void test_detail_effects() {
    int w = 40, h = 20;
    var px = new uint8[w * h * 4];
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int i = (y * w + x) * 4;
        uint8 v = x < w / 2 ? 80 : 170;
        px[i] = px[i + 1] = px[i + 2] = v;
        px[i + 3] = 255;
    }
    var src = new DecodedPhoto(WorkingSpace.from_srgb8(px, w, h, w * 4, true));
    var p = new EditParams();
    p.set_value(Adjustment.SHARPNESS, 1);
    var out_img = DevelopPipeline.render(src, p, new RenderOptions());
    int r1, g1, b1, r2, g2, b2;
    srgb_at(out_img, w / 2 - 1, 10, out r1, out g1, out b1);
    srgb_at(out_img, w / 2, 10, out r2, out g2, out b2);
    assert(r1 < 80 && r2 > 170);
    srgb_at(out_img, 2, 10, out r1, out g1, out b1);
    near(r1, 80, 1);
    var flat = photo_from_srgb(40, 30, 150, 150, 150);
    p = new EditParams();
    p.set_value(Adjustment.VIGNETTE, 1);
    out_img = DevelopPipeline.render(flat, p, new RenderOptions());
    srgb_at(out_img, 0, 0, out r1, out g1, out b1);
    srgb_at(out_img, 20, 15, out r2, out g2, out b2);
    assert(r1 < r2 - 20);
    near(r2, 150, 1);
    p = new EditParams();
    p.develop.set("effects.grain.amount", 1);
    out_img = DevelopPipeline.render(flat, p, new RenderOptions());
    double var_sum = 0;
    for (int i = 0; i < 40 * 30; i++) {
        double d = out_img.data[i * 4] - flat.image.data[i * 4];
        var_sum += d * d;
    }
    assert(var_sum > 1e-4);
    var again = DevelopPipeline.render(flat, p, new RenderOptions());
    for (int i = 0; i < again.data.length; i++) assert(again.data[i] == out_img.data[i]);
}

private void test_local_tone() {
    int w = 64, h = 64;
    var px = new uint8[w * h * 4];
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int i = (y * w + x) * 4;
        uint8 v = (uint8) (x * 4);
        px[i] = px[i + 1] = px[i + 2] = v;
        px[i + 3] = 255;
    }
    var src = new DecodedPhoto(WorkingSpace.from_srgb8(px, w, h, w * 4, true));
    var p = new EditParams();
    p.set_value(Adjustment.SHADOWS, 1);
    var out_img = DevelopPipeline.render(src, p, new RenderOptions());
    int r_dark, g0, b0, r_bright, g1, b1;
    srgb_at(out_img, 6, 32, out r_dark, out g0, out b0);
    srgb_at(out_img, 60, 32, out r_bright, out g1, out b1);
    assert(r_dark > 24 + 10);
    near(r_bright, 240, 6);
    p = new EditParams();
    p.set_value(Adjustment.HIGHLIGHTS, -1);
    out_img = DevelopPipeline.render(src, p, new RenderOptions());
    srgb_at(out_img, 60, 32, out r_bright, out g1, out b1);
    assert(r_bright < 230);
    p = new EditParams();
    p.set_value(Adjustment.DEHAZE, 1);
    var hazy = photo_from_srgb(32, 32, 180, 185, 190);
    var hz = hazy.image;
    for (int y = 0; y < 32; y++) for (int x = 16; x < 32; x++) {
        size_t i = hz.offset(x, y);
        hz.data[i] *= 0.6f;
        hz.data[i + 1] *= 0.6f;
        hz.data[i + 2] *= 0.6f;
    }
    out_img = DevelopPipeline.render(hazy, p, new RenderOptions());
    double before = hz.data[hz.offset(2, 2)] / hz.data[hz.offset(28, 2)];
    double after = out_img.data[out_img.offset(2, 2)] / double.max(1e-6, out_img.data[out_img.offset(28, 2)]);
    assert(after > before);
}

private void test_settings_keys() {
    var d = new DevelopSettings();
    assert(DevelopSettings.find_key("hsl.hue.aqua") != null);
    d.set("detail.sharpen.radius", 99);
    near(d.get("detail.sharpen.radius"), 3.0, 1e-9);
    d.set("detail.sharpen.radius", 1.0);
    assert(d.is_default());
    near(d.get("wb.temperature"), 5500, 1e-9);
}

private void test_depth_from_defocus() {
    int w = 160, h = 80;
    var img = new Singularity.Imaging.FloatImage(w, h);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float v = ((x / 4 + y / 4) % 2 == 0) ? 0.8f : 0.1f;
        img.set_pixel(x, y, v, v, v);
    }
    var right = Singularity.Imaging.Filters.gaussian(img.cropped(80, 0, 80, 80), 3.0);
    img.paste(right, 80, 0);
    var d = DepthEstimate.from_defocus(img);
    double left_sum = 0, right_sum = 0;
    for (int y = 10; y < 70; y++) {
        for (int x = 10; x < 60; x++) left_sum += d[y * w + x];
        for (int x = 100; x < 150; x++) right_sum += d[y * w + x];
    }
    assert(right_sum > left_sum * 2);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/develop/identity", test_identity);
    Test.add_func("/develop/exposure", test_exposure_linear);
    Test.add_func("/develop/geometry", test_geometry);
    Test.add_func("/develop/transform", test_transform_homography);
    Test.add_func("/develop/curves", test_curves);
    Test.add_func("/develop/hsl", test_hsl);
    Test.add_func("/develop/wb-grading", test_white_balance_and_grading);
    Test.add_func("/develop/masks", test_masks);
    Test.add_func("/develop/rotated-mask", test_rotated_mask_follows_image);
    Test.add_func("/develop/json", test_json_v2);
    Test.add_func("/develop/lut3d", test_lut3d);
    Test.add_func("/develop/detail-effects", test_detail_effects);
    Test.add_func("/develop/local-tone", test_local_tone);
    Test.add_func("/develop/settings", test_settings_keys);
    Test.add_func("/develop/depth", test_depth_from_defocus);
    return Test.run();
}
