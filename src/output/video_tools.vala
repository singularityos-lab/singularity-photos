using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class VideoInfo : Object {
        public int64 duration = 0;
        public int width = 0;
        public int height = 0;
        public bool has_audio = false;
        public bool has_video = false;
    }

    namespace VideoTools {

        private bool demoted = false;

        public void ensure() {
            if (!Gst.is_initialized()) {
                unowned string[]? none = null;
                Gst.init(ref none);
            }
            prefer_software();
        }

        public void prefer_software() {
            if (demoted || Environment.get_variable("SINGULARITY_PHOTOS_HW_VIDEO") == "1") return;
            demoted = true;
            var registry = Gst.Registry.get();
            foreach (unowned string plugin in new string[] { "va", "vaapi", "nvcodec", "v4l2codecs", "qsv" }) {
                foreach (var feature in registry.get_feature_list_by_plugin(plugin)) feature.set_rank(Gst.Rank.NONE);
            }
        }

        private Gst.Pipeline decode_pipeline(File file, int max_side, out Gst.App.Sink sink) throws Error {
            ensure();
            string caps = max_side > 0 ? ",width=[1,%d],height=[1,%d],pixel-aspect-ratio=1/1".printf(max_side, max_side) : "";
            var pipe = (Gst.Pipeline) Gst.parse_launch(
                "uridecodebin name=src src. ! audio/x-raw ! fakesink sync=false async=false src. ! video/x-raw ! videoconvert ! videoscale add-borders=false ! videoflip video-direction=auto ! videoconvert ! video/x-raw,format=RGBA%s ! appsink name=sink sync=false".printf(caps));
            pipe.get_by_name("src").set("uri", file.get_uri());
            sink = (Gst.App.Sink) pipe.get_by_name("sink");
            return pipe;
        }

        private FloatImage? sample_to_image(Gst.Sample sample) {
            var caps = sample.get_caps();
            var buffer = sample.get_buffer();
            if (caps == null || buffer == null) return null;
            var info = new Gst.Video.Info();
            if (!info.from_caps(caps)) return null;
            Gst.MapInfo map;
            if (!buffer.map(out map, Gst.MapFlags.READ)) return null;
            var img = FloatImage.from_rgba8(map.data, info.width, info.height, info.stride[0], true, true);
            buffer.unmap(map);
            WorkingSpace.from_linear_srgb(img);
            return img;
        }

        private bool wait_state(Gst.Pipeline pipe, out string? error) {
            error = null;
            Gst.State state, pending;
            var ret = pipe.get_state(out state, out pending, 15 * Gst.SECOND);
            if (ret == Gst.StateChangeReturn.FAILURE || ret == Gst.StateChangeReturn.ASYNC) {
                var msg = pipe.get_bus().pop_filtered(Gst.MessageType.ERROR);
                if (msg != null) {
                    Error e;
                    string debug;
                    msg.parse_error(out e, out debug);
                    error = e.message;
                } else {
                    error = _("The video could not be opened");
                }
                return false;
            }
            return true;
        }

        public FloatImage poster(File file, double seconds = 0.5, int max_side = 512) throws Error {
            Gst.App.Sink sink;
            var pipe = decode_pipeline(file, 0, out sink);
            sink.set("max-buffers", 0u);
            sink.set("drop", false);
            pipe.set_state(Gst.State.PLAYING);
            Gst.Sample? chosen = null;
            int64 target = (int64) (seconds * Gst.SECOND);
            while (true) {
                var sample = sink.try_pull_sample(10 * Gst.SECOND);
                if (sample == null) break;
                chosen = sample;
                var buffer = sample.get_buffer();
                if (buffer != null && buffer.pts != Gst.CLOCK_TIME_NONE && (int64) buffer.pts >= target) break;
            }
            string? error = null;
            var msg = pipe.get_bus().pop_filtered(Gst.MessageType.ERROR);
            if (msg != null) {
                Error e;
                string debug;
                msg.parse_error(out e, out debug);
                error = e.message;
            }
            FloatImage? img = chosen != null ? sample_to_image(chosen) : null;
            pipe.set_state(Gst.State.NULL);
            if (img == null) throw new IOError.FAILED(error ?? _("The video has no picture"));
            return max_side > 0 ? img.scaled_to_fit(max_side) : img;
        }

        public File poster_cache(File file) {
            return File.new_for_path(Path.build_filename(Environment.get_user_cache_dir(), "singularity-photos", "posters",
                Checksum.compute_for_string(ChecksumType.SHA256, file.get_uri()) + ".png"));
        }

        public File? cached_poster(File file, int max_side = 512) {
            var cache = poster_cache(file);
            try {
                if (cache.query_exists()) {
                    var ci = cache.query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                    var vi = file.query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                    if (ci.get_modification_date_time().compare(vi.get_modification_date_time()) >= 0) return cache;
                }
                var img = poster(file, 0.5, max_side);
                DirUtils.create_with_parents(cache.get_parent().get_path(), 0755);
                FileUtils.set_data(cache.get_path() + ".part", ImageWriters.encode_png(WorkingSpace.to_srgb_encoded(img), 8, new uint8[0], new uint8[0], "", 72));
                FileUtils.rename(cache.get_path() + ".part", cache.get_path());
                return cache;
            } catch (Error e) {
                return null;
            }
        }

        public VideoInfo probe(File file) throws Error {
            ensure();
            var pipe = new Gst.Pipeline(null);
            var src = Gst.ElementFactory.make("uridecodebin", null);
            if (src == null) throw new IOError.NOT_SUPPORTED(_("GStreamer is not complete on this system"));
            src.set("uri", file.get_uri());
            pipe.add(src);
            var info = new VideoInfo();
            src.pad_added.connect((pad) => {
                var caps = pad.get_current_caps() ?? pad.query_caps(null);
                string name = caps != null && caps.get_size() > 0 ? caps.get_structure(0).get_name() : "";
                if (name.has_prefix("audio/")) info.has_audio = true;
                if (name.has_prefix("video/")) {
                    info.has_video = true;
                    unowned Gst.Structure st = caps.get_structure(0);
                    st.get_int("width", out info.width);
                    st.get_int("height", out info.height);
                }
                var fake = Gst.ElementFactory.make("fakesink", null);
                fake.set("sync", false);
                pipe.add(fake);
                fake.sync_state_with_parent();
                pad.link(fake.get_static_pad("sink"));
            });
            pipe.set_state(Gst.State.PAUSED);
            string? error;
            bool ok = wait_state(pipe, out error);
            if (ok) pipe.query_duration(Gst.Format.TIME, out info.duration);
            pipe.set_state(Gst.State.NULL);
            if (!ok) throw new IOError.FAILED(error);
            return info;
        }

        public string container_for(File source) {
            string name = (source.get_basename() ?? "").down();
            var available = SlideshowVideo.available_containers();
            if ((name.has_suffix(".webm") || name.has_suffix(".mkv")) && "webm" in available) return "webm";
            if ("mp4" in available) return "mp4";
            return available.length > 0 ? available[0] : "";
        }

        public File trim_target(File source, string container) {
            var parent = source.get_parent() ?? File.new_for_path(Environment.get_home_dir());
            string name = source.get_basename() ?? "video";
            int dot = name.last_index_of_char('.');
            string stem = dot > 0 ? name.substring(0, dot) : name;
            var candidate = parent.get_child(_("%s (Trimmed)").printf(stem) + "." + container);
            for (int n = 2; candidate.query_exists(); n++) candidate = parent.get_child(_("%s (Trimmed %d)").printf(stem, n) + "." + container);
            return candidate;
        }

        public File trim(File source, int64 start, int64 end, File? target = null, Cancellable? cancellable = null) throws Error {
            ensure();
            var info = probe(source);
            if (!info.has_video) throw new IOError.INVALID_ARGUMENT(_("This file has no video"));
            if (info.duration > 0) end = int64.min(end, info.duration);
            start = int64.max(0, start);
            if (end - start < Gst.SECOND / 10) throw new IOError.INVALID_ARGUMENT(_("The trimmed video would be too short"));
            string container = container_for(source);
            if (container == "") throw new IOError.NOT_SUPPORTED(_("No video encoder is available on this system"));
            var out_file = target ?? trim_target(source, container);
            string venc = container == "mp4"
                ? (SlideshowVideo.has("x264enc") ? "x264enc speed-preset=medium bitrate=12000 ! video/x-h264,profile=high" : "openh264enc bitrate=12000000")
                : (SlideshowVideo.has("vp9enc") ? "vp9enc deadline=1 cpu-used=4 target-bitrate=12000000" : "vp8enc deadline=1 target-bitrate=12000000");
            string aenc = container == "mp4" ? "voaacenc bitrate=192000" : "opusenc bitrate=160000";
            string mux = container == "mp4" ? "mp4mux faststart=true" : "webmmux";
            var desc = new StringBuilder();
            desc.append_printf("uridecodebin name=src %s name=mux ! filesink name=out", mux);
            desc.append_printf(" src. ! video/x-raw ! queue name=vq ! videoconvert ! videoflip video-direction=auto ! videoconvert ! video/x-raw,format=I420 ! %s ! queue ! mux.", venc);
            if (info.has_audio && (SlideshowVideo.has("voaacenc") || container != "mp4")) desc.append_printf(" src. ! audio/x-raw ! queue ! audioconvert ! audioresample ! %s ! queue ! mux.", aenc);
            var pipe = (Gst.Pipeline) Gst.parse_launch(desc.str);
            pipe.get_by_name("src").set("uri", source.get_uri());
            string partial = out_file.get_path() + ".part";
            pipe.get_by_name("out").set("location", partial);
            pipe.set_state(Gst.State.PAUSED);
            string? error;
            if (!wait_state(pipe, out error)) {
                pipe.set_state(Gst.State.NULL);
                FileUtils.remove(partial);
                throw new IOError.FAILED(error);
            }
            var seek = new Gst.Event.seek(1.0, Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.ACCURATE, Gst.SeekType.SET, start, Gst.SeekType.SET, end);
            if (!pipe.get_by_name("vq").get_static_pad("src").send_event(seek)) {
                pipe.set_state(Gst.State.NULL);
                FileUtils.remove(partial);
                throw new IOError.FAILED(_("The video cannot be cut at that point"));
            }
            pipe.set_state(Gst.State.PLAYING);
            var bus = pipe.get_bus();
            string? failure = null;
            while (true) {
                if (cancellable != null && cancellable.is_cancelled()) {
                    failure = _("Cancelled");
                    break;
                }
                var msg = bus.timed_pop_filtered(200 * Gst.MSECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR);
                if (msg == null) continue;
                if (msg.type == Gst.MessageType.ERROR) {
                    Error e;
                    string debug;
                    msg.parse_error(out e, out debug);
                    failure = e.message;
                }
                break;
            }
            pipe.set_state(Gst.State.NULL);
            if (failure != null) {
                FileUtils.remove(partial);
                throw new IOError.FAILED(failure);
            }
            if (FileUtils.rename(partial, out_file.get_path()) != 0) throw new IOError.FAILED(_("Cannot write %s").printf(out_file.get_basename()));
            return out_file;
        }
    }
}
