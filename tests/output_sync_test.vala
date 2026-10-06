using Singularity.Apps.Photos;
using Singularity.Imaging;

private string tmp_dir;

private void png(string path, float v) {
    DirUtils.create_with_parents(Path.get_dirname(path), 0755);
    try {
        FileUtils.set_data(path, ImageWriters.encode_png(new FloatImage.filled(8, 8, v, v, v), 8, new uint8[0], new uint8[0], "", 72));
    } catch (Error e) {
        assert_not_reached();
    }
}

private SyncReport run(SyncEngine e) {
    var loop = new MainLoop();
    SyncReport? report = null;
    e.sync.begin(null, (o, res) => {
        try {
            report = e.sync.end(res);
        } catch (Error err) {
            stderr.printf("%s\n", err.message);
        }
        loop.quit();
    });
    loop.run();
    assert(report != null);
    foreach (var s in report.errors) stderr.printf("sync error: %s\n", s);
    assert(report.errors.size == 0);
    return report;
}

private void edit(string path, double exposure) {
    var p = EditStore.load(File.new_for_path(path)) ?? new EditParams();
    p.set_value(Adjustment.EXPOSURE, exposure);
    try {
        EditStore.save(File.new_for_path(path), p);
    } catch (Error e) {
        assert_not_reached();
    }
}

private double exposure(string path) {
    var p = EditStore.load(File.new_for_path(path));
    return p != null ? p.get_value(Adjustment.EXPOSURE) : 0;
}

private void test_sync() {
    Environment.set_variable("SINGULARITY_PHOTOS_SYNC_DIR", Path.build_filename(tmp_dir, "state"), true);
    string a = Path.build_filename(tmp_dir, "deviceA"), b = Path.build_filename(tmp_dir, "deviceB");
    string remote_dir = Path.build_filename(tmp_dir, "remote");
    foreach (var root in new string[] { a, b }) {
        png(Path.build_filename(root, "2026", "one.png"), 0.3f);
        png(Path.build_filename(root, "2026", "two.png"), 0.6f);
    }
    png(Path.build_filename(a, "only-a.png"), 0.9f);
    var ea = new SyncEngine(a, new FolderRemote(remote_dir));
    var eb = new SyncEngine(b, new FolderRemote(remote_dir));
    ea.catalog_snapshot = false;
    eb.catalog_snapshot = false;
    edit(Path.build_filename(a, "2026", "one.png"), 0.5);
    var r = run(ea);
    assert(r.pushed == 1);
    r = run(eb);
    assert(r.pulled == 1);
    assert((exposure(Path.build_filename(b, "2026", "one.png")) - 0.5).abs() < 1e-9);
    r = run(eb);
    assert(r.pushed == 0 && r.pulled == 0);
    edit(Path.build_filename(b, "2026", "one.png"), 1.25);
    assert(run(eb).pushed == 1);
    assert(run(ea).pulled == 1);
    assert((exposure(Path.build_filename(a, "2026", "one.png")) - 1.25).abs() < 1e-9);
    edit(Path.build_filename(a, "2026", "two.png"), -0.5);
    edit(Path.build_filename(b, "2026", "two.png"), 0.75);
    assert(run(ea).pushed == 1);
    r = run(eb);
    assert(r.conflicts == 1);
    assert((exposure(Path.build_filename(b, "2026", "two.png")) + 0.5).abs() < 1e-9);
    bool kept = false;
    try {
        var d = Dir.open(Path.build_filename(b, "2026"));
        string? n;
        while ((n = d.read_name()) != null) if (n.has_prefix(".two.png.conflict-")) kept = true;
    } catch (Error e) {
    }
    assert(kept);
    ea.originals = true;
    eb.originals = true;
    run(ea);
    assert(!FileUtils.test(Path.build_filename(b, "only-a.png"), FileTest.EXISTS));
    run(eb);
    assert(FileUtils.test(Path.build_filename(b, "only-a.png"), FileTest.EXISTS));
    string catalog = Path.build_filename(tmp_dir, "catalog.db");
    Sqlite.Database db;
    Sqlite.Database.open(catalog, out db);
    db.exec("CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (42);");
    ea.catalog_snapshot = true;
    ea.catalog_path = catalog;
    ea.device_name = "laptop";
    run(ea);
    Sqlite.Database snap;
    assert(Sqlite.Database.open_v2(Path.build_filename(remote_dir, "catalog", "laptop.db"), out snap, Sqlite.OPEN_READONLY) == Sqlite.OK);
    Sqlite.Statement st;
    snap.prepare_v2("SELECT x FROM t", -1, out st);
    assert(st.step() == Sqlite.ROW && st.column_int(0) == 42);
}

int main(string[] args) {
    Test.init(ref args);
    try {
        tmp_dir = DirUtils.make_tmp("photos-sync-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Test.add_func("/output/sync/folder", test_sync);
    return Test.run();
}
