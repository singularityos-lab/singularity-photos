using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace Chromaticity {

        public const double TINT_SCALE = 3000.0;

        public void planck_uv(double t, out double u, out double v) {
            t = t.clamp(1000, 100000);
            u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t);
            v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t);
        }

        public void white_uv(double t, double tint, out double u, out double v) {
            double u0, v0, u1, v1;
            planck_uv(t, out u0, out v0);
            planck_uv(t * 1.01, out u1, out v1);
            double du = u1 - u0, dv = v1 - v0;
            double len = Math.sqrt(du * du + dv * dv);
            double nu = len > 0 ? -dv / len : 0, nv = len > 0 ? du / len : 1;
            if (nv < 0) {
                nu = -nu;
                nv = -nv;
            }
            u = u0 + nu * tint / TINT_SCALE;
            v = v0 + nv * tint / TINT_SCALE;
        }

        public void white_xy(double t, double tint, out double x, out double y) {
            double u, v;
            white_uv(t, tint, out u, out v);
            double d = 2 * u - 8 * v + 4;
            x = 3 * u / d;
            y = 2 * v / d;
        }

        public double[] white_xyz(double t, double tint) {
            double x, y;
            white_xy(t, tint, out x, out y);
            return { x / y, 1.0, (1 - x - y) / y };
        }

        public double[] mul(double[] m, double[] v) {
            return { m[0] * v[0] + m[1] * v[1] + m[2] * v[2], m[3] * v[0] + m[4] * v[1] + m[5] * v[2], m[6] * v[0] + m[7] * v[1] + m[8] * v[2] };
        }

        public double illuminant_temperature(int code) {
            switch (code) {
                case 1: case 4: case 9: return 5500;
                case 2: case 14: return 4150;
                case 3: return 2850;
                case 10: return 6500;
                case 11: return 7500;
                case 12: return 6430;
                case 13: return 5000;
                case 15: return 3525;
                case 16: return 2925;
                case 17: return 2856;
                case 18: return 4874;
                case 19: return 6774;
                case 20: return 5503;
                case 21: return 6504;
                case 22: return 7504;
                case 23: return 5003;
                case 24: return 3200;
                default: return 0;
            }
        }
    }

    namespace RawColor {

        public const string[] HIGHLIGHT_MODES = { "reconstruct", "blend", "clip" };

        public double[] interpolate(double[] cm1, double[] cm2, double t1, double t2, double temperature) {
            if (cm1.length != 9) return cm2;
            if (cm2.length != 9 || t1 <= 0 || t2 <= 0 || (t1 - t2).abs() < 1) return cm1;
            if (t1 > t2) return interpolate(cm2, cm1, t2, t1, temperature);
            double g = ((1.0 / temperature - 1.0 / t2) / (1.0 / t1 - 1.0 / t2)).clamp(0, 1);
            var m = new double[9];
            for (int i = 0; i < 9; i++) m[i] = g * cm1[i] + (1 - g) * cm2[i];
            return m;
        }

        private class Matrices {
            public double[] cm1;
            public double[] cm2 = {};
            public double t1 = 0;
            public double t2 = 0;

            public double[] at(double temperature) {
                return interpolate(cm1, cm2, t1, t2, temperature);
            }
        }

        private Matrices resolve(RawData raw) {
            var m = new Matrices();
            m.cm1 = raw.xyz_to_camera;
            if (raw.camera_profile_name != "") {
                var profile = CameraProfiles.find(raw, raw.camera_profile_name);
                if (profile != null && profile.color_matrix1.length == 9) {
                    m.cm1 = profile.color_matrix1;
                    m.cm2 = profile.color_matrix2;
                    m.t1 = profile.temperature1;
                    m.t2 = profile.temperature2;
                    return m;
                }
            }
            var dual = raw as DngRawData;
            if (dual != null && dual.color_matrix1.length == 9) {
                m.cm1 = dual.color_matrix1;
                m.cm2 = dual.color_matrix2;
                m.t1 = dual.temperature1;
                m.t2 = dual.temperature2;
            }
            return m;
        }

        public double[] xyz_to_camera_for(RawData raw, double temperature) {
            return resolve(raw).at(temperature);
        }

        private void normalize(ref double r, ref double g, ref double b) {
            if (g <= 0) g = 1e-6;
            r /= g;
            b /= g;
            g = 1;
        }

        public void multipliers_at(RawData raw, double temperature, double tint, out double r, out double g, out double b) {
            multipliers_with(resolve(raw), temperature, tint, out r, out g, out b);
        }

        private void multipliers_with(Matrices mats, double temperature, double tint, out double r, out double g, out double b) {
            var cm = mats.at(temperature);
            var neutral = Chromaticity.mul(cm, Chromaticity.white_xyz(temperature, tint));
            r = neutral[0] > 1e-9 ? 1.0 / neutral[0] : 1;
            g = neutral[1] > 1e-9 ? 1.0 / neutral[1] : 1;
            b = neutral[2] > 1e-9 ? 1.0 / neutral[2] : 1;
            normalize(ref r, ref g, ref b);
        }

        public void auto_multipliers(RawData raw, out double r, out double g, out double b) {
            double sr = 0, sg = 0, sb = 0;
            var img = raw.camera.scaled_to_fit(512);
            size_t n = img.pixel_count();
            for (size_t i = 0; i < n; i++) {
                float cr = img.data[i * 4], cg = img.data[i * 4 + 1], cb = img.data[i * 4 + 2];
                if (cr >= raw.clip_level[0] * 0.97f || cg >= raw.clip_level[1] * 0.97f || cb >= raw.clip_level[2] * 0.97f) continue;
                double l = cr + cg + cb;
                if (l < 0.01) continue;
                double w = Math.sqrt(l);
                sr += cr * w;
                sg += cg * w;
                sb += cb * w;
            }
            if (sr <= 0 || sg <= 0 || sb <= 0) {
                r = raw.as_shot_multipliers[0];
                g = raw.as_shot_multipliers[1];
                b = raw.as_shot_multipliers[2];
                return;
            }
            r = sg / sr;
            g = 1;
            b = sg / sb;
        }

        public void multipliers_for(RawData raw, string mode, double temperature, double tint, out double r, out double g, out double b) {
            if (mode == "auto") {
                auto_multipliers(raw, out r, out g, out b);
                return;
            }
            if (mode == "custom" || mode == "temperature") {
                multipliers_at(raw, temperature, tint, out r, out g, out b);
                return;
            }
            double preset = preset_temperature(mode);
            if (preset > 0) {
                multipliers_at(raw, preset, preset_tint(mode), out r, out g, out b);
                return;
            }
            r = raw.as_shot_multipliers[0];
            g = raw.as_shot_multipliers[1];
            b = raw.as_shot_multipliers[2];
            normalize(ref r, ref g, ref b);
        }

        public double preset_temperature(string mode) {
            switch (mode) {
                case "daylight": return 5500;
                case "cloudy": return 6500;
                case "shade": return 7500;
                case "tungsten": return 2850;
                case "fluorescent": return 3800;
                case "flash": return 5500;
                default: return 0;
            }
        }

        public double preset_tint(string mode) {
            switch (mode) {
                case "cloudy": return 10;
                case "shade": return 10;
                case "fluorescent": return 21;
                case "flash": return 0;
                default: return 0;
            }
        }

        private double error_for(Matrices mats, double t, double tint, double lr, double lb) {
            double r, g, b;
            multipliers_with(mats, t, tint, out r, out g, out b);
            double er = Math.log(r) - lr, eb = Math.log(b) - lb;
            return er * er + eb * eb;
        }

        public void temperature_for(RawData raw, double r, double g, double b, out double temperature, out double tint) {
            normalize(ref r, ref g, ref b);
            double lr = Math.log(double.max(r, 1e-6)), lb = Math.log(double.max(b, 1e-6));
            var mats = resolve(raw);
            double best_t = 5500, best_tint = 0, best = double.MAX;
            for (int i = 0; i <= 120; i++) {
                double t = 2000 * Math.pow(25.0, i / 120.0);
                for (int j = -15; j <= 15; j++) {
                    double e = error_for(mats, t, j * 10.0, lr, lb);
                    if (e < best) {
                        best = e;
                        best_t = t;
                        best_tint = j * 10.0;
                    }
                }
            }
            double lt = Math.log(best_t), ti = best_tint;
            for (int iter = 0; iter < 30; iter++) {
                double r0, g0, b0;
                multipliers_with(mats, Math.exp(lt), ti, out r0, out g0, out b0);
                double f0 = Math.log(r0) - lr, f1 = Math.log(b0) - lb;
                if (f0.abs() + f1.abs() < 1e-10) break;
                double ra, ga, ba, rb, gb, bb;
                multipliers_with(mats, Math.exp(lt + 1e-4), ti, out ra, out ga, out ba);
                multipliers_with(mats, Math.exp(lt), ti + 1e-2, out rb, out gb, out bb);
                double j00 = (Math.log(ra) - Math.log(r0)) / 1e-4, j10 = (Math.log(ba) - Math.log(b0)) / 1e-4;
                double j01 = (Math.log(rb) - Math.log(r0)) / 1e-2, j11 = (Math.log(bb) - Math.log(b0)) / 1e-2;
                double det = j00 * j11 - j01 * j10;
                if (det.abs() < 1e-14) break;
                double d_lt = (j11 * f0 - j01 * f1) / det, d_ti = (-j10 * f0 + j00 * f1) / det;
                double nlt = (lt - d_lt).clamp(Math.log(1500), Math.log(60000)), nti = (ti - d_ti).clamp(-200, 200);
                double e = error_for(mats, Math.exp(nlt), nti, lr, lb);
                if (e > best) {
                    nlt = lt - d_lt * 0.3;
                    nti = ti - d_ti * 0.3;
                    e = error_for(mats, Math.exp(nlt), nti, lr, lb);
                    if (e > best) break;
                }
                lt = nlt;
                ti = nti;
                best = e;
            }
            best_t = Math.exp(lt).clamp(2000, 50000);
            best_tint = ti.clamp(-150, 150);
            temperature = best_t;
            tint = best_tint;
        }

        public double[] camera_to_working(RawData raw, double r_mul, double g_mul, double b_mul) {
            double t, tint;
            temperature_for(raw, r_mul, g_mul, b_mul, out t, out tint);
            var cm = resolve(raw).at(t);
            var inv = Matrix3.invert(cm);
            double[] diag = { 1.0 / r_mul, 0, 0, 0, 1.0 / g_mul, 0, 0, 0, 1.0 / b_mul };
            var to_xyz = Matrix3.multiply(inv, diag);
            var white = Chromaticity.mul(to_xyz, { 1, 1, 1 });
            double sum = white[0] + white[1] + white[2];
            if (white[1] <= 1e-9 || sum <= 1e-9) return Matrix3.multiply(Matrix3.invert(WorkingSpace.primaries().to_xyz()), raw.camera_to_xyz);
            double wx = white[0] / sum, wy = white[1] / sum;
            var p = WorkingSpace.primaries();
            var adapt = Matrix3.bradford(wx, wy, p.wx, p.wy);
            var m = Matrix3.multiply(Matrix3.invert(p.to_xyz()), Matrix3.multiply(adapt, to_xyz));
            double scale = 1.0 / white[1];
            for (int i = 0; i < 9; i++) m[i] *= scale;
            return m;
        }

        public void reconstruct_highlights(FloatImage img, float[] clip, string mode) {
            if (mode == "none") return;
            int w = img.width, h = img.height;
            size_t n = img.pixel_count();
            float cmin = float.min(clip[0], float.min(clip[1], clip[2]));
            if (mode == "clip") {
                for (size_t i = 0; i < n; i++)
                    for (int c = 0; c < 3; c++) img.data[i * 4 + c] = float.min(img.data[i * 4 + c], cmin);
                return;
            }
            var clipped = new uint8[n];
            bool any = false;
            for (size_t i = 0; i < n; i++) {
                for (int c = 0; c < 3; c++) {
                    if (img.data[i * 4 + c] >= clip[c] * 0.995f) {
                        clipped[i] = 1;
                        any = true;
                        break;
                    }
                }
            }
            if (!any) return;
            if (mode == "blend") {
                for (size_t i = 0; i < n; i++) {
                    if (clipped[i] == 0) continue;
                    float mx = 0;
                    int count = 0;
                    for (int c = 0; c < 3; c++) {
                        float v = img.data[i * 4 + c];
                        if (v >= clip[c] * 0.995f) count++;
                        mx = float.max(mx, float.min(v, clip[c]));
                    }
                    float t = count / 3.0f;
                    for (int c = 0; c < 3; c++) {
                        float v = float.min(img.data[i * 4 + c], clip[c]);
                        img.data[i * 4 + c] = v + (mx - v) * t;
                    }
                }
                return;
            }
            int sw = int.max(1, w / 8), sh = int.max(1, h / 8);
            var rg = new float[(size_t) sw * sh];
            var bg = new float[(size_t) sw * sh];
            var wt = new float[(size_t) sw * sh];
            for (int y = 0; y < h; y++) {
                int sy = int.min(sh - 1, y * sh / h);
                for (int x = 0; x < w; x++) {
                    size_t i = (size_t) y * w + x;
                    if (clipped[i] != 0) continue;
                    float g = img.data[i * 4 + 1];
                    if (g < cmin * 0.2f) continue;
                    int sx = int.min(sw - 1, x * sw / w);
                    size_t s = (size_t) sy * sw + sx;
                    rg[s] += img.data[i * 4] / g;
                    bg[s] += img.data[i * 4 + 2] / g;
                    wt[s] += 1;
                }
            }
            double sigma = double.max(2.0, double.max(sw, sh) / 16.0);
            var rgb = Filters.gaussian_plane(rg, sw, sh, sigma);
            var bgb = Filters.gaussian_plane(bg, sw, sh, sigma);
            var wtb = Filters.gaussian_plane(wt, sw, sh, sigma);
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    size_t i = (size_t) y * w + x;
                    if (clipped[i] == 0) continue;
                    double sx = (x + 0.5) * sw / w, sy = (y + 0.5) * sh / h;
                    float ww = Filters.sample_plane(wtb, sw, sh, sx, sy);
                    float kr = ww > 1e-4f ? Filters.sample_plane(rgb, sw, sh, sx, sy) / ww : 1.0f;
                    float kb = ww > 1e-4f ? Filters.sample_plane(bgb, sw, sh, sx, sy) / ww : 1.0f;
                    float r = img.data[i * 4], g = img.data[i * 4 + 1], b = img.data[i * 4 + 2];
                    bool cr = r >= clip[0] * 0.995f, cg = g >= clip[1] * 0.995f, cb = b >= clip[2] * 0.995f;
                    float gest = g;
                    if (cg) {
                        float from_r = cr ? 0 : r / float.max(kr, 1e-3f);
                        float from_b = cb ? 0 : b / float.max(kb, 1e-3f);
                        gest = float.max(clip[1], float.max(from_r, from_b));
                    }
                    if (cr) r = float.max(clip[0], gest * kr);
                    if (cb) b = float.max(clip[2], gest * kb);
                    if (cr && cg && cb) {
                        float m = float.max(r, float.max(gest, b));
                        r = gest = b = m;
                    }
                    img.data[i * 4] = r;
                    img.data[i * 4 + 1] = gest;
                    img.data[i * 4 + 2] = b;
                }
            }
        }

        public FloatImage develop(RawData raw, double r_mul, double g_mul, double b_mul, string highlight_mode) {
            var img = raw.camera.copy();
            float mr = (float) r_mul, mg = (float) g_mul, mb = (float) b_mul;
            int w = img.width;
            Parallel.range(img.height, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    img.data[i * 4] *= mr;
                    img.data[i * 4 + 1] *= mg;
                    img.data[i * 4 + 2] *= mb;
                }
            });
            float[] clip = { raw.clip_level[0] * mr, raw.clip_level[1] * mg, raw.clip_level[2] * mb };
            string mode = highlight_mode;
            if (mode != "clip" && mode != "blend" && mode != "none") mode = "reconstruct";
            reconstruct_highlights(img, clip, mode);
            var m = camera_to_working(raw, r_mul, g_mul, b_mul);
            if (raw.baseline_exposure.abs() > 1e-6) {
                double k = Math.pow(2.0, raw.baseline_exposure);
                for (int i = 0; i < 9; i++) m[i] *= k;
            }
            Matrix3.apply_image(m, img);
            if (raw.camera_profile_name != "") {
                var profile = CameraProfiles.find(raw, raw.camera_profile_name);
                if (profile != null) profile.apply_looks(img);
            }
            return img;
        }
    }
}
