using Singularity.Apps.Photos;
using Singularity.Imaging;

private string fixtures;

private void near(double got, double want, double tolerance, string what = "") {
    if ((got - want).abs() > tolerance) {
        stderr.printf("%s: got %f want %f\n", what, got, want);
        assert_not_reached();
    }
}

private FloatImage encoded_image(int w, int h, float r, float g, float b, float a = 1) {
    var img = new FloatImage.filled(w, h, r, g, b, a);
    RetouchColor.encoded_to_working(img);
    return img;
}

private void encoded_at(FloatImage img, int x, int y, out float r, out float g, out float b, out float a) {
    float wr, wg, wb;
    img.get_pixel(x, y, out wr, out wg, out wb, out a);
    RetouchColor.pixel_to_encoded(wr, wg, wb, out r, out g, out b);
}

private FloatImage noise_image(int w, int h, uint seed) {
    var img = new FloatImage(w, h);
    var rand = new Rand.with_seed(seed);
    for (size_t i = 0; i < img.pixel_count(); i++) {
        img.data[i * 4] = (float) rand.next_double();
        img.data[i * 4 + 1] = (float) rand.next_double();
        img.data[i * 4 + 2] = (float) rand.next_double();
        img.data[i * 4 + 3] = 1;
    }
    RetouchColor.encoded_to_working(img);
    return img;
}

private RetouchDocument sample_document() {
    var doc = new RetouchDocument(48, 32);
    var base_layer = new RetouchLayer("Base", RetouchLayerKind.RASTER);
    base_layer.pixels = noise_image(48, 32, 7);
    doc.layers.add(base_layer);
    var group = new RetouchLayer("Group", RetouchLayerKind.GROUP);
    group.opacity = 0.8f;
    var child = new RetouchLayer("Child", RetouchLayerKind.RASTER);
    child.pixels = encoded_image(20, 10, 0.2f, 0.6f, 0.9f, 0.75f);
    child.x = 5;
    child.y = 7;
    child.mode = BlendMode.MULTIPLY;
    child.mask = doc.full_plane(1.0f);
    for (int x = 0; x < 48; x++) child.mask[x] = 0.25f;
    group.children.add(child);
    doc.layers.add(group);
    var adj = new RetouchLayer("Levels", RetouchLayerKind.ADJUSTMENT);
    adj.adjustment = new RetouchAdjustment("levels");
    adj.adjustment.put("gamma", 1.4);
    adj.visible = false;
    doc.layers.add(adj);
    var hidden = new RetouchLayer("Hidden", RetouchLayerKind.RASTER);
    hidden.pixels = encoded_image(48, 32, 1, 1, 1, 1);
    hidden.visible = false;
    hidden.locked = true;
    doc.layers.add(hidden);
    doc.recomposite();
    return doc;
}

