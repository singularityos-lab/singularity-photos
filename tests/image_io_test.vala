using Singularity.Apps.Photos;

private const string ORIENT6_JPEG = "/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAAAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAAIABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD8X6/Ieiiv9UP9GX/5zY/71u/+D2f7Uf6Qz/ziH/3n7/4Ch//Z";

private string make_dir() {
    try {
        return DirUtils.make_tmp("photos-io-XXXXXX");
    } catch (Error e) {
        error("%s", e.message);
    }
}

private File write_orient6(string dir) {
    var file = File.new_for_path(Path.build_filename(dir, "o6.jpg"));
    try {
        FileUtils.set_data(file.get_path(), Base64.decode(ORIENT6_JPEG));
    } catch (Error e) {
        error("%s", e.message);
    }
    return file;
}

private void texture_pixel(Gdk.Texture texture, int x, int y, out int r, out int g, out int b) {
    var downloader = new Gdk.TextureDownloader(texture);
    downloader.set_format(Gdk.MemoryFormat.R8G8B8A8);
    size_t stride;
    var bytes = downloader.download_bytes(out stride);
    unowned uint8[] data = bytes.get_data();
    size_t i = y * stride + x * 4;
    r = data[i];
    g = data[i + 1];
    b = data[i + 2];
}

private void assert_red_top_blue_bottom(Gdk.Texture texture) {
    int r, g, b;
    texture_pixel(texture, 4, 2, out r, out g, out b);
    assert(r > 200 && g < 60 && b < 60);
    texture_pixel(texture, 4, 13, out r, out g, out b);
    assert(b > 200 && r < 60 && g < 60);
}

private void test_display_texture_orientation() {
    string dir = make_dir();
    var file = write_orient6(dir);
    try {
        var texture = EditImageIO.load_display_texture(file);
        assert(texture.width == 8 && texture.height == 16);
        assert_red_top_blue_bottom(texture);
    } catch (Error e) {
        error("%s", e.message);
    }
    FileUtils.remove(file.get_path());
    DirUtils.remove(dir);
}

private void test_thumbnail_orientation() {
    string dir = make_dir();
    var file = write_orient6(dir);
    try {
        var pb = EditImageIO.oriented(new Gdk.Pixbuf.from_file_at_scale(file.get_path(), 8, 8, true));
        assert(pb.width == 4 && pb.height == 8);
    } catch (Error e) {
        error("%s", e.message);
    }
    FileUtils.remove(file.get_path());
    DirUtils.remove(dir);
}

private void test_markup_source() {
    string dir = make_dir();
    Environment.set_variable("XDG_CACHE_HOME", Path.build_filename(dir, "cache"), true);
    Environment.set_variable("XDG_DATA_HOME", Path.build_filename(dir, "data"), true);
    var file = write_orient6(dir);
    try {
        var upright = EditImageIO.markup_source(file);
        assert(!upright.equal(file));
        var texture = Gdk.Texture.from_file(upright);
        assert(texture.width == 8 && texture.height == 16);
        assert_red_top_blue_bottom(texture);

        var p = new EditParams();
        p.set_crop(0.0, 0.0, 1.0, 0.5);
        EditStore.save(file, p);
        var edited = EditImageIO.markup_source(file);
        assert(edited.equal(EditStore.render_cache(file)));
        var et = Gdk.Texture.from_file(edited);
        assert(et.width == 8 && et.height == 8);
        int r, g, b;
        texture_pixel(et, 4, 4, out r, out g, out b);
        assert(r > 200 && b < 60);
        EditStore.revert(file);

        var png = File.new_for_path(Path.build_filename(dir, "plain.png"));
        new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, 4, 4).savev(png.get_path(), "png", {}, {});
        assert(EditImageIO.markup_source(png).equal(png));
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_display_off_main_thread() {
    string dir = make_dir();
    Environment.set_variable("XDG_CACHE_HOME", Path.build_filename(dir, "cache"), true);
    Environment.set_variable("XDG_DATA_HOME", Path.build_filename(dir, "data"), true);
    var file = File.new_for_path(Path.build_filename(dir, "big.png"));
    try {
        var pb = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, 3000, 2000);
        pb.fill(0x406080ff);
        pb.savev(file.get_path(), "png", {}, {});
        var p = new EditParams();
        p.set_value(Adjustment.CONTRAST, 0.4);
        p.set_value(Adjustment.SHARPNESS, 0.5);
        EditStore.save(file, p);
    } catch (Error e) {
        error("%s", e.message);
    }
    var loop = new MainLoop();
    int64 last = get_monotonic_time();
    int64 worst = 0;
    int ticks = 0;
    Gdk.Texture? result = null;
    var tick = Timeout.add(5, () => {
        int64 now = get_monotonic_time();
        worst = int64.max(worst, now - last);
        last = now;
        ticks++;
        return Source.CONTINUE;
    });
    int64 start = get_monotonic_time();
    new Thread<void>("load", () => {
        try {
            result = EditImageIO.load_display_texture(file);
        } catch (Error e) {
            error("%s", e.message);
        }
        Idle.add(() => {
            loop.quit();
            return Source.REMOVE;
        });
    });
    loop.run();
    Source.remove(tick);
    int64 took = get_monotonic_time() - start;
    stdout.printf("# render %s ms, %d ticks, worst main loop gap %s ms\n", (took / 1000).to_string(), ticks, (worst / 1000).to_string());
    assert(result != null && result.width == 3000 && result.height == 2000);
    assert(EditStore.valid_cache(file) != null);
    assert(worst < 60000);
    assert(ticks > 3);
}

void main(string[] args) {
    Test.init(ref args);
    Test.add_func("/image-io/display-texture-orientation", test_display_texture_orientation);
    Test.add_func("/image-io/thumbnail-orientation", test_thumbnail_orientation);
    Test.add_func("/image-io/markup-source", test_markup_source);
    Test.add_func("/image-io/display-off-main-thread", test_display_off_main_thread);
    Test.run();
}
