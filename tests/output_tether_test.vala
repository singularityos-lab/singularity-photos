using Singularity.Apps.Photos;
using Singularity.Imaging;

private string tmp_dir;

private void test_detect() {
    if (Environment.get_variable("SINGULARITY_PHOTOS_PROBE_CAMERAS") == "1") {
        var cams = TetherSession.detect();
        stdout.printf("# cameras detected: %d\n", cams.size);
    }
    var bogus = new TetherSession(new TetherCamera("No Such Camera 9000", "usb:999,999"));
    try {
        bogus.open();
        assert_not_reached();
    } catch (Error e) {
        assert(e.message != "");
    }
    bogus.close();
}

private void test_preset_import() {
    Environment.set_variable("SINGULARITY_PHOTOS_PRESET_DIR", Path.build_filename(tmp_dir, "presets"), true);
    string p = Path.build_filename(tmp_dir, "cap.png");
    try {
        FileUtils.set_data(p, ImageWriters.encode_png(new FloatImage.filled(8, 8, 0.4f, 0.4f, 0.4f), 8, new uint8[0], new uint8[0], "", 72));
    } catch (Error e) {
        assert_not_reached();
    }
    var file = File.new_for_path(p);
    DevelopPreset? chosen = null;
    foreach (var preset in DevelopPresets.all()) {
        if (!preset.params.is_identity()) {
            chosen = preset;
            break;
        }
    }
    assert(chosen != null);
    try {
        TetherImport.apply_preset(file, "");
        assert(!EditStore.has_edits(file));
        TetherImport.apply_preset(file, chosen.id);
        assert(EditStore.has_edits(file));
        var p2 = EditStore.load(file);
        assert(p2 != null && !p2.is_identity());
        TetherImport.apply_preset(file, "missing-preset");
        assert_not_reached();
    } catch (Error e) {
        assert(e is IOError.NOT_FOUND);
    }
}

private void test_directory_camera() {
    string card = Path.build_filename(tmp_dir, "card", "DCIM", "100TEST");
    DirUtils.create_with_parents(card, 0755);
    try {
        FileUtils.set_data(Path.build_filename(card, "IMG_0001.png"), ImageWriters.encode_png(new FloatImage.filled(8, 8, 0.3f, 0.3f, 0.3f), 8, new uint8[0], new uint8[0], "", 72));
        FileUtils.set_data(Path.build_filename(card, "IMG_0002.png"), ImageWriters.encode_png(new FloatImage.filled(8, 8, 0.6f, 0.3f, 0.3f), 8, new uint8[0], new uint8[0], "", 72));
        FileUtils.set_data(Path.build_filename(card, "notes.txt"), "x".data);
    } catch (Error e) {
        assert_not_reached();
    }
    var session = new TetherSession(new TetherCamera("Directory Browse", "disk:" + Path.build_filename(tmp_dir, "card")));
    try {
        session.open();
        var files = session.camera_files();
        stdout.printf("# camera files: %s\n", string.joinv(", ", files));
        assert(files.length == 2);
        assert(!session.can_capture());
        try {
            session.preview();
            assert_not_reached();
        } catch (Error e) {
            assert(e is IOError.NOT_SUPPORTED);
        }
        var dest = File.new_for_path(Path.build_filename(tmp_dir, "imported"));
        var got = TetherImport.import_new(session, dest, "");
        assert(got.size == 2);
        assert(FileUtils.test(Path.build_filename(tmp_dir, "imported", "IMG_0001.png"), FileTest.EXISTS));
        assert(TetherImport.import_new(session, dest, "").size == 0);
        session.close();
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
}

int main(string[] args) {
    Test.init(ref args);
    try {
        tmp_dir = DirUtils.make_tmp("photos-tether-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Test.add_func("/output/tether/detect", test_detect);
    Test.add_func("/output/tether/preset", test_preset_import);
    Environment.set_variable("XDG_DATA_HOME", Path.build_filename(tmp_dir, "data"), true);
    Test.add_func("/output/tether/directory-camera", test_directory_camera);
    return Test.run();
}
