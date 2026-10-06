using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace Masks {

        public const int BRUSH_PLANE_SIDE = 1024;

        public string strokes_signature(MaskComponent c) {
            var b = new Json.Builder();
            c.write(b);
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            return Checksum.compute_for_string(ChecksumType.MD5, gen.to_data(null));
        }

        public float[] rasterize_brush(MaskComponent c, int sw, int sh, out int pw, out int ph) {
            double f = (double) BRUSH_PLANE_SIDE / int.max(sw, sh);
            if (f > 1) f = 1;
            pw = int.max(1, (int) (sw * f));
            ph = int.max(1, (int) (sh * f));
            var plane = new float[(size_t) pw * ph];
            int long_side = int.max(pw, ph);
            foreach (var st in c.strokes) {
                double radius = double.max(0.75, st.radius * long_side);
                double hard = 1 - st.feather.clamp(0, 1);
                double step = double.max(0.5, radius * 0.25);
                double px = -1, py = -1;
                for (int i = 0; i + 1 < st.points.length; i += 2) {
                    double x = st.points[i] * pw, y = st.points[i + 1] * ph;
                    if (px < 0) {
                        dab(plane, pw, ph, x, y, radius, hard, st.flow, st.erase);
                    } else {
                        double dx = x - px, dy = y - py;
                        double dist = Math.sqrt(dx * dx + dy * dy);
                        int steps = int.max(1, (int) (dist / step));
                        for (int k = 1; k <= steps; k++) {
                            double t = (double) k / steps;
                            dab(plane, pw, ph, px + dx * t, py + dy * t, radius, hard, st.flow, st.erase);
                        }
                    }
                    px = x;
                    py = y;
                }
            }
            return plane;
        }

        private void dab(float[] plane, int w, int h, double cx, double cy, double radius, double hard, double flow, bool erase) {
            int x0 = int.max(0, (int) (cx - radius - 1)), x1 = int.min(w - 1, (int) (cx + radius + 1));
            int y0 = int.max(0, (int) (cy - radius - 1)), y1 = int.min(h - 1, (int) (cy + radius + 1));
            float fl = (float) flow.clamp(0, 1);
            for (int y = y0; y <= y1; y++) {
                for (int x = x0; x <= x1; x++) {
                    double d = Math.sqrt((x + 0.5 - cx) * (x + 0.5 - cx) + (y + 0.5 - cy) * (y + 0.5 - cy)) / radius;
                    if (d >= 1) continue;
                    float v = d <= hard ? 1.0f : Tone.smooth(1.0f, (float) hard, (float) d);
                    v *= fl;
                    size_t i = (size_t) y * w + x;
                    if (erase) plane[i] *= 1 - v;
                    else plane[i] = plane[i] + v * (1 - plane[i]);
                }
            }
        }

        public float[] component(MaskComponent c, FloatImage img, float[] coords, GeometryMap g, DevelopCache cache) {
            int w = img.width, h = img.height;
            size_t n = img.pixel_count();
            var m = new float[n];
            double aspect = (double) g.source_width / g.source_height;
            switch (c.kind) {
                case "all":
                    for (size_t i = 0; i < n; i++) m[i] = 1;
                    break;
                case "linear": {
                    double x0 = c.g("x0", 0.5), y0 = c.g("y0", 0.3), x1 = c.g("x1", 0.5), y1 = c.g("y1", 0.7);
                    double dx = (x1 - x0) * aspect, dy = y1 - y0;
                    double len2 = dx * dx + dy * dy;
                    if (len2 < 1e-12) len2 = 1e-12;
                    Parallel.range(h, (start, end) => {
                        for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                            double u = (coords[i * 2] - x0) * aspect, v = coords[i * 2 + 1] - y0;
                            double t = (u * dx + v * dy) / len2;
                            m[i] = 1 - Tone.smooth(0, 1, (float) t);
                        }
                    });
                    break;
                }
                case "radial": {
                    double cx = c.g("cx", 0.5), cy = c.g("cy", 0.5);
                    double rx = double.max(1e-4, c.g("rx", 0.25)), ry = double.max(1e-4, c.g("ry", 0.25));
                    double angle = c.g("angle", 0) * Math.PI / 180.0;
                    double feather = c.g("feather", 0.5).clamp(0, 1);
                    double ca = Math.cos(angle), sa = Math.sin(angle);
                    Parallel.range(h, (start, end) => {
                        for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                            double u = (coords[i * 2] - cx) * g.source_width, v = (coords[i * 2 + 1] - cy) * g.source_height;
                            double ru = u * ca + v * sa, rv = -u * sa + v * ca;
                            double ex = ru / (rx * g.source_width), ey = rv / (ry * g.source_height);
                            double d = Math.sqrt(ex * ex + ey * ey);
                            m[i] = 1 - Tone.smooth((float) (1 - feather), 1.0f, (float) d);
                        }
                    });
                    break;
                }
                case "brush": {
                    string key = "brush:" + strokes_signature(c) + ":" + g.source_width.to_string() + "x" + g.source_height.to_string();
                    var plane = cache.planes[key];
                    if (plane == null) {
                        int pw, ph;
                        var data = rasterize_brush(c, g.source_width, g.source_height, out pw, out ph);
                        plane = new MaskPlane((owned) data, pw, ph);
                        cache.planes[key] = plane;
                    }
                    var pl = plane;
                    Parallel.range(h, (start, end) => {
                        for (size_t i = (size_t) start * w; i < (size_t) end * w; i++)
                            m[i] = Filters.sample_plane(pl.data, pl.width, pl.height, coords[i * 2] * pl.width, coords[i * 2 + 1] * pl.height);
                    });
                    break;
                }
                case "color": {
                    float sr = (float) c.g("r", 0.5), sg = (float) c.g("g", 0.5), sb = (float) c.g("b", 0.5);
                    float range = (float) c.g("range", 0.3).clamp(0.02, 1);
                    float sh, ss, sl;
                    Tone.rgb_to_hsl(sr, sg, sb, out sh, out ss, out sl);
                    Parallel.range(h, (start, end) => {
                        for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                            float r = Transfer.linear_to_srgb(img.data[i * 4]).clamp(0, 1);
                            float gg = Transfer.linear_to_srgb(img.data[i * 4 + 1]).clamp(0, 1);
                            float b = Transfer.linear_to_srgb(img.data[i * 4 + 2]).clamp(0, 1);
                            float ph2, ps, pl2;
                            Tone.rgb_to_hsl(r, gg, b, out ph2, out ps, out pl2);
                            float dh = (ph2 - sh).abs();
                            if (dh > 180) dh = 360 - dh;
                            float dist = Math.sqrtf((dh / 180) * (dh / 180) * float.min(ps, ss) * 4 + (ps - ss) * (ps - ss) * 0.5f + (pl2 - sl) * (pl2 - sl) * 0.35f);
                            m[i] = 1 - Tone.smooth(range * 0.3f, range * 0.3f + 0.12f, dist);
                        }
                    });
                    break;
                }
                case "luminance": {
                    float lo = (float) c.g("low", 0.5), hi = (float) c.g("high", 1.0), fe = (float) c.g("feather", 0.1).clamp(0.001, 0.5);
                    Parallel.range(h, (start, end) => {
                        for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                            float l = Transfer.linear_to_srgb(WorkingSpace.luminance(img.data[i * 4], img.data[i * 4 + 1], img.data[i * 4 + 2]).clamp(0, 1));
                            m[i] = Tone.smooth(lo - fe, lo, l) * (1 - Tone.smooth(hi, hi + fe, l));
                        }
                    });
                    break;
                }
                case "depth": {
                    string key = "depth:" + cache.geo_key;
                    var plane = cache.planes[key];
                    if (plane == null) {
                        var small = img.scaled_to_fit(720);
                        var data = DepthEstimate.from_defocus(small);
                        plane = new MaskPlane((owned) data, small.width, small.height);
                        cache.planes[key] = plane;
                    }
                    var full = Filters.resize_plane(plane.data, plane.width, plane.height, w, h);
                    float lo = (float) c.g("low", 0.0), hi = (float) c.g("high", 0.3), fe = (float) c.g("feather", 0.1).clamp(0.001, 0.5);
                    for (size_t i = 0; i < n; i++) m[i] = Tone.smooth(lo - fe, lo, full[i]) * (1 - Tone.smooth(hi, hi + fe, full[i]));
                    break;
                }
                case "sky":
                case "subject": {
                    string key = c.kind + ":" + cache.geo_key;
                    var plane = cache.planes[key];
                    if (plane == null) {
                        var small = img.scaled_to_fit(640);
                        var data = c.kind == "sky" ? Segmentation.sky(small) : Segmentation.subject(small);
                        plane = new MaskPlane((owned) data, small.width, small.height);
                        cache.planes[key] = plane;
                    }
                    var full = Filters.resize_plane(plane.data, plane.width, plane.height, w, h);
                    for (size_t i = 0; i < n; i++) m[i] = full[i].clamp(0, 1);
                    break;
                }
                default:
                    break;
            }
            if (c.invert) for (size_t i = 0; i < n; i++) m[i] = 1 - m[i];
            return m;
        }

        public float[] evaluate(LocalAdjustment l, FloatImage img, float[] coords, GeometryMap g, DevelopCache cache) {
            size_t n = img.pixel_count();
            float[]? result = null;
            foreach (var c in l.components) {
                var m = component(c, img, coords, g, cache);
                if (result == null) {
                    result = c.mode == "subtract" ? new float[n] : m;
                    if (c.mode == "subtract") continue;
                    continue;
                }
                switch (c.mode) {
                    case "subtract":
                        for (size_t i = 0; i < n; i++) result[i] *= 1 - m[i];
                        break;
                    case "intersect":
                        for (size_t i = 0; i < n; i++) result[i] = float.min(result[i], m[i]);
                        break;
                    default:
                        for (size_t i = 0; i < n; i++) result[i] = float.max(result[i], m[i]);
                        break;
                }
            }
            return result ?? new float[n];
        }
    }

    namespace Locals {

        public void apply_one(FloatImage img, LocalAdjustment l, float[] mask, double res) {
            var local = img.copy();
            float ev = (float) l.get("exposure");
            float temp = (float) l.get("temperature"), tint = (float) l.get("tint");
            if (ev != 0 || temp != 0 || tint != 0) {
                float k = (float) Math.pow(2.0, ev);
                float kr = k * (float) Math.pow(2.0, temp * 0.35 + tint * 0.08);
                float kg = k * (float) Math.pow(2.0, -tint * 0.3);
                float kb = k * (float) Math.pow(2.0, -temp * 0.35 + tint * 0.08);
                int w = local.width;
                Parallel.range(local.height, (start, end) => {
                    for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                        local.data[i * 4] *= kr;
                        local.data[i * 4 + 1] *= kg;
                        local.data[i * 4 + 2] *= kb;
                    }
                });
            }
            float dehaze = (float) l.get("dehaze");
            if (dehaze != 0) Detail.dehaze(local, dehaze, res);
            float hi = (float) l.get("highlights"), sh = (float) l.get("shadows"), tex = (float) l.get("texture"), cla = (float) l.get("clarity");
            if (hi != 0 || sh != 0 || tex != 0 || cla != 0) Detail.local_tone(local, hi, sh, tex, cla, 1.0f, res);
            var t = new ToneSettings();
            t.contrast = (float) l.get("contrast");
            t.whites = (float) l.get("whites");
            t.blacks = (float) l.get("blacks");
            t.saturation = (float) l.get("saturation");
            float hue = (float) l.get("hue");
            if (hue != 0) {
                for (int i = 0; i < 8; i++) t.hsl_hue[i] = hue / 30.0f;
                t.has_hsl = true;
            }
            if (t.contrast != 0 || t.whites != 0 || t.blacks != 0 || t.saturation != 0 || t.has_hsl) Tone.apply_pixels(local, t);
            float sharp = (float) l.get("sharpness"), noise = (float) l.get("noise");
            if (sharp > 0) Detail.sharpen(local, sharp, 1.0, 0.5, 0, res);
            if (sharp < 0 || noise > 0) {
                double sigma = double.max(0.5, (double.max(-sharp, 0) * 2 + noise * 3) * double.max(res, 0.25));
                var soft = Filters.gaussian(local, sigma);
                float k = float.min(1, float.max(-sharp, noise));
                for (size_t i = 0; i < local.data.length; i++) if ((i & 3) != 3) local.data[i] += (soft.data[i] - local.data[i]) * k;
            }
            float defringe = (float) l.get("defringe");
            if (defringe > 0) {
                int w = local.width;
                Parallel.range(local.height, (start, end) => {
                    for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                        float r = local.data[i * 4], g = local.data[i * 4 + 1], b = local.data[i * 4 + 2];
                        float y = WorkingSpace.luminance(r, g, b);
                        float ph, ps, pl;
                        Tone.rgb_to_hsl(Transfer.linear_to_srgb(r).clamp(0, 1), Transfer.linear_to_srgb(g).clamp(0, 1), Transfer.linear_to_srgb(b).clamp(0, 1), out ph, out ps, out pl);
                        bool fringe = (ph > 250 && ph < 330) || (ph > 60 && ph < 150);
                        if (!fringe) continue;
                        float k = defringe * ps;
                        local.data[i * 4] = r + (y - r) * k;
                        local.data[i * 4 + 1] = g + (y - g) * k;
                        local.data[i * 4 + 2] = b + (y - b) * k;
                    }
                });
            }
            float amount = (float) l.amount;
            int w = img.width;
            Parallel.range(img.height, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    float m = (mask[i] * amount).clamp(0, 2);
                    if (m <= 0) continue;
                    for (int c = 0; c < 3; c++) img.data[i * 4 + c] += (local.data[i * 4 + c] - img.data[i * 4 + c]) * m;
                }
            });
        }

        public void apply_all(FloatImage img, EditParams p, float[] coords, GeometryMap g, DevelopCache cache, double res) {
            foreach (var l in p.locals) {
                if (!l.has_effect()) continue;
                var mask = Masks.evaluate(l, img, coords, g, cache);
                apply_one(img, l, mask, res);
            }
        }
    }
}
