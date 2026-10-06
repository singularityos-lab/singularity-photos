using Singularity.Imaging;
using Singularity.Apps.Photos;

private const string REAL_PHOTO = "/usr/share/doc/texlive-doc/xelatex/cqubeamer/figure/CQU_Campus_D.jpg";

private double enc(float v) {
    return Transfer.linear_to_srgb(v);
}

private FloatImage texture_image(int w, int h, uint32 seed) {
    var img = new FloatImage(w, h);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            double v = 0.35 + 0.15 * Math.sin(x * 0.21 + seed) * Math.cos(y * 0.13) + 0.1 * Math.sin((x + y) * 0.05);
            uint32 n = AlgoUtil.hash((uint32) (x * 7919 + y * 104729) ^ seed);
            v += ((n & 0xff) / 255.0 - 0.5) * 0.02;
            img.set_pixel(x, y, Transfer.srgb_to_linear((float) v), Transfer.srgb_to_linear((float) (v * 0.9)), Transfer.srgb_to_linear((float) (v * 0.7)));
        }
    }
    return img;
}

private FloatImage scene_image(int w, int h, uint32 seed) {
    var img = new FloatImage.filled(w, h, 0.2f, 0.22f, 0.25f);
    uint32 rng = seed;
    for (int k = 0; k < 260; k++) {
        rng = AlgoUtil.hash(rng + 1);
        int cx = (int) (rng % (uint) w);
        rng = AlgoUtil.hash(rng + 1);
        int cy = (int) (rng % (uint) h);
        rng = AlgoUtil.hash(rng + 1);
        int r = 4 + (int) (rng % 22u);
        rng = AlgoUtil.hash(rng + 1);
        float cr = (rng & 0xff) / 255.0f, cg = ((rng >> 8) & 0xff) / 255.0f, cb = ((rng >> 16) & 0xff) / 255.0f;
        bool square = (rng >> 24) % 2 == 0;
        for (int y = int.max(0, cy - r); y < int.min(h, cy + r); y++)
            for (int x = int.max(0, cx - r); x < int.min(w, cx + r); x++)
                if (square || (x - cx) * (x - cx) + (y - cy) * (y - cy) < r * r) img.set_pixel(x, y, cr, cg, cb);
    }
    return img;
}

private FloatImage? load_real(int max_side) {
    if (!FileUtils.test(REAL_PHOTO, FileTest.EXISTS)) return null;
    try {
        var pb = new Gdk.Pixbuf.from_file(REAL_PHOTO);
        unowned uint8[] px = pb.get_pixels_with_length();
        var img = FloatImage.from_rgba8(px, pb.width, pb.height, pb.rowstride, pb.has_alpha, true);
        return img.scaled_to_fit(max_side);
    } catch (Error e) {
        return null;
    }
}

private double region_error(FloatImage a, FloatImage b, int x0, int y0, int x1, int y1) {
    double s = 0;
    int n = 0;
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) {
            size_t i = a.offset(x, y);
            for (int c = 0; c < 3; c++) s += (enc(a.data[i + c]) - enc(b.data[i + c])).abs();
            n += 3;
        }
    return s / n;
}

private void test_heal_spot() {
    var clean = texture_image(200, 160, 3);
    var img = clean.copy();
    for (int y = 60; y < 90; y++) for (int x = 50; x < 80; x++) if ((x - 65) * (x - 65) + (y - 75) * (y - 75) < 100) img.set_pixel(x, y, 0.01f, 0.01f, 0.01f);
    var spot = new SpotEdit();
    spot.mode = "heal";
    spot.x = 65.0 / 200;
    spot.y = 75.0 / 160;
    spot.radius = 16.0 / 200;
    spot.feather = 0.3;
    spot.source_x = spot.x;
    spot.source_y = spot.y;
    spot.auto_source = true;
    double before = region_error(img, clean, 55, 65, 75, 85);
    Heal.spot(img, spot);
    double after = region_error(img, clean, 55, 65, 75, 85);
    stdout.printf("# heal: error before %.4f after %.4f source (%.3f, %.3f)\n", before, after, spot.source_x, spot.source_y);
    assert(after < before * 0.4);
    assert(region_error(img, clean, 150, 10, 190, 40) < 1e-6);
    assert(spot.source_x != spot.x || spot.source_y != spot.y);
}

