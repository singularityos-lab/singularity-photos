using Singularity.Apps.Photos;

private string fixtures;
private string tmp_dir;

private void near(double got, double want, double tolerance, string what = "") {
    if ((got - want).abs() > tolerance) {
        stderr.printf("%s: got %f want %f\n", what, got, want);
        assert_not_reached();
    }
}

private void test_real_camera_exif() {
    var file = File.new_for_path(Path.build_filename(fixtures, "raw", "canon_exif.jpg"));
    var m = MetadataReader.read(file);
    assert(m.make == "Canon");
    assert(m.model == "Canon EOS 700D");
    assert(m.camera_label() == "Canon EOS 700D");
    near(m.exposure_time, 1.0 / 60.0, 1e-6, "exposure");
    near(m.aperture, 8.0, 1e-6, "aperture");
    assert(m.iso == 100);
    near(m.focal_length, 18.0, 1e-6, "focal");
    assert(m.lens.contains("EF-S18-135mm f/3.5-5.6 IS STM"));
    assert(m.date_taken != null);
    assert(m.date_taken.get_year() == 2016 && m.date_taken.get_month() == 4 && m.date_taken.get_day_of_month() == 17);
    assert(m.date_taken.get_hour() == 18 && m.date_taken.get_minute() == 38);
    assert(m.width == 16 && m.height == 12);
    assert(m.orientation == 1);
    assert(m.summary() == "f/8.0 · 1/60s · ISO 100 · 18 mm");
}

private uint8[] build_exif_tiff() {
    var b = new ByteArray();
    uint8[] header = { 'M', 'M', 0, 42, 0, 0, 0, 8 };
    b.append(header);
    uint8[] ifd0 = {
        0, 5,
        1, 15, 0, 2, 0, 0, 0, 5, 0, 0, 0, 74,
        1, 16, 0, 2, 0, 0, 0, 4, 'T', 'e', 's', 0,
        1, 18, 0, 3, 0, 0, 0, 1, 0, 6, 0, 0,
        0x88, 0x25, 0, 4, 0, 0, 0, 1, 0, 0, 0, 80,
        0x47, 0x46, 0, 3, 0, 0, 0, 1, 0, 4, 0, 0,
        0, 0, 0, 0
    };
    b.append(ifd0);
    b.append({ 'M', 'a', 'k', 'e', 0, 0 });
    uint8[] gps = {
        0, 4,
        0, 1, 0, 2, 0, 0, 0, 2, 'S', 0, 0, 0,
        0, 2, 0, 5, 0, 0, 0, 3, 0, 0, 0, 134,
        0, 3, 0, 2, 0, 0, 0, 2, 'W', 0, 0, 0,
        0, 4, 0, 5, 0, 0, 0, 3, 0, 0, 0, 158,
        0, 0, 0, 0
    };
    b.append(gps);
    uint8[] lat = { 0, 0, 0, 33, 0, 0, 0, 1, 0, 0, 0, 30, 0, 0, 0, 1, 0, 0, 0, 36, 0, 0, 0, 1 };
    uint8[] lon = { 0, 0, 0, 70, 0, 0, 0, 1, 0, 0, 0, 15, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1 };
    b.append(lat);
    b.append(lon);
    return b.steal();
}

private void test_exif_gps_orientation() {
    var tiff = build_exif_tiff();
    TiffReader r;
    try {
        r = new TiffReader(tiff);
    } catch (Error e) {
        assert_not_reached();
    }
    var m = new PhotoMetadata();
    MetadataReader.read_exif(r, m);
    assert(m.make == "Make");
    assert(m.model == "Tes");
    assert(m.orientation == 6);
    assert(m.rating == 4);
    assert(m.has_gps);
    near(m.latitude, -(33 + 30.0 / 60 + 36.0 / 3600), 1e-9, "lat");
    near(m.longitude, -(70 + 15.0 / 60), 1e-9, "lon");
    var jpeg = new ByteArray();
    jpeg.append({ 0xFF, 0xD8, 0xFF, 0xE1 });
    int len = tiff.length + 8;
    jpeg.append({ (uint8) (len >> 8), (uint8) len, 'E', 'x', 'i', 'f', 0, 0 });
    jpeg.append(tiff);
    jpeg.append({ 0xFF, 0xC0, 0, 11, 8, 0, 20, 0, 30, 1, 1, 0x11, 0, 0xFF, 0xD9 });
    var m2 = MetadataReader.read_bytes(jpeg.data);
    assert(m2.orientation == 6);
    assert(m2.width == 20 && m2.height == 30);
}

