using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public delegate void MergeDone(File? result, string? error);

    namespace MergeRunner {

        public string title(string kind) {
            switch (kind) {
                case "hdr": return _("HDR");
                case "panorama": return _("Panorama");
                case "focus": return _("Focus Stack");
                default: return _("Super Resolution");
            }
        }

        public File target_for(File first, string kind) {
            var parent = first.get_parent() ?? File.new_for_path(Environment.get_home_dir());
            string name = first.get_basename() ?? "photo";
            int dot = name.last_index_of_char('.');
            string stem = dot > 0 ? name.substring(0, dot) : name;
            string suffix;
            switch (kind) {
                case "hdr": suffix = "-HDR"; break;
                case "panorama": suffix = "-Pano"; break;
                case "focus": suffix = "-Focus"; break;
                default: suffix = "-Enhanced"; break;
            }
            return PhotoImporter.unique_target(parent, stem + suffix + ".dng");
        }

        public static double exposure_value(PhotoMetadata m) {
            if (m.exposure_time <= 0 || m.aperture <= 0) return m.exposure_bias;
            double iso = m.iso > 0 ? m.iso : 100;
            return Math.log2(m.exposure_time * iso / 100.0 / (m.aperture * m.aperture));
        }

        public void run(string kind, Gee.List<PhotoRecord> records, string projection, owned MergeProgress progress, owned MergeDone done) {
            var files = new Gee.ArrayList<File>();
            var variants = new Gee.ArrayList<string>();
            foreach (var r in records) {
                files.add(r.file());
                variants.add(r.variant());
            }
            new Thread<void>("photos-merge", () => {
                File? result = null;
                string? err = null;
                try {
                    FloatImage[] images = {};
                    double[] evs = {};
                    PhotoMetadata? meta = null;
                    for (int i = 0; i < files.size; i++) {
                        var f = files[i];
                        var photo = Codecs.load(f, 0);
                        if (meta == null) meta = photo.meta;
                        evs += exposure_value(photo.meta);
                        EditParams? p = kind == "hdr" ? null : EditStore.load(f, variants[i]);
                        var o = new RenderOptions();
                        o.max_side = 0;
                        if (kind == "hdr") o.highlight_mode = "clip";
                        images += DevelopPipeline.render(photo, p ?? new EditParams(), o);
                        int step = i + 1;
                        Idle.add(() => {
                            progress(0.3 * step / files.size, _("Loading photos"));
                            return Source.REMOVE;
                        });
                    }
                    MergeProgress relay = (frac, stage) => {
                        string s = stage;
                        double v = 0.3 + frac * 0.65;
                        Idle.add(() => {
                            progress(v, s);
                            return Source.REMOVE;
                        });
                    };
                    FloatImage merged;
                    switch (kind) {
                        case "hdr": merged = Hdr.merge(images, evs, relay); break;
                        case "panorama": merged = Panorama.stitch(images, projection, relay); break;
                        case "focus": merged = FocusStack.merge(images, relay); break;
                        default: merged = SuperResolution.upscale(images[0], 2); break;
                    }
                    var target = target_for(files[0], kind);
                    DngWriter.write_linear(merged, target, meta);
                    result = target;
                } catch (Error e) {
                    err = e.matches(IOError.quark(), IOError.NOT_SUPPORTED) ? _("%s is not available on this system yet").printf(title(kind)) : e.message;
                }
                Idle.add(() => {
                    done(result, err);
                    return Source.REMOVE;
                });
            });
        }
    }
}
