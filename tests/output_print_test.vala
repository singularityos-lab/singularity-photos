using Singularity.Apps.Photos;
using Singularity.Imaging;

private string tmp_dir;

private File make_photo(string name, int w, int h, float r, float g, float b) {
    var img = new FloatImage.filled(w, h, r, g, b, 1.0f);
    string p = Path.build_filename(tmp_dir, name);
    try {
        FileUtils.set_data(p, ImageWriters.encode_png(img, 8, new uint8[0], new uint8[0], "", 72));
    } catch (Error e) {
        assert_not_reached();
    }
    return File.new_for_path(p);
}

private int paginate(PhotoPrintSource src, Singularity.Print.PageFormat f) {
    var loop = new MainLoop();
    int pages = -1;
    src.paginate.begin(f, (o, res) => {
        try {
            pages = src.paginate.end(res);
        } catch (Error e) {
            pages = -2;
        }
        loop.quit();
    });
    loop.run();
    return pages;
}

private Singularity.Print.PageFormat a4() {
    var f = new Singularity.Print.PageFormat();
    f.width = 595.3;
    f.height = 841.9;
    f.margin_top = f.margin_bottom = f.margin_left = f.margin_right = 36;
    return f;
}

private Cairo.ImageSurface render(PhotoPrintSource src, int page) {
    var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, 596, 842);
    var cr = new Cairo.Context(surface);
    cr.set_source_rgb(1, 1, 1);
    cr.paint();
    src.render_page(cr, page);
    surface.flush();
    return surface;
}

private void rgb_at(Cairo.ImageSurface s, int x, int y, out int r, out int g, out int b) {
    unowned uint8[] d = s.get_data();
    int o = y * s.get_stride() + x * 4;
    b = d[o];
    g = d[o + 1];
    r = d[o + 2];
}

private void test_layouts() {
    File[] files = {};
    for (int i = 0; i < 10; i++) files += make_photo("p%d.png".printf(i), 300, 200, 0.8f, 0.1f, 0.1f);
    var src = new PhotoPrintSource(files);
    var f = a4();
    assert(paginate(src, f) == 10);
    var page = render(src, 3);
    int r, g, b;
    rgb_at(page, 298, 421, out r, out g, out b);
    assert(r > 180 && g < 120 && b < 120);
    rgb_at(page, 298, 150, out r, out g, out b);
    assert(r == 255 && g == 255 && b == 255);
    src.extra_options.set_choice("fit", "fill");
    page = render(src, 0);
    rgb_at(page, 298, 150, out r, out g, out b);
    assert(r > 180 && g < 120);
    rgb_at(page, 10, 10, out r, out g, out b);
    assert(r == 255);
    src.extra_options.set_choice("layout", "contact");
    src.extra_options.set_number("columns", 3);
    int contact = paginate(src, f);
    int per = PrintLayout.contact_per_page(f.content_width, f.content_height, 3, 0);
    assert(per == 12);
    assert(contact == 1);
    var cells = src.cells_for(0);
    assert(cells.length == 10);
    assert(cells[9].photo == 9);
    src.extra_options.set_number("columns", 6);
    assert(paginate(src, f) == 1);
    src.extra_options.set_number("columns", 2);
    int per2 = PrintLayout.contact_per_page(f.content_width, f.content_height, 2, 0);
    assert(paginate(src, f) == (10 + per2 - 1) / per2);
    src.extra_options.set_choice("layout", "package");
    src.extra_options.set_choice("package", "4x3.5x5");
    assert(paginate(src, f) == 10);
    var pkg = src.cells_for(2);
    assert(pkg.length == 4);
    foreach (var c in pkg) {
        assert(c.photo == 2);
        assert(c.x >= 36 - 0.01 && c.x + c.width <= 595.3 - 36 + 0.6);
        assert(c.y >= 36 - 0.01 && c.y + c.height <= 841.9 - 36 + 0.6);
        assert(((c.width - 252).abs() < 0.01 && (c.height - 360).abs() < 0.01) || ((c.width - 360).abs() < 0.01 && (c.height - 252).abs() < 0.01));
    }
    for (int i = 0; i < pkg.length; i++)
        for (int j = i + 1; j < pkg.length; j++)
            assert(pkg[i].x + pkg[i].width <= pkg[j].x + 0.01 || pkg[j].x + pkg[j].width <= pkg[i].x + 0.01
                || pkg[i].y + pkg[i].height <= pkg[j].y + 0.01 || pkg[j].y + pkg[j].height <= pkg[i].y + 0.01);
    src.extra_options.set_choice("package", "8wallet");
    assert(src.cells_for(0).length == 8);
    src.extra_options.set_choice("package", "2x5x7");
    var two = src.cells_for(0);
    assert(two.length == 2);
    assert((two[0].width - two[1].width).abs() < 0.01 && (two[0].width / two[0].height - 5.0 / 7.0).abs() < 0.01 || (two[0].width / two[0].height - 7.0 / 5.0).abs() < 0.01);
}

private void test_pdf_and_proof() {
    string icc_path = Path.build_filename(tmp_dir, "printer.icc");
    try {
        FileUtils.set_data(icc_path, IccProfile.adobe_rgb().to_data());
    } catch (Error e) {
        assert_not_reached();
    }
    var photo = make_photo("green.png", 200, 200, 0.0f, 0.9f, 0.1f);
    var src = new PhotoPrintSource({ photo });
    src.add_profile(icc_path);
    var f = a4();
    assert(paginate(src, f) == 1);
    var plain = render(src, 0);
    int r0, g0, b0;
    rgb_at(plain, 298, 421, out r0, out g0, out b0);
    src.extra_options.set_choice("profile", "file:" + icc_path);
    src.extra_options.set_bool("proof", false);
    var device = render(src, 0);
    int r1, g1, b1;
    rgb_at(device, 298, 421, out r1, out g1, out b1);
    stdout.printf("# plain %d %d %d device %d %d %d\n", r0, g0, b0, r1, g1, b1);
    assert(r1 > r0 + 20);
    src.extra_options.set_bool("proof", true);
    var proofed = render(src, 0);
    int r2, g2, b2;
    rgb_at(proofed, 298, 421, out r2, out g2, out b2);
    stdout.printf("# proofed %d %d %d\n", r2, g2, b2);
    assert((g2 - g0).abs() <= 6 && (r2 - r0).abs() <= 12);
    string pdf = Path.build_filename(tmp_dir, "out.pdf");
    var surface = new Cairo.PdfSurface(pdf, f.width, f.height);
    var cr = new Cairo.Context(surface);
    src.render_page(cr, 0);
    cr.show_page();
    surface.finish();
    uint8[] data;
    try {
        FileUtils.get_data(pdf, out data);
    } catch (Error e) {
        assert_not_reached();
    }
    assert(data.length > 500 && data[0] == '%' && data[1] == 'P');
}

int main(string[] args) {
    Test.init(ref args);
    try {
        tmp_dir = DirUtils.make_tmp("photos-print-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Test.add_func("/output/print/layouts", test_layouts);
    Test.add_func("/output/print/proof", test_pdf_and_proof);
    return Test.run();
}
