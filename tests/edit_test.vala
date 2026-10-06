using Singularity.Apps.Photos;

private EditImage solid(int w, int h, uint8 r, uint8 g, uint8 b) {
    var img = new EditImage(w, h);
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            img.set_pixel(x, y, r, g, b);
    return img;
}

private EditImage gradient(int w, int h) {
    var img = new EditImage(w, h);
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            img.set_pixel(x, y, (uint8) ((x * 37 + y * 11) % 256), (uint8) ((x * 5 + y * 53) % 256), (uint8) ((x * 71 + y * 3) % 256));
    return img;
}

private void pixel(EditImage img, int x, int y, out int r, out int g, out int b) {
    uint8 rr, gg, bb, aa;
    img.get_pixel(x, y, out rr, out gg, out bb, out aa);
    r = rr;
    g = gg;
    b = bb;
}

private void assert_near(int got, int want, int tolerance = 1) {
    if ((got - want).abs() > tolerance) {
        stderr.printf("got %d want %d\n", got, want);
        assert_not_reached();
    }
}

private EditImage one(uint8 r, uint8 g, uint8 b, EditParams p) {
    return EditPipeline.render(solid(4, 4, r, g, b), p);
}

private void check_one(EditParams p, uint8 r, uint8 g, uint8 b, int er, int eg, int eb) {
    int rr, gg, bb;
    pixel(one(r, g, b, p), 1, 1, out rr, out gg, out bb);
    assert_near(rr, er);
    assert_near(gg, eg);
    assert_near(bb, eb);
}

private void test_identity() {
    var src = gradient(37, 23);
    var out_img = EditPipeline.render(src, new EditParams());
    assert(out_img.width == 37 && out_img.height == 23);
    for (int i = 0; i < src.data.length; i++) assert(out_img.data[i] == src.data[i]);
    assert(new EditParams().is_identity());
}

private void test_exposure() {
    var p = new EditParams();
    p.set_value(Adjustment.EXPOSURE, 0.5);
    check_one(p, 50, 100, 20, 100, 200, 40);
    p.set_value(Adjustment.EXPOSURE, -0.5);
    check_one(p, 200, 100, 40, 100, 50, 20);
}

private void test_brightness() {
    var p = new EditParams();
    p.set_value(Adjustment.BRIGHTNESS, 0.5);
    double v = 1.0 - Math.pow(1.0 - 100.0 / 255.0, 1.75);
    int want = (int) (v * 255 + 0.5);
    check_one(p, 100, 100, 100, want, want, want);
    check_one(p, 0, 255, 0, 0, 255, 0);
    p.set_value(Adjustment.BRIGHTNESS, -0.5);
    want = (int) (Math.pow(100.0 / 255.0, 1.75) * 255 + 0.5);
    check_one(p, 100, 100, 100, want, want, want);
}

private void test_contrast() {
    var p = new EditParams();
    p.set_value(Adjustment.CONTRAST, 1.0);
    check_one(p, 64, 128, 191, 1, 128, 255);
    p.set_value(Adjustment.CONTRAST, -1.0);
    check_one(p, 10, 200, 90, 128, 128, 128);
}

private void test_highlights_shadows() {
    var p = new EditParams();
    p.set_value(Adjustment.HIGHLIGHTS, -1.0);
    check_one(p, 255, 255, 255, 166, 166, 166);
    check_one(p, 20, 20, 20, 20, 20, 20);
    p = new EditParams();
    p.set_value(Adjustment.SHADOWS, 1.0);
    check_one(p, 0, 0, 0, 89, 89, 89);
    check_one(p, 240, 240, 240, 240, 240, 240);
}

private void test_saturation_and_vibrance() {
    var p = new EditParams();
    p.set_value(Adjustment.SATURATION, -1.0);
    int l = (int) ((0.2126 * 200 + 0.7152 * 100 + 0.0722 * 50) + 0.5);
    check_one(p, 200, 100, 50, l, l, l);
    p = new EditParams();
    p.set_value(Adjustment.SATURATION, 1.0);
    check_one(p, 128, 128, 128, 128, 128, 128);
    p = new EditParams();
    p.set_value(Adjustment.VIBRANCE, 1.0);
    check_one(p, 255, 0, 0, 255, 0, 0);
    int rr, gg, bb;
    pixel(one(140, 120, 120, p), 0, 0, out rr, out gg, out bb);
    assert(rr > 140 + 10 && gg < 120);
}

