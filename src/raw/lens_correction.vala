using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class LensModel : Object {
        public string distortion_model = "";
        public double[] distortion = {};
        public double[] tca = { 1.0, 1.0 };
        public double[] vignetting = {};
        public double manual_distortion = 0;
        public double manual_vignette = 0;
        public double manual_vignette_mid = 0.5;
        public double ca_red = 1.0;
        public double ca_blue = 1.0;
        public double defringe = 0;
        public bool auto_ca = false;

        public bool has_geometry() {
            return distortion.length > 0 || manual_distortion.abs() > 1e-9 || (tca[0] - 1).abs() > 1e-9 || (tca[1] - 1).abs() > 1e-9
                || (ca_red - 1).abs() > 1e-9 || (ca_blue - 1).abs() > 1e-9;
        }

        public double distort(double r) {
            double rd = r;
            if (manual_distortion.abs() > 1e-9) {
                double k = -manual_distortion * 0.15;
                rd = rd * (1 - k + k * rd * rd);
            }
            if (distortion.length > 0) {
                double r2 = rd * rd;
                if (distortion_model == "poly3") {
                    double k1 = distortion[0];
                    rd = rd * (1 - k1 + k1 * r2);
                } else if (distortion_model == "poly5") {
                    rd = rd * (1 + distortion[0] * r2 + distortion[1] * r2 * r2);
                } else if (distortion_model == "ptlens" && distortion.length >= 3) {
                    double a = distortion[0], b = distortion[1], c = distortion[2];
                    rd = rd * (a * r2 * rd + b * r2 + c * rd + 1 - a - b - c);
                }
            }
            return rd;
        }

        public double vignette_gain(double rc) {
            double g = 1.0;
            if (vignetting.length >= 3) {
                double r2 = rc * rc;
                double c = 1 + vignetting[0] * r2 + vignetting[1] * r2 * r2 + vignetting[2] * r2 * r2 * r2;
                if (c > 0.05) g /= c;
            }
            if (manual_vignette.abs() > 1e-9) {
                double t = ((rc - manual_vignette_mid * 0.8) / double.max(1e-3, 1.0 - manual_vignette_mid * 0.8)).clamp(0, 1);
                t = t * t * (3 - 2 * t);
                g *= Math.pow(2.0, manual_vignette * 1.5 * t);
            }
            return g;
        }
    }

    namespace LensCorrection {

        public bool needed(DevelopSettings d) {
            return d.has_prefix("lens.");
        }

        public LensProfile? profile_for(PhotoMetadata meta, DevelopSettings d) {
            string id = d.get_string("lens.profile.id");
            if (id != "") {
                var p = LensDatabase.by_id(id);
                if (p != null) return p;
            }
            return LensDatabase.find(meta.lens, meta.make);
        }

        public string[] find_profiles(PhotoMetadata meta) {
            string[] ids = {};
            var best = LensDatabase.find(meta.lens, meta.make);
            if (best != null) ids += best.id();
            foreach (var l in LensDatabase.all()) {
                if (best != null && l.id() == best.id()) continue;
                if (meta.make != "" && l.maker.down().contains(meta.make.down().split(" ")[0])) ids += l.id();
            }
            return ids;
        }

        public LensModel model_for(DevelopSettings d, PhotoMetadata meta) {
            var m = new LensModel();
            if (d.get("lens.profile") >= 0.5) {
                var p = profile_for(meta, d);
                if (p != null) {
                    double focal = meta.focal_length > 0 ? meta.focal_length : 50;
                    double amount_d = d.get("lens.profile.distortion"), amount_v = d.get("lens.profile.vignette");
                    var dist = p.interpolate("distortion", focal);
                    if (dist != null) {
                        m.distortion_model = p.model_of("distortion");
                        m.distortion = new double[dist.length];
                        for (int i = 0; i < dist.length; i++) m.distortion[i] = dist[i] * amount_d;
                    }
                    var tca = p.interpolate("tca", focal);
                    if (tca != null && tca.length >= 2) m.tca = { tca[0], tca[1] };
                    var vig = p.interpolate("vignetting", focal, meta.aperture);
                    if (vig != null && vig.length >= 3) m.vignetting = { vig[0] * amount_v, vig[1] * amount_v, vig[2] * amount_v };
                }
            }
            m.manual_distortion = d.get("lens.distortion");
            m.manual_vignette = d.get("lens.vignette");
            m.manual_vignette_mid = d.get("lens.vignette.midpoint");
            m.ca_red = 1.0 + d.get("lens.ca.red") * 0.003;
            m.ca_blue = 1.0 + d.get("lens.ca.blue") * 0.003;
            m.defringe = d.get("lens.defringe");
            m.auto_ca = d.get("lens.ca") >= 0.5;
            return m;
        }

        public FloatImage apply(FloatImage img, DevelopSettings d, PhotoMetadata meta) {
            if (!needed(d)) return img;
            var m = model_for(d, meta);
            if (m.auto_ca) estimate_ca(img, m);
            return apply_model(img, m);
        }

        public FloatImage apply_model(FloatImage img, LensModel m) {
            var out_img = img;
            if (m.vignetting.length >= 3 || m.manual_vignette.abs() > 1e-9) out_img = vignette(out_img, m);
            if (m.has_geometry()) out_img = remap(out_img, m);
            if (m.defringe > 1e-6) defringe(out_img, m.defringe);
            return out_img;
        }

        private FloatImage vignette(FloatImage img, LensModel m) {
            var out_img = img.copy();
            int w = img.width, h = img.height;
            double cx = w / 2.0, cy = h / 2.0, half_diag = Math.sqrt(cx * cx + cy * cy);
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        double dx = x + 0.5 - cx, dy = y + 0.5 - cy;
                        float g = (float) m.vignette_gain(Math.sqrt(dx * dx + dy * dy) / half_diag);
                        size_t o = out_img.offset(x, y);
                        out_img.data[o] *= g;
                        out_img.data[o + 1] *= g;
                        out_img.data[o + 2] *= g;
                    }
                }
            });
            return out_img;
        }

        private FloatImage remap(FloatImage img, LensModel m) {
            var out_img = new FloatImage(img.width, img.height);
            int w = img.width, h = img.height;
            double cx = w / 2.0, cy = h / 2.0, norm = double.min(cx, cy);
            double kr = m.tca[0] * m.ca_red, kb = m.tca[1] * m.ca_blue;
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        double dx = (x + 0.5 - cx) / norm, dy = (y + 0.5 - cy) / norm;
                        double r = Math.sqrt(dx * dx + dy * dy);
                        double s = r > 1e-9 ? m.distort(r) / r : 1.0;
                        double sx = cx + dx * s * norm, sy = cy + dy * s * norm;
                        float rr, gg, bb, aa, t1, t2, t3;
                        img.sample(sx, sy, out t1, out gg, out t2, out aa);
                        img.sample(cx + dx * s * kr * norm, cy + dy * s * kr * norm, out rr, out t1, out t2, out t3);
                        img.sample(cx + dx * s * kb * norm, cy + dy * s * kb * norm, out t1, out t2, out bb, out t3);
                        size_t o = out_img.offset(x, y);
                        out_img.data[o] = rr;
                        out_img.data[o + 1] = gg;
                        out_img.data[o + 2] = bb;
                        out_img.data[o + 3] = aa;
                    }
                }
            });
            return out_img;
        }

        private double ca_error(float[] c, float[] g, int w, int h, double k) {
            double cx = w / 2.0, cy = h / 2.0, err = 0;
            int step = int.max(1, int.min(w, h) / 200);
            for (int y = step; y < h - step; y += step) {
                for (int x = step; x < w - step; x += step) {
                    double dx = x + 0.5 - cx, dy = y + 0.5 - cy;
                    if (dx * dx + dy * dy < cx * cy * 0.1) continue;
                    float gv = g[(size_t) y * w + x];
                    float gx = g[(size_t) y * w + x + 1] - g[(size_t) y * w + x - 1];
                    float gy = g[(size_t) (y + 1) * w + x] - g[(size_t) (y - 1) * w + x];
                    float grad = gx.abs() + gy.abs();
                    if (grad < 0.02f) continue;
                    float cv = Filters.sample_plane(c, w, h, cx + dx * k, cy + dy * k);
                    err += (cv - gv).abs() * grad;
                }
            }
            return err;
        }

        public void estimate_ca(FloatImage img, LensModel m) {
            var small = img.scaled_to_fit(1024);
            int w = small.width, h = small.height;
            var g = small.channel(1);
            var r = small.channel(0);
            var b = small.channel(2);
            double best_r = 1, best_b = 1, er = double.MAX, eb = double.MAX;
            for (int i = -12; i <= 12; i++) {
                double k = 1.0 + i * 0.00025;
                double e = ca_error(r, g, w, h, k);
                if (e < er) { er = e; best_r = k; }
                e = ca_error(b, g, w, h, k);
                if (e < eb) { eb = e; best_b = k; }
            }
            m.ca_red *= best_r;
            m.ca_blue *= best_b;
        }

        public void defringe(FloatImage img, double amount) {
            int w = img.width, h = img.height;
            var lum = img.luminance();
            var edge = new float[lum.length];
            for (int y = 1; y < h - 1; y++) {
                for (int x = 1; x < w - 1; x++) {
                    size_t i = (size_t) y * w + x;
                    float gx = lum[i + 1] - lum[i - 1], gy = lum[i + w] - lum[i - w];
                    edge[i] = Math.sqrtf(gx * gx + gy * gy);
                }
            }
            var spread = Filters.gaussian_plane(edge, w, h, 2.0);
            float amt = (float) amount;
            Parallel.range(h, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    float r = img.data[i * 4], g = img.data[i * 4 + 1], b = img.data[i * 4 + 2];
                    float purple = float.max(0, float.min(r, b) - g);
                    float green = float.max(0, g - float.max(r, b));
                    float fringe = float.max(purple, green * 0.7f);
                    if (fringe <= 0) continue;
                    float k = (spread[i] * 8).clamp(0, 1) * amt;
                    if (k <= 0) continue;
                    float l = 0.2627f * r + 0.678f * g + 0.0593f * b;
                    img.data[i * 4] = r + (l - r) * k;
                    img.data[i * 4 + 1] = g + (l - g) * k;
                    img.data[i * 4 + 2] = b + (l - b) * k;
                }
            });
        }

        public FloatImage vignette_radial(FloatImage img, double[] k, double cx, double cy, double amount) {
            var out_img = img.copy();
            int w = img.width, h = img.height;
            double px = cx * w, py = cy * h;
            double mx = double.max(px, w - px), my = double.max(py, h - py);
            double max_r = Math.sqrt(mx * mx + my * my);
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        double dx = (x + 0.5 - px) / max_r, dy = (y + 0.5 - py) / max_r;
                        double r2 = dx * dx + dy * dy;
                        double g = 1 + k[0] * r2 + k[1] * r2 * r2 + k[2] * r2 * r2 * r2 + k[3] * r2 * r2 * r2 * r2 + k[4] * r2 * r2 * r2 * r2 * r2;
                        g = 1 + (g - 1) * amount;
                        size_t o = out_img.offset(x, y);
                        for (int c = 0; c < 3; c++) out_img.data[o + c] = (float) (out_img.data[o + c] * g);
                    }
                }
            });
            return out_img;
        }

        public FloatImage warp_rectilinear(FloatImage img, double[] coeffs, int planes, double cx, double cy) {
            var out_img = new FloatImage(img.width, img.height);
            int w = img.width, h = img.height;
            double px = cx * w, py = cy * h;
            double mx = double.max(px, w - px), my = double.max(py, h - py);
            double max_r = Math.sqrt(mx * mx + my * my);
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        double dx = (x + 0.5 - px) / max_r, dy = (y + 0.5 - py) / max_r;
                        double r2 = dx * dx + dy * dy;
                        size_t o = out_img.offset(x, y);
                        for (int c = 0; c < 3; c++) {
                            int p = int.min(c, planes - 1) * 6;
                            double radial = coeffs[p] + coeffs[p + 1] * r2 + coeffs[p + 2] * r2 * r2 + coeffs[p + 3] * r2 * r2 * r2;
                            double tx = 2 * coeffs[p + 4] * dx * dy + coeffs[p + 5] * (r2 + 2 * dx * dx);
                            double ty = coeffs[p + 4] * (r2 + 2 * dy * dy) + 2 * coeffs[p + 5] * dx * dy;
                            double sx = px + (dx * radial + tx) * max_r, sy = py + (dy * radial + ty) * max_r;
                            float v0, v1, v2, a;
                            img.sample(sx, sy, out v0, out v1, out v2, out a);
                            out_img.data[o + c] = c == 0 ? v0 : (c == 1 ? v1 : v2);
                            if (c == 1) out_img.data[o + 3] = a;
                        }
                    }
                }
            });
            return out_img;
        }
    }
}
