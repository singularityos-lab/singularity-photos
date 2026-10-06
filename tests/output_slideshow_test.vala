using Singularity.Apps.Photos;
using Singularity.Imaging;

private string tmp_dir;

private File photo(int i, float r, float g, float b) {
    string p = Path.build_filename(tmp_dir, "s%d.png".printf(i));
    try {
        FileUtils.set_data(p, ImageWriters.encode_png(new FloatImage.filled(320, 240, r, g, b), 8, new uint8[0], new uint8[0], "", 72));
    } catch (Error e) {
        assert_not_reached();
    }
    return File.new_for_path(p);
}

private string wav(double seconds) {
    string p = Path.build_filename(tmp_dir, "tone.wav");
    int samples = (int) (seconds * 48000);
    var b = new ByteArray();
    uint8[] head = new uint8[44];
    b.append(head);
    for (int i = 0; i < samples; i++) {
        int16 v = (int16) (Math.sin(2 * Math.PI * 440 * i / 48000.0) * 8000);
        uint8[] frame = { (uint8) (v & 0xFF), (uint8) ((v >> 8) & 0xFF), (uint8) (v & 0xFF), (uint8) ((v >> 8) & 0xFF) };
        b.append(frame);
    }
    var d = b.steal();
    uint32 data_len = samples * 4;
    uint32[] fields = { 0x46464952, 36 + data_len, 0x45564157, 0x20746d66, 16 };
    for (int i = 0; i < 5; i++) for (int k = 0; k < 4; k++) d[i * 4 + k] = (uint8) ((fields[i] >> (8 * k)) & 0xFF);
    d[20] = 1; d[21] = 0; d[22] = 2; d[23] = 0;
    uint32 rate = 48000, byte_rate = 48000 * 4;
    for (int k = 0; k < 4; k++) { d[24 + k] = (uint8) ((rate >> (8 * k)) & 0xFF); d[28 + k] = (uint8) ((byte_rate >> (8 * k)) & 0xFF); }
    d[32] = 4; d[33] = 0; d[34] = 16; d[35] = 0;
    d[36] = 'd'; d[37] = 'a'; d[38] = 't'; d[39] = 'a';
    for (int k = 0; k < 4; k++) d[40 + k] = (uint8) ((data_len >> (8 * k)) & 0xFF);
    try {
        FileUtils.set_data(p, d);
    } catch (Error e) {
        assert_not_reached();
    }
    return p;
}

private void test_compositor() {
    var spec = new SlideshowSpec();
    spec.slide_seconds = 2;
    spec.transition_seconds = 1;
    var comp = new SlideCompositor(spec, 64, 48);
    comp.add_image(new FloatImage.filled(64, 48, 1, 0, 0), "");
    comp.add_image(new FloatImage.filled(64, 48, 0, 0, 1), "");
    var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, 64, 48);
    var cr = new Cairo.Context(surface);
    double[] times = { 0.5, 1.5, 2.5 };
    int[] reds = new int[3], blues = new int[3];
    for (int i = 0; i < 3; i++) {
        comp.draw(cr, times[i]);
        surface.flush();
        unowned uint8[] d = surface.get_data();
        int o = 24 * surface.get_stride() + 32 * 4;
        blues[i] = d[o];
        reds[i] = d[o + 2];
    }
    assert(reds[0] > 240 && blues[0] < 10);
    assert(reds[1] > 60 && reds[1] < 200 && blues[1] > 60 && blues[1] < 200);
    assert(blues[2] > 240 && reds[2] < 10);
}

private void test_video() {
    var containers = SlideshowVideo.available_containers();
    assert(containers.length > 0);
    File[] files = { photo(0, 0.9f, 0.1f, 0.1f), photo(1, 0.1f, 0.9f, 0.1f), photo(2, 0.1f, 0.1f, 0.9f) };
    var spec = new SlideshowSpec();
    spec.slide_seconds = 1;
    spec.transition_seconds = 0.4;
    spec.caption = "filename";
    spec.music = wav(1.3);
    foreach (var c in containers) {
        string out_path = Path.build_filename(tmp_dir, "show." + c);
        double last = 0;
        try {
            SlideshowVideo.export(files, spec, 160, 90, 10, c, out_path, null, (f) => last = f);
        } catch (Error e) {
            stderr.printf("%s: %s\n", c, e.message);
            assert_not_reached();
        }
        assert(last == 1.0);
        var pipe = (Gst.Pipeline) Gst.parse_launch("filesrc location=\"%s\" ! decodebin name=d d. ! queue ! videoconvert ! appsink name=v sync=false d. ! queue ! audioconvert ! fakesink sync=false".printf(out_path));
        var sink = (Gst.App.Sink) pipe.get_by_name("v");
        pipe.set_state(Gst.State.PLAYING);
        int frames = 0;
        Gst.ClockTime last_pts = 0;
        while (true) {
            var sample = sink.try_pull_sample(5 * Gst.SECOND);
            if (sample == null) break;
            frames++;
            last_pts = sample.get_buffer().pts;
        }
        pipe.set_state(Gst.State.NULL);
        stdout.printf("# %s: %d frames, last pts %.2f s\n", c, frames, (double) last_pts / Gst.SECOND);
        assert(frames >= 28 && frames <= 31);
    }
}

int main(string[] args) {
    Test.init(ref args);
    Gst.init(ref args);
    try {
        tmp_dir = DirUtils.make_tmp("photos-show-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Test.add_func("/output/slideshow/compositor", test_compositor);
    Test.add_func("/output/slideshow/video", test_video);
    return Test.run();
}