private void test_warmth_tint() {
    var p = new EditParams();
    p.set_value(Adjustment.WARMTH, 1.0);
    check_one(p, 100, 100, 100, 131, 100, 69);
    p = new EditParams();
    p.set_value(Adjustment.TINT, 1.0);
    check_one(p, 100, 100, 100, 110, 69, 110);
}

private void test_levels() {
    var p = new EditParams();
    p.black_point = 64 / 255.0;
    p.white_point = 192 / 255.0;
    check_one(p, 64, 128, 192, 0, 128, 255);
}

private void test_filters() {
    var p = new EditParams();
    p.filter = "mono";
    int l = (int) ((0.2126 * 10 + 0.7152 * 200 + 0.0722 * 90) + 0.5);
    check_one(p, 10, 200, 90, l, l, l);
    p.filter = "sepia";
    double r = 100 / 255.0;
    check_one(p, 100, 100, 100,
        (int) ((0.393 + 0.769 + 0.189) * r * 255 + 0.5).clamp(0, 255),
        (int) ((0.349 + 0.686 + 0.168) * r * 255 + 0.5),
        (int) ((0.272 + 0.534 + 0.131) * r * 255 + 0.5));
    p.filter = "warm";
    assert((EditPipeline.effective(p, Adjustment.WARMTH) - 0.45).abs() < 1e-9);
    p.set_value(Adjustment.WARMTH, 0.8);
    assert(EditPipeline.effective(p, Adjustment.WARMTH) == 1.0);
    foreach (unowned FilterPreset f in FilterPreset.all()) assert(FilterPreset.find(f.id) == f);
}

private void test_sharpness() {
    var img = solid(5, 5, 100, 100, 100);
    img.set_pixel(2, 2, 200, 200, 200);
    var p = new EditParams();
    p.set_value(Adjustment.SHARPNESS, 1.0);
    EditPipeline.apply_color(img, p);
    int r, g, b;
    pixel(img, 2, 2, out r, out g, out b);
    assert_near(r, 255);
    pixel(img, 1, 2, out r, out g, out b);
    assert_near(r, 83);
    pixel(img, 4, 4, out r, out g, out b);
    assert_near(r, 100);
    var flat = solid(5, 5, 90, 90, 90);
    EditPipeline.apply_color(flat, p);
    pixel(flat, 2, 2, out r, out g, out b);
    assert(r == 90);
}

private void test_vignette() {
    var img = solid(101, 101, 200, 200, 200);
    var p = new EditParams();
    p.set_value(Adjustment.VIGNETTE, 1.0);
    EditPipeline.apply_color(img, p);
    int r, g, b;
    pixel(img, 50, 50, out r, out g, out b);
    assert(r == 200);
    pixel(img, 0, 0, out r, out g, out b);
    assert(r < 80);
    assert(EditPipeline.vignette_factor(0.5, 0.5) == 0.0);
    assert((EditPipeline.vignette_factor(0.0, 0.0) - 1.0).abs() < 1e-9);
}

private void test_crop() {
    var src = gradient(40, 20);
    var p = new EditParams();
    p.set_crop(0.25, 0.5, 0.5, 0.5);
    var out_img = EditPipeline.render(src, p);
    assert(out_img.width == 20 && out_img.height == 10);
    for (int y = 0; y < 10; y++)
        for (int x = 0; x < 20; x++) {
            int a, b, c, d, e, f;
            pixel(out_img, x, y, out a, out b, out c);
            pixel(src, x + 10, y + 10, out d, out e, out f);
            assert(a == d && b == e && c == f);
        }
}