private void test_clone_and_region() {
    var img = new FloatImage.filled(100, 100, 0.1f, 0.1f, 0.1f);
    for (int y = 10; y < 30; y++) for (int x = 10; x < 30; x++) img.set_pixel(x, y, 0.8f, 0.2f, 0.3f);
    var mask = new float[100 * 100];
    for (int y = 60; y < 80; y++) for (int x = 60; x < 80; x++) mask[y * 100 + x] = 1;
    var src = img.copy();
    Heal.clone_region(img, src, mask, -50, -50);
    float r, g, b, a;
    img.get_pixel(70, 70, out r, out g, out b, out a);
    assert((r - 0.8f).abs() < 1e-6 && (g - 0.2f).abs() < 1e-6);
    var grad = new FloatImage(80, 80);
    for (int y = 0; y < 80; y++) for (int x = 0; x < 80; x++) grad.set_pixel(x, y, x / 80.0f, 0.3f, y / 80.0f);
    var truth = grad.copy();
    var m2 = new float[80 * 80];
    for (int y = 30; y < 50; y++) for (int x = 30; x < 50; x++) {
        m2[y * 80 + x] = 1;
        grad.set_pixel(x, y, 1, 1, 1);
    }
    Heal.heal_region(grad, m2, -25, 0);
    double err = region_error(grad, truth, 30, 30, 50, 50);
    stdout.printf("# poisson membrane error %.5f\n", err);
    assert(err < 0.01);
}

private void test_find_source() {
    var img = new FloatImage(240, 120);
    for (int y = 0; y < 120; y++) for (int x = 0; x < 240; x++) {
        if (x < 120) img.set_pixel(x, y, 0.6f, 0.05f, 0.05f);
        else img.set_pixel(x, y, 0.05f, 0.05f, 0.6f);
    }
    var spot = new SpotEdit();
    spot.x = 60.0 / 240;
    spot.y = 0.5;
    spot.radius = 8.0 / 240;
    Heal.find_source(img, spot);
    assert(spot.source_x * 240 < 118);
}

private void test_fill_region() {
    int w = 240, h = 160;
    var truth = new FloatImage(w, h);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float v = ((x / 8) % 2 == 0) ? 0.7f : 0.15f;
        truth.set_pixel(x, y, v, v * 0.8f, 0.2f);
    }
    var img = truth.copy();
    var mask = new float[w * h];
    for (int y = 60; y < 100; y++) for (int x = 100; x < 140; x++) {
        mask[y * w + x] = 1;
        img.set_pixel(x, y, 0.0f, 1.0f, 0.0f);
    }
    var timer = new Timer();
    Heal.fill_region(img, mask);
    double err = region_error(img, truth, 100, 60, 140, 100);
    var membrane = truth.copy();
    Heal.heal_region(membrane, mask, 0, 0);
    stdout.printf("# patchmatch fill: error %.4f in %.3fs\n", err, timer.elapsed());
    assert(err < 0.12);
    float r, g, b, a;
    img.get_pixel(120, 80, out r, out g, out b, out a);
    assert(g < 0.9f);
}

private void test_real_fill_and_timing() {
    var img = load_real(1600);
    if (img == null) {
        stdout.printf("# real photo missing, skipped\n");
        return;
    }
    int w = img.width, h = img.height;
    var truth = img.copy();
    var mask = new float[w * h];
    int x0 = (int) (w * 0.55), y0 = (int) (h * 0.08);
    for (int y = y0; y < y0 + 60; y++) for (int x = x0; x < x0 + 60; x++) {
        mask[y * w + x] = 1;
        img.set_pixel(x, y, 0, 0, 0);
    }
    var timer = new Timer();
    Heal.fill_region(img, mask);
    double err = region_error(img, truth, x0, y0, x0 + 60, y0 + 60);
    stdout.printf("# real sky fill %dx%d: error %.4f in %.3fs\n", w, h, err, timer.elapsed());
    assert(err < 0.05);
    var noisy = img.copy();
    uint32 rng = 7;
    for (size_t i = 0; i < noisy.pixel_count(); i++) {
        rng = AlgoUtil.hash(rng + 1);
        float nz = ((rng & 0xffff) / 65535.0f - 0.5f) * 0.12f;
        for (int c = 0; c < 3; c++) noisy.data[i * 4 + c] = Transfer.srgb_to_linear((Transfer.linear_to_srgb(noisy.data[i * 4 + c]) + nz).clamp(0, 1));
    }
    double before = AlgoUtil.psnr(AlgoUtil.encoded_copy(noisy), AlgoUtil.encoded_copy(img), 4);
    timer.start();
    Denoise.luminance(noisy, 0.6, 0.5, 0);
    double t = timer.elapsed();
    double after = AlgoUtil.psnr(AlgoUtil.encoded_copy(noisy), AlgoUtil.encoded_copy(img), 4);
    stdout.printf("# real denoise %dx%d: psnr %.2f -> %.2f dB in %.3fs\n", w, h, before, after, t);
    assert(after > before + 2.0);
    assert(t < 3.0);
}

