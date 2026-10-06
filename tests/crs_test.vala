using Singularity.Apps.Photos;

private void near(double got, double want, double tolerance) {
    if ((got - want).abs() > tolerance) {
        stderr.printf("got %f want %f\n", got, want);
        assert_not_reached();
    }
}

private EditParams sample() {
    var p = new EditParams();
    p.set_value(Adjustment.EXPOSURE, 0.35);
    p.set_value(Adjustment.CONTRAST, 0.2);
    p.set_value(Adjustment.HIGHLIGHTS, -0.6);
    p.set_value(Adjustment.SHADOWS, 0.4);
    p.set_value(Adjustment.CLARITY, 0.15);
    p.set_value(Adjustment.VIGNETTE, 0.3);
    p.set_value(Adjustment.SHARPNESS, 0.3);
    p.develop.set("hsl.sat.blue", -0.25);
    p.develop.set("grading.shadows.hue", 210);
    p.develop.set("grading.shadows.sat", 0.2);
    p.develop.set("detail.noise.amount", 0.3);
    p.develop.set("transform.vertical", 0.4);
    p.develop.curve("master").set_points({ 0.25, 0.75 }, { 0.2, 0.8 });
    p.set_crop(0.1, 0.1, 0.8, 0.7);
    p.straighten = 2.5;
    var l = new LocalAdjustment();
    l.set("exposure", -1.0);
    l.set("clarity", 0.3);
    var c = new MaskComponent("linear");
    c.s("x0", 0.5);
    c.s("y0", 0.1);
    c.s("x1", 0.5);
    c.s("y1", 0.5);
    l.components.add(c);
    p.locals.add(l);
    var r = new LocalAdjustment();
    r.set("saturation", -0.5);
    var rc = new MaskComponent("radial");
    rc.s("cx", 0.4);
    rc.s("cy", 0.6);
    rc.s("rx", 0.2);
    rc.s("ry", 0.1);
    rc.s("feather", 0.4);
    r.components.add(rc);
    p.locals.add(r);
    var b = new LocalAdjustment();
    b.set("shadows", 0.5);
    var bc = new MaskComponent("brush");
    var st = new BrushStroke();
    st.radius = 0.05;
    st.add_point(0.1, 0.2);
    st.add_point(0.3, 0.25);
    bc.strokes.add(st);
    b.components.add(bc);
    p.locals.add(b);
    var s = new SpotEdit();
    s.x = 0.3;
    s.y = 0.4;
    s.source_x = 0.35;
    s.source_y = 0.4;
    s.radius = 0.02;
    s.mode = "clone";
    p.spots.add(s);
    return p;
}

private void check_crs_only(EditParams q, EditParams p) {
    near(q.get_value(Adjustment.EXPOSURE), p.get_value(Adjustment.EXPOSURE), 1e-5);
    near(q.get_value(Adjustment.HIGHLIGHTS), -0.6, 1e-5);
    near(q.get_value(Adjustment.VIGNETTE), 0.3, 1e-5);
    near(q.get_value(Adjustment.SHARPNESS), 0.3, 1e-5);
    near(q.develop.get("hsl.sat.blue"), -0.25, 1e-5);
    near(q.develop.get("grading.shadows.hue"), 210, 1e-5);
    near(q.develop.get("transform.vertical"), 0.4, 1e-5);
    assert(q.develop.has_curve("master"));
    near(q.develop.curve("master").xs[0], 0.25, 0.01);
    near(q.crop_x, 0.1, 1e-5);
    near(q.crop_h, 0.7, 1e-5);
    near(q.straighten, 2.5, 1e-5);
    assert(q.locals.size == 3);
    assert(q.locals[0].components[0].kind == "linear");
    near(q.locals[0].get("exposure"), -1.0, 1e-5);
    near(q.locals[0].components[0].g("y0"), 0.1, 1e-5);
    assert(q.locals[1].components[0].kind == "radial");
    near(q.locals[1].components[0].g("cx"), 0.4, 1e-5);
    near(q.locals[1].components[0].g("rx"), 0.2, 1e-5);
    assert(!q.locals[1].components[0].invert);
    assert(q.locals[2].components[0].kind == "brush");
    assert(q.locals[2].components[0].strokes[0].points.length == 4);
    assert(q.spots.size == 1 && q.spots[0].mode == "clone");
    near(q.spots[0].source_x, 0.35, 1e-5);
}

