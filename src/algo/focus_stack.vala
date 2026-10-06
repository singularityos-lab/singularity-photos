using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace FocusStack {

        public float[] sharpness(FloatImage img) {
            int w = img.width, h = img.height;
            var l = AlgoUtil.perceptual_luma(img);
            var lap = new float[l.length];
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    int ym = int.max(y - 1, 0), yp = int.min(y + 1, h - 1);
                    for (int x = 0; x < w; x++) {
                        int xm = int.max(x - 1, 0), xp = int.min(x + 1, w - 1);
                        float v = 4 * l[y * w + x] - l[y * w + xm] - l[y * w + xp] - l[ym * w + x] - l[yp * w + x];
                        lap[y * w + x] = v * v;
                    }
                }
            });
            return Filters.gaussian_plane(lap, w, h, 2.5);
        }

        public FloatImage merge(FloatImage[] images, MergeProgress? progress = null) throws Error {
            int n = images.length;
            if (n < 2) throw new IOError.INVALID_ARGUMENT(_("Select at least two photos focused at different distances"));
            int w = images[0].width, h = images[0].height;
            var aligned = new FloatImage[n];
            aligned[0] = images[0];
            var ref_l = AlgoUtil.perceptual_luma(images[0]);
            for (int i = 1; i < n; i++) {
                var img = images[i];
                if (img.width != w || img.height != h) img = img.resized(w, h);
                int dx, dy;
                MergeUtil.mtb_offset(ref_l, AlgoUtil.perceptual_luma(img), w, h, out dx, out dy);
                aligned[i] = dx == 0 && dy == 0 ? img : AlgoUtil.translate(img, dx, dy);
                if (progress != null) progress(0.3 * i / n, _("Aligning"));
            }
            var energies = new MergePlane[n];
            for (int i = 0; i < n; i++) energies[i] = new MergePlane(sharpness(aligned[i]), w, h);
            var weights = new MergePlane[n];
            for (int i = 0; i < n; i++) weights[i] = new MergePlane(new float[w * h], w, h);
            for (int p = 0; p < w * h; p++) {
                float mx = 0;
                for (int i = 0; i < n; i++) mx = float.max(mx, energies[i].data[p]);
                float sum = 0;
                for (int i = 0; i < n; i++) {
                    float r = mx > 1e-9f ? energies[i].data[p] / mx : 1.0f;
                    float wt = r * r * r * r * r * r + 1e-4f;
                    weights[i].data[p] = wt;
                    sum += wt;
                }
                for (int i = 0; i < n; i++) weights[i].data[p] /= sum;
            }
            for (int i = 0; i < n; i++) weights[i].data = Filters.gaussian_plane(weights[i].data, w, h, 1.0);
            if (progress != null) progress(0.5, _("Blending"));
            int levels = MergeUtil.pyramid_levels(w, h, 6);
            Gee.ArrayList<FloatImage>? acc = null;
            for (int i = 0; i < n; i++) {
                var lap = MergeUtil.laplacian(aligned[i], levels);
                var gw = MergeUtil.gaussian_planes(weights[i].data, w, h, levels);
                if (acc == null) {
                    acc = new Gee.ArrayList<FloatImage>();
                    foreach (var l in lap) acc.add(new FloatImage(l.width, l.height));
                }
                for (int lv = 0; lv < levels; lv++) {
                    var l = lap[lv];
                    var a = acc[lv];
                    unowned float[] wd = gw[lv].data;
                    size_t np = l.pixel_count();
                    for (size_t p = 0; p < np; p++) {
                        float wt = wd[p];
                        for (int c = 0; c < 3; c++) a.data[p * 4 + c] += l.data[p * 4 + c] * wt;
                        a.data[p * 4 + 3] = 1;
                    }
                }
                if (progress != null) progress(0.5 + 0.5 * (i + 1) / n, _("Blending"));
            }
            var result = MergeUtil.collapse(acc);
            for (size_t p = 0; p < result.pixel_count(); p++) result.data[p * 4 + 3] = 1;
            return result;
        }
    }

    namespace SuperResolution {

        private double lanczos(double x) {
            x = x.abs();
            if (x < 1e-9) return 1;
            if (x >= 3) return 0;
            double px = Math.PI * x;
            return 3 * Math.sin(px) * Math.sin(px / 3) / (px * px);
        }

        public FloatImage lanczos_resize(FloatImage src, int nw, int nh) {
            int w = src.width, h = src.height;
            var tmp = new FloatImage(nw, h);
            double sx = (double) w / nw;
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < nw; x++) {
                        double center = (x + 0.5) * sx - 0.5;
                        int x0 = (int) Math.floor(center) - 2;
                        double acc0 = 0, acc1 = 0, acc2 = 0, acc3 = 0, ws = 0;
                        for (int k = x0; k < x0 + 6; k++) {
                            double wt = lanczos(center - k);
                            size_t o = src.offset(k.clamp(0, w - 1), y);
                            acc0 += src.data[o] * wt;
                            acc1 += src.data[o + 1] * wt;
                            acc2 += src.data[o + 2] * wt;
                            acc3 += src.data[o + 3] * wt;
                            ws += wt;
                        }
                        size_t d = tmp.offset(x, y);
                        tmp.data[d] = (float) (acc0 / ws);
                        tmp.data[d + 1] = (float) (acc1 / ws);
                        tmp.data[d + 2] = (float) (acc2 / ws);
                        tmp.data[d + 3] = (float) (acc3 / ws);
                    }
                }
            });
            var out_img = new FloatImage(nw, nh);
            double sy = (double) h / nh;
            Parallel.range(nh, (start, end) => {
                for (int y = start; y < end; y++) {
                    double center = (y + 0.5) * sy - 0.5;
                    int y0 = (int) Math.floor(center) - 2;
                    for (int x = 0; x < nw; x++) {
                        double acc0 = 0, acc1 = 0, acc2 = 0, acc3 = 0, ws = 0;
                        for (int k = y0; k < y0 + 6; k++) {
                            double wt = lanczos(center - k);
                            size_t o = tmp.offset(x, k.clamp(0, h - 1));
                            acc0 += tmp.data[o] * wt;
                            acc1 += tmp.data[o + 1] * wt;
                            acc2 += tmp.data[o + 2] * wt;
                            acc3 += tmp.data[o + 3] * wt;
                            ws += wt;
                        }
                        size_t d = out_img.offset(x, y);
                        out_img.data[d] = (float) (acc0 / ws);
                        out_img.data[d + 1] = (float) (acc1 / ws);
                        out_img.data[d + 2] = (float) (acc2 / ws);
                        out_img.data[d + 3] = (float) (acc3 / ws);
                    }
                }
            });
            return out_img;
        }

        private float cubic_mid(float a, float b, float c, float d) {
            return (-a + 9 * b + 9 * c - d) / 16.0f;
        }

        public FloatImage directional_cubic(FloatImage enc) {
            int w = enc.width, h = enc.height;
            int hw = w * 2, hh = h * 2;
            var out_img = new FloatImage(hw, hh);
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++) {
                    size_t s = enc.offset(x, y), d = out_img.offset(x * 2, y * 2);
                    for (int c = 0; c < 4; c++) out_img.data[d + c] = enc.data[s + c];
                }
            for (int pass = 0; pass < 2; pass++) {
                Parallel.range(hh, (start, end) => {
                    for (int y = start; y < end; y++) {
                        for (int x = 0; x < hw; x++) {
                            bool diagonal = (x % 2 == 1) && (y % 2 == 1);
                            bool axial = (x + y) % 2 == 1;
                            if (pass == 0 && !diagonal) continue;
                            if (pass == 1 && !axial) continue;
                            int ax, ay, bx, by;
                            if (pass == 0) {
                                ax = 1; ay = 1; bx = 1; by = -1;
                            } else {
                                ax = 1; ay = 0; bx = 0; by = 1;
                            }
                            double g1 = 0, g2 = 0;
                            for (int k = -2; k <= 2; k++) {
                                for (int m = -2; m <= 2; m++) {
                                    int px = x + k, py = y + m;
                                    if (((px + py) & 1) != 0 && pass == 1) continue;
                                    if (pass == 0 && ((px & 1) != 0 || (py & 1) != 0)) continue;
                                    int qx = px + 2 * ax, qy = py + 2 * ay;
                                    int rx = px + 2 * bx, ry = py + 2 * by;
                                    float l0 = lum_at(out_img, px, py);
                                    if (qx >= 0 && qy >= 0 && qx < hw && qy < hh) g1 += (l0 - lum_at(out_img, qx, qy)).abs();
                                    if (rx >= 0 && ry >= 0 && rx < hw && ry < hh) g2 += (l0 - lum_at(out_img, rx, ry)).abs();
                                }
                            }
                            size_t d = out_img.offset(x, y);
                            for (int c = 0; c < 4; c++) {
                                float along_a = cubic_mid(fetch(out_img, x - 3 * ax, y - 3 * ay, c), fetch(out_img, x - ax, y - ay, c), fetch(out_img, x + ax, y + ay, c), fetch(out_img, x + 3 * ax, y + 3 * ay, c));
                                float along_b = cubic_mid(fetch(out_img, x - 3 * bx, y - 3 * by, c), fetch(out_img, x - bx, y - by, c), fetch(out_img, x + bx, y + by, c), fetch(out_img, x + 3 * bx, y + 3 * by, c));
                                float v;
                                if ((1 + g1) / (1 + g2) > 1.15) v = along_b;
                                else if ((1 + g2) / (1 + g1) > 1.15) v = along_a;
                                else {
                                    double w1 = 1.0 / (1 + Math.pow(g1, 5)), w2 = 1.0 / (1 + Math.pow(g2, 5));
                                    v = (float) ((w1 * along_a + w2 * along_b) / (w1 + w2));
                                }
                                out_img.data[d + c] = v;
                            }
                        }
                    }
                });
            }
            var aligned = new FloatImage(hw, hh);
            Parallel.range(hh, (start, end) => {
                for (int y = start; y < end; y++)
                    for (int x = 0; x < hw; x++) {
                        float r, g, b, a;
                        out_img.sample(x, y, out r, out g, out b, out a);
                        aligned.set_pixel(x, y, r, g, b, a);
                    }
            });
            return aligned;
        }

        private float fetch(FloatImage img, int x, int y, int c) {
            x = x.clamp(0, img.width - 1);
            y = y.clamp(0, img.height - 1);
            return img.data[img.offset(x, y) + c];
        }

        private float lum_at(FloatImage img, int x, int y) {
            size_t o = img.offset(x.clamp(0, img.width - 1), y.clamp(0, img.height - 1));
            return img.data[o] * 0.2627f + img.data[o + 1] * 0.678f + img.data[o + 2] * 0.0593f;
        }

        private FloatImage upscale2(FloatImage img) {
            int w = img.width, h = img.height;
            var enc = AlgoUtil.encoded_copy(img);
            var est = directional_cubic(enc);
            for (int it = 0; it < 3; it++) {
                var down = est.resized(w, h);
                var err = enc.copy();
                for (int k = 0; k < err.data.length; k++) err.data[k] -= down.data[k];
                var up = lanczos_resize(err, w * 2, h * 2);
                for (int k = 0; k < est.data.length; k++) est.data[k] += up.data[k];
            }
            var blur = Filters.gaussian(est, 0.7);
            float[] gx, gy;
            var l = AlgoUtil.luma(est);
            var mag = AlgoUtil.sobel_magnitude(l, est.width, est.height, out gx, out gy);
            for (size_t p = 0; p < est.pixel_count(); p++) {
                float edge = (mag[p] * 4).clamp(0, 1);
                float k = 0.2f * (1 - edge * 0.6f);
                for (int c = 0; c < 3; c++) est.data[p * 4 + c] = (est.data[p * 4 + c] + (est.data[p * 4 + c] - blur.data[p * 4 + c]) * k).clamp(0, 1.5f);
                est.data[p * 4 + 3] = est.data[p * 4 + 3].clamp(0, 1);
            }
            AlgoUtil.decode_in_place(est);
            return est;
        }

        public FloatImage upscale(FloatImage img, int factor) {
            if (factor <= 1) return img.copy();
            var cur = img;
            int reached = 1;
            while (reached < factor) {
                cur = upscale2(cur);
                reached *= 2;
            }
            if (reached != factor) cur = cur.resized(img.width * factor, img.height * factor);
            return cur;
        }
    }
}
