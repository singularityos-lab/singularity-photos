using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace AlgoUtil {

        public const float LR = 0.2627f;
        public const float LG = 0.6780f;
        public const float LB = 0.0593f;

        public float[] luma(FloatImage img) {
            var plane = new float[img.pixel_count()];
            int w = img.width;
            Parallel.range(img.height, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++)
                    plane[i] = img.data[i * 4] * LR + img.data[i * 4 + 1] * LG + img.data[i * 4 + 2] * LB;
            });
            return plane;
        }

        public float[] perceptual_luma(FloatImage img) {
            var plane = luma(img);
            encode_plane(plane);
            return plane;
        }

        public void encode_plane(float[] plane) {
            int n = plane.length;
            Parallel.range(n, (start, end) => {
                for (int i = start; i < end; i++) plane[i] = Transfer.linear_to_srgb(float.max(plane[i], 0));
            }, 4096);
        }

        public FloatImage encoded_copy(FloatImage img) {
            var c = img.copy();
            int w = c.width;
            Parallel.range(c.height, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++)
                    for (int k = 0; k < 3; k++) c.data[i * 4 + k] = Transfer.linear_to_srgb(c.data[i * 4 + k]);
            });
            return c;
        }

        public void decode_in_place(FloatImage img) {
            int w = img.width;
            Parallel.range(img.height, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++)
                    for (int k = 0; k < 3; k++) img.data[i * 4 + k] = Transfer.srgb_to_linear(img.data[i * 4 + k]);
            });
        }

        public float[] sobel_magnitude(float[] p, int w, int h, out float[] gx_out, out float[] gy_out) {
            var mag = new float[p.length];
            var gx = new float[p.length];
            var gy = new float[p.length];
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    int ym = int.max(y - 1, 0), yp = int.min(y + 1, h - 1);
                    for (int x = 0; x < w; x++) {
                        int xm = int.max(x - 1, 0), xp = int.min(x + 1, w - 1);
                        float a = p[ym * w + xm], b = p[ym * w + x], c = p[ym * w + xp];
                        float d = p[y * w + xm], f = p[y * w + xp];
                        float g = p[yp * w + xm], hh = p[yp * w + x], k = p[yp * w + xp];
                        float sx = (c + 2 * f + k) - (a + 2 * d + g);
                        float sy = (g + 2 * hh + k) - (a + 2 * b + c);
                        gx[y * w + x] = sx;
                        gy[y * w + x] = sy;
                        mag[y * w + x] = Math.sqrtf(sx * sx + sy * sy);
                    }
                }
            });
            gx_out = gx;
            gy_out = gy;
            return mag;
        }

        public float[] half_plane(float[] p, int w, int h, out int nw, out int nh) {
            nw = int.max(1, (w + 1) / 2);
            nh = int.max(1, (h + 1) / 2);
            var blurred = Filters.gaussian_plane(p, w, h, 1.0);
            var out_p = new float[(size_t) nw * nh];
            int ow = nw, oh = nh;
            Parallel.range(oh, (start, end) => {
                for (int y = start; y < end; y++)
                    for (int x = 0; x < ow; x++)
                        out_p[y * ow + x] = blurred[int.min(y * 2, h - 1) * w + int.min(x * 2, w - 1)];
            });
            return out_p;
        }

        public double[] solve_linear(double[] a, double[] b, int n) {
            var m = a.copy();
            var v = b.copy();
            for (int col = 0; col < n; col++) {
                int piv = col;
                double best = m[col * n + col].abs();
                for (int r = col + 1; r < n; r++) {
                    double c = m[r * n + col].abs();
                    if (c > best) {
                        best = c;
                        piv = r;
                    }
                }
                if (best < 1e-14) continue;
                if (piv != col) {
                    for (int k = 0; k < n; k++) {
                        double t = m[col * n + k];
                        m[col * n + k] = m[piv * n + k];
                        m[piv * n + k] = t;
                    }
                    double t2 = v[col];
                    v[col] = v[piv];
                    v[piv] = t2;
                }
                for (int r = 0; r < n; r++) {
                    if (r == col) continue;
                    double f = m[r * n + col] / m[col * n + col];
                    if (f == 0) continue;
                    for (int k = col; k < n; k++) m[r * n + k] -= f * m[col * n + k];
                    v[r] -= f * v[col];
                }
            }
            var x = new double[n];
            for (int i = 0; i < n; i++) x[i] = m[i * n + i].abs() > 1e-14 ? v[i] / m[i * n + i] : 0;
            return x;
        }

        public void apply_h(double[] h, double x, double y, out double ox, out double oy) {
            double z = h[6] * x + h[7] * y + h[8];
            if (z.abs() < 1e-12) z = 1e-12;
            ox = (h[0] * x + h[1] * y + h[2]) / z;
            oy = (h[3] * x + h[4] * y + h[5]) / z;
        }

        public double[] homography_dlt(double[] src, double[] dst, int[] idx) {
            int n = idx.length;
            double mx = 0, my = 0, nx = 0, ny = 0;
            foreach (int i in idx) {
                mx += src[i * 2];
                my += src[i * 2 + 1];
                nx += dst[i * 2];
                ny += dst[i * 2 + 1];
            }
            mx /= n; my /= n; nx /= n; ny /= n;
            double ds = 0, dd = 0;
            foreach (int i in idx) {
                ds += Math.sqrt(Math.pow(src[i * 2] - mx, 2) + Math.pow(src[i * 2 + 1] - my, 2));
                dd += Math.sqrt(Math.pow(dst[i * 2] - nx, 2) + Math.pow(dst[i * 2 + 1] - ny, 2));
            }
            double ss = ds > 1e-9 ? Math.SQRT2 * n / ds : 1;
            double sd = dd > 1e-9 ? Math.SQRT2 * n / dd : 1;
            var ata = new double[64];
            var atb = new double[8];
            foreach (int i in idx) {
                double x = (src[i * 2] - mx) * ss, y = (src[i * 2 + 1] - my) * ss;
                double u = (dst[i * 2] - nx) * sd, v = (dst[i * 2 + 1] - ny) * sd;
                double[] r1 = { x, y, 1, 0, 0, 0, -u * x, -u * y };
                double[] r2 = { 0, 0, 0, x, y, 1, -v * x, -v * y };
                for (int a = 0; a < 8; a++) {
                    atb[a] += r1[a] * u + r2[a] * v;
                    for (int b = 0; b < 8; b++) ata[a * 8 + b] += r1[a] * r1[b] + r2[a] * r2[b];
                }
            }
            var hv = solve_linear(ata, atb, 8);
            double[] hn = { hv[0], hv[1], hv[2], hv[3], hv[4], hv[5], hv[6], hv[7], 1 };
            double[] ts = { ss, 0, -ss * mx, 0, ss, -ss * my, 0, 0, 1 };
            double[] td_inv = { 1 / sd, 0, nx, 0, 1 / sd, ny, 0, 0, 1 };
            var h = Matrix3.multiply(td_inv, Matrix3.multiply(hn, ts));
            if (h[8].abs() > 1e-12) for (int i = 0; i < 9; i++) h[i] /= h[8];
            return h;
        }

        public FloatImage warp(FloatImage src, double[] out_to_in, int w, int h, double ox = 0, double oy = 0) {
            var out_img = new FloatImage(w, h);
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        double sx, sy;
                        apply_h(out_to_in, x + 0.5 + ox, y + 0.5 + oy, out sx, out sy);
                        size_t d = out_img.offset(x, y);
                        if (sx < 0 || sy < 0 || sx > src.width || sy > src.height) {
                            out_img.data[d + 3] = 0;
                            continue;
                        }
                        float r, g, b, a;
                        src.sample(sx, sy, out r, out g, out b, out a);
                        out_img.data[d] = r;
                        out_img.data[d + 1] = g;
                        out_img.data[d + 2] = b;
                        out_img.data[d + 3] = a;
                    }
                }
            });
            return out_img;
        }

        public FloatImage translate(FloatImage src, int dx, int dy) {
            var out_img = new FloatImage(src.width, src.height);
            int w = src.width, h = src.height;
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    int sy = (y - dy).clamp(0, h - 1);
                    for (int x = 0; x < w; x++) {
                        int sx = (x - dx).clamp(0, w - 1);
                        size_t s = src.offset(sx, sy), d = out_img.offset(x, y);
                        out_img.data[d] = src.data[s];
                        out_img.data[d + 1] = src.data[s + 1];
                        out_img.data[d + 2] = src.data[s + 2];
                        out_img.data[d + 3] = src.data[s + 3];
                    }
                }
            });
            return out_img;
        }

        public uint32 hash(uint32 v) {
            v ^= v >> 16;
            v *= 0x7feb352du;
            v ^= v >> 15;
            v *= 0x846ca68bu;
            v ^= v >> 16;
            return v;
        }

        public double psnr(FloatImage a, FloatImage b, int border = 0) {
            double mse = 0;
            long n = 0;
            for (int y = border; y < a.height - border; y++) {
                for (int x = border; x < a.width - border; x++) {
                    size_t i = a.offset(x, y), j = b.offset(x, y);
                    for (int c = 0; c < 3; c++) {
                        double d = a.data[i + c] - b.data[j + c];
                        mse += d * d;
                    }
                    n += 3;
                }
            }
            mse /= double.max(1, n);
            return mse < 1e-20 ? 200 : 10 * Math.log10(1.0 / mse);
        }
    }
}
