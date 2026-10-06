using Singularity.Apps.Photos;
using Singularity.Imaging;

private string tmp_dir;

private File[] photos(int n) {
    File[] files = {};
    for (int i = 0; i < n; i++) {
        string p = Path.build_filename(tmp_dir, "b%02d.png".printf(i));
        int w = i % 3 == 0 ? 200 : 300, h = i % 3 == 0 ? 300 : 200;
        try {
            FileUtils.set_data(p, ImageWriters.encode_png(new FloatImage.filled(w, h, (float) i / n, 0.5f, 0.2f), 8, new uint8[0], new uint8[0], "", 72));
        } catch (Error e) {
            assert_not_reached();
        }
        files += File.new_for_path(p);
    }
    return files;
}

private int count(string hay, string needle) {
    int n = 0, at = 0;
    while ((at = hay.index_of(needle, at)) >= 0) {
        n++;
        at += needle.length;
    }
    return n;
}

private void test_layouts() {
    var files = photos(10);
    var book = new PhotoBookDocument(files);
    book.template = "four";
    book.layout();
    assert(book.page_count == 3);
    assert(book.page(2).cells.length == 2);
    book.template = "single";
    book.layout();
    assert(book.page_count == 10);
    book.template = "auto";
    book.title = "Summer";
    book.layout();
    assert(book.page(0).template == "cover");
    int placed = 0;
    for (int i = 0; i < book.page_count; i++) placed += book.page(i).cells.length;
    assert(placed == 10);
    var seen = new bool[10];
    for (int i = 0; i < book.page_count; i++) foreach (var c in book.page(i).cells) seen[c.photo] = true;
    foreach (bool s in seen) assert(s);
    book.template = "three";
    book.title = "";
    book.layout();
    double pw, ph;
    book.page_size(out pw, out ph);
    foreach (var c in book.page(0).cells) assert(c.x >= 0 && c.y >= 0 && c.x + c.width <= pw + 0.01 && c.y + c.height <= ph + 0.01);
}

private void test_outputs() {
    var files = photos(5);
    var book = new PhotoBookDocument(files);
    book.title = "Trip";
    book.captions = true;
    book.layout();
    string pdf = Path.build_filename(tmp_dir, "book.pdf");
    try {
        book.save_pdf(pdf);
        string text;
        uint8[] data;
        FileUtils.get_data(pdf, out data);
        var sb = new StringBuilder();
        sb.append_len((string) data, data.length);
        text = sb.str;
        assert(text.has_prefix("%PDF") && data.length > 1000);
        assert(book.page_count == 4);
        string sla = Path.build_filename(tmp_dir, "book.sla");
        string media = book.save_publish(sla);
        Xml.Doc* doc = Xml.Parser.read_file(sla);
        assert(doc != null);
        var root = doc->get_root_element();
        assert(root->name == "SCRIBUSUTF8NEW");
        Xml.Node* dn = root->children;
        while (dn != null && dn->name != "DOCUMENT") dn = dn->next;
        assert(dn != null);
        int pages = 0, images = 0, texts = 0;
        for (Xml.Node* c = dn->children; c != null; c = c->next) {
            if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
            if (c->name == "PAGE") pages++;
            if (c->name == "PAGEOBJECT") {
                if (c->get_prop("PTYPE") == "2") {
                    images++;
                    assert(FileUtils.test(c->get_prop("PFILE"), FileTest.IS_REGULAR));
                    assert(c->get_prop("PFILE").has_prefix(media));
                } else if (c->get_prop("PTYPE") == "4") {
                    texts++;
                }
            }
        }
        delete doc;
        assert(pages == book.page_count);
        assert(images == 5);
        assert(texts == 1);
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
}

int main(string[] args) {
    Test.init(ref args);
    try {
        tmp_dir = DirUtils.make_tmp("photos-book-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Test.add_func("/output/book/layouts", test_layouts);
    Test.add_func("/output/book/outputs", test_outputs);
    return Test.run();
}