private void test_denoise() {
    int w = 256, h = 256;
    var clean = new FloatImage(w, h);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float v = Transfer.srgb_to_linear(0.2f + 0.6f * x / w);
        clean.set_pixel(x, y, v, v, v);
    }
    var noisy = clean.copy();
    uint32 rng = 99;
    for (size_t i = 0; i < noisy.pixel_count(); i++) {
        rng = AlgoUtil.hash(rng + 1);
        float nz = ((rng & 0xffff) / 65535.0f - 0.5f) * 0.1f;
        for (int c = 0; c < 3; c++) noisy.data[i * 4 + c] = Transfer.srgb_to_linear((Transfer.linear_to_srgb(noisy.data[i * 4 + c]) + nz).clamp(0, 1));
    }
    double before = AlgoUtil.psnr(AlgoUtil.encoded_copy(noisy), AlgoUtil.encoded_copy(clean), 4);
    Denoise.luminance(noisy, 0.7, 0.3, 0);
    double after = AlgoUtil.psnr(AlgoUtil.encoded_copy(noisy), AlgoUtil.encoded_copy(clean), 4);
    stdout.printf("# denoise psnr %.2f -> %.2f\n", before, after);
    assert(after > before + 4.0);
}

private double luma_psnr(FloatImage a, FloatImage b) {
    var la = AlgoUtil.perceptual_luma(a), lb = AlgoUtil.perceptual_luma(b);
    double mse = 0;
    for (int i = 0; i < la.length; i++) mse += Math.pow(la[i] - lb[i], 2);
    mse /= la.length;
    return 10 * Math.log10(1.0 / double.max(mse, 1e-20));
}

private void test_denoise_high_iso() {
    var real = load_real(1477);
    FloatImage clean = real != null ? SuperResolution.lanczos_resize(real, 4000, (int) (4000.0 * real.height / real.width)) : scene_image(4000, 2300, 3);
    var noisy = clean.copy();
    uint32 rng = 12345;
    for (size_t i = 0; i < noisy.pixel_count(); i++) {
        for (int c = 0; c < 3; c++) {
            rng = AlgoUtil.hash(rng + 0x9e3779b9u);
            double u1 = (rng & 0xffff) / 65536.0 + 1e-6, u2 = (rng >> 16) / 65536.0;
            double g = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
            double x = double.max(clean.data[i * 4 + c], 0);
            double sigma = Math.sqrt(0.002 * x + 0.0001);
            noisy.data[i * 4 + c] = (float) (x + g * sigma);
        }
    }
    double before = luma_psnr(noisy, clean);
    var timer = new Timer();
    Denoise.luminance(noisy, 0.7, 0.4, 0.1);
    double t = timer.elapsed();
    double after = luma_psnr(noisy, clean);
    stdout.printf("# high ISO denoise %dx%d (%.1f MP): luma psnr %.2f -> %.2f dB in %.2fs\n", clean.width, clean.height, clean.pixel_count() / 1e6, before, after, t);
    assert(after > before + 4.0);
    assert(t < 20.0);
}

private void test_sky() {
    int w = 400, h = 300;
    var img = new FloatImage(w, h);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        if (y < 120) {
            float t = y / 120.0f;
            img.set_pixel(x, y, Transfer.srgb_to_linear(0.45f + 0.2f * t), Transfer.srgb_to_linear(0.62f + 0.15f * t), Transfer.srgb_to_linear(0.9f));
        } else {
            uint32 n = AlgoUtil.hash((uint32) (x * 31 + y * 977));
            float v = 0.25f + ((n & 0xff) / 255.0f) * 0.25f;
            img.set_pixel(x, y, Transfer.srgb_to_linear(v * 0.6f), Transfer.srgb_to_linear(v), Transfer.srgb_to_linear(v * 0.4f));
        }
    }
    for (int y = 50; y < 120; y++) for (int x = 150; x < 230; x++) {
        uint32 n = AlgoUtil.hash((uint32) (x * 13 + y * 7));
        float v = 0.3f + ((n & 0x3f) / 255.0f);
        img.set_pixel(x, y, Transfer.srgb_to_linear(v), Transfer.srgb_to_linear(v * 0.9f), Transfer.srgb_to_linear(v * 0.8f));
    }
    var mask = Segmentation.sky(img);
    int correct = 0;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        bool truth = y < 120 && !(y >= 50 && x >= 150 && x < 230);
        if ((mask[y * w + x] > 0.5f) == truth) correct++;
    }
    double acc = (double) correct / (w * h);
    stdout.printf("# sky synthetic accuracy %.3f\n", acc);
    assert(acc > 0.93);
    var real = load_real(900);
    if (real == null) return;
    var rm = Segmentation.sky(real);
    int rw = real.width, rh = real.height;
    float top = rm[(int) (rh * 0.05) * rw + (int) (rw * 0.5)];
    float building = rm[(int) (rh * 0.4) * rw + (int) (rw * 0.65)];
    float water = rm[(int) (rh * 0.85) * rw + (int) (rw * 0.6)];
    stdout.printf("# real sky mask: sky %.2f building %.2f water %.2f\n", top, building, water);
    assert(top > 0.8f && building < 0.2f && water < 0.3f);
}