private void test_zip() {
    var w = new RetouchZipWriter();
    try {
        w.add_text("mimetype", "image/openraster", false);
        var big = new uint8[50000];
        for (int i = 0; i < big.length; i++) big[i] = (uint8) (i % 7);
        w.add("data/big.bin", big);
        var data = w.finish();
        var r = new RetouchZipReader(data);
        assert(r.read_text("mimetype") == "image/openraster");
        var back = r.read("data/big.bin");
        assert(back.length == big.length);
        for (int i = 0; i < big.length; i++) assert(back[i] == big[i]);
        assert(data[30] == 'm');
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_composite() {
    var doc = new RetouchDocument(4, 4);
    var a = new RetouchLayer("a", RetouchLayerKind.RASTER);
    a.pixels = encoded_image(4, 4, 0.8f, 0.2f, 0.4f);
    var b = new RetouchLayer("b", RetouchLayerKind.RASTER);
    b.pixels = encoded_image(2, 2, 0.2f, 0.6f, 1.0f);
    b.x = 1;
    b.y = 1;
    b.opacity = 0.5f;
    doc.layers.add(a);
    doc.layers.add(b);
    doc.recomposite();
    float r, g, bb, al;
    encoded_at(doc.composite, 1, 1, out r, out g, out bb, out al);
    near(r, 0.5, 2e-3, "normal r");
    near(g, 0.4, 2e-3, "normal g");
    near(bb, 0.7, 2e-3, "normal b");
    encoded_at(doc.composite, 0, 0, out r, out g, out bb, out al);
    near(r, 0.8, 2e-3, "outside");
    b.opacity = 1;
    b.mode = BlendMode.MULTIPLY;
    doc.recomposite();
    encoded_at(doc.composite, 2, 2, out r, out g, out bb, out al);
    near(r, 0.16, 2e-3, "multiply r");
    near(g, 0.12, 2e-3, "multiply g");
    near(bb, 0.4, 2e-3, "multiply b");
    var adj = new RetouchLayer("inv", RetouchLayerKind.ADJUSTMENT);
    adj.adjustment = new RetouchAdjustment("invert");
    adj.mask = doc.full_plane(0.0f);
    adj.mask[0] = 1.0f;
    doc.layers.add(adj);
    doc.recomposite();
    encoded_at(doc.composite, 0, 0, out r, out g, out bb, out al);
    near(r, 0.2, 2e-3, "invert masked in");
    encoded_at(doc.composite, 3, 0, out r, out g, out bb, out al);
    near(r, 0.8, 2e-3, "invert masked out");
    doc.update_rect(0, 0, 2, 2);
    encoded_at(doc.composite, 0, 0, out r, out g, out bb, out al);
    near(r, 0.2, 2e-3, "rect recomposite");
}

private void test_undo() {
    var doc = sample_document();
    var layer = doc.layers[0];
    float before = layer.pixels.data[layer.pixels.offset(3, 3)];
    doc.record_pixels(layer, 0, 0, 10, 10);
    layer.pixels.set_pixel(3, 3, 5, 5, 5);
    doc.undo();
    near(layer.pixels.data[layer.pixels.offset(3, 3)], before, 1e-7, "pixel undo");
    doc.redo();
    near(layer.pixels.data[layer.pixels.offset(3, 3)], 5, 1e-7, "pixel redo");
    int count = doc.layers.size;
    doc.record_structure("delete");
    doc.remove_layer(doc.layers[1]);
    assert(doc.layers.size == count - 1);
    doc.undo();
    assert(doc.layers.size == count);
    assert(doc.layers[1].name == "Group");
}

private void compare_layers(RetouchLayer a, RetouchLayer b, double tolerance) {
    assert(a.name == b.name);
    assert(a.kind == b.kind);
    assert(a.visible == b.visible);
    assert(a.locked == b.locked);
    assert(a.mode == b.mode);
    near(a.opacity, b.opacity, 1.0 / 250, "opacity " + a.name);
    assert((a.mask == null) == (b.mask == null));
    if (a.mask != null) for (int i = 0; i < a.mask.length; i += 37) near(a.mask[i], b.mask[i], 1.0 / 250, "mask " + a.name);
    assert(a.children.size == b.children.size);
    for (int i = 0; i < a.children.size; i++) compare_layers(a.children[i], b.children[i], tolerance);
    if (a.kind == RetouchLayerKind.RASTER) {
        assert(a.x == b.x && a.y == b.y);
        assert(a.pixels.width == b.pixels.width && a.pixels.height == b.pixels.height);
        for (int y = 0; y < a.pixels.height; y += 3) {
            for (int x = 0; x < a.pixels.width; x += 3) {
                float ar, ag, ab, aa, br, bg, bb, ba;
                encoded_at(a.pixels, x, y, out ar, out ag, out ab, out aa);
                encoded_at(b.pixels, x, y, out br, out bg, out bb, out ba);
                near(ar, br, tolerance, "r " + a.name);
                near(ag, bg, tolerance, "g " + a.name);
                near(ab, bb, tolerance, "b " + a.name);
                near(aa, ba, tolerance, "a " + a.name);
            }
        }
    }
}

private void test_ora_roundtrip() {
    var doc = sample_document();
    var text = new RetouchLayer("Caption", RetouchLayerKind.TEXT);
    text.text = new RetouchText();
    text.text.text = "Hello";
    text.text.font = "Sans Bold 12";
    text.text.x = 2;
    text.text.y = 2;
    doc.layers.add(text);
    doc.recomposite();
    try {
        var data = RetouchOra.save(doc);
        string path = Path.build_filename(Environment.get_tmp_dir(), "retouch-roundtrip.ora");
        FileUtils.set_data(path, data);
        uint8[] read_back;
        FileUtils.get_data(path, out read_back);
        var zip = new RetouchZipReader(read_back);
        assert(zip.read_text("mimetype") == "image/openraster");
        assert(zip.has("mergedimage.png") && zip.has("Thumbnails/thumbnail.png"));
        string stack = zip.read_text("stack.xml");
        assert(stack.contains("composite-op=\"svg:multiply\""));
        var doc2 = RetouchOra.load(read_back);
        assert(doc2.width == 48 && doc2.height == 32);
        assert(doc2.layers.size == doc.layers.size);
        for (int i = 0; i < 4; i++) compare_layers(doc.layers[i], doc2.layers[i], 1.0 / 4000);
        assert(doc2.layers[2].adjustment != null);
        near(doc2.layers[2].adjustment.value_of("gamma"), 1.4, 1e-6, "gamma");
        assert(doc2.layers[4].kind == RetouchLayerKind.TEXT && doc2.layers[4].text.text == "Hello");
        for (int y = 0; y < 32; y += 5) {
            for (int x = 0; x < 48; x += 5) {
                float ar, ag, ab, aa, br, bg, bb, ba;
                encoded_at(doc.composite, x, y, out ar, out ag, out ab, out aa);
                encoded_at(doc2.composite, x, y, out br, out bg, out bb, out ba);
                near(ar, br, 2e-3, "composite r");
                near(ab, bb, 2e-3, "composite b");
            }
        }
        var decoded = new OraDecoder().decode(File.new_for_path(path), 0);
        assert(decoded.image.width == 48 && decoded.layers != null && decoded.layers.size > 0);
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_psd_roundtrip(int depth) {
    var doc = sample_document();
    doc.layers.remove_at(2);
    doc.recomposite();
    try {
        var data = RetouchPsd.write(doc, depth);
        string path = Path.build_filename(Environment.get_tmp_dir(), "retouch-roundtrip-%d.psd".printf(depth));
        FileUtils.set_data(path, data);
        var doc2 = RetouchPsd.read(data);
        assert(doc2.width == 48 && doc2.height == 32);
        assert(doc2.layers.size == doc.layers.size);
        double tol = depth == 8 ? 1.0 / 250 : 1.0 / 3000;
        for (int i = 0; i < doc.layers.size; i++) compare_layers(doc.layers[i], doc2.layers[i], tol);
        var merged = RetouchPsd.read_merged(data);
        for (int y = 0; y < 32; y += 4) {
            for (int x = 0; x < 48; x += 4) {
                float ar, ag, ab, aa, br, bg, bb, ba;
                encoded_at(doc.composite, x, y, out ar, out ag, out ab, out aa);
                encoded_at(merged, x, y, out br, out bg, out bb, out ba);
                near(ar, br, tol * 2, "merged r");
                near(ag, bg, tol * 2, "merged g");
            }
        }
        var decoded = new PsdDecoder().decode(File.new_for_path(path), 0);
        assert(decoded.format == "psd" && decoded.image.width == 48);
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_psd_8() {
    test_psd_roundtrip(8);
}

private void test_psd_16() {
    test_psd_roundtrip(16);
}

private void check_magick(string name, double tol, double alpha) {
    try {
        uint8[] data;
        FileUtils.get_data(Path.build_filename(fixtures, "retouch", name), out data);
        var doc = RetouchPsd.read(data);
        assert(doc.width == 64 && doc.height == 48);
        assert(doc.layers.size == 2);
        assert(doc.layers[0].name == "Base" && doc.layers[1].name == "Blue");
        assert(doc.layers[1].x == 10 && doc.layers[1].y == 8);
        assert(doc.layers[1].pixels.width == 20 && doc.layers[1].pixels.height == 16);
        float r, g, b, a;
        encoded_at(doc.layers[1].pixels, 3, 3, out r, out g, out b, out a);
        near(r * 255, 20, 255 * tol, "blue r");
        near(b * 255, 220, 255 * tol, "blue b");
        near(a, alpha, 0.002, "blue alpha");
        if (alpha > 0.1) {
            encoded_at(doc.composite, 15, 12, out r, out g, out b, out a);
            near(r * 255, 110, 2, "merged r");
            near(g * 255, 35, 2, "merged g");
            near(b * 255, 130, 2, "merged b");
        }
        var merged = RetouchPsd.read_merged(data);
        encoded_at(merged, 15, 12, out r, out g, out b, out a);
        near(r * 255, 110, 2, "stored merged r");
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_psd_magick() {
    check_magick("magick-layers8.psd", 1.0 / 250, 127.0 / 255);
    check_magick("magick-layers16.psd", 1.0 / 2000, 128.0 / 65535);
}

private double area(float[] plane) {
    double s = 0;
    foreach (var v in plane) s += v;
    return s;
}

private void test_selection() {
    int w = 100, h = 80;
    var rect = RetouchSelection.rect(w, h, 10.5, 10, 20, 30);
    near(area(rect), 600, 1e-3, "rect area");
    var ell = RetouchSelection.ellipse(w, h, 20, 20, 40, 40);
    near(area(ell), Math.PI * 400, 15, "ellipse area");
    var tri = RetouchSelection.polygon(w, h, { 0, 0, 60, 0, 0, 40 });
    near(area(tri), 1200, 6, "triangle area");
    var inv = RetouchSelection.invert(rect, w, h);
    near(area(inv), w * h - 600, 1e-3, "invert");
    var add = RetouchSelection.combine(rect, RetouchSelection.rect(w, h, 20.5, 10, 20, 30), SelectionOp.ADD);
    near(area(add), 900, 1e-3, "add");
    var inter = RetouchSelection.combine(rect, RetouchSelection.rect(w, h, 20.5, 10, 20, 30), SelectionOp.INTERSECT);
    near(area(inter), 300, 1e-3, "intersect");
    var sub = RetouchSelection.combine(rect, RetouchSelection.rect(w, h, 20.5, 10, 20, 30), SelectionOp.SUBTRACT);
    near(area(sub), 300, 1e-3, "subtract");
    var square = RetouchSelection.rect(w, h, 30, 30, 20, 20);
    var grown = RetouchSelection.expand(square, w, h, 5);
    near(area(grown), 900 - (4 - Math.PI) * 25, 40, "expand");
    var shrunk = RetouchSelection.expand(square, w, h, -5);
    near(area(shrunk), 100, 15, "contract");
    var img = encoded_image(w, h, 0.1f, 0.1f, 0.1f);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            bool left = x < 30, right = x >= 70;
            if (left || right) {
                float r, g, b;
                RetouchColor.pixel_to_working(0.9f, 0.2f, 0.2f, out r, out g, out b);
                img.set_pixel(x, y, r, g, b);
            }
        }
    }
    var wand = RetouchSelection.magic_wand(img, 5, 5, 0.1, true);
    near(area(wand), 30 * h, 1e-3, "wand contiguous");
    var global = RetouchSelection.magic_wand(img, 5, 5, 0.1, false);
    near(area(global), 60 * h, 1e-3, "wand global");
    var quick = RetouchSelection.quick_select(img, null, { 50, 40, 52, 40 }, 4, false);
    double inside = 0, outside = 0;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            if (x >= 32 && x < 68) inside += quick[y * w + x];
            if (x < 28 || x >= 72) outside += quick[y * w + x];
        }
    }
    assert(inside > 36 * h * 0.95);
    assert(outside < 10);
    var feathered = RetouchSelection.feather(rect, w, h, 3);
    near(area(feathered), 600, 5, "feather preserves area");
    var lum = RetouchSelection.luminance_range(img, 0.5, 1.0, 0.0);
    near(area(lum), 0, 1e-3, "luminance range");
}

private void test_liquify() {
    var src = noise_image(64, 40, 3);
    var liq = new RetouchLiquify(src);
    assert(liq.is_identity());
    var out_img = liq.render();
    for (size_t i = 0; i < src.data.length; i++) assert(out_img.data[i] == src.data[i]);
    liq.apply_brush(LiquifyBrush.BLOAT, 32, 20, 0, 0, 15, 1);
    assert(!liq.is_identity());
    var bloated = liq.render();
    bool changed = false;
    for (size_t i = 0; i < src.data.length; i++) if ((bloated.data[i] - src.data[i]).abs() > 1e-4) changed = true;
    assert(changed);
    near(bloated.data[bloated.offset(32, 20)], src.data[src.offset(32, 20)], 1e-5, "center fixed");
    for (int k = 0; k < 60; k++) liq.apply_brush(LiquifyBrush.RECONSTRUCT, 32, 20, 0, 0, 40, 1);
    double max_d = 0;
    for (size_t i = 0; i < liq.dx.length; i++) max_d = double.max(max_d, double.max(liq.dx[i].abs(), liq.dy[i].abs()));
    assert(max_d < 0.05);
    liq.reset();
    liq.freeze[20 * liq.grid_w + 32] = 1;
    liq.apply_brush(LiquifyBrush.FORWARD, 32, 20, 5, 0, 10, 1);
    near(liq.dx[20 * liq.grid_w + 32], 0, 1e-6, "frozen");
}

private void test_mesh() {
    var src = noise_image(30, 20, 11);
    double[] corners = { 0, 0, 30, 0, 30, 20, 0, 20 };
    var mesh = RetouchMesh.mesh_from_quad(corners, 8);
    var out_img = RetouchMesh.render(src, mesh, 8, 30, 20);
    for (int y = 1; y < 19; y++)
        for (int x = 1; x < 29; x++)
            for (int c = 0; c < 4; c++) near(out_img.data[out_img.offset(x, y) + c], src.data[src.offset(x, y) + c], 1e-4, "mesh identity");
    double[] shifted = { 5, 3, 35, 3, 35, 23, 5, 23 };
    var moved = RetouchMesh.render(src, RetouchMesh.mesh_from_quad(shifted, 8), 8, 40, 30);
    for (int c = 0; c < 3; c++) near(moved.data[moved.offset(15, 13) + c], src.data[src.offset(10, 10) + c], 1e-4, "mesh translate");
    var hm = RetouchMesh.homography({ 0, 0, 1, 0, 1, 1, 0, 1 }, { 0, 0, 2, 0, 2, 1, 0, 1 });
    double u, v;
    RetouchMesh.project(hm, 0.5, 0.5, out u, out v);
    near(u, 1, 1e-9, "homography u");
    near(v, 0.5, 1e-9, "homography v");
}

private void test_frequency_separation() {
    var doc = new RetouchDocument(40, 30);
    var layer = new RetouchLayer("Photo", RetouchLayerKind.RASTER);
    layer.pixels = noise_image(40, 30, 21);
    doc.layers.add(layer);
    doc.recomposite();
    var original = doc.composite.copy();
    var made = RetouchOps.frequency_separation(doc, layer, 3);
    layer.visible = false;
    doc.layers.add(made[0]);
    doc.layers.add(made[1]);
    doc.recomposite();
    assert(made[1].mode == BlendMode.LINEAR_LIGHT);
    for (int y = 0; y < 30; y++) {
        for (int x = 0; x < 40; x++) {
            float ar, ag, ab, aa, br, bg, bb, ba;
            encoded_at(original, x, y, out ar, out ag, out ab, out aa);
            encoded_at(doc.composite, x, y, out br, out bg, out bb, out ba);
            near(ar, br, 2e-3, "freq r");
            near(ag, bg, 2e-3, "freq g");
            near(ab, bb, 2e-3, "freq b");
        }
    }
}

private void test_adjustments() {
    var a = new RetouchAdjustment("black-white");
    float r = 0.5f, g = 0.5f, b = 0.5f;
    a.pixel(ref r, ref g, ref b);
    near(r, 0.5, 1e-6, "bw gray");
    r = 1; g = 0; b = 0;
    a.pixel(ref r, ref g, ref b);
    near(r, 0.4, 1e-6, "bw red");
    assert(r == g && g == b);
    var lv = new RetouchAdjustment("levels");
    lv.put("input-black", 0.2);
    lv.put("input-white", 0.8);
    r = 0.5f; g = 0.2f; b = 0.8f;
    lv.pixel(ref r, ref g, ref b);
    near(r, 0.5, 1e-5, "levels mid");
    near(g, 0, 1e-5, "levels black");
    near(b, 1, 1e-5, "levels white");
    var hs = new RetouchAdjustment("hue-saturation");
    hs.put("saturation", -1);
    r = 0.9f; g = 0.1f; b = 0.3f;
    hs.pixel(ref r, ref g, ref b);
    near(r, g, 1e-5, "desaturate");
    try {
        var back = RetouchAdjustment.from_json(lv.to_json());
        near(back.value_of("input-white"), 0.8, 1e-9, "json");
    } catch (Error e) {
        error("%s", e.message);
    }
    var packed = RetouchPsd.pack_bits({ 1, 1, 1, 1, 2, 3, 4, 4, 5 });
    assert(packed.length < 9);
}

private void test_brush_and_heal_fallback() {
    var img = encoded_image(20, 20, 0.5f, 0.5f, 0.5f);
    float r, g, b;
    RetouchColor.pixel_to_working(1, 0, 0, out r, out g, out b);
    RetouchBrush.paint_dab(img, 0, 0, 10, 10, 4, 1.0, r, g, b, 1, null, 20, false);
    float er, eg, eb, ea;
    encoded_at(img, 10, 10, out er, out eg, out eb, out ea);
    near(er, 1, 1e-3, "paint");
    encoded_at(img, 0, 0, out er, out eg, out eb, out ea);
    near(er, 0.5, 1e-3, "paint outside");
    var src = noise_image(20, 20, 5);
    var dst = encoded_image(20, 20, 0, 0, 0);
    RetouchBrush.clone_dab(dst, 0, 0, src, 10, 10, 3, 2, 3, 1.0, 1, null, 20, null);
    for (int c = 0; c < 3; c++) near(dst.data[dst.offset(10, 10) + c], src.data[src.offset(13, 12) + c], 1e-5, "clone");
}

private void test_svg_export() {
    try {
        string svg = RetouchExternal.svg_with_image(encoded_image(8, 6, 1, 0, 0), "a<b");
        assert(svg.contains("viewBox=\"0 0 8 6\""));
        assert(svg.contains("data:image/png;base64,"));
        assert(svg.contains("a&lt;b"));
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_fill_variants() {
    int w = 80, h = 60;
    var img = new FloatImage(w, h);
    var rand = new Rand.with_seed(17);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            float v = 0.2f + 0.5f * (float) rand.next_double();
            img.set_pixel(x, y, v, v * 0.9f, v * 0.5f);
        }
    }
    var mask = RetouchSelection.rect(w, h, 30, 22, 14, 12);
    var original = img.copy();
    var results = new Gee.ArrayList<FloatImage>();
    for (int variant = 0; variant < 3; variant++) {
        int ox, oy;
        var piece = RetouchOps.fill_variant(img, mask, variant, out ox, out oy);
        for (size_t i = 0; i < img.data.length; i++) assert(img.data[i] == original.data[i]);
        var out_img = original.copy();
        RetouchOps.apply_variant(out_img, mask, piece, ox, oy);
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                bool inside = mask[y * w + x] > 0;
                size_t o = out_img.offset(x, y);
                if (!inside) assert(out_img.data[o] == original.data[o]);
                else assert(out_img.data[o] >= 0.19f && out_img.data[o] <= 0.71f);
            }
        }
        results.add(out_img);
    }
    int differing = 0;
    for (int i = 1; i < results.size; i++) {
        double diff = 0;
        for (size_t k = 0; k < results[0].data.length; k++) diff += (results[i].data[k] - results[0].data[k]).abs();
        if (diff > 0.5) differing++;
    }
    assert(differing >= 1);
}

private bool wait_for(owned SourceFunc done, int seconds) {
    var loop = new MainLoop();
    bool ok = false;
    uint timeout = Timeout.add_seconds(seconds, () => {
        loop.quit();
        return Source.REMOVE;
    });
    uint poll = Timeout.add(50, () => {
        if (done()) {
            ok = true;
            loop.quit();
            return Source.REMOVE;
        }
        return Source.CONTINUE;
    });
    loop.run();
    Source.remove(timeout);
    if (!ok) Source.remove(poll);
    return ok;
}

private void test_external_roundtrip() {
    try {
        string dir = Path.build_filename(Environment.get_tmp_dir(), "retouch-external-" + Uuid.string_random());
        var doc = RetouchDocument.from_image(encoded_image(40, 30, 0.2f, 0.4f, 0.6f), "Base");
        var ext = new RetouchExternal();
        FloatImage? got = null;
        ext.returned.connect((img) => got = img);
        var file = ext.prepare(doc, RetouchExternal.DRAW_ID, "photo", dir);
        assert(file.get_basename() == "photo.ora");
        uint8[] exported;
        FileUtils.get_data(file.get_path(), out exported);
        var roundtrip = RetouchOra.load(exported);
        assert(roundtrip.width == 40 && roundtrip.layers.size == 1);
        var edited = RetouchDocument.from_image(encoded_image(40, 30, 0.9f, 0.1f, 0.1f), "Painted");
        var extra = new RetouchLayer("Stroke", RetouchLayerKind.RASTER);
        extra.pixels = encoded_image(10, 10, 0.0f, 1.0f, 0.0f);
        extra.x = 5;
        extra.y = 5;
        edited.layers.add(extra);
        edited.recomposite();
        string partial = file.get_path() + ".tmp";
        FileUtils.set_data(partial, RetouchOra.save(edited));
        FileUtils.rename(partial, file.get_path());
        assert(wait_for(() => got != null, 10));
        float r, g, b, a;
        encoded_at(got, 20, 20, out r, out g, out b, out a);
        near(r, 0.9, 5e-3, "draw return r");
        encoded_at(got, 8, 8, out r, out g, out b, out a);
        near(g, 1.0, 5e-3, "draw return stroke");
        ext.stop();
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_open_document_colors() {
    check_open_colors("colors.png", 1.5);
    check_open_colors("colors.jpg", 4);
}

private void check_open_colors(string name, double tol) {
    try {
        var file = File.new_for_path(Path.build_filename(fixtures, "retouch", name));
        var doc = RetouchDocument.open(file);
        assert(doc.width == 64 && doc.height == 40);
        for (int y = 0; y < 40; y += 7) {
            for (int x = 0; x < 64; x += 9) {
                float r, g, b, a;
                encoded_at(doc.composite, x, y, out r, out g, out b, out a);
                near(r * 255, int.min(255, x * 4), tol, "open r " + name);
                near(g * 255, int.min(255, y * 6), tol, "open g " + name);
                near(b * 255, (x * y) % 256, tol * 3, "open b " + name);
            }
        }
    } catch (Error e) {
        error("%s", e.message);
    }
}

int main(string[] args) {
    Test.init(ref args);
    fixtures = args.length > 1 ? args[1] : "tests/fixtures";
    Test.add_func("/retouch/zip", test_zip);
    Test.add_func("/retouch/composite", test_composite);
    Test.add_func("/retouch/undo", test_undo);
    Test.add_func("/retouch/ora", test_ora_roundtrip);
    Test.add_func("/retouch/psd8", test_psd_8);
    Test.add_func("/retouch/psd16", test_psd_16);
    Test.add_func("/retouch/psd-imagemagick", test_psd_magick);
    Test.add_func("/retouch/selection", test_selection);
    Test.add_func("/retouch/liquify", test_liquify);
    Test.add_func("/retouch/mesh", test_mesh);
    Test.add_func("/retouch/frequency", test_frequency_separation);
    Test.add_func("/retouch/adjustments", test_adjustments);
    Test.add_func("/retouch/brush", test_brush_and_heal_fallback);
    Test.add_func("/retouch/svg", test_svg_export);
    Test.add_func("/retouch/fill-variants", test_fill_variants);
    Test.add_func("/retouch/open-colors", test_open_document_colors);
    Test.add_func("/retouch/external-roundtrip", test_external_roundtrip);
    return Test.run();
}