private const string LR_XMP = """<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
    xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
    xmlns:exif="http://ns.adobe.com/exif/1.0/"
   xmp:Rating="3"
   xmp:Label="Red"
   crs:Version="15.0"
   crs:Exposure2012="+0.65"
   crs:Contrast2012="-12"
   crs:WhiteBalance="Custom"
   crs:Temperature="5600"
   photoshop:City="Torino"
   exif:GPSLatitude="45,4.2N"
   exif:GPSLongitude="7,41.1E">
   <crs:ToneCurvePV2012>
    <rdf:Seq>
     <rdf:li>0, 0</rdf:li>
     <rdf:li>128, 140</rdf:li>
     <rdf:li>255, 255</rdf:li>
    </rdf:Seq>
   </crs:ToneCurvePV2012>
   <crs:GradientBasedCorrections>
    <rdf:Seq>
     <rdf:li>
      <rdf:Description crs:What="Correction" crs:CorrectionAmount="1.000000" crs:LocalExposure2012="0.500000">
       <crs:CorrectionMasks>
        <rdf:Seq>
         <rdf:li crs:What="Mask/Gradient" crs:ZeroX="0.5" crs:ZeroY="0.1" crs:FullX="0.5" crs:FullY="0.6"/>
        </rdf:Seq>
       </crs:CorrectionMasks>
      </rdf:Description>
     </rdf:li>
    </rdf:Seq>
   </crs:GradientBasedCorrections>
   <dc:subject>
    <rdf:Bag>
     <rdf:li>Mountains</rdf:li>
     <rdf:li>Snow</rdf:li>
    </rdf:Bag>
   </dc:subject>
   <dc:title>
    <rdf:Alt>
     <rdf:li xml:lang="it">Monte</rdf:li>
     <rdf:li xml:lang="x-default">Mountain &amp; snow</rdf:li>
    </rdf:Alt>
   </dc:title>
   <lr:hierarchicalSubject>
    <rdf:Bag>
     <rdf:li>Places|Italy|Alps</rdf:li>
    </rdf:Bag>
   </lr:hierarchicalSubject>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>""";

private void check_packet(XmpPacket p) {
    assert(p.get_simple(XmpPacket.NS_XMP, "Rating") == "3");
    assert(p.get_simple(XmpPacket.NS_CRS, "Exposure2012") == "+0.65");
    assert(p.get_simple(XmpPacket.NS_CRS, "Temperature") == "5600");
    var curve = p.get_list(XmpPacket.NS_CRS, "ToneCurvePV2012");
    assert(curve.length == 3 && curve[1] == "128, 140");
    assert(p.list_kind(XmpPacket.NS_CRS, "ToneCurvePV2012") == "Seq");
    var subj = p.get_list(XmpPacket.NS_DC, "subject");
    assert(subj.length == 2 && subj[1] == "Snow");
    assert(p.get_lang_alt(XmpPacket.NS_DC, "title") == "Mountain & snow");
    string? raw = p.get_raw(XmpPacket.NS_CRS, "GradientBasedCorrections");
    assert(raw != null);
    assert(raw.has_prefix("<rdf:Seq>"));
    assert(raw.contains("crs:LocalExposure2012=\"0.500000\""));
    assert(raw.contains("crs:ZeroY=\"0.1\""));
}

private void test_xmp_parse_roundtrip() {
    XmpPacket p;
    try {
        p = XmpPacket.parse(LR_XMP);
    } catch (Error e) {
        assert_not_reached();
    }
    check_packet(p);
    string text = p.serialize();
    assert(text.has_prefix("<?xpacket begin="));
    assert(text.contains("xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\""));
    assert(text.contains("xmlns:Iptc4xmpCore="));
    XmpPacket again;
    try {
        again = XmpPacket.parse(text);
    } catch (Error e) {
        stderr.printf("%s\n%s\n", e.message, text);
        assert_not_reached();
    }
    check_packet(again);
    var fresh = new XmpPacket();
    string inner = "<rdf:Seq><rdf:li><rdf:Description crs:What=\"Correction\" crs:LocalContrast2012=\"0.25\"/></rdf:li></rdf:Seq>";
    fresh.set_raw(XmpPacket.NS_CRS, "crs", "PaintBasedCorrections", inner);
    fresh.set_simple(XmpPacket.NS_CRS, "crs", "Clarity2012", "+20");
    try {
        var back = XmpPacket.parse(fresh.serialize());
        assert(back.get_simple(XmpPacket.NS_CRS, "Clarity2012") == "+20");
        string? r = back.get_raw(XmpPacket.NS_CRS, "PaintBasedCorrections");
        assert(r != null && r.contains("crs:LocalContrast2012=\"0.25\""));
        var twice = XmpPacket.parse(back.serialize());
        assert(twice.get_raw(XmpPacket.NS_CRS, "PaintBasedCorrections") == r);
    } catch (Error e) {
        assert_not_reached();
    }
    try {
        XmpPacket.parse("not xml at all <<<");
        assert_not_reached();
    } catch (Error e) {
    }
}