private void test_subject() {
    int w = 320, h = 240;
    var img = new FloatImage(w, h);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        uint32 n = AlgoUtil.hash((uint32) (x * 31 + y * 977));
        float v = 0.45f + ((n & 0xff) / 255.0f) * 0.06f;
        bool inside = (x - 170) * (x - 170) / (70.0 * 70.0) + (y - 125) * (y - 125) / (60.0 * 60.0) < 1;
        if (inside) img.set_pixel(x, y, Transfer.srgb_to_linear(0.8f), Transfer.srgb_to_linear(0.25f), Transfer.srgb_to_linear(0.15f));
        else img.set_pixel(x, y, Transfer.srgb_to_linear(v * 0.8f), Transfer.srgb_to_linear(v), Transfer.srgb_to_linear(v * 0.9f));
    }
    var mask = Segmentation.subject(img);
    int inter = 0, uni = 0;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        bool truth = (x - 170) * (x - 170) / (70.0 * 70.0) + (y - 125) * (y - 125) / (60.0 * 60.0) < 1;
        bool got = mask[y * w + x] > 0.5f;
        if (truth && got) inter++;
        if (truth || got) uni++;
    }
    double iou = (double) inter / uni;
    stdout.printf("# subject IoU %.3f\n", iou);
    assert(iou > 0.8);
    var real = load_real(900);
    if (real == null) return;
    var rm = Segmentation.subject(real);
    int rw = real.width, rh = real.height;
    float tower = rm[(int) (rh * 0.4) * rw + (int) (rw * 0.62)];
    float building = rm[(int) (rh * 0.5) * rw + (int) (rw * 0.35)];
    float sky_v = rm[(int) (rh * 0.08) * rw + (int) (rw * 0.5)];
    float water = rm[(int) (rh * 0.93) * rw + (int) (rw * 0.6)];
    int selected = 0;
    foreach (float v in rm) if (v > 0.5f) selected++;
    stdout.printf("# real subject: tower %.2f building %.2f sky %.2f water %.2f coverage %.2f\n", tower, building, sky_v, water, (double) selected / rm.length);
    assert(tower > 0.5f && building > 0.5f && sky_v < 0.2f && water < 0.3f);
}

private FloatImage grid_image(int w, int h) {
    var img = new FloatImage.filled(w, h, 0.8f, 0.8f, 0.78f);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        if (x % 80 < 4 || (y % 90 < 4 && x > 60 && x < w - 60)) img.set_pixel(x, y, 0.05f, 0.05f, 0.06f);
    }
    return img;
}