private void test_rotate() {
    var src = gradient(6, 4);
    var p = new EditParams();
    p.rotate(1);
    var cw = EditPipeline.render(src, p);
    assert(cw.width == 4 && cw.height == 6);
    int a, b, c, d, e, f;
    pixel(cw, 0, 0, out a, out b, out c);
    pixel(src, 0, 3, out d, out e, out f);
    assert(a == d && b == e && c == f);
    pixel(cw, 3, 0, out a, out b, out c);
    pixel(src, 0, 0, out d, out e, out f);
    assert(a == d && b == e && c == f);
    p.rotate(1);
    var half = EditPipeline.render(src, p);
    pixel(half, 0, 0, out a, out b, out c);
    pixel(src, 5, 3, out d, out e, out f);
    assert(a == d && b == e && c == f);
    p.rotate(2);
    assert(p.quarter_turns == 0);
    p.rotate(-1);
    assert(p.quarter_turns == 3);
    var ccw = EditPipeline.render(src, p);
    pixel(ccw, 0, 0, out a, out b, out c);
    pixel(src, 5, 0, out d, out e, out f);
    assert(a == d && b == e && c == f);

    var q = new EditParams();
    q.set_crop(0.0, 0.0, 0.5, 0.25);
    q.rotate(1);
    assert((q.crop_x - 0.75).abs() < 1e-9 && q.crop_y.abs() < 1e-9);
    assert((q.crop_w - 0.25).abs() < 1e-9 && (q.crop_h - 0.5).abs() < 1e-9);
}

private void test_flip() {
    var src = gradient(6, 4);
    var p = new EditParams();
    p.toggle_flip();
    var out_img = EditPipeline.render(src, p);
    int a, b, c, d, e, f;
    pixel(out_img, 0, 1, out a, out b, out c);
    pixel(src, 5, 1, out d, out e, out f);
    assert(a == d && b == e && c == f);
}

private void test_straighten() {
    assert((EditPipeline.straighten_scale(100, 100, 0) - 1.0).abs() < 1e-12);
    double t = 10 * Math.PI / 180;
    assert((EditPipeline.straighten_scale(200, 100, 10) - (Math.cos(t) + 2 * Math.sin(t))).abs() < 1e-12);
    assert(EditPipeline.straighten_scale(200, 100, -10) == EditPipeline.straighten_scale(200, 100, 10));
    var p = new EditParams();
    p.straighten = 10;
    double s = EditPipeline.straighten_scale(200, 100, 10);
    double sx, sy;
    EditPipeline.map_point(p, 200, 100, 100, 50, out sx, out sy);
    assert((sx - 100).abs() < 1e-9 && (sy - 50).abs() < 1e-9);
    double[,] corners = { {0, 0}, {200, 0}, {0, 100}, {200, 100} };
    int touching = 0;
    for (int i = 0; i < 4; i++) {
        EditPipeline.map_point(p, 200, 100, corners[i, 0], corners[i, 1], out sx, out sy);
        assert(sx >= -1e-6 && sx <= 200 + 1e-6 && sy >= -1e-6 && sy <= 100 + 1e-6);
        if (sx.abs() < 1e-6 || sy.abs() < 1e-6 || (sx - 200).abs() < 1e-6 || (sy - 100).abs() < 1e-6) touching++;
    }
    assert(touching == 2);
    EditPipeline.map_point(p, 200, 100, 200, 50, out sx, out sy);
    double a = -10 * Math.PI / 180;
    assert((sx - (100 + 100 * Math.cos(a) / s)).abs() < 1e-9);
    assert((sy - (50 + 100 * Math.sin(a) / s)).abs() < 1e-9);
    var img = EditPipeline.render(solid(60, 40, 10, 20, 30), p);
    assert(img.width == 60 && img.height == 40);
    int r, g, b;
    pixel(img, 0, 0, out r, out g, out b);
    assert(r == 10 && g == 20 && b == 30);
}

private void test_auto_enhance() {
    var img = new EditImage(128, 2);
    for (int x = 0; x < 128; x++) {
        img.set_pixel(x, 0, (uint8) (64 + x), (uint8) (64 + x), (uint8) (64 + x));
        img.set_pixel(x, 1, (uint8) (64 + x), (uint8) (64 + x), (uint8) (64 + x));
    }
    var p = EditPipeline.auto_enhance(img, new EditParams());
    assert((p.black_point * 255 - 64).abs() < 1.5);
    assert((p.white_point * 255 - 191).abs() < 1.5);
    assert(p.get_value(Adjustment.VIBRANCE) > 0);
    var out_img = EditPipeline.render(img, p);
    int r, g, b;
    pixel(out_img, 0, 0, out r, out g, out b);
    assert(r <= 1);
    pixel(out_img, 127, 0, out r, out g, out b);
    assert(r >= 254);

    var full = new EditImage(256, 1);
    for (int x = 0; x < 256; x++) full.set_pixel(x, 0, (uint8) x, (uint8) x, (uint8) x);
    var q = EditPipeline.auto_enhance(full, new EditParams());
    assert(q.black_point == 0.0 && q.white_point == 1.0);

    var dark = solid(16, 16, 20, 20, 20);
    for (int x = 0; x < 16; x++) dark.set_pixel(x, 0, 200, 200, 200);
    var d = EditPipeline.auto_enhance(dark, new EditParams());
    assert(d.get_value(Adjustment.SHADOWS) > 0);
}