private void test_metadata_xmp() {
    XmpPacket p;
    try {
        p = XmpPacket.parse(LR_XMP);
    } catch (Error e) {
        assert_not_reached();
    }
    var m = new PhotoMetadata();
    MetadataWriter.from_xmp(p, m);
    assert(m.rating == 3);
    assert(m.label == "Red");
    assert(m.title == "Mountain & snow");
    assert(m.keywords.length == 2);
    assert(m.hierarchical_keywords[0] == "Places|Italy|Alps");
    assert(m.city == "Torino");
    assert(m.has_gps);
    near(m.latitude, 45.07, 1e-9, "lat");
    near(m.longitude, 7.685, 1e-9, "lon");
    m.caption = "Caption";
    m.creator = "Someone";
    m.latitude = -12.5;
    m.longitude = -45.25;
    m.altitude = 812.5;
    m.keywords = { "Snow" };
    var out_p = new XmpPacket();
    MetadataWriter.to_xmp(m, out_p);
    var m2 = new PhotoMetadata();
    try {
        MetadataWriter.from_xmp(XmpPacket.parse(out_p.serialize()), m2);
    } catch (Error e) {
        assert_not_reached();
    }
    assert(m2.rating == 3 && m2.label == "Red" && m2.caption == "Caption" && m2.creator == "Someone");
    near(m2.latitude, -12.5, 1e-6, "lat2");
    near(m2.longitude, -45.25, 1e-6, "lon2");
    near(m2.altitude, 812.5, 1e-6, "alt2");
    var subj = out_p.get_list(XmpPacket.NS_DC, "subject");
    assert(subj.length == 2 && subj[0] == "Snow" && subj[1] == "Alps");
}

private void test_sidecar() {
    string photo_path = Path.build_filename(tmp_dir, "IMG_0001.CR2");
    try {
        FileUtils.set_contents(photo_path, "raw");
    } catch (Error e) {
        assert_not_reached();
    }
    var photo = File.new_for_path(photo_path);
    assert(XmpSidecar.beside(photo).get_basename() == "IMG_0001.xmp");
    assert(XmpSidecar.load(photo).is_empty());
    var p = new XmpPacket();
    p.set_simple(XmpPacket.NS_XMP, "xmp", "Rating", "5");
    try {
        var target = XmpSidecar.save(photo, p);
        assert(target.equal(XmpSidecar.beside(photo)));
    } catch (Error e) {
        assert_not_reached();
    }
    var q = new XmpPacket();
    q.set_simple(XmpPacket.NS_CRS, "crs", "Exposure2012", "+1.00");
    try {
        XmpSidecar.save(photo, q);
    } catch (Error e) {
        assert_not_reached();
    }
    var loaded = XmpSidecar.load(photo);
    assert(loaded.get_simple(XmpPacket.NS_XMP, "Rating") == "5");
    assert(loaded.get_simple(XmpPacket.NS_CRS, "Exposure2012") == "+1.00");
    var m = MetadataReader.read(photo);
    assert(m.rating == 5);
    m.rating = 0;
    m.keywords = { "Test" };
    try {
        MetadataWriter.save_sidecar(photo, m);
    } catch (Error e) {
        assert_not_reached();
    }
    var after = XmpSidecar.load(photo);
    assert(after.get_simple(XmpPacket.NS_XMP, "Rating") == null);
    assert(after.get_list(XmpPacket.NS_DC, "subject")[0] == "Test");
    assert(after.get_simple(XmpPacket.NS_CRS, "Exposure2012") == "+1.00");
    XmpSidecar.remove(photo);
    assert(!XmpSidecar.exists(photo));
    FileUtils.remove(photo_path);
}

