using Singularity.Apps.Photos;
using Singularity.Imaging;

private string? samples = null;

private void check_image(FloatImage img) {
    double sum = 0;
    size_t n = img.pixel_count();
    for (size_t i = 0; i < n; i++) {
        for (int c = 0; c < 3; c++) {
            float v = img.data[i * 4 + c];
            assert(v == v && v.abs() < 1e30f);
            sum += Transfer.linear_to_srgb(v.clamp(0, 1));
        }
    }
    double mean = sum / (n * 3);
    if (mean < 0.03 || mean > 0.97) {
        stderr.printf("mean %f\n", mean);
        assert_not_reached();
    }
}

private void develop_one(string name) {
    if (samples == null) {
        Test.skip("SINGULARITY_PHOTOS_RAW_SAMPLES is not set; run tests/fetch-raw-samples.sh DIR");
        return;
    }
    var file = File.new_for_path(Path.build_filename(samples, name));
    if (!file.query_exists()) {
        Test.skip("sample missing");
        return;
    }
    DecodedPhoto photo;
    try {
        photo = Codecs.load(file, 1024);
    } catch (Error e) {
        if (e.matches(IOError.quark(), IOError.NOT_SUPPORTED)) {
            Test.skip("LibRaw is not available: " + e.message);
            return;
        }
        stderr.printf("%s: %s\n", name, e.message);
        assert_not_reached();
    }
    assert(photo.is_raw());
    assert(photo.full_width > 1000 && photo.full_height > 600);
    assert(int.max(photo.image.width, photo.image.height) <= 1100);
    assert(photo.meta.make != "");
    double r, g, b;
    DevelopPipeline.white_balance_multipliers(photo, new EditParams(), out r, out g, out b);
    assert(r > 0.2 && r < 5 && b > 0.2 && b < 5);
    double t, ti;
    RawColor.temperature_for(photo.raw, r, g, b, out t, out ti);
    assert(t > 2000 && t < 15000);
    var plain = DevelopPipeline.render(photo, new EditParams(), new RenderOptions.preview(800));
    check_image(plain);
    var p = new EditParams();
    p.set_value(Adjustment.EXPOSURE, 0.25);
    p.set_value(Adjustment.HIGHLIGHTS, -0.5);
    p.set_value(Adjustment.SHADOWS, 0.4);
    p.set_value(Adjustment.CLARITY, 0.2);
    p.set_value(Adjustment.SHARPNESS, 0.3);
    p.develop.set("detail.noise.amount", 0.3);
    p.develop.set("detail.color.amount", 0.3);
    p.develop.set_string("wb.mode", "custom");
    p.develop.set("wb.temperature", t * 0.7);
    p.develop.set("wb.tint", ti);
    var edited = DevelopPipeline.render(photo, p, new RenderOptions.preview(800));
    check_image(edited);
    double cool = 0, warm = 0;
    for (size_t i = 0; i < plain.pixel_count(); i += 7) {
        warm += plain.data[i * 4] - plain.data[i * 4 + 2];
        cool += edited.data[i * 4] - edited.data[i * 4 + 2];
    }
    assert(cool < warm);
    string out_dir = Environment.get_variable("SINGULARITY_PHOTOS_RAW_PREVIEWS") ?? Environment.get_tmp_dir();
    try {
        EditImageIO.save_working(edited, File.new_for_path(Path.build_filename(out_dir, name + ".png")));
        EditImageIO.save_working(plain, File.new_for_path(Path.build_filename(out_dir, name + ".plain.png")));
    } catch (Error e) {
        assert_not_reached();
    }
}

int main(string[] args) {
    Test.init(ref args);
    samples = Environment.get_variable("SINGULARITY_PHOTOS_RAW_SAMPLES");
    foreach (var ext in new string[] { "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2" }) {
        string name = "sample." + ext;
        Test.add_data_func("/raw-samples/" + ext, () => develop_one(name));
    }
    return Test.run();
}
