using Singularity.Apps.Photos;
using Singularity.Imaging;

private string tmp_dir;

private void test_plugins() {
    string exe = "";
    try {
        exe = FileUtils.read_link("/proc/self/exe");
    } catch (Error e) {
        assert_not_reached();
    }
    Environment.set_variable("SINGULARITY_PHOTOS_PLUGIN_PATH", Path.build_filename(Path.get_dirname(exe), "src", "output"), true);
    Environment.set_variable("PHOTOS_SAMPLE_EXPORT_DIR", Path.build_filename(tmp_dir, "delivered"), true);
    var host = PhotosPluginHost.get_default();
    assert("sample-tools" in host.loaded_modules);
    assert(host.filters().size >= 1);
    assert(host.export_destinations().size >= 1);
    assert(host.metadata_providers().size >= 1);
    var img = new FloatImage.filled(4, 4, 0.2f, 0.5f, 0.8f);
    host.apply_filter("sample-warm-film", img, 1.0);
    float r, g, b, a;
    img.get_pixel(1, 1, out r, out g, out b, out a);
    assert(r > 0.2f && b < 0.8f);
    string p = Path.build_filename(tmp_dir, "x.png");
    try {
        FileUtils.set_data(p, ImageWriters.encode_png(img, 8, new uint8[0], new uint8[0], "", 72));
    } catch (Error e) {
        assert_not_reached();
    }
    var dest = host.find_destination("sample-copy-folder");
    assert(dest != null);
    var loop = new MainLoop();
    dest.deliver.begin({ File.new_for_path(p) }, null, (o, res) => {
        try {
            dest.deliver.end(res);
        } catch (Error e) {
            assert_not_reached();
        }
        loop.quit();
    });
    loop.run();
    assert(FileUtils.test(Path.build_filename(tmp_dir, "delivered", "x.png"), FileTest.EXISTS));
    var facts = host.metadata_providers()[0];
    assert(facts.read(File.new_for_path(p), "extension") == "png");
    var s = new ExportSettings();
    s.filter = "sample-warm-film";
    s.filter_amount = 1.0;
    s.format = "png";
    s.destination = "folder";
    s.folder = Path.build_filename(tmp_dir, "out");
    var src_img = new FloatImage.filled(4, 4, 0.2f, 0.5f, 0.8f);
    string src = Path.build_filename(tmp_dir, "src.png");
    try {
        FileUtils.set_data(src, ImageWriters.encode_png(src_img, 8, new uint8[0], new uint8[0], "", 72));
    } catch (Error e) {
        assert_not_reached();
    }
    var results = ExportEngine.run({ File.new_for_path(src) }, s);
    assert(results[0].ok);
    try {
        var out_img = FloatImage.from_texture(Gdk.Texture.from_file(results[0].target), false);
        var in_img = FloatImage.from_texture(Gdk.Texture.from_filename(src), false);
        float r1, g1, b1, a1, r0, g0, b0, a0;
        out_img.get_pixel(1, 1, out r1, out g1, out b1, out a1);
        in_img.get_pixel(1, 1, out r0, out g0, out b0, out a0);
        assert(b1 < b0 - 0.02f);
    } catch (Error e) {
        assert_not_reached();
    }
}

int main(string[] args) {
    Test.init(ref args);
    try {
        tmp_dir = DirUtils.make_tmp("photos-plugins-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Test.add_func("/output/plugins/sample", test_plugins);
    return Test.run();
}
