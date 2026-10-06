using Singularity.Apps.Photos;
using Singularity.Imaging;

private string tmp_dir;

private void test_live() {
    var jpeg_img = new FloatImage.filled(16, 16, 0.5f, 0.2f, 0.1f);
    uint8[] jpeg;
    try {
        jpeg = ImageWriters.encode_jpeg(jpeg_img, 90, new uint8[0], new uint8[0], "", 72);
    } catch (Error e) {
        assert_not_reached();
    }
    uint8[] mp4 = { 0, 0, 0, 0x18, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm', 0, 0, 2, 0, 'i', 's', 'o', 'm', 'm', 'p', '4', '1', 0, 0, 0, 8, 'f', 'r', 'e', 'e' };
    var motion = new ByteArray();
    motion.append(jpeg);
    motion.append(mp4);
    string mp = Path.build_filename(tmp_dir, "PXL_motion.jpg");
    try {
        FileUtils.set_data(mp, motion.data);
    } catch (Error e) {
        assert_not_reached();
    }
    assert(LivePhoto.embedded_video_offset(motion.data) == jpeg.length);
    assert(LivePhoto.embedded_video_offset(jpeg) == -1);
    var extracted = LivePhoto.playable_for(File.new_for_path(mp));
    assert(extracted != null);
    uint8[] got;
    try {
        FileUtils.get_data(extracted.get_path(), out got);
    } catch (Error e) {
        assert_not_reached();
    }
    assert(got.length == mp4.length && Memory.cmp(got, mp4, mp4.length) == 0);
    string still = Path.build_filename(tmp_dir, "IMG_0001.HEIC");
    string mov = Path.build_filename(tmp_dir, "IMG_0001.MOV");
    try {
        FileUtils.set_data(still, jpeg);
        FileUtils.set_data(mov, mp4);
    } catch (Error e) {
        assert_not_reached();
    }
    var companion = LivePhoto.playable_for(File.new_for_path(still));
    assert(companion != null && companion.get_path() == mov);
    assert(LivePhoto.playable_for(File.new_for_path(mov)).get_path() == mov);
    string plain = Path.build_filename(tmp_dir, "plain.jpg");
    try {
        FileUtils.set_data(plain, jpeg);
    } catch (Error e) {
        assert_not_reached();
    }
    assert(LivePhoto.playable_for(File.new_for_path(plain)) == null);
}

int main(string[] args) {
    Test.init(ref args);
    try {
        tmp_dir = DirUtils.make_tmp("photos-live-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Environment.set_variable("XDG_CACHE_HOME", Path.build_filename(tmp_dir, "cache"), true);
    Test.add_func("/output/live", test_live);
    return Test.run();
}
