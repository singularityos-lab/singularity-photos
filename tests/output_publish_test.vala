using Singularity.Apps.Photos;
using Singularity.Imaging;

private string tmp_dir;

private void test_ledger() {
    Environment.set_variable("SINGULARITY_PHOTOS_PUBLISH_DIR", Path.build_filename(tmp_dir, "ledger"), true);
    string p = Path.build_filename(tmp_dir, "a.png");
    try {
        FileUtils.set_data(p, ImageWriters.encode_png(new FloatImage.filled(8, 8, 0.5f, 0.5f, 0.5f), 8, new uint8[0], new uint8[0], "", 72));
    } catch (Error e) {
        assert_not_reached();
    }
    var file = File.new_for_path(p);
    var s = new ExportSettings();
    var ledger = new PublishLedger("account-1");
    assert(ledger.state(file, s) == PublishState.NEW);
    ledger.record(file, s, "a.jpg");
    assert(ledger.state(file, s) == PublishState.PUBLISHED);
    try {
        ledger.save();
    } catch (Error e) {
        assert_not_reached();
    }
    var reloaded = new PublishLedger("account-1");
    assert(reloaded.count() == 1);
    assert(reloaded.remote_name(file) == "a.jpg");
    assert(reloaded.state(file, s) == PublishState.PUBLISHED);
    assert(new PublishLedger("account-2").state(file, s) == PublishState.NEW);
    var params = new EditParams();
    params.set_value(Adjustment.EXPOSURE, 0.4);
    try {
        EditStore.save(file, params);
    } catch (Error e) {
        assert_not_reached();
    }
    assert(reloaded.state(file, s) == PublishState.CHANGED);
    reloaded.record(file, s, "a.jpg");
    assert(reloaded.state(file, s) == PublishState.PUBLISHED);
    var other = s.copy();
    other.quality = 50;
    assert(reloaded.state(file, other) == PublishState.CHANGED);
    reloaded.forget(file);
    assert(reloaded.state(file, s) == PublishState.NEW);
}

int main(string[] args) {
    Test.init(ref args);
    try {
        tmp_dir = DirUtils.make_tmp("photos-publish-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Test.add_func("/output/publish/ledger", test_ledger);
    return Test.run();
}