private void test_embedded_xmp_png() {
    var b = new ByteArray();
    b.append({ 0x89, 'P', 'N', 'G', 13, 10, 26, 10 });
    b.append({ 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 7, 0, 0, 0, 5, 8, 2, 0, 0, 0, 0, 0, 0, 0 });
    string xml = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:Rating=\"2\"/></rdf:RDF></x:xmpmeta>";
    var chunk = new ByteArray();
    chunk.append("XML:com.adobe.xmp".data);
    chunk.append({ 0, 0, 0, 0, 0 });
    chunk.append(xml.data);
    uint32 len = chunk.len;
    b.append({ (uint8) (len >> 24), (uint8) (len >> 16), (uint8) (len >> 8), (uint8) len, 'i', 'T', 'X', 't' });
    b.append(chunk.data);
    b.append({ 0, 0, 0, 0, 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0, 0, 0, 0 });
    var m = MetadataReader.read_bytes(b.data);
    assert(m.rating == 2);
    assert(m.width == 7 && m.height == 5);
}

private void test_real_camera_raw_xmp() {
    var file = File.new_for_path(Path.build_filename(fixtures, "raw", "camera_raw_xmp.jpg"));
    var p = XmpSidecar.load_embedded(file);
    assert(p != null);
    assert(p.get_simple(XmpPacket.NS_CRS, "Version") == "9.4");
    assert(p.get_simple(XmpPacket.NS_CRS, "Temperature") == "5150");
    assert(p.get_simple(XmpPacket.NS_CRS, "Tint") == "+17");
    assert(p.get_simple(XmpPacket.NS_CRS, "Shadows2012") == "+43");
    assert(p.get_simple(XmpPacket.NS_CRS, "SaturationAdjustmentRed") == "+77");
    assert(p.get_simple(XmpPacket.NS_CRS, "CameraProfile") == "Adobe Standard");
    var curve = p.get_list(XmpPacket.NS_CRS, "ToneCurve");
    assert(curve.length == 6 && curve[1] == "32, 22");
    assert(p.get_list(XmpPacket.NS_PHOTOSHOP, "DocumentAncestors").length == 2);
    string? history = p.get_raw(XmpPacket.NS_XMPMM, "History");
    assert(history != null && history.contains("stEvt:softwareAgent=\"Adobe Photoshop Camera Raw 9.4 (Windows)\""));
    assert(p.get_raw(XmpPacket.NS_XMPMM, "DerivedFrom") != null);
    var m = MetadataReader.read(file);
    assert(m.lens.has_prefix("EF-S18-135mm"));
    var combined = XmpSidecar.load_combined(file);
    assert(combined.get_simple(XmpPacket.NS_CRS, "Temperature") == "5150");
    try {
        var again = XmpPacket.parse(p.serialize());
        assert(again.get_simple(XmpPacket.NS_CRS, "Tint") == "+17");
        assert(again.get_raw(XmpPacket.NS_XMPMM, "History") == history);
    } catch (Error e) {
        assert_not_reached();
    }
}

private const string MASK_GROUP = """<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Version="15.4" crs:ProcessVersion="11.0">
<crs:MaskGroupBasedCorrections>
<rdf:Seq>
<rdf:li>
<rdf:Description crs:What="Correction" crs:CorrectionAmount="1" crs:CorrectionActive="true" crs:CorrectionName="Sky" crs:LocalExposure2012="-0.35" crs:LocalDehaze="0.2">
<crs:CorrectionMasks>
<rdf:Seq>
<rdf:li crs:What="Mask/Image" crs:MaskActive="true" crs:MaskName="Sky" crs:MaskBlendMode="0" crs:MaskInverted="false" crs:MaskValue="1" crs:MaskSubType="2" crs:ReferencePoint="0.500000 0.500000"/>
<rdf:li crs:What="Mask/Gradient" crs:MaskBlendMode="1" crs:ZeroX="0.5" crs:ZeroY="0.7" crs:FullX="0.5" crs:FullY="0.4"/>
</rdf:Seq>
</crs:CorrectionMasks>
</rdf:Description>
</rdf:li>
</rdf:Seq>
</crs:MaskGroupBasedCorrections>
</rdf:Description></rdf:RDF></x:xmpmeta>""";

