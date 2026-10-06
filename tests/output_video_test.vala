using Singularity.Apps.Photos;
using Singularity.Imaging;

private string tmp_dir;

private string make_video(string name, string mux, double seconds) {
    string path = Path.build_filename(tmp_dir, name);
    int frames = (int) (seconds * 30);
    string desc = ("videotestsrc num-buffers=%d pattern=smpte ! video/x-raw,width=320,height=240,framerate=30/1 ! videoconvert ! video/x-raw,format=I420 ! x264enc speed-preset=ultrafast ! h264parse ! queue ! %s name=mux ! filesink location=\"%s\" "
        + "audiotestsrc num-buffers=%d samplesperbuffer=1600 ! audio/x-raw,rate=48000,channels=2 ! audioconvert ! voaacenc ! queue ! mux.").printf(frames, mux, path, (int) (seconds * 30));
    try {
        var pipe = (Gst.Pipeline) Gst.parse_launch(desc);
        pipe.set_state(Gst.State.PLAYING);
        var msg = pipe.get_bus().timed_pop_filtered(60 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR);
        assert(msg != null && msg.type == Gst.MessageType.EOS);
        pipe.set_state(Gst.State.NULL);
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    return path;
}

private void test_video_tools() {
    var clip = File.new_for_path(make_video("VID_0001.mp4", "mp4mux", 3.0));
    try {
        var info = VideoTools.probe(clip);
        stdout.printf("# probe video=%s audio=%s %dx%d\n", info.has_video.to_string(), info.has_audio.to_string(), info.width, info.height);
        assert(info.has_video && info.has_audio && info.width == 320 && info.height == 240);
        assert((info.duration / 1e9 - 3.0).abs() < 0.2);
        var poster = VideoTools.poster(clip, 1.0, 160);
        assert(poster.width == 160 && poster.height == 120);
        float r, g, b, a;
        poster.get_pixel(10, 30, out r, out g, out b, out a);
        assert(r + g + b > 0.3f);
        var cached = VideoTools.cached_poster(clip, 200);
        assert(cached != null && cached.query_exists());
        var trimmed = VideoTools.trim(clip, (int64) (1.0 * Gst.SECOND), (int64) (2.5 * Gst.SECOND));
        assert(trimmed.get_basename() == "VID_0001 (Trimmed).mp4");
        var tinfo = VideoTools.probe(trimmed);
        stdout.printf("# trimmed duration %.2f s\n", tinfo.duration / 1e9);
        assert((tinfo.duration / 1e9 - 1.5).abs() < 0.25);
        assert(tinfo.has_audio && tinfo.width == 320);
        assert(clip.query_exists());
        var again = VideoTools.trim(clip, 0, (int64) (1.0 * Gst.SECOND));
        assert(again.get_basename() == "VID_0001 (Trimmed 2).mp4");
        try {
            VideoTools.trim(clip, (int64) (1.0 * Gst.SECOND), (int64) (1.02 * Gst.SECOND));
            assert_not_reached();
        } catch (IOError e) {
            assert(e is IOError.INVALID_ARGUMENT);
        }
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
}

private void test_live_pair() {
    string mov = make_video("IMG_0100.MOV", "qtmux", 1.5);
    string still = Path.build_filename(tmp_dir, "IMG_0100.JPG");
    try {
        var frame = VideoTools.poster(File.new_for_path(mov), 0.2, 0);
        FileUtils.set_data(still, ImageWriters.encode_jpeg(WorkingSpace.to_srgb_encoded(frame), 90, new uint8[0], new uint8[0], "", 72));
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        assert_not_reached();
    }
    var playable = LivePhoto.playable_for(File.new_for_path(still));
    assert(playable != null && playable.get_path() == mov);
    try {
        assert(VideoTools.probe(playable).has_video);
    } catch (Error e) {
        assert_not_reached();
    }
}

int main(string[] args) {
    Test.init(ref args);
    Gst.init(ref args);
    try {
        tmp_dir = DirUtils.make_tmp("photos-video-XXXXXX");
    } catch (Error e) {
        return 1;
    }
    Environment.set_variable("XDG_CACHE_HOME", Path.build_filename(tmp_dir, "cache"), true);
    Test.add_func("/output/video/tools", test_video_tools);
    Test.add_func("/output/video/live-pair", test_live_pair);
    return Test.run();
}