private void test_upright() {
    int w = 800, h = 600;
    var grid = grid_image(w, h);
    var hm = Upright.homography(0.25, 0, 0, 0, 1, 0, 0, w, h);
    var fwd = Upright.forward(0.25, 0, 0, 0, 1, 0, 0, w, h);
    var id = Matrix3.multiply(hm, fwd);
    for (int i = 0; i < 9; i++) assert((id[i] / id[8] - (i % 4 == 0 ? 1 : 0)).abs() < 1e-9);
    var keystoned = AlgoUtil.warp(grid, hm, w, h);
    for (size_t i = 0; i < keystoned.pixel_count(); i++) if (keystoned.data[i * 4 + 3] <= 0) { keystoned.data[i * 4] = 0.8f; keystoned.data[i * 4 + 1] = 0.8f; keystoned.data[i * 4 + 2] = 0.78f; keystoned.data[i * 4 + 3] = 1; }
    double v, hz, r;
    Upright.solve(keystoned, "vertical", out v, out hz, out r);
    stdout.printf("# upright vertical: %.3f (want -0.25) rotate %.2f\n", v, r);
    assert((v + 0.25).abs() < 0.04);
    assert(r.abs() < 1.0);
    var rot = AlgoUtil.warp(grid, Upright.homography(0, 0, 3, 0, 1, 0, 0, w, h), w, h);
    for (size_t i = 0; i < rot.pixel_count(); i++) if (rot.data[i * 4 + 3] <= 0) { rot.data[i * 4] = 0.8f; rot.data[i * 4 + 1] = 0.8f; rot.data[i * 4 + 2] = 0.78f; rot.data[i * 4 + 3] = 1; }
    Upright.solve(rot, "level", out v, out hz, out r);
    stdout.printf("# upright level: rotate %.2f (want -3)\n", r);
    assert((r + 3).abs() < 0.4);
    var both = AlgoUtil.warp(grid, Upright.homography(-0.2, 0.15, 0, 0, 1, 0, 0, w, h), w, h);
    for (size_t i = 0; i < both.pixel_count(); i++) if (both.data[i * 4 + 3] <= 0) { both.data[i * 4] = 0.8f; both.data[i * 4 + 1] = 0.8f; both.data[i * 4 + 2] = 0.78f; both.data[i * 4 + 3] = 1; }
    Upright.solve(both, "full", out v, out hz, out r);
    stdout.printf("# upright full: v %.3f (want 0.2) h %.3f (want -0.15) r %.2f\n", v, hz, r);
    assert((v - 0.2).abs() < 0.06 && (hz + 0.15).abs() < 0.08);
    var real = load_real(1200);
    if (real == null) return;
    int rw = real.width, rh = real.height;
    var rk = clamp_warp(real, Upright.homography(0.2, 0, 0, 0, 1, 0, 0, rw, rh));
    double dev_before = vertical_deviation(rk);
    Upright.solve(rk, "vertical", out v, out hz, out r);
    var fixed_img = clamp_warp(rk, Upright.homography(v, hz, r, 0, 1, 0, 0, rw, rh));
    double dev_after = vertical_deviation(fixed_img);
    double v0, h0, r0;
    Upright.solve(real, "vertical", out v0, out h0, out r0);
    stdout.printf("# real upright: original v %.3f, keystoned solve v %.3f (group relation predicts %.3f) r %.2f, keystone slope %.2f -> %.2f deg per width, original %.2f\n", v0, v, v0 - 0.2, r, dev_before, dev_after, vertical_deviation(real));
    assert(dev_after < dev_before * 0.8);
    assert((v - (v0 - 0.2)).abs() < 0.1);
}

private FloatImage clamp_warp(FloatImage src, double[] out_to_in) {
    var out_img = new FloatImage(src.width, src.height);
    for (int y = 0; y < src.height; y++) for (int x = 0; x < src.width; x++) {
        double sx, sy;
        AlgoUtil.apply_h(out_to_in, x + 0.5, y + 0.5, out sx, out sy);
        float r, g, b, a;
        src.sample(sx, sy, out r, out g, out b, out a);
        out_img.set_pixel(x, y, r, g, b, 1);
    }
    return out_img;
}

private double vertical_deviation(FloatImage img) {
    int ww, wh;
    var segs = Upright.detect_segments(img, out ww, out wh);
    double sw = 0, sx = 0, sa = 0, sxx = 0, sxa = 0;
    foreach (var sg in segs) {
        double dx = sg.x1 - sg.x0, dy = sg.y1 - sg.y0;
        double a = Math.atan2(dx, dy) * 180 / Math.PI;
        while (a > 90) a -= 180;
        while (a <= -90) a += 180;
        if (a.abs() > 25) continue;
        double xn = (sg.x0 + sg.x1) / 2 / ww - 0.5;
        if (xn.abs() > 0.47) continue;
        double wt = sg.weight;
        sw += wt;
        sx += wt * xn;
        sa += wt * a;
        sxx += wt * xn * xn;
        sxa += wt * xn * a;
    }
    if (sw <= 0) return 0;
    double mx = sx / sw, ma = sa / sw;
    double vx = sxx / sw - mx * mx;
    return vx > 1e-9 ? ((sxa / sw - mx * ma) / vx).abs() : 0;
}

