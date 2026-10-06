using Singularity.Apps.Photos;

private string tmp_root;
private int serial = 0;

private string fresh_dir(string name) {
    string dir = Path.build_filename(tmp_root, "%s-%d".printf(name, serial++));
    DirUtils.create_with_parents(dir, 0755);
    return dir;
}

private void write_png(string path, uint8 shade) {
    var px = new uint8[4 * 4 * 4];
    for (int i = 0; i < px.length; i++) px[i] = (i % 4 == 3) ? 255 : shade;
    var tex = new Gdk.MemoryTexture(4, 4, Gdk.MemoryFormat.R8G8B8A8, new Bytes(px), 16);
    DirUtils.create_with_parents(Path.get_dirname(path), 0755);
    assert(tex.save_to_png(path));
}

private Catalog open_catalog(string dir) {
    try {
        return new Catalog(Path.build_filename(dir, "catalog.db"));
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_schema_persistence() {
    string dir = fresh_dir("schema");
    var c = open_catalog(dir);
    bool changed;
    var r = c.upsert_file("/nowhere/a.jpg", 10, 100, out changed);
    assert(changed);
    c.set_rating(r, 4);
    c.set_flag(r, PickFlag.PICK);
    c.set_label(r, "red");
    var k = c.ensure_keyword_path("Places|Italy|Rome");
    c.assign_keyword(r, k.id);
    var col = c.create_collection("Trip", "manual");
    c.add_to_collection(col, r);
    c.save_keyword_set("Travel", { "Beach", "Museum" });
    c = null;
    var again = open_catalog(dir);
    var r2 = again.find_path("/nowhere/a.jpg");
    assert(r2 != null);
    assert(r2.rating == 4 && r2.flag == PickFlag.PICK && r2.label == "red");
    assert(again.keyword_paths(r2)[0] == "Places|Italy|Rome");
    assert(again.collections.size == 1);
    foreach (var cc in again.collections.values) assert(again.collection_photos(cc).size == 1);
    assert(again.keyword_sets.size == 1);
    assert(again.get_meta("schema") == Catalog.SCHEMA_VERSION.to_string());
    again.set_label(r2, "red");
    assert(r2.label == "");
}

private void test_indexer() {
    string dir = fresh_dir("index");
    string lib = Path.build_filename(dir, "Pictures");
    write_png(Path.build_filename(lib, "one.png"), 10);
    write_png(Path.build_filename(lib, "2024", "two.png"), 20);
    write_png(Path.build_filename(lib, "2024", "deep", "three.png"), 30);
    write_png(Path.build_filename(lib, ".hidden", "skip.png"), 40);
    try {
        FileUtils.set_contents(Path.build_filename(lib, "notes.txt"), "x");
    } catch (Error e) {
        assert_not_reached();
    }
    var c = open_catalog(dir);
    var idx = new LibraryIndexer(c);
    idx.scan_sync({ File.new_for_path(lib) });
    assert(c.photos.size == 3);
    assert(c.folder_for_path(Path.build_filename(lib, "2024", "deep")) != null);
    var deep = c.folder_for_path(Path.build_filename(lib, "2024", "deep"));
    var mid = c.folder_for_path(Path.build_filename(lib, "2024"));
    assert(deep.parent_id == mid.id);
    var filter = new LibraryFilter();
    filter.folder_id = mid.id;
    assert(c.query(filter).size == 2);
    filter.include_subfolders = false;
    assert(c.query(filter).size == 1);
    FileUtils.remove(Path.build_filename(lib, "one.png"));
    idx.scan_sync({ File.new_for_path(lib) });
    var gone = c.find_path(Path.build_filename(lib, "one.png"));
    assert(gone != null && gone.missing);
    assert(c.missing_photos().size == 1);
    string moved = Path.build_filename(lib, "moved.png");
    write_png(moved, 10);
    c.relink(gone, moved);
    assert(!gone.missing && c.find_path(moved) == gone);
    foreach (var r in c.photos.values) assert(r.meta_mtime == r.mtime);
}

private void test_keywords() {
    var c = open_catalog(fresh_dir("kw"));
    var rome = c.ensure_keyword_path("Places|Italy|Rome");
    var italy = c.ensure_keyword_path("Places|Italy");
    var places = c.ensure_keyword_path("Places");
    assert(rome.parent_id == italy.id && italy.parent_id == places.id);
    assert(c.keyword_under(rome.id, places.id));
    assert(!c.keyword_under(places.id, rome.id));
    c.set_synonyms(rome, "Roma, Eternal City");
    assert(c.find_keyword("roma") == rome);
    bool ch;
    var a = c.upsert_file("/k/a.jpg", 1, 1, out ch);
    var b = c.upsert_file("/k/b.jpg", 1, 1, out ch);
    var d = c.upsert_file("/k/d.jpg", 1, 1, out ch);
    var beach = c.ensure_keyword("Beach");
    c.assign_keyword(a, rome.id);
    c.assign_keyword(b, rome.id);
    c.assign_keyword(b, beach.id);
    var filter = new LibraryFilter();
    filter.keyword_id = places.id;
    assert(c.query(filter).size == 2);
    filter.keyword_id = 0;
    filter.text = "roma";
    assert(c.query(filter).size == 2);
    var sugg = c.suggest_keywords(a);
    assert(sugg.size > 0 && sugg[0] == beach);
    c.delete_keyword(italy);
    assert(c.find_keyword("Rome") == null);
    assert(a.keywords.size == 0);
    assert(d.keywords.size == 0);
}

private void test_smart_rules() {
    var c = open_catalog(fresh_dir("smart"));
    bool ch;
    var a = c.upsert_file("/s/a.jpg", 1, 1, out ch);
    var b = c.upsert_file("/s/b.cr2", 1, 1, out ch);
    var d = c.upsert_file("/s/d.jpg", 1, 1, out ch);
    c.set_rating(a, 5);
    c.set_rating(b, 3);
    c.set_label(b, "green");
    b.camera = "Canon EOS R5";
    b.captured = get_real_time() / 1000000 - 86400 * 2;
    c.save(b);
    d.captured = new DateTime.local(2019, 5, 1, 0, 0, 0).to_unix();
    c.save(d);
    c.assign_keyword(a, c.ensure_keyword_path("Family|Kids").id);
    var rules = new SmartRules();
    rules.rules.add(new SmartRule("rating", ">=", "3"));
    var col = c.create_collection("Good", "smart", 0, rules.to_json());
    assert(c.collection_photos(col).size == 2);
    var parsed = SmartRules.parse(col.rules);
    assert(parsed.match_all && parsed.rules.size == 1);
    rules.rules.add(new SmartRule("label", "is", "green"));
    col.rules = rules.to_json();
    c.update_collection(col);
    assert(c.collection_photos(col).size == 1);
    rules.match_all = false;
    rules.rules.clear();
    rules.rules.add(new SmartRule("keyword", "contains", "family"));
    rules.rules.add(new SmartRule("camera", "contains", "canon"));
    col.rules = rules.to_json();
    assert(c.collection_photos(col).size == 2);
    rules = new SmartRules();
    rules.rules.add(new SmartRule("date", "within-days", "7"));
    assert(rules.matches(b, c) && !rules.matches(d, c));
    rules = new SmartRules();
    rules.rules.add(new SmartRule("date", "before", "2020-01-01"));
    assert(rules.matches(d, c) && !rules.matches(b, c));
    rules = new SmartRules();
    rules.rules.add(new SmartRule("kind", "is", "raw"));
    assert(rules.matches(b, c) && !rules.matches(a, c));
    var set = c.create_collection("All sets", "set");
    var m1 = c.create_collection("One", "manual", set.id);
    var m2 = c.create_collection("Two", "manual", set.id);
    c.add_to_collection(m1, a);
    c.add_to_collection(m2, a);
    c.add_to_collection(m2, d);
    assert(c.collection_photos(set).size == 2);
    assert(c.child_collections(set.id).size == 2);
    c.delete_collection(set);
    assert(!c.collections.has_key(m1.id));
    var f = new LibraryFilter();
    f.rating = 3;
    f.labels = { "green" };
    assert(c.query(f).size == 1);
    f = new LibraryFilter();
    f.flag = "unflagged";
    f.kind = "raw";
    assert(c.query(f).size == 1);
    f = new LibraryFilter();
    f.sort_key = "rating";
    var sorted = c.query(f);
    assert(sorted[0] == a);
}

private void test_duplicates_and_import() {
    string dir = fresh_dir("import");
    string card = Path.build_filename(dir, "card", "DCIM", "100CANON");
    write_png(Path.build_filename(card, "IMG_0001.png"), 50);
    write_png(Path.build_filename(card, "IMG_0002.png"), 60);
    write_png(Path.build_filename(card, "IMG_0003.png"), 50);
    var c = open_catalog(dir);
    var importer = new PhotoImporter(c);
    var candidates = PhotoImporter.scan_source(File.new_for_path(Path.build_filename(dir, "card")));
    assert(candidates.size == 3);
    var o = new ImportOptions();
    o.destination = File.new_for_path(Path.build_filename(dir, "Pictures"));
    o.structure = "flat";
    o.rename_template = "{seq}-{original}";
    o.keywords = { "Import|Card" };
    var result = importer.run(candidates, o);
    assert(result.imported == 2);
    assert(result.skipped_duplicates == 1);
    assert(FileUtils.test(Path.build_filename(dir, "Pictures", "0001-IMG_0001.png"), FileTest.EXISTS));
    assert(FileUtils.test(Path.build_filename(dir, "Pictures", "0002-IMG_0002.png"), FileTest.EXISTS));
    assert(FileUtils.test(Path.build_filename(card, "IMG_0003.png"), FileTest.EXISTS));
    foreach (var r in result.records) assert(c.keyword_paths(r)[0] == "Import|Card");
    var again = PhotoImporter.scan_source(File.new_for_path(Path.build_filename(dir, "card")));
    importer.mark_duplicates(again);
    foreach (var cand in again) assert(cand.duplicate && !cand.selected);
    write_png(Path.build_filename(dir, "Pictures", "copy.png"), 60);
    new LibraryIndexer(c).scan_sync({ File.new_for_path(Path.build_filename(dir, "Pictures")) }, false);
    var groups = c.duplicate_groups();
    assert(groups.size == 1 && groups[0].size == 2);
    var t = new DateTime.local(2023, 7, 14, 9, 5, 3);
    string name = PhotoImporter.render_name("{date}_{time}_{camera}_{seq}", File.new_for_path("/x/IMG_1.CR2"), t, "Canon R5", 7);
    assert(name == "2023-07-14_090503_Canon-R5_0007.cr2");
    o.structure = "date";
    assert(PhotoImporter.destination_folder(o, t).get_path().has_suffix("Pictures/2023/2023-07-14"));
    assert(PhotoImporter.sanitize("a/b:c") == "a_b_c");
}

private void test_stacks_and_copies() {
    var c = open_catalog(fresh_dir("stack"));
    bool ch;
    var a = c.upsert_file("/st/a.jpg", 1, 1, out ch);
    var b = c.upsert_file("/st/b.jpg", 1, 2, out ch);
    var e = c.upsert_file("/st/e.jpg", 1, 3, out ch);
    int64 sid = c.stack({ a, b });
    assert(sid != 0 && a.stack_id == sid && b.stack_id == sid);
    var f = new LibraryFilter();
    assert(c.query(f).size == 2);
    f.expanded_stacks.add(sid);
    assert(c.query(f).size == 3);
    c.set_stack_top(b);
    assert(b.stack_pos == 0 && a.stack_pos == 1);
    c.unstack(sid);
    assert(a.stack_id == 0 && b.stack_id == 0);
    var vc = c.create_virtual_copy(e);
    assert(vc.master_id == e.id && vc.path == e.path && vc.variant() != "");
    assert(c.virtual_copies(e).size == 1);
    assert(vc.stack_id != 0 && vc.stack_id == e.stack_id);
    assert(c.find_path("/st/e.jpg") == e);
    var vf = new LibraryFilter();
    vf.kind = "virtual";
    vf.collapse_stacks = false;
    assert(c.query(vf).size == 1);
    c.remove_photo(e);
    assert(c.virtual_copies(e).size == 0 && !c.photos.has_key(vc.id));
}

private void exec(Sqlite.Database db, string sql) {
    string? err;
    if (db.exec(sql, null, out err) != Sqlite.OK) error("%s: %s", err ?? "", sql);
}

private void test_lrcat() {
    string dir = fresh_dir("lrcat");
    string pics = Path.build_filename(dir, "photos");
    write_png(Path.build_filename(pics, "sub", "a.png"), 1);
    write_png(Path.build_filename(pics, "sub", "b.png"), 2);
    string lrcat = Path.build_filename(dir, "Test.lrcat");
    Sqlite.Database db;
    Sqlite.Database.open(lrcat, out db);
    exec(db, """CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, absolutePath TEXT, name TEXT);
        CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, rootFolder INTEGER, pathFromRoot TEXT);
        CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, folder INTEGER, baseName TEXT, extension TEXT);
        CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, rootFile INTEGER, rating REAL, colorLabels TEXT, pick REAL, masterImage INTEGER);
        CREATE TABLE AgLibraryKeyword (id_local INTEGER PRIMARY KEY, name TEXT, parent INTEGER);
        CREATE TABLE AgLibraryKeywordImage (id_local INTEGER PRIMARY KEY, image INTEGER, tag INTEGER);
        CREATE TABLE AgLibraryCollection (id_local INTEGER PRIMARY KEY, name TEXT, creationId TEXT, parent INTEGER);
        CREATE TABLE AgLibraryCollectionImage (id_local INTEGER PRIMARY KEY, collection INTEGER, image INTEGER, positionInCollection TEXT);
        CREATE TABLE AgLibraryCollectionContent (id_local INTEGER PRIMARY KEY, collection INTEGER, content TEXT, owningModule TEXT);""");
    exec(db, "INSERT INTO AgLibraryRootFolder VALUES (1, '%s/', 'photos')".printf(pics));
    exec(db, """INSERT INTO AgLibraryFolder VALUES (1, 1, 'sub/');
        INSERT INTO AgLibraryFile VALUES (1, 1, 'a', 'png'), (2, 1, 'b', 'png'), (3, 1, 'gone', 'nef');
        INSERT INTO Adobe_images VALUES (10, 1, 5, 'Red', 1, NULL), (11, 2, 2, 'Blue', -1, NULL), (12, 3, 0, '', 0, NULL), (13, 1, 3, '', 0, 10);
        INSERT INTO AgLibraryKeyword VALUES (1, NULL, NULL), (2, 'Animals', 1), (3, 'Cat', 2);
        INSERT INTO AgLibraryKeywordImage VALUES (1, 10, 3), (2, 11, 2);
        INSERT INTO AgLibraryCollection VALUES (1, 'Set', 'com.adobe.ag.library.group', NULL), (2, 'Best', 'com.adobe.ag.library.collection', 1),
            (3, 'Five', 'com.adobe.ag.library.smart_collection', NULL), (4, 'Quick', 'com.adobe.ag.library.quick_collection', NULL);
        INSERT INTO AgLibraryCollectionImage VALUES (1, 2, 10, 'a'), (2, 2, 11, 'b');""");
    exec(db, "INSERT INTO AgLibraryCollectionContent VALUES (1, 3, 's = { { criteria = \"rating\", operation = \">=\", value = 5, }, combine = \"intersect\", }', 'ag.library.smart_collection')");
    db = null;
    var c = open_catalog(dir);
    LrcatReport report;
    try {
        report = new LrcatImporter(c).import_catalog(lrcat);
    } catch (Error e) {
        error("%s", e.message);
    }
    assert(report.photos == 4);
    assert(report.missing == 1);
    var a = c.find_path(Path.build_filename(pics, "sub", "a.png"));
    var b = c.find_path(Path.build_filename(pics, "sub", "b.png"));
    assert(a.rating == 5 && a.label == "red" && a.flag == PickFlag.PICK);
    assert(b.rating == 2 && b.label == "blue" && b.flag == PickFlag.REJECT);
    assert(c.keyword_paths(a)[0] == "Animals|Cat");
    assert(c.keyword_paths(b)[0] == "Animals");
    assert(c.virtual_copies(a).size == 1 && c.virtual_copies(a)[0].rating == 3);
    CollectionRecord? best = null, five = null, set = null;
    foreach (var col in c.collections.values) {
        if (col.name == "Best") best = col;
        if (col.name == "Five") five = col;
        if (col.name == "Set") set = col;
        assert(col.name != "Quick");
    }
    assert(best != null && set != null && five != null);
    assert(best.parent_id == set.id);
    assert(c.collection_photos(best).size == 2);
    assert(five.is_smart());
    assert(c.collection_photos(five).size == 1);
    try {
        FileUtils.set_contents(Path.build_filename(dir, "bad.lrcat"), "no");
        new LrcatImporter(c).import_catalog(Path.build_filename(dir, "bad.lrcat"));
        assert_not_reached();
    } catch (Error e) {
    }
}

private void test_gpx() {
    var c = open_catalog(fresh_dir("gpx"));
    string xml = """<?xml version="1.0"?><gpx><trk><trkseg>
        <trkpt lat="41.0" lon="12.0"><ele>10</ele><time>2024-05-01T10:00:00Z</time></trkpt>
        <trkpt lat="42.0" lon="13.0"><time>2024-05-01T10:10:00Z</time></trkpt>
        </trkseg></trk></gpx>""";
    GpxTrack track;
    try {
        track = GpxTrack.parse(xml);
    } catch (Error e) {
        error("%s", e.message);
    }
    assert(track.points.length == 2);
    bool ch;
    var r = c.upsert_file("/g/a.jpg", 1, 1, out ch);
    var far = c.upsert_file("/g/b.jpg", 1, 1, out ch);
    r.captured = new DateTime.utc(2024, 5, 1, 10, 5, 0).to_unix();
    far.captured = new DateTime.utc(2024, 5, 2, 10, 5, 0).to_unix();
    var list = new Gee.ArrayList<PhotoRecord>();
    list.add(r);
    list.add(far);
    assert(track.tag(c, list, 0) == 1);
    assert(r.has_gps && (r.latitude - 41.5).abs() < 1e-6 && (r.longitude - 12.5).abs() < 1e-6);
    assert(!far.has_gps);
    assert(CatalogXmp.format_gps(-41.5, true) == "41,30.000000S");
}

private void test_people() {
    var c = open_catalog(fresh_dir("people"));
    bool ch;
    var r = c.upsert_file("/p/a.jpg", 1, 1, out ch);
    var box = FaceBox() { x = 0.1, y = 0.1, width = 0.2, height = 0.2, score = 1 };
    c.add_face(r, box, { 1.0f, 0.0f });
    c.add_face(r, box, { 1.05f, 0.0f });
    c.add_face(r, box, { 0.0f, 1.0f });
    assert(PeopleClustering.cluster(c, 0.3) == 3);
    assert(c.people.size == 2);
    var ids = new Gee.ArrayList<PersonRecord>();
    ids.add_all(c.people.values);
    c.merge_people(ids[0], ids[1]);
    assert(c.people.size == 1);
    foreach (var f in c.faces.values) assert(f.person_id == ids[0].id);
    var reopened = open_catalog(Path.get_dirname(c.db_path));
    assert(reopened.faces.size == 3);
    foreach (var f in reopened.faces.values) assert(f.descriptor.length == 2);
    var anna = ids[0];
    c.rename_person(anna, "Anna");
    var rule = new SmartRules();
    rule.rules.add(new SmartRule("person", "is", "anna"));
    assert(rule.matches(r, c));
    var col = c.create_collection("Anna", "smart", 0, rule.to_json());
    assert(c.collection_photos(col).size == 1);
    var list = c.person_faces(anna.id);
    assert(list.size == 3);
    var odd = list[2];
    var bob = c.create_person("Bob");
    c.move_face(odd, bob.id);
    assert(odd.person_id == bob.id && odd.confirmed());
    assert(c.person_faces(anna.id).size == 2);
    c.set_face_state(list[0], -1);
    assert(list[0].person_id == 0 && list[0].rejected());
    PeopleClustering.cluster(c, 0.3);
    assert(list[0].person_id == 0);
    var again2 = open_catalog(Path.get_dirname(c.db_path));
    int confirmed = 0, rejected = 0;
    foreach (var f in again2.faces.values) {
        if (f.confirmed()) confirmed++;
        if (f.rejected()) rejected++;
    }
    assert(confirmed == 1 && rejected == 1);
    assert(again2.find_person("bob") != null);
    c.move_face(odd, anna.id);
    c.prune_people();
    assert(c.find_person("Bob") == null);
}

private void test_face_detection(string fixtures) {
    string dir = Path.build_filename(fixtures, "catalog", "faces");
    if (!FileUtils.test(dir, FileTest.IS_DIR)) return;
    int with_faces = 0, total = 0, empty_ok = 0;
    try {
        var d = Dir.open(dir);
        string? name;
        while ((name = d.read_name()) != null) {
            var photo = Codecs.load(File.new_for_path(Path.build_filename(dir, name)), 1024);
            var boxes = Faces.detect(photo.image);
            if (name.has_prefix("face")) {
                total++;
                if (boxes.length >= 1) with_faces++;
            } else if (boxes.length == 0) {
                empty_ok++;
            }
        }
    } catch (Error e) {
        error("%s", e.message);
    }
    stdout.printf("# face fixtures: %d of %d detected, %d empty scenes clean\n", with_faces, total, empty_ok);
    assert(total == 0 || with_faces * 3 >= total * 2);
}

private void test_xmp_fill() {
    var c = open_catalog(fresh_dir("xmp"));
    bool ch;
    var r = c.upsert_file("/x/a.cr2", 1, 1, out ch);
    c.set_rating(r, 3);
    c.set_label(r, "purple");
    r.title = "Title";
    c.assign_keyword(r, c.ensure_keyword_path("A|B").id);
    var p = new XmpPacket();
    CatalogXmp.fill(p, r, c);
    assert(p.get_simple(XmpPacket.NS_XMP, "Rating") == "3");
    assert(p.get_simple(XmpPacket.NS_XMP, "Label") == "Purple");
    assert(p.get_list(XmpPacket.NS_DC, "subject")[0] == "B");
    assert(p.get_list(XmpPacket.NS_LR, "hierarchicalSubject")[0] == "A|B");
    assert(p.get_lang_alt(XmpPacket.NS_DC, "title") == "Title");
    string dir = fresh_dir("xmpfile");
    write_png(Path.build_filename(dir, "b.png"), 5);
    var real = c.upsert_file(Path.build_filename(dir, "b.png"), 1, 1, out ch);
    c.set_rating(real, 4);
    c.assign_keyword(real, c.ensure_keyword_path("Trip|Beach").id);
    assert(CatalogXmp.write(real, c));
    var back = XmpSidecar.load(real.file());
    assert(back.get_simple(XmpPacket.NS_XMP, "Rating") == "4");
    assert(back.get_list(XmpPacket.NS_LR, "hierarchicalSubject")[0] == "Trip|Beach");
    assert(FileUtils.test(Path.build_filename(dir, "b.xmp"), FileTest.EXISTS));
    assert(CatalogXmp.label_from_xmp("Purple") == "purple");
}

int main(string[] args) {
    Test.init(ref args);
    tmp_root = Path.build_filename(Environment.get_tmp_dir(), ("photos-catalog-test-%" + int64.FORMAT).printf(get_real_time()));
    DirUtils.create_with_parents(tmp_root, 0755);
    Test.add_func("/catalog/schema", test_schema_persistence);
    Test.add_func("/catalog/indexer", test_indexer);
    Test.add_func("/catalog/keywords", test_keywords);
    Test.add_func("/catalog/smart", test_smart_rules);
    Test.add_func("/catalog/import", test_duplicates_and_import);
    Test.add_func("/catalog/stacks", test_stacks_and_copies);
    Test.add_func("/catalog/lrcat", test_lrcat);
    Test.add_func("/catalog/gpx", test_gpx);
    Test.add_func("/catalog/people", test_people);
    Test.add_func("/catalog/xmp", test_xmp_fill);
    string fixtures = args.length > 1 ? args[1] : "";
    Test.add_data_func("/catalog/face-detection", () => test_face_detection(fixtures));
    return Test.run();
}
