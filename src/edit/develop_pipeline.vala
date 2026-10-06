using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class RenderOptions : Object {
        public int max_side = 0;
        public bool crop = true;
        public bool color = true;
        public bool locals = true;
        public bool spots = true;
        public bool detail = true;
        public string highlight_mode = "reconstruct";

        public RenderOptions.preview(int max_side) {
            this.max_side = max_side;
        }
    }

    public class GeometryMap : Object {
        public int source_width;
        public int source_height;
        public int oriented_width;
        public int oriented_height;
        public int out_width;
        public int out_height;
        public double scale;
        public double crop_x;
        public double crop_y;
        public double crop_w;
        public double crop_h;
        public int quarter_turns;
        public bool flip;
        public double straighten;
        public double straighten_scale;
        public double[] homography = { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
        public bool has_homography = false;

        public GeometryMap(EditParams p, int sw, int sh, int max_side, bool crop) {
            source_width = sw;
            source_height = sh;
            quarter_turns = p.quarter_turns;
            flip = p.flip;
            straighten = p.straighten;
            bool swap = quarter_turns % 2 == 1;
            oriented_width = swap ? sh : sw;
            oriented_height = swap ? sw : sh;
            crop_x = crop ? p.crop_x : 0;
            crop_y = crop ? p.crop_y : 0;
            crop_w = crop ? p.crop_w : 1;
            crop_h = crop ? p.crop_h : 1;
            straighten_scale = EditPipeline.straighten_scale(oriented_width, oriented_height, straighten);
            homography = DevelopPipeline.transform_homography(p.develop, oriented_width, oriented_height);
            has_homography = !Matrix3Util.is_identity(homography);
            double cw = crop_w * oriented_width, ch = crop_h * oriented_height;
            scale = 1.0;
            if (max_side > 0 && double.max(cw, ch) > max_side) scale = max_side / double.max(cw, ch);
            out_width = int.max(1, (int) Math.round(cw * scale));
            out_height = int.max(1, (int) Math.round(ch * scale));
        }

        public bool is_identity() {
            return quarter_turns == 0 && !flip && straighten.abs() < 1e-9 && !has_homography
                && crop_x < 1e-9 && crop_y < 1e-9 && crop_w > 1 - 1e-9 && crop_h > 1 - 1e-9
                && out_width == source_width && out_height == source_height;
        }

        public void to_oriented(double ox, double oy, out double px, out double py) {
            px = crop_x * oriented_width + ox / scale;
            py = crop_y * oriented_height + oy / scale;
            if (straighten.abs() > 1e-9) {
                double a = -straighten * Math.PI / 180.0;
                double cx = oriented_width / 2.0, cy = oriented_height / 2.0;
                double dx = px - cx, dy = py - cy;
                double rx = dx * Math.cos(a) - dy * Math.sin(a);
                double ry = dx * Math.sin(a) + dy * Math.cos(a);
                px = cx + rx / straighten_scale;
                py = cy + ry / straighten_scale;
            }
            if (has_homography) {
                double w = homography[6] * px + homography[7] * py + homography[8];
                if (w.abs() < 1e-12) w = 1e-12;
                double nx = (homography[0] * px + homography[1] * py + homography[2]) / w;
                double ny = (homography[3] * px + homography[4] * py + homography[5]) / w;
                px = nx;
                py = ny;
            }
        }

        public void oriented_to_source(double px, double py, out double sx, out double sy) {
            if (flip) px = oriented_width - px;
            switch (quarter_turns) {
                case 1:
                    sx = py;
                    sy = source_height - px;
                    break;
                case 2:
                    sx = source_width - px;
                    sy = source_height - py;
                    break;
                case 3:
                    sx = source_width - py;
                    sy = px;
                    break;
                default:
                    sx = px;
                    sy = py;
                    break;
            }
        }

        public void map(double ox, double oy, out double sx, out double sy) {
            double px, py;
            to_oriented(ox, oy, out px, out py);
            oriented_to_source(px, py, out sx, out sy);
        }

        public void source_to_oriented(double sx, double sy, out double px, out double py) {
            switch (quarter_turns) {
                case 1:
                    px = source_height - sy;
                    py = sx;
                    break;
                case 2:
                    px = source_width - sx;
                    py = source_height - sy;
                    break;
                case 3:
                    px = sy;
                    py = source_width - sx;
                    break;
                default:
                    px = sx;
                    py = sy;
                    break;
            }
            if (flip) px = oriented_width - px;
        }

        public void source_to_output(double sx, double sy, out double ox, out double oy) {
            double px, py;
            switch (quarter_turns) {
                case 1:
                    px = source_height - sy;
                    py = sx;
                    break;
                case 2:
                    px = source_width - sx;
                    py = source_height - sy;
                    break;
                case 3:
                    px = sy;
                    py = source_width - sx;
                    break;
                default:
                    px = sx;
                    py = sy;
                    break;
            }
            if (flip) px = oriented_width - px;
            if (has_homography) {
                var inv = Singularity.Imaging.Matrix3.invert(homography);
                double w = inv[6] * px + inv[7] * py + inv[8];
                if (w.abs() < 1e-12) w = 1e-12;
                double nx = (inv[0] * px + inv[1] * py + inv[2]) / w;
                double ny = (inv[3] * px + inv[4] * py + inv[5]) / w;
                px = nx;
                py = ny;
            }
            if (straighten.abs() > 1e-9) {
                double a = straighten * Math.PI / 180.0;
                double cx = oriented_width / 2.0, cy = oriented_height / 2.0;
                double dx = (px - cx) * straighten_scale, dy = (py - cy) * straighten_scale;
                px = cx + dx * Math.cos(a) - dy * Math.sin(a);
                py = cy + dx * Math.sin(a) + dy * Math.cos(a);
            }
            ox = (px - crop_x * oriented_width) * scale;
            oy = (py - crop_y * oriented_height) * scale;
        }

        public string signature() {
            return "%d:%d:%d:%d:%.6f:%.6f:%.6f:%.6f:%d:%s:%.6f:%s".printf(source_width, source_height, out_width, out_height,
                crop_x, crop_y, crop_w, crop_h, quarter_turns, flip.to_string(), straighten,
                string.joinv(",", Matrix3Util.to_strings(homography)));
        }
    }

    namespace Matrix3Util {

        public bool is_identity(double[] m) {
            double[] id = { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
            for (int i = 0; i < 9; i++) if ((m[i] - id[i]).abs() > 1e-9) return false;
            return true;
        }

        public string[] to_strings(double[] m) {
            string[] r = {};
            foreach (var v in m) r += "%.6f".printf(v);
            return r;
        }
    }

    public class MaskPlane : Object {
        public float[] data;
        public int width;
        public int height;

        public MaskPlane(owned float[] data, int width, int height) {
            this.data = (owned) data;
            this.width = width;
            this.height = height;
        }
    }

    public class DevelopCache : Object {
        public string raw_key = "";
        public FloatImage? raw_base = null;
        public string lens_key = "";
        public FloatImage? lens_base = null;
        public string spot_key = "";
        public FloatImage? spot_base = null;
        public string geo_key = "";
        public FloatImage? geo_base = null;
        public float[]? geo_coords = null;
        public string nr_key = "";
        public FloatImage? nr_base = null;
        public string local_key = "";
        public FloatImage? local_base = null;
        public Gee.HashMap<string, MaskPlane> planes = new Gee.HashMap<string, MaskPlane>();
        public Mutex lock;

        public void clear() {
            raw_base = null;
            lens_base = null;
            spot_base = null;
            geo_base = null;
            geo_coords = null;
            nr_base = null;
            local_base = null;
            raw_key = lens_key = spot_key = geo_key = nr_key = local_key = "";
            planes.clear();
        }
    }

    public class RenderResult : Object {
        public FloatImage image;
        public GeometryMap geometry;
        public float[] coords;

        public RenderResult(FloatImage image, GeometryMap geometry, float[] coords) {
            this.image = image;
            this.geometry = geometry;
            this.coords = coords;
        }
    }

    namespace DevelopPipeline {

        public double[] transform_homography(DevelopSettings d, int w, int h) {
            double vertical = d.get("transform.vertical");
            double horizontal = d.get("transform.horizontal");
            double rotate = d.get("transform.rotate");
            double aspect = d.get("transform.aspect");
            double scale = d.get("transform.scale");
            double tx = d.get("transform.x");
            double ty = d.get("transform.y");
            if (vertical.abs() < 1e-9 && horizontal.abs() < 1e-9 && rotate.abs() < 1e-9 && aspect.abs() < 1e-9
                && (scale - 1).abs() < 1e-9 && tx.abs() < 1e-9 && ty.abs() < 1e-9)
                return { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
            return Upright.homography(vertical, horizontal, rotate, aspect, scale, tx, ty, w, h);
        }

        public double[] parse_guides(string text) {
            double[] v = {};
            foreach (var seg in text.split(";")) {
                var parts = seg.split(",");
                if (parts.length != 4) continue;
                foreach (var p in parts) v += double.parse(p);
            }
            return v;
        }

        public string format_guides(double[] v) {
            var sb = new StringBuilder();
            for (int i = 0; i + 3 < v.length; i += 4) {
                if (sb.len > 0) sb.append(";");
                sb.append_printf("%.5f,%.5f,%.5f,%.5f", v[i], v[i + 1], v[i + 2], v[i + 3]);
            }
            return sb.str;
        }

        private double guide_cost(double[] seg, double v, double h, double r, int w, int ht) {
            var f = Upright.forward(v, h, r, 0, 1, 0, 0, w, ht);
            double cost = 0;
            for (int i = 0; i + 3 < seg.length; i += 4) {
                double[] out_pts = new double[4];
                for (int k = 0; k < 2; k++) {
                    double x = seg[i + k * 2], y = seg[i + k * 2 + 1];
                    double z = f[6] * x + f[7] * y + f[8];
                    out_pts[k * 2] = (f[0] * x + f[1] * y + f[2]) / z;
                    out_pts[k * 2 + 1] = (f[3] * x + f[4] * y + f[5]) / z;
                }
                double dx = out_pts[2] - out_pts[0], dy = out_pts[3] - out_pts[1];
                double len = Math.sqrt(dx * dx + dy * dy);
                if (len < 1e-9) continue;
                double a = double.min(dx.abs(), dy.abs()) / len;
                cost += a * a;
            }
            return cost;
        }

        public void solve_guided(double[] oriented_segments, int w, int h, out double vertical, out double horizontal, out double rotate) {
            double bv = 0, bh = 0, br = 0;
            double best = guide_cost(oriented_segments, 0, 0, 0, w, h);
            double[] steps = { 0.2, 0.05, 0.01, 0.002 };
            foreach (double step in steps) {
                bool improved = true;
                int guard = 0;
                while (improved && guard++ < 200) {
                    improved = false;
                    for (int axis = 0; axis < 3; axis++) {
                        foreach (double sign in new double[] { -1, 1 }) {
                            double nv = bv, nh = bh, nr = br;
                            if (axis == 0) nv = (bv + sign * step).clamp(-1, 1);
                            else if (axis == 1) nh = (bh + sign * step).clamp(-1, 1);
                            else nr = (br + sign * step * 10).clamp(-10, 10);
                            double c = guide_cost(oriented_segments, nv, nh, nr, w, h);
                            if (c < best - 1e-12) {
                                best = c;
                                bv = nv;
                                bh = nh;
                                br = nr;
                                improved = true;
                            }
                        }
                    }
                }
            }
            vertical = bv;
            horizontal = bh;
            rotate = br;
        }

        public void white_balance_multipliers(DecodedPhoto src, EditParams p, out double r, out double g, out double b) {
            var raw = src.raw;
            string mode = p.develop.get_string("wb.mode", "as-shot");
            if (raw == null) {
                r = g = b = 1.0;
                return;
            }
            if (mode == "as-shot") {
                r = raw.as_shot_multipliers[0];
                g = raw.as_shot_multipliers[1];
                b = raw.as_shot_multipliers[2];
                return;
            }
            if (mode == "auto") {
                auto_white_balance(raw, out r, out g, out b);
                return;
            }
            RawColor.multipliers_for(raw, mode, p.develop.get("wb.temperature"), p.develop.get("wb.tint"), out r, out g, out b);
        }

        public void auto_white_balance(RawData raw, out double r, out double g, out double b) {
            var small = raw.camera.scaled_to_fit(256);
            double sr = 0, sg = 0, sb = 0;
            size_t n = small.pixel_count();
            int used = 0;
            for (size_t i = 0; i < n; i++) {
                float cr = small.data[i * 4], cg = small.data[i * 4 + 1], cb = small.data[i * 4 + 2];
                float mx = float.max(cr, float.max(cg, cb));
                if (mx > 0.95f || mx < 0.02f) continue;
                sr += cr;
                sg += cg;
                sb += cb;
                used++;
            }
            if (used == 0 || sr <= 0 || sb <= 0) {
                r = raw.as_shot_multipliers[0];
                g = raw.as_shot_multipliers[1];
                b = raw.as_shot_multipliers[2];
                return;
            }
            r = sg / sr;
            g = 1.0;
            b = sg / sb;
        }

        private FloatImage base_image(DecodedPhoto src, EditParams p, RenderOptions o, DevelopCache cache) {
            if (src.raw == null) return src.image;
            double r, g, b;
            white_balance_multipliers(src, p, out r, out g, out b);
            string camera_profile = p.develop.get_string("camera.profile");
            string key = "%.6f:%.6f:%.6f:%s:%s".printf(r, g, b, o.highlight_mode, camera_profile);
            if (cache.raw_base != null && cache.raw_key == key) return cache.raw_base;
            src.raw.camera_profile_name = camera_profile;
            var img = RawColor.develop(src.raw, r, g, b, o.highlight_mode);
            double bexp = src.raw.baseline_exposure;
            if (bexp.abs() > 1e-6) Tone.scale(img, (float) Math.pow(2.0, bexp));
            cache.raw_base = img;
            cache.raw_key = key;
            cache.lens_key = "";
            cache.spot_key = "";
            cache.geo_key = "";
            return img;
        }

        private string lens_signature(DevelopSettings d) {
            var sb = new StringBuilder();
            foreach (var e in d.values.entries) if (e.key.has_prefix("lens.")) sb.append_printf("%s=%.6f;", e.key, e.value);
            sb.append(d.get_string("lens.profile.id"));
            return sb.str;
        }

        private FloatImage lens_image(FloatImage base_img, DecodedPhoto src, EditParams p, DevelopCache cache) {
            if (!LensCorrection.needed(p.develop)) return base_img;
            string key = lens_signature(p.develop) + "@" + cache.raw_key;
            if (cache.lens_base != null && cache.lens_key == key) return cache.lens_base;
            var img = LensCorrection.apply(base_img, p.develop, src.meta);
            cache.lens_base = img;
            cache.lens_key = key;
            cache.spot_key = "";
            cache.geo_key = "";
            return img;
        }

        public string spots_signature(EditParams p) {
            var b = new Json.Builder();
            b.begin_array();
            foreach (var s in p.spots) s.write(b);
            b.end_array();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            return gen.to_data(null);
        }

        private FloatImage spot_image(FloatImage lens_img, EditParams p, RenderOptions o, DevelopCache cache) {
            if (!o.spots || p.spots.size == 0) return lens_img;
            string key = spots_signature(p) + "@" + cache.lens_key + cache.raw_key;
            if (cache.spot_base != null && cache.spot_key == key) return cache.spot_base;
            var img = lens_img.copy();
            foreach (var s in p.spots) Heal.spot(img, s);
            cache.spot_base = img;
            cache.spot_key = key;
            cache.geo_key = "";
            return img;
        }

        public FloatImage resample(FloatImage src, GeometryMap g, out float[] coords) {
            var out_img = new FloatImage(g.out_width, g.out_height);
            var c = new float[(size_t) g.out_width * g.out_height * 2];
            double ratio = (double) src.width / g.source_width;
            bool downscale = g.scale * g.straighten_scale < 0.75;
            FloatImage sampler = src;
            double sampler_ratio = ratio;
            if (downscale) {
                double f = g.scale * 1.5;
                int sw = int.max(1, (int) (src.width * f)), sh = int.max(1, (int) (src.height * f));
                if (sw < src.width && sh < src.height) {
                    sampler = src.resized(sw, sh);
                    sampler_ratio = (double) sampler.width / g.source_width;
                }
            }
            Parallel.range(g.out_height, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < g.out_width; x++) {
                        double sx, sy;
                        g.map(x + 0.5, y + 0.5, out sx, out sy);
                        size_t ci = ((size_t) y * g.out_width + x) * 2;
                        c[ci] = (float) (sx / g.source_width);
                        c[ci + 1] = (float) (sy / g.source_height);
                        size_t d = out_img.offset(x, y);
                        if (sx < -0.5 || sy < -0.5 || sx > g.source_width + 0.5 || sy > g.source_height + 0.5) {
                            out_img.data[d] = out_img.data[d + 1] = out_img.data[d + 2] = 0;
                            out_img.data[d + 3] = 0;
                            continue;
                        }
                        float r, gg, b, a;
                        sampler.sample(sx * sampler_ratio, sy * sampler_ratio, out r, out gg, out b, out a);
                        out_img.data[d] = r;
                        out_img.data[d + 1] = gg;
                        out_img.data[d + 2] = b;
                        out_img.data[d + 3] = a;
                    }
                }
            });
            coords = (owned) c;
            return out_img;
        }

        private FloatImage geometry_image(FloatImage spot_img, DecodedPhoto src, EditParams p, RenderOptions o, DevelopCache cache, out GeometryMap g, out float[] coords) {
            g = new GeometryMap(p, src.full_width > 0 ? src.full_width : spot_img.width, src.full_height > 0 ? src.full_height : spot_img.height, 0, o.crop);
            double full_scale = 1.0;
            double cw = g.crop_w * g.oriented_width, ch = g.crop_h * g.oriented_height;
            double avail = (double) spot_img.width / g.source_width;
            double want = o.max_side > 0 ? double.min(1.0, o.max_side / double.max(cw, ch)) : 1.0;
            full_scale = double.min(want, avail);
            g.scale = full_scale;
            g.out_width = int.max(1, (int) Math.round(cw * full_scale));
            g.out_height = int.max(1, (int) Math.round(ch * full_scale));
            string key = g.signature() + "@" + cache.spot_key + cache.lens_key + cache.raw_key + "#" + ((size_t) spot_img).to_string();
            if (cache.geo_base != null && cache.geo_key == key && cache.geo_coords != null) {
                coords = cache.geo_coords;
                return cache.geo_base;
            }
            var img = resample(spot_img, g, out coords);
            cache.geo_base = img;
            cache.geo_coords = coords;
            cache.geo_key = key;
            cache.nr_key = "";
            return img;
        }

        private FloatImage noise_image(FloatImage geo, EditParams p, RenderOptions o, DevelopCache cache, double res) {
            double lum = p.develop.get("detail.noise.amount");
            double col = p.develop.get("detail.color.amount");
            if (!o.color || !o.detail || (lum < 1e-6 && col < 1e-6)) return geo;
            string key = "%s:%.4f:%.4f:%.4f:%.4f:%.4f:%.4f".printf(cache.geo_key, lum, p.develop.get("detail.noise.detail"),
                p.develop.get("detail.noise.contrast"), col, p.develop.get("detail.color.detail"), p.develop.get("detail.color.smoothness"));
            if (cache.nr_base != null && cache.nr_key == key) return cache.nr_base;
            var img = geo.copy();
            if (lum > 1e-6) Denoise.luminance(img, lum, p.develop.get("detail.noise.detail"), p.develop.get("detail.noise.contrast"));
            if (col > 1e-6) Detail.color_noise(img, col, p.develop.get("detail.color.detail"), p.develop.get("detail.color.smoothness"), res);
            cache.nr_base = img;
            cache.nr_key = key;
            return img;
        }

        public RenderResult render_full(DecodedPhoto src, EditParams p, RenderOptions o, DevelopCache? cache = null) {
            var c = cache ?? new DevelopCache();
            c.lock.lock();
            var base_img = base_image(src, p, o, c);
            var lens_img = lens_image(base_img, src, p, c);
            var spot_img = spot_image(lens_img, p, o, c);
            GeometryMap g;
            float[] coords;
            var geo = geometry_image(spot_img, src, p, o, c, out g, out coords);
            double res = g.scale * (src.full_width > 0 ? 1.0 : 1.0);
            var nr = noise_image(geo, p, o, c, res);
            c.lock.unlock();
            if (!o.color) return new RenderResult(nr.copy(), g, coords);
            var t = Tone.settings(p);
            if (src.is_raw() && p.develop.get_string("raw.base") != "linear") t.base_curve = Tone.raw_base();
            string lk = "%s|%s|%.5f|%.5f|%.5f|%.5f|%.5f|%.5f".printf(c.nr_key, c.geo_key, t.dehaze, t.highlights, t.shadows, t.texture, t.clarity, t.exposure);
            FloatImage img;
            c.lock.lock();
            if (c.local_base != null && c.local_key == lk && c.local_base.width == nr.width && c.local_base.height == nr.height) {
                img = c.local_base.copy();
                c.lock.unlock();
            } else {
                c.lock.unlock();
                img = nr.copy();
                Tone.neighbourhood(img, t, res);
                c.lock.lock();
                c.local_base = img.copy();
                c.local_key = lk;
                c.lock.unlock();
            }
            Tone.apply_pixels(img, t);
            if (o.locals) Locals.apply_all(img, p, coords, g, c, res);
            if (o.detail) Detail.sharpen_final(img, p, res);
            Effects.apply(img, p, res);
            return new RenderResult(img, g, coords);
        }

        public FloatImage render(DecodedPhoto src, EditParams p, RenderOptions o, DevelopCache? cache = null) {
            return render_full(src, p, o, cache).image;
        }
    }
}