private void test_hdr() {
    int w = 240, h = 180;
    var radiance = new FloatImage(w, h);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float base_v = 0.01f * Math.powf(800.0f, (float) x / w);
        float tex = 1.0f + 0.3f * (float) Math.sin(y * 0.3) * (float) Math.cos(x * 0.2);
        radiance.set_pixel(x, y, base_v * tex, base_v * tex * 0.8f, base_v * tex * 0.6f);
    }
    double[] evs = { -3, 0, 3 };
    var shots = new FloatImage[3];
    for (int i = 0; i < 3; i++) {
        var s = AlgoUtil.translate(radiance, i == 0 ? 3 : 0, i == 0 ? -2 : 0);
        float gain = (float) Math.pow(2, evs[i]);
        for (size_t p = 0; p < s.pixel_count(); p++) for (int c = 0; c < 3; c++) s.data[p * 4 + c] = (s.data[p * 4 + c] * gain).clamp(0, 1);
        shots[i] = s;
    }
    FloatImage merged;
    try {
        merged = Hdr.merge(shots, evs);
    } catch (Error e) {
        assert_not_reached();
    }
    var errs = new Gee.ArrayList<double?>();
    for (int y = 10; y < h - 10; y++) for (int x = 10; x < w - 10; x++) {
        float r, g, b, a, tr, tg, tb, ta;
        merged.get_pixel(x, y, out r, out g, out b, out a);
        radiance.get_pixel(x, y, out tr, out tg, out tb, out ta);
        errs.add((r - tr).abs() / tr);
    }
    errs.sort((a, b) => { double x = a, y = b; return x < y ? -1 : (x > y ? 1 : 0); });
    double median = errs[errs.size / 2], p95 = errs[(int) (errs.size * 0.95)];
    float mr, mg, mb, ma;
    merged.get_pixel(w - 15, h / 2, out mr, out mg, out mb, out ma);
    float tr2, tg2, tb2, ta2;
    radiance.get_pixel(w - 15, h / 2, out tr2, out tg2, out tb2, out ta2);
    stdout.printf("# hdr relative error median %.4f p95 %.4f, highlight %.3f vs %.3f\n", median, p95, mr, tr2);
    assert(median < 0.02 && p95 < 0.15);
    assert(mr > 1.5f && (mr - tr2).abs() / tr2 < 0.05);
    FloatImage est;
    try {
        est = Hdr.merge(shots, {});
    } catch (Error e) {
        assert_not_reached();
    }
    est.get_pixel(w / 2, h / 2, out mr, out mg, out mb, out ma);
    radiance.get_pixel(w / 2, h / 2, out tr2, out tg2, out tb2, out ta2);
    assert((mr - tr2).abs() / tr2 < 0.1);
}