private void test_sidecar_roundtrip() {
    try {
        sidecar_roundtrip();
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void sidecar_roundtrip() throws Error {
    var p = new EditParams();
    p.set_value(Adjustment.EXPOSURE, 0.25);
    p.set_value(Adjustment.VIGNETTE, -0.5);
    p.set_value(Adjustment.SHARPNESS, 0.7);
    p.rotate(3);
    p.toggle_flip();
    p.straighten = -4.5;
    p.set_crop(0.1, 0.2, 0.5, 0.6);
    p.black_point = 0.05;
    p.white_point = 0.9;
    p.filter = "noir";
    var back = EditParams.from_json(p.to_json());
    assert(back.equals(p));
    assert(!back.is_identity());
    var id = EditParams.from_json("{\"version\":1}");
    assert(id.is_identity());
    var clamp = EditParams.from_json("{\"version\":1,\"adjust\":{\"exposure\":7,\"bogus\":1,\"sharpness\":-3},\"filter\":\"nope\",\"rotation\":450}");
    assert(clamp.get_value(Adjustment.EXPOSURE) == Adjustment.EXPOSURE.max_value());
    assert(clamp.get_value(Adjustment.SHARPNESS) == 0.0);
    assert(clamp.filter == "none");
    assert(clamp.quarter_turns == 1);
    try {
        EditParams.from_json("{\"version\":99}");
        assert_not_reached();
    } catch (Error e) { }
    try {
        EditParams.from_json("[1,2]");
        assert_not_reached();
    } catch (Error e) { }
}

private void test_store() {
    try {
        store();
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void store() throws Error {
    string dir = DirUtils.make_tmp("photos-edit-XXXXXX");
    var file = File.new_for_path(Path.build_filename(dir, "a.png"));
    FileUtils.set_contents(file.get_path(), "x");
    assert(!EditStore.has_edits(file));
    var p = new EditParams();
    p.set_value(Adjustment.CONTRAST, 0.3);
    var sidecar = EditStore.save(file, p);
    assert(sidecar.get_basename() == ".a.png.edit.json");
    assert(EditStore.has_edits(file));
    assert(EditStore.load(file).equals(p));
    var copy = EditStore.copy_target(file, ".png");
    assert(copy.get_basename() == "a (Edited).png");
    EditStore.revert(file);
    assert(!EditStore.has_edits(file));
    FileUtils.remove(file.get_path());
    DirUtils.remove(dir);
}

private void test_scaled_to_fit() {
    var img = solid(400, 200, 30, 60, 90);
    var small = img.scaled_to_fit(100);
    assert(small.width == 100 && small.height == 50);
    int r, g, b;
    pixel(small, 10, 10, out r, out g, out b);
    assert(r == 30 && g == 60 && b == 90);
    assert(img.scaled_to_fit(1000) == img);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/edit/identity", test_identity);
    Test.add_func("/edit/exposure", test_exposure);
    Test.add_func("/edit/brightness", test_brightness);
    Test.add_func("/edit/contrast", test_contrast);
    Test.add_func("/edit/highlights-shadows", test_highlights_shadows);
    Test.add_func("/edit/saturation-vibrance", test_saturation_and_vibrance);
    Test.add_func("/edit/warmth-tint", test_warmth_tint);
    Test.add_func("/edit/levels", test_levels);
    Test.add_func("/edit/filters", test_filters);
    Test.add_func("/edit/sharpness", test_sharpness);
    Test.add_func("/edit/vignette", test_vignette);
    Test.add_func("/edit/crop", test_crop);
    Test.add_func("/edit/rotate", test_rotate);
    Test.add_func("/edit/flip", test_flip);
    Test.add_func("/edit/straighten", test_straighten);
    Test.add_func("/edit/auto-enhance", test_auto_enhance);
    Test.add_func("/edit/sidecar-roundtrip", test_sidecar_roundtrip);
    Test.add_func("/edit/store", test_store);
    Test.add_func("/edit/scaled-to-fit", test_scaled_to_fit);
    return Test.run();
}