private void test_mask_group_and_extended() {
    XmpPacket p;
    try {
        p = XmpPacket.parse(MASK_GROUP);
    } catch (Error e) {
        assert_not_reached();
    }
    string? raw = p.get_raw(XmpPacket.NS_CRS, "MaskGroupBasedCorrections");
    assert(raw != null && raw.has_prefix("<rdf:Seq>"));
    assert(raw.contains("crs:MaskSubType=\"2\"") && raw.contains("crs:LocalDehaze=\"0.2\""));
    assert(p.get_simple(XmpPacket.NS_CRS, "ProcessVersion") == "11.0");
    string main_xml = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:xmpNote=\"http://ns.adobe.com/xmp/note/\" xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\" xmpNote:HasExtendedXMP=\"0123456789ABCDEF0123456789ABCDEF\" crs:Exposure2012=\"+0.30\"/></rdf:RDF></x:xmpmeta>";
    var ext = MASK_GROUP.data;
    var jpeg = new ByteArray();
    jpeg.append({ 0xFF, 0xD8 });
    const string SIG = "http://ns.adobe.com/xap/1.0/";
    int len = 2 + SIG.length + 1 + main_xml.length;
    jpeg.append({ 0xFF, 0xE1, (uint8) (len >> 8), (uint8) len });
    jpeg.append(SIG.data);
    jpeg.append({ 0 });
    jpeg.append(main_xml.data);
    const string ESIG = "http://ns.adobe.com/xmp/extension/";
    int half = ext.length / 2;
    for (int part = 0; part < 2; part++) {
        int off = part == 0 ? 0 : half;
        int n = part == 0 ? half : ext.length - half;
        int seg = 2 + ESIG.length + 1 + 32 + 8 + n;
        jpeg.append({ 0xFF, 0xE1, (uint8) (seg >> 8), (uint8) seg });
        jpeg.append(ESIG.data);
        jpeg.append({ 0 });
        jpeg.append("0123456789ABCDEF0123456789ABCDEF".data);
        uint32 full = ext.length;
        jpeg.append({ (uint8) (full >> 24), (uint8) (full >> 16), (uint8) (full >> 8), (uint8) full });
        jpeg.append({ (uint8) (off >> 24), (uint8) (off >> 16), (uint8) (off >> 8), (uint8) off });
        jpeg.append(ext[off:off + n]);
    }
    jpeg.append({ 0xFF, 0xD9 });
    var merged = XmpPacket.from_embedded(jpeg.data);
    assert(merged != null);
    assert(merged.get_simple(XmpPacket.NS_CRS, "Exposure2012") == "+0.30");
    assert(merged.get_raw(XmpPacket.NS_CRS, "MaskGroupBasedCorrections") == raw);
    assert(!merged.has("http://ns.adobe.com/xmp/note/", "HasExtendedXMP"));
    var t = new TiffWriter();
    t.set_long(256, { 1 });
    t.set_long(257, { 1 });
    t.set_byte(700, MASK_GROUP.data);
    string tif = Path.build_filename(tmp_dir, "embedded.tif");
    try {
        FileUtils.set_data(tif, t.build());
    } catch (Error e) {
        assert_not_reached();
    }
    var fromtiff = XmpSidecar.load_embedded(File.new_for_path(tif));
    assert(fromtiff != null && fromtiff.get_raw(XmpPacket.NS_CRS, "MaskGroupBasedCorrections") == raw);
    FileUtils.remove(tif);
}

int main(string[] args) {
    Test.init(ref args);
    fixtures = args.length > 1 ? args[1] : "tests/fixtures";
    try {
        tmp_dir = DirUtils.make_tmp("photos-meta-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Test.add_func("/meta/real-camera-exif", test_real_camera_exif);
    Test.add_func("/meta/exif-gps", test_exif_gps_orientation);
    Test.add_func("/meta/xmp", test_xmp_parse_roundtrip);
    Test.add_func("/meta/metadata-xmp", test_metadata_xmp);
    Test.add_func("/meta/sidecar", test_sidecar);
    Test.add_func("/meta/png-xmp", test_embedded_xmp_png);
    Test.add_func("/meta/real-camera-raw-xmp", test_real_camera_raw_xmp);
    Test.add_func("/meta/mask-group-extended", test_mask_group_and_extended);
    int rc = Test.run();
    DirUtils.remove(tmp_dir);
    return rc;
}