private void test_panorama() {
    int w = 1200, h = 500;
    var scene = scene_image(w, h, 42);
    var parts = new FloatImage[3];
    for (int i = 0; i < 3; i++) parts[i] = scene.cropped(i * 320, 0, 560, h);
    var timer = new Timer();
    FloatImage pano;
    try {
        pano = Panorama.stitch(parts, "perspective");
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    stdout.printf("# panorama %dx%d in %.2fs\n", pano.width, pano.height, timer.elapsed());
    assert((pano.width - w).abs() < 16 && (pano.height - h).abs() < 16);
    double best = 0;
    for (int ox = -8; ox <= 8; ox++) for (int oy = -8; oy <= 8; oy++) {
        double s = 0;
        int n = 0;
        for (int y = 40; y < h - 40; y += 3) for (int x = 40; x < w - 40; x += 3) {
            int px = x + ox, py = y + oy;
            if (px < 0 || py < 0 || px >= pano.width || py >= pano.height) continue;
            size_t a = pano.offset(px, py), b = scene.offset(x, y);
            for (int c = 0; c < 3; c++) s += Math.pow(pano.data[a + c] - scene.data[b + c], 2);
            n += 3;
        }
        double p = 10 * Math.log10(1.0 / (s / n + 1e-12));
        if (p > best) best = p;
    }
    stdout.printf("# panorama psnr vs ground truth %.2f dB\n", best);
    assert(best > 25);
    try {
        var cyl = Panorama.stitch(parts, "cylindrical+crop");
        stdout.printf("# cylindrical cropped %dx%d\n", cyl.width, cyl.height);
        assert(cyl.width > w * 0.8 && cyl.height > h * 0.7);
        for (size_t p = 0; p < cyl.pixel_count(); p++) assert(cyl.data[p * 4 + 3] > 0.5f);
    } catch (Error e) {
        assert_not_reached();
    }
}

private void test_real_panorama() {
    var real = load_real(1477);
    if (real == null) return;
    int w = real.width, h = real.height;
    var left = real.cropped(0, 0, 700, h);
    var mid_src = real.cropped(380, 0, 700, h);
    var mid = clamp_warp(mid_src, Upright.homography(0, 0.05, 1.5, 0, 1.08, 0, 0, 700, h));
    var right = real.cropped(w - 700, 0, 700, h);
    FloatImage pano;
    try {
        pano = Panorama.stitch({ left, mid, right }, "perspective+crop");
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    stdout.printf("# real panorama %dx%d from 3 crops (middle rotated and tilted)\n", pano.width, pano.height);
    assert(pano.width > w * 0.85 && pano.width < w * 1.2 && pano.height > h * 0.75);
}

private void test_focus_stack() {
    int w = 256, h = 192;
    var sharp = scene_image(w, h, 5);
    var blurred = Filters.gaussian(sharp, 3.0);
    var a = sharp.copy();
    var b = sharp.copy();
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        size_t i = a.offset(x, y);
        if (x < w / 2) for (int c = 0; c < 3; c++) a.data[i + c] = blurred.data[i + c];
        else for (int c = 0; c < 3; c++) b.data[i + c] = blurred.data[i + c];
    }
    FloatImage merged;
    try {
        merged = FocusStack.merge({ a, b });
    } catch (Error e) {
        assert_not_reached();
    }
    double pa = AlgoUtil.psnr(a, sharp, 8), pb = AlgoUtil.psnr(b, sharp, 8), pm = AlgoUtil.psnr(merged, sharp, 8);
    stdout.printf("# focus stack psnr a %.2f b %.2f merged %.2f\n", pa, pb, pm);
    assert(pm > double.max(pa, pb) + 5);
}

private void test_superres() {
    var sharp = scene_image(240, 180, 9);
    var small = sharp.resized(120, 90);
    var up = SuperResolution.upscale(small, 2);
    var bil = small.resized(240, 180);
    double ps = AlgoUtil.psnr(AlgoUtil.encoded_copy(up), AlgoUtil.encoded_copy(sharp), 4);
    double pb = AlgoUtil.psnr(AlgoUtil.encoded_copy(bil), AlgoUtil.encoded_copy(sharp), 4);
    stdout.printf("# super resolution psnr %.2f vs bilinear %.2f\n", ps, pb);
    var lz = SuperResolution.lanczos_resize(small, 240, 180);
    double pl = AlgoUtil.psnr(AlgoUtil.encoded_copy(lz), AlgoUtil.encoded_copy(sharp), 4);
    stdout.printf("# lanczos psnr %.2f\n", pl);
    assert(up.width == 240 && up.height == 180);
    assert(ps > pb + 0.5 && ps > pl + 0.3);
    var real = load_real(1200);
    if (real == null) return;
    var rs = real.resized(real.width / 2, real.height / 2);
    var rt = real.cropped(0, 0, rs.width * 2, rs.height * 2);
    var ru = SuperResolution.upscale(rs, 2);
    var rl = SuperResolution.lanczos_resize(rs, rs.width * 2, rs.height * 2);
    var rb = rs.resized(rs.width * 2, rs.height * 2);
    double a1 = AlgoUtil.psnr(AlgoUtil.encoded_copy(ru), AlgoUtil.encoded_copy(rt), 4);
    double a2 = AlgoUtil.psnr(AlgoUtil.encoded_copy(rl), AlgoUtil.encoded_copy(rt), 4);
    double a3 = AlgoUtil.psnr(AlgoUtil.encoded_copy(rb), AlgoUtil.encoded_copy(rt), 4);
    stdout.printf("# real 2x: ours %.2f lanczos %.2f bilinear %.2f dB\n", a1, a2, a3);
    assert(a1 > a2 && a1 > a3);
}

private FloatImage face_image(int w, int h, double cx, double cy, double s, float eye_gap, bool beard) {
    var img = new FloatImage.filled(w, h, Transfer.srgb_to_linear(0.2f), Transfer.srgb_to_linear(0.35f), Transfer.srgb_to_linear(0.55f));
    float sr = Transfer.srgb_to_linear(0.87f), sg = Transfer.srgb_to_linear(0.66f), sb = Transfer.srgb_to_linear(0.55f);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        double dx = (x - cx) / (s * 0.8), dy = (y - cy) / s;
        if (dx * dx + dy * dy < 1) {
            img.set_pixel(x, y, sr, sg, sb);
            double ex1 = (x - (cx - eye_gap * s)) / (s * 0.13), ey = (y - (cy - s * 0.3)) / (s * 0.08);
            double ex2 = (x - (cx + eye_gap * s)) / (s * 0.13);
            if (ex1 * ex1 + ey * ey < 1 || ex2 * ex2 + ey * ey < 1) img.set_pixel(x, y, 0.01f, 0.01f, 0.01f);
            double mx = (x - cx) / (s * 0.3), my = (y - (cy + s * 0.45)) / (s * 0.06);
            if (mx * mx + my * my < 1) img.set_pixel(x, y, Transfer.srgb_to_linear(0.45f), 0.05f, 0.05f);
            if (beard && dy > 0.55 && (AlgoUtil.hash((uint32) (x * 3 + y * 5)) & 3) == 0) img.set_pixel(x, y, Transfer.srgb_to_linear(0.35f), Transfer.srgb_to_linear(0.25f), Transfer.srgb_to_linear(0.2f));
        }
    }
    return img;
}

