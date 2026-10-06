using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class SlideshowSpec : Object {
        public double slide_seconds { get; set; default = 4.0; }
        public double transition_seconds { get; set; default = 1.0; }
        public string transition { get; set; default = "fade"; }
        public string caption { get; set; default = "none"; }
        public string music { get; set; default = ""; }
        public bool loop { get; set; default = true; }

        public const string[] TRANSITIONS = { "none", "fade", "slide", "zoom" };

        public double total_seconds(int count) {
            return count * slide_seconds;
        }
    }

    public class SlideCompositor : Object {
        public SlideshowSpec spec { get; construct; }
        public int width { get; construct; }
        public int height { get; construct; }
        private Gee.ArrayList<Cairo.ImageSurface> slides = new Gee.ArrayList<Cairo.ImageSurface>();
        private Gee.ArrayList<string> captions = new Gee.ArrayList<string>();

        public SlideCompositor(SlideshowSpec spec, int width, int height) {
            Object(spec: spec, width: width, height: height);
        }

        public int count {
            get { return slides.size; }
        }

        public void add_image(FloatImage working, string caption) {
            var fitted = working.scaled_to_fit((int) (int.max(width, height) * (spec.transition == "zoom" ? 1.15 : 1.0)));
            slides.add(PhotoPrintSource.to_surface(WorkingSpace.to_srgb_encoded(fitted)));
            captions.add(caption);
        }

        public void add_file(File file) throws Error {
            var r = OutputRender.render(file, int.max(width, height) * 2);
            string text = "";
            switch (spec.caption) {
                case "filename": text = file.get_basename() ?? ""; break;
                case "title": text = r.meta.title != "" ? r.meta.title : (file.get_basename() ?? ""); break;
                case "caption": text = r.meta.caption; break;
                default: break;
            }
            add_image(r.image, text);
        }

        private void draw_slide(Cairo.Context cr, int index, double progress, double alpha, double shift) {
            if (index < 0 || index >= slides.size || alpha <= 0) return;
            var s = slides[index];
            double sw = s.get_width(), sh = s.get_height();
            double scale = double.min(width / sw, height / sh);
            if (spec.transition == "zoom") scale *= 1.0 + 0.08 * progress.clamp(0, 1);
            cr.save();
            cr.translate(width / 2.0 + shift * width, height / 2.0);
            cr.scale(scale, scale);
            cr.translate(-sw / 2, -sh / 2);
            cr.set_source_surface(s, 0, 0);
            ((Cairo.Pattern) cr.get_source()).set_filter(Cairo.Filter.GOOD);
            cr.paint_with_alpha(alpha);
            cr.restore();
            string text = captions[index];
            if (text != "") {
                var pl = Pango.cairo_create_layout(cr);
                var font = Pango.FontDescription.from_string("Sans");
                font.set_absolute_size(int.max(10, height / 28) * Pango.SCALE);
                pl.set_font_description(font);
                pl.set_width(width * Pango.SCALE);
                pl.set_alignment(Pango.Alignment.CENTER);
                pl.set_text(text, -1);
                int lw, lh;
                pl.get_pixel_size(out lw, out lh);
                cr.move_to(shift * width + 1, height - lh - height / 20 + 1);
                cr.set_source_rgba(0, 0, 0, 0.6 * alpha);
                Pango.cairo_show_layout(cr, pl);
                cr.move_to(shift * width, height - lh - height / 20);
                cr.set_source_rgba(1, 1, 1, alpha);
                Pango.cairo_show_layout(cr, pl);
            }
        }

        public void draw(Cairo.Context cr, double t) {
            cr.set_source_rgb(0, 0, 0);
            cr.paint();
            if (slides.size == 0) return;
            double d = spec.slide_seconds;
            int index = (int) Math.floor(t / d);
            double local = t - index * d;
            if (spec.loop) index = index % slides.size;
            else if (index >= slides.size) {
                index = slides.size - 1;
                local = d;
            }
            int next = spec.loop ? (index + 1) % slides.size : index + 1;
            double tr = double.min(spec.transition_seconds, d * 0.5);
            double into = local - (d - tr);
            bool transitioning = spec.transition != "none" && tr > 0 && into > 0 && next < slides.size && next != index;
            double k = transitioning ? (into / tr).clamp(0, 1) : 0;
            k = k * k * (3 - 2 * k);
            switch (spec.transition) {
                case "slide":
                    draw_slide(cr, index, local / d, 1, -k);
                    if (transitioning) draw_slide(cr, next, 0, 1, 1 - k);
                    break;
                default:
                    draw_slide(cr, index, local / d, 1, 0);
                    if (transitioning) draw_slide(cr, next, 0, k, 0);
                    break;
            }
        }
    }

    public delegate void SlideshowProgress(double fraction);

    namespace SlideshowVideo {

        public bool has(string element) {
            return Gst.ElementFactory.find(element) != null;
        }

        public string[] available_containers() {
            string[] out_list = {};
            if (has("mp4mux") && (has("x264enc") || has("openh264enc"))) out_list += "mp4";
            if (has("webmmux") && (has("vp9enc") || has("vp8enc"))) out_list += "webm";
            return out_list;
        }

        private string video_encoder(string container) {
            if (container == "mp4") return has("x264enc") ? "x264enc speed-preset=medium tune=stillimage bitrate=8000 ! video/x-h264,profile=high" : "openh264enc bitrate=8000000";
            return has("vp9enc") ? "vp9enc deadline=1 cpu-used=4 target-bitrate=8000000" : "vp8enc deadline=1 target-bitrate=8000000";
        }

        private string? audio_encoder(string container) {
            if (container == "mp4") return has("voaacenc") ? "voaacenc bitrate=192000" : (has("avenc_aac") ? "avenc_aac" : null);
            return has("opusenc") ? "opusenc bitrate=160000" : (has("vorbisenc") ? "vorbisenc" : null);
        }

        public uint8[]? decode_music(string path, double seconds) throws Error {
            string uri = Filename.to_uri(path);
            var pipe = (Gst.Pipeline) Gst.parse_launch("uridecodebin uri=\"%s\" ! audioconvert ! audioresample ! audio/x-raw,format=S16LE,channels=2,rate=48000,layout=interleaved ! appsink name=sink sync=false".printf(uri));
            var sink = (Gst.App.Sink) pipe.get_by_name("sink");
            pipe.set_state(Gst.State.PLAYING);
            var pcm = new ByteArray();
            size_t wanted = (size_t) (seconds * 48000) * 4;
            while (pcm.len < wanted) {
                var sample = sink.try_pull_sample(10 * Gst.SECOND);
                if (sample == null) break;
                var buffer = sample.get_buffer();
                Gst.MapInfo map;
                if (buffer.map(out map, Gst.MapFlags.READ)) {
                    pcm.append(map.data);
                    buffer.unmap(map);
                }
            }
            pipe.set_state(Gst.State.NULL);
            if (pcm.len == 0) return null;
            var looped = new uint8[wanted];
            size_t n = pcm.len;
            for (size_t i = 0; i < wanted; i++) looped[i] = pcm.data[i % n];
            size_t fade = (size_t) (2.0 * 48000) * 4;
            if (fade > wanted) fade = wanted;
            for (size_t f = 0; f + 1 < fade; f += 2) {
                size_t i = wanted - fade + f;
                int16 v = (int16) (looped[i] | (looped[i + 1] << 8));
                double g = 1.0 - (double) f / fade;
                int16 nv = (int16) (v * g);
                looped[i] = (uint8) (nv & 0xFF);
                looped[i + 1] = (uint8) ((nv >> 8) & 0xFF);
            }
            return looped;
        }

        public void export(File[] files, SlideshowSpec spec, int width, int height, int fps, string container, string path,
                           Cancellable? cancellable = null, SlideshowProgress? progress = null) throws Error {
            if (!(container in available_containers())) throw new IOError.NOT_SUPPORTED(_("No video encoder is available for this format"));
            width = (width / 2) * 2;
            height = (height / 2) * 2;
            var comp = new SlideCompositor(spec, width, height);
            foreach (var f in files) comp.add_file(f);
            if (comp.count == 0) throw new IOError.INVALID_ARGUMENT(_("There are no photos to show"));
            var looping = spec.loop;
            spec.loop = false;
            double seconds = spec.total_seconds(comp.count);
            uint8[]? music = spec.music != "" ? decode_music(spec.music, seconds) : null;
            string? aenc = music != null ? audio_encoder(container) : null;
            string mux = container == "mp4" ? "mp4mux faststart=true" : "webmmux";
            var desc = new StringBuilder();
            desc.append_printf("appsrc name=video format=time is-live=false do-timestamp=false caps=video/x-raw,format=BGRx,width=%d,height=%d,framerate=%d/1 ! videoconvert ! video/x-raw,format=I420 ! %s ! queue ! %s name=mux ! filesink location=\"%s\"",
                width, height, fps, video_encoder(container), mux, path.replace("\"", "\\\""));
            if (aenc != null) desc.append_printf(" appsrc name=audio format=time caps=audio/x-raw,format=S16LE,channels=2,rate=48000,layout=interleaved ! audioconvert ! %s ! queue ! mux.", aenc);
            var pipe = (Gst.Pipeline) Gst.parse_launch(desc.str);
            var vsrc = (Gst.App.Src) pipe.get_by_name("video");
            var asrc = aenc != null ? (Gst.App.Src) pipe.get_by_name("audio") : null;
            pipe.set_state(Gst.State.PLAYING);
            int frames = (int) Math.ceil(seconds * fps);
            var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, width, height);
            var cr = new Cairo.Context(surface);
            size_t audio_pos = 0;
            size_t audio_step = 48000 / fps * 4;
            bool failed = false;
            for (int i = 0; i < frames && !failed; i++) {
                if (cancellable != null && cancellable.is_cancelled()) break;
                comp.draw(cr, (double) i / fps);
                surface.flush();
                unowned uint8[] px = surface.get_data();
                int stride = surface.get_stride();
                var data = new uint8[width * height * 4];
                for (int y = 0; y < height; y++) Memory.copy(&data[y * width * 4], &px[y * stride], width * 4);
                var buffer = new Gst.Buffer.wrapped((owned) data);
                buffer.pts = (Gst.ClockTime) (i * Gst.SECOND / fps);
                buffer.duration = (Gst.ClockTime) (Gst.SECOND / fps);
                if (vsrc.push_buffer(buffer) != Gst.FlowReturn.OK) failed = true;
                if (asrc != null && audio_pos < music.length) {
                    size_t end = size_t.min(music.length, audio_pos + audio_step);
                    var chunk = new uint8[end - audio_pos];
                    Memory.copy(chunk, &music[audio_pos], end - audio_pos);
                    var abuf = new Gst.Buffer.wrapped((owned) chunk);
                    abuf.pts = (Gst.ClockTime) (audio_pos / 4 * Gst.SECOND / 48000);
                    abuf.duration = (Gst.ClockTime) ((end - audio_pos) / 4 * Gst.SECOND / 48000);
                    asrc.push_buffer(abuf);
                    audio_pos = end;
                }
                if (progress != null) progress((double) (i + 1) / frames);
                var msg = pipe.get_bus().pop_filtered(Gst.MessageType.ERROR);
                if (msg != null) failed = true;
            }
            vsrc.end_of_stream();
            if (asrc != null) asrc.end_of_stream();
            var done = pipe.get_bus().timed_pop_filtered(60 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR);
            string? error = null;
            if (done == null) error = _("The video encoder did not finish");
            else if (done.type == Gst.MessageType.ERROR) {
                Error e;
                string debug;
                done.parse_error(out e, out debug);
                error = e.message;
            }
            pipe.set_state(Gst.State.NULL);
            spec.loop = looping;
            if (cancellable != null && cancellable.is_cancelled()) {
                FileUtils.remove(path);
                throw new IOError.CANCELLED(_("Export cancelled"));
            }
            if (failed || error != null) throw new IOError.FAILED(error ?? _("The video could not be written"));
        }
    }
}