private void test_round_trip_full() {
    var p = sample();
    var x = new XmpPacket();
    CrsMapping.write(p, x, false);
    string text = x.serialize();
    assert(text.contains("crs:Exposure2012"));
    assert(text.contains("crs:GradientBasedCorrections"));
    XmpPacket y;
    try {
        y = XmpPacket.parse(text);
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    assert(CrsMapping.has_settings(y));
    string[] groups;
    var q = CrsMapping.read(y, out groups);
    assert(q.equals(p));
}

private void test_round_trip_crs_only() {
    var p = sample();
    var x = new XmpPacket();
    CrsMapping.write(p, x, false);
    x.remove(XmpPacket.NS_SINTY, "Develop");
    XmpPacket y;
    try {
        y = XmpPacket.parse(x.serialize());
    } catch (Error e) {
        assert_not_reached();
    }
    string[] groups;
    var q = CrsMapping.read(y, out groups);
    check_crs_only(q, p);
    bool has_light = false;
    foreach (var g in groups) if (g == "light") has_light = true;
    assert(has_light);
}

private void test_lightroom_attribute_form() {
    string xmp = """<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
    crs:Version="15.0"
    crs:ProcessVersion="11.0"
    crs:WhiteBalance="Custom"
    crs:Temperature="4800"
    crs:Tint="+12"
    crs:Exposure2012="+1.00"
    crs:Contrast2012="-15"
    crs:Shadows2012="+40"
    crs:SaturationAdjustmentBlue="-30"
    crs:ConvertToGrayscale="False"
    crs:HasCrop="False">
   <crs:Name>
    <rdf:Alt>
     <rdf:li xml:lang="x-default">Test Look</rdf:li>
    </rdf:Alt>
   </crs:Name>
   <crs:ToneCurvePV2012>
    <rdf:Seq>
     <rdf:li>0, 0</rdf:li>
     <rdf:li>64, 50</rdf:li>
     <rdf:li>192, 210</rdf:li>
     <rdf:li>255, 255</rdf:li>
    </rdf:Seq>
   </crs:ToneCurvePV2012>
   <crs:CircularGradientBasedCorrections>
    <rdf:Seq>
     <rdf:li>
      <rdf:Description crs:What="Correction" crs:CorrectionAmount="1.000000" crs:CorrectionActive="true" crs:LocalExposure2012="0.250000">
       <crs:CorrectionMasks>
        <rdf:Seq>
         <rdf:li crs:What="Mask/CircularGradient" crs:MaskValue="1.000000" crs:Top="0.2" crs:Left="0.3" crs:Bottom="0.6" crs:Right="0.7" crs:Angle="0" crs:Midpoint="50" crs:Roundness="0" crs:Feather="50" crs:Flipped="true"/>
        </rdf:Seq>
       </crs:CorrectionMasks>
      </rdf:Description>
     </rdf:li>
    </rdf:Seq>
   </crs:CircularGradientBasedCorrections>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>""";
    XmpPacket x;
    try {
        x = XmpPacket.parse(xmp);
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    assert(CrsMapping.has_settings(x));
    string[] groups;
    var p = CrsMapping.read(x, out groups);
    near(p.get_value(Adjustment.EXPOSURE), 0.5, 1e-6);
    near(p.get_value(Adjustment.CONTRAST), -0.15, 1e-6);
    near(p.develop.get("hsl.sat.blue"), -0.3, 1e-6);
    assert(p.develop.get_string("wb.mode") == "custom");
    near(p.develop.get("wb.temperature"), 4800, 1e-6);
    near(p.develop.get("wb.tint"), 12, 1e-6);
    near(p.develop.curve("master").ys[0], 50.0 / 255, 1e-6);
    assert(p.locals.size == 1);
    near(p.locals[0].get("exposure"), 1.0, 1e-6);
    var c = p.locals[0].components[0];
    near(c.g("cx"), 0.5, 1e-6);
    near(c.g("cy"), 0.4, 1e-6);
    near(c.g("rx"), 0.2, 1e-6);
    assert(x.get_lang_alt(XmpPacket.NS_CRS, "Name") == "Test Look");
}

private void test_preset_import() {
    string dir;
    try {
        dir = DirUtils.make_tmp("crs-XXXXXX");
    } catch (Error e) {
        assert_not_reached();
    }
    var p = new EditParams();
    p.set_value(Adjustment.VIBRANCE, 0.4);
    p.develop.set("grading.highlights.hue", 45);
    p.develop.set("grading.highlights.sat", 0.3);
    var x = new XmpPacket();
    CrsMapping.write(p, x, false);
    x.remove(XmpPacket.NS_SINTY, "Develop");
    x.remove(XmpPacket.NS_CRS, "Exposure2012");
    x.set_lang_alt(XmpPacket.NS_CRS, "crs", "Name", "Golden Hour");
    string path = Path.build_filename(dir, "golden.xmp");
    try {
        FileUtils.set_contents(path, x.serialize());
        var preset = DevelopPresets.import_xmp(File.new_for_path(path));
        assert(preset.name == "Golden Hour");
        var target = new EditParams();
        target.set_value(Adjustment.EXPOSURE, 0.2);
        DevelopPresets.apply(target, preset, 1.0);
        near(target.get_value(Adjustment.VIBRANCE), 0.4, 1e-6);
        near(target.develop.get("grading.highlights.hue"), 45, 1e-6);
        near(target.get_value(Adjustment.EXPOSURE), 0.2, 1e-6);
        var half = new EditParams();
        DevelopPresets.apply(half, preset, 0.5);
        near(half.get_value(Adjustment.VIBRANCE), 0.2, 1e-6);
        bool found = false;
        foreach (var q in DevelopPresets.all()) if (q.name == "Golden Hour") found = true;
        assert(found);
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
}

private void test_groups_transfer() {
    var src = sample();
    var dst = new EditParams();
    EditParamsGroups.transfer(src, dst, { "light", "hsl" });
    near(dst.get_value(Adjustment.EXPOSURE), 0.35, 1e-9);
    near(dst.develop.get("hsl.sat.blue"), -0.25, 1e-9);
    near(dst.get_value(Adjustment.CLARITY), 0, 1e-9);
    assert(dst.locals.size == 0);
    assert(!dst.has_crop());
    SettingsClipboard.copy(src, { "masks", "crop" });
    var dst2 = new EditParams();
    SettingsClipboard.paste(dst2);
    assert(dst2.locals.size == 3);
    assert(dst2.has_crop());
    near(dst2.get_value(Adjustment.EXPOSURE), 0, 1e-9);
}

private void test_orientation() {
    for (int t = 0; t < 4; t++) {
        foreach (bool f in new bool[] { false, true }) {
            int turns;
            bool flip;
            CrsMapping.turns_for(CrsMapping.orientation_for(t, f), out turns, out flip);
            assert(turns == t && flip == f);
        }
    }
}

private string fixtures;

private void test_real_camera_raw() {
    var f = File.new_for_path(Path.build_filename(fixtures, "raw", "camera_raw_xmp.jpg"));
    var x = XmpSidecar.load_combined(f);
    assert(CrsMapping.has_settings(x));
    string[] groups;
    var p = CrsMapping.read(x, out groups);
    assert(!p.is_identity());
    assert(groups.length > 0);
    var y = new XmpPacket();
    CrsMapping.write(p, y, false);
    y.remove(XmpPacket.NS_SINTY, "Develop");
    XmpPacket z;
    try {
        z = XmpPacket.parse(y.serialize());
    } catch (Error e) {
        assert_not_reached();
    }
    string[] g2;
    var q = CrsMapping.read(z, out g2);
    for (int i = 0; i < Adjustment.COUNT; i++) near(q.values[i], p.values[i], 1e-4);
    foreach (unowned string band in HSL_BANDS) near(q.develop.get("hsl.hue." + band), p.develop.get("hsl.hue." + band), 1e-4);
    var real = EditStore.load_xmp(f);
    assert(real != null);
}

int main(string[] args) {
    try {
        Environment.set_variable("XDG_DATA_HOME", DirUtils.make_tmp("crs-data-XXXXXX"), true);
    } catch (Error e) {
        return 1;
    }
    Test.init(ref args);
    fixtures = args.length > 1 ? args[1] : "tests/fixtures";
    Test.add_func("/crs/real-camera-raw", test_real_camera_raw);
    Test.add_func("/crs/round-trip-full", test_round_trip_full);
    Test.add_func("/crs/round-trip-crs-only", test_round_trip_crs_only);
    Test.add_func("/crs/lightroom-attributes", test_lightroom_attribute_form);
    Test.add_func("/crs/preset-import", test_preset_import);
    Test.add_func("/crs/groups", test_groups_transfer);
    Test.add_func("/crs/orientation", test_orientation);
    return Test.run();
}