private void test_faces() {
    var a = face_image(320, 240, 160, 120, 70, 0.35f, false);
    var faces = Faces.detect(a);
    stdout.printf("# faces found %d\n", faces.length);
    assert(faces.length == 1);
    var f = faces[0];
    double fx = f.x * 320, fy = f.y * 240, fw = f.width * 320, fh = f.height * 240;
    double ix = double.max(0, double.min(fx + fw, 160 + 56) - double.max(fx, 160 - 56));
    double iy = double.max(0, double.min(fy + fh, 190) - double.max(fy, 50));
    double inter = ix * iy, uni = fw * fh + 112 * 140 - inter;
    stdout.printf("# face IoU %.3f\n", inter / uni);
    assert(inter / uni > 0.6);
    var b = face_image(400, 300, 180, 150, 90, 0.35f, false);
    var c = face_image(320, 240, 150, 120, 75, 0.22f, true);
    var fb = Faces.detect(b);
    var fc = Faces.detect(c);
    assert(fb.length == 1 && fc.length == 1);
    FaceSignature[] sigs = {
        new FaceSignature(Faces.descriptor(a, faces[0])),
        new FaceSignature(Faces.descriptor(b, fb[0])),
        new FaceSignature(Faces.descriptor(c, fc[0]))
    };
    double dab = Faces.distance(sigs[0].values, sigs[1].values), dac = Faces.distance(sigs[0].values, sigs[2].values);
    stdout.printf("# face distances same %.3f different %.3f\n", dab, dac);
    assert(dab < dac);
    var labels = Faces.cluster(sigs, (dab + dac) / 2);
    assert(labels[0] == labels[1] && labels[0] != labels[2]);
    var empty = Faces.detect(scene_image(200, 200, 77));
    stdout.printf("# faces in non-face scene %d\n", empty.length);
    string people = "/usr/share/go-1.26/src/image/testdata/video-001.jpeg";
    if (!FileUtils.test(people, FileTest.EXISTS)) return;
    try {
        var pb = new Gdk.Pixbuf.from_file(people);
        unowned uint8[] px = pb.get_pixels_with_length();
        var img = FloatImage.from_rgba8(px, pb.width, pb.height, pb.rowstride, pb.has_alpha, true);
        var found = Faces.detect(img);
        bool left = false, right = false;
        foreach (var fd in found) {
            double cx = (fd.x + fd.width / 2) * pb.width, cy = (fd.y + fd.height / 2) * pb.height;
            if (cx > 12 && cx < 40 && cy > 10 && cy < 40) left = true;
            if (cx > 108 && cx < 132 && cy > 10 && cy < 36) right = true;
        }
        stdout.printf("# real photo with two people: %d detections, left face %s, right face %s\n", found.length, left.to_string(), right.to_string());
        assert(left && right);
    } catch (Error e) {
        assert_not_reached();
    }
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/algo/heal-spot", test_heal_spot);
    Test.add_func("/algo/clone-region", test_clone_and_region);
    Test.add_func("/algo/find-source", test_find_source);
    Test.add_func("/algo/fill-region", test_fill_region);
    Test.add_func("/algo/denoise", test_denoise);
    Test.add_func("/algo/real-photo", test_real_fill_and_timing);
    Test.add_func("/algo/denoise-high-iso", test_denoise_high_iso);
    Test.add_func("/algo/sky", test_sky);
    Test.add_func("/algo/subject", test_subject);
    Test.add_func("/algo/upright", test_upright);
    Test.add_func("/algo/hdr", test_hdr);
    Test.add_func("/algo/panorama", test_panorama);
    Test.add_func("/algo/real-panorama", test_real_panorama);
    Test.add_func("/algo/focus-stack", test_focus_stack);
    Test.add_func("/algo/super-resolution", test_superres);
    Test.add_func("/algo/faces", test_faces);
    return Test.run();
}
