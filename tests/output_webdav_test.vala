using Singularity.Apps.Photos;
using Singularity.Imaging;

private string tmp_dir;

private class MockDav : Object {
    public Soup.Server server;
    public Gee.HashMap<string, Bytes> files = new Gee.HashMap<string, Bytes>();
    public Gee.HashMap<string, string> etags = new Gee.HashMap<string, string>();
    public Gee.HashSet<string> collections = new Gee.HashSet<string>();
    public int puts = 0;
    public int deletes = 0;
    public string url = "";
    private int counter = 0;

    public MockDav() throws Error {
        server = new Soup.Server("server-header", "mock-dav");
        collections.add("/");
        server.add_handler(null, handle);
        server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
        foreach (var u in server.get_uris()) url = "http://127.0.0.1:%d/".printf(u.get_port());
    }

    private static string parent_of(string path) {
        string p = path.has_suffix("/") ? path.substring(0, path.length - 1) : path;
        int i = p.last_index_of_char('/');
        return i <= 0 ? "/" : p.substring(0, i + 1);
    }

    private static string escape(string path) {
        string[] parts = {};
        foreach (var s in path.split("/")) parts += Uri.escape_string(s, null, false);
        return string.joinv("/", parts);
    }

    private void handle(Soup.Server s, Soup.ServerMessage msg, string raw_path, HashTable<string, string>? query) {
        string? auth = msg.get_request_headers().get_one("Authorization");
        if (auth != "Basic " + Base64.encode("ada:secret".data)) {
            msg.set_status(401, null);
            return;
        }
        string path = Uri.unescape_string(raw_path) ?? raw_path;
        string dir = path.has_suffix("/") ? path : path + "/";
        switch (msg.get_method()) {
            case "MKCOL":
                if (collections.contains(dir) || files.has_key(path)) { msg.set_status(405, null); return; }
                if (!collections.contains(parent_of(dir))) { msg.set_status(409, null); return; }
                collections.add(dir);
                msg.set_status(201, null);
                return;
            case "PUT":
                if (!collections.contains(parent_of(path))) { msg.set_status(409, null); return; }
                if (msg.get_request_headers().get_one("If-None-Match") == "*" && files.has_key(path)) { msg.set_status(412, null); return; }
                bool existed = files.has_key(path);
                files[path] = msg.get_request_body().flatten();
                etags[path] = "\"e%d\"".printf(++counter);
                puts++;
                msg.get_response_headers().replace("ETag", etags[path]);
                msg.set_status(existed ? 204 : 201, null);
                return;
            case "GET":
                if (!files.has_key(path)) { msg.set_status(404, null); return; }
                msg.set_response("application/octet-stream", Soup.MemoryUse.COPY, files[path].get_data());
                msg.set_status(200, null);
                return;
            case "DELETE":
                if (!files.has_key(path)) { msg.set_status(404, null); return; }
                files.unset(path);
                deletes++;
                msg.set_status(204, null);
                return;
            case "PROPFIND":
                if (!collections.contains(dir)) { msg.set_status(404, null); return; }
                var b = new StringBuilder("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">");
                foreach (var c in collections) {
                    if (!c.has_prefix(dir)) continue;
                    b.append_printf("<d:response><d:href>%s</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>", escape(c));
                }
                foreach (var e in files.entries) {
                    if (!e.key.has_prefix(dir)) continue;
                    b.append_printf("<d:response><d:href>%s</d:href><d:propstat><d:prop><d:resourcetype/><d:getetag>%s</d:getetag><d:getcontentlength>%d</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>", escape(e.key), Markup.escape_text(etags[e.key]), (int) e.value.get_size());
                }
                b.append("</d:multistatus>");
                msg.set_response("application/xml", Soup.MemoryUse.COPY, b.str.data);
                msg.set_status(207, null);
                return;
            default:
                msg.set_status(405, null);
                return;
        }
    }

    public int count_under(string prefix) {
        int n = 0;
        foreach (var k in files.keys) if (k.has_prefix(prefix)) n++;
        return n;
    }
}

private delegate void AsyncStep(MainLoop loop);

private void wait(AsyncStep step) {
    var loop = new MainLoop();
    step(loop);
    loop.run();
}

private string png(string path, float v) {
    DirUtils.create_with_parents(Path.get_dirname(path), 0755);
    try {
        FileUtils.set_data(path, ImageWriters.encode_png(new FloatImage.filled(24, 16, v, 0.4f, 0.2f), 8, new uint8[0], new uint8[0], "", 72));
    } catch (Error e) {
        assert_not_reached();
    }
    return path;
}

private void test_client() {
    MockDav mock;
    try {
        mock = new MockDav();
    } catch (Error e) {
        assert_not_reached();
    }
    var dav = new WebDav(mock.url + "Photos Root/sub", new BasicDavTransport("ada", "secret"));
    wait((loop) => {
        dav.put.begin("a/b.txt", new Bytes("hello".data), false, null, (o, res) => {
            try {
                string tag = dav.put.end(res);
                assert(tag != "");
            } catch (Error e) {
                stderr.printf("%s\n", e.message);
                assert_not_reached();
            }
            loop.quit();
        });
    });
    assert(mock.files.has_key("/Photos Root/sub/a/b.txt"));
    wait((loop) => {
        dav.put.begin("a/b.txt", new Bytes("again".data), false, null, (o, res) => {
            try {
                dav.put.end(res);
                assert_not_reached();
            } catch (Error e) {
                assert(e is IOError.EXISTS);
            }
            loop.quit();
        });
    });
    wait((loop) => {
        dav.list.begin(null, (o, res) => {
            try {
                var map = dav.list.end(res);
                assert(map.size == 1 && map.has_key("a/b.txt") && map["a/b.txt"] != "");
            } catch (Error e) {
                assert_not_reached();
            }
            loop.quit();
        });
    });
    wait((loop) => {
        dav.get.begin("a/b.txt", null, (o, res) => {
            try {
                var got = dav.get.end(res);
                assert(got.get_size() == 5 && Memory.cmp(got.get_data(), "hello".data, 5) == 0);
            } catch (Error e) {
                assert_not_reached();
            }
            loop.quit();
        });
    });
    wait((loop) => {
        dav.delete.begin("a/b.txt", null, (o, res) => {
            try {
                dav.delete.end(res);
            } catch (Error e) {
                assert_not_reached();
            }
            loop.quit();
        });
    });
    assert(mock.files.size == 0);
    var bad = new WebDav(mock.url + "x", new BasicDavTransport("ada", "wrong"));
    wait((loop) => {
        bad.list.begin(null, (o, res) => {
            try {
                bad.list.end(res);
                assert_not_reached();
            } catch (Error e) {
                assert(e is IOError.PERMISSION_DENIED);
            }
            loop.quit();
        });
    });
}

private PublishReport publish(PublishSession session, File[] files) {
    PublishReport? report = null;
    wait((loop) => {
        session.run.begin(files, null, null, (o, res) => {
            try {
                report = session.run.end(res);
            } catch (Error e) {
                stderr.printf("%s\n", e.message);
            }
            loop.quit();
        });
    });
    assert(report != null);
    foreach (var e in report.errors) stderr.printf("publish: %s\n", e);
    assert(report.errors.size == 0);
    return report;
}

private void test_publish() {
    Environment.set_variable("SINGULARITY_PHOTOS_PUBLISH_DIR", Path.build_filename(tmp_dir, "ledger"), true);
    MockDav mock;
    try {
        mock = new MockDav();
    } catch (Error e) {
        assert_not_reached();
    }
    File[] files = {};
    for (int i = 0; i < 3; i++) files += File.new_for_path(png(Path.build_filename(tmp_dir, "pub", "p%d.png".printf(i)), 0.2f + i * 0.2f));
    files += File.new_for_path(png(Path.build_filename(tmp_dir, "pub", "other", "p0.png"), 0.9f));
    var dav = new WebDav(mock.url + "Singularity Photos/Published/Holiday", new BasicDavTransport("ada", "secret"));
    var target = new DavPublishTarget(dav, "mock:Holiday", "Mock");
    var settings = new ExportSettings();
    settings.format = "jpeg";
    var session = new PublishSession(target, settings);
    var r = publish(session, files);
    assert(r.published == 4 && r.replaced == 0);
    assert(mock.count_under("/Singularity Photos/Published/Holiday/") == 4);
    assert(mock.files.has_key("/Singularity Photos/Published/Holiday/p0.jpg"));
    assert(mock.files.has_key("/Singularity Photos/Published/Holiday/p0-2.jpg"));
    r = publish(new PublishSession(target, settings), files);
    assert(r.unchanged == 4 && r.published == 0);
    var before = mock.files["/Singularity Photos/Published/Holiday/p1.jpg"];
    var p = new EditParams();
    p.set_value(Adjustment.EXPOSURE, 1.0);
    try {
        EditStore.save(files[1], p);
    } catch (Error e) {
        assert_not_reached();
    }
    int puts = mock.puts;
    r = publish(new PublishSession(target, settings), files);
    assert(r.replaced == 1 && r.published == 0 && r.unchanged == 3);
    assert(mock.puts == puts + 1);
    assert(mock.count_under("/Singularity Photos/Published/Holiday/") == 4);
    assert(mock.files["/Singularity Photos/Published/Holiday/p1.jpg"].compare(before) != 0);
    var shrink = new PublishSession(target, settings);
    shrink.remove_missing = true;
    r = publish(shrink, { files[0], files[1] });
    assert(r.removed == 2 && r.unchanged == 2);
    assert(mock.deletes == 2);
    assert(mock.count_under("/Singularity Photos/Published/Holiday/") == 2);
}

private SyncReport sync_once(SyncEngine e) {
    SyncReport? report = null;
    wait((loop) => {
        e.sync.begin(null, (o, res) => {
            try {
                report = e.sync.end(res);
            } catch (Error err) {
                stderr.printf("%s\n", err.message);
            }
            loop.quit();
        });
    });
    assert(report != null);
    foreach (var s in report.errors) stderr.printf("sync: %s\n", s);
    assert(report.errors.size == 0);
    return report;
}

private void test_sync() {
    Environment.set_variable("SINGULARITY_PHOTOS_SYNC_DIR", Path.build_filename(tmp_dir, "syncstate"), true);
    MockDav mock;
    try {
        mock = new MockDav();
    } catch (Error e) {
        assert_not_reached();
    }
    string a = Path.build_filename(tmp_dir, "devA"), b = Path.build_filename(tmp_dir, "devB");
    foreach (var root in new string[] { a, b }) png(Path.build_filename(root, "trip", "x.png"), 0.5f);
    var ra = new DavRemote(new WebDav(mock.url + "Singularity Photos/Sync", new BasicDavTransport("ada", "secret")), "mock-sync");
    var rb = new DavRemote(new WebDav(mock.url + "Singularity Photos/Sync", new BasicDavTransport("ada", "secret")), "mock-sync");
    var ea = new SyncEngine(a, ra);
    var eb = new SyncEngine(b, rb);
    string catalog = Path.build_filename(tmp_dir, "cat.db");
    Sqlite.Database db;
    Sqlite.Database.open(catalog, out db);
    db.exec("CREATE TABLE photos (rating INTEGER); INSERT INTO photos VALUES (5);");
    ea.catalog_path = catalog;
    ea.device_name = "studio";
    eb.catalog_snapshot = false;
    var photo_a = File.new_for_path(Path.build_filename(a, "trip", "x.png"));
    var p = new EditParams();
    p.set_value(Adjustment.CONTRAST, 0.3);
    var xmp = new XmpPacket();
    xmp.set_simple(XmpPacket.NS_XMP, "xmp", "Rating", "4");
    try {
        EditStore.save(photo_a, p);
        XmpSidecar.save(photo_a, xmp);
    } catch (Error e) {
        assert_not_reached();
    }
    var r = sync_once(ea);
    assert(r.pushed >= 2);
    assert(mock.files.has_key("/Singularity Photos/Sync/catalog/studio.db"));
    r = sync_once(eb);
    assert(r.pulled >= 2);
    var photo_b = File.new_for_path(Path.build_filename(b, "trip", "x.png"));
    var pb = EditStore.load(photo_b);
    assert(pb != null && (pb.get_value(Adjustment.CONTRAST) - 0.3).abs() < 1e-9);
    assert(XmpSidecar.load(photo_b).get_simple(XmpPacket.NS_XMP, "Rating") == "4");
    r = sync_once(eb);
    assert(r.pushed == 0 && r.pulled == 0 && r.conflicts == 0);
    var pa2 = EditStore.load(photo_a);
    pa2.set_value(Adjustment.CONTRAST, -0.2);
    var pb2 = EditStore.load(photo_b);
    pb2.set_value(Adjustment.CONTRAST, 0.8);
    try {
        EditStore.save(photo_a, pa2);
        EditStore.save(photo_b, pb2);
    } catch (Error e) {
        assert_not_reached();
    }
    assert(sync_once(ea).pushed >= 1);
    r = sync_once(eb);
    assert(r.conflicts == 1);
    assert((EditStore.load(photo_b).get_value(Adjustment.CONTRAST) + 0.2).abs() < 1e-9);
    Gee.List<string>? devices = null;
    wait((loop) => {
        eb.catalog_backups.begin(null, (o, res) => {
            try {
                devices = eb.catalog_backups.end(res);
            } catch (Error e) {
                assert_not_reached();
            }
            loop.quit();
        });
    });
    assert(devices.size == 1 && devices[0] == "studio");
    string restored = Path.build_filename(tmp_dir, "restored", "catalog.db");
    wait((loop) => {
        eb.restore_catalog.begin("studio", restored, null, (o, res) => {
            try {
                eb.restore_catalog.end(res);
            } catch (Error e) {
                assert_not_reached();
            }
            loop.quit();
        });
    });
    Sqlite.Database back;
    assert(Sqlite.Database.open_v2(restored, out back, Sqlite.OPEN_READONLY) == Sqlite.OK);
    Sqlite.Statement st;
    back.prepare_v2("SELECT rating FROM photos", -1, out st);
    assert(st.step() == Sqlite.ROW && st.column_int(0) == 5);
}

int main(string[] args) {
    Test.init(ref args);
    try {
        tmp_dir = DirUtils.make_tmp("photos-dav-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Environment.set_variable("XDG_CACHE_HOME", Path.build_filename(tmp_dir, "cache"), true);
    Test.add_func("/output/webdav/client", test_client);
    Test.add_func("/output/webdav/publish", test_publish);
    Test.add_func("/output/webdav/sync", test_sync);
    return Test.run();
}
