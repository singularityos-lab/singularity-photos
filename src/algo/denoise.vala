using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace Denoise {

        public double estimate_sigma(float[] e, int w, int h) {
            int step = int.max(1, (int) Math.sqrt((double) w * h / 200000.0));
            var samples = new Gee.ArrayList<float?>();
            for (int y = 1; y < h - 1; y += step) {
                for (int x = 1; x < w - 1; x += step) {
                    int i = y * w + x;
                    float lap = 4 * e[i] - e[i - 1] - e[i + 1] - e[i - w] - e[i + w];
                    samples.add(lap.abs());
                }
            }
            if (samples.size == 0) return 0.01;
            samples.sort((a, b) => { float x = a, y = b; return x < y ? -1 : (x > y ? 1 : 0); });
            double med = samples[samples.size / 2];
            return double.max(0.002, med / 0.6745 / Math.sqrt(20.0));
        }

        public float[] nlm_plane(float[] e, int w, int h, double hh, int search, int patch) {
            var out_p = new float[e.length];
            float inv_h2 = (float) (1.0 / double.max(hh * hh, 1e-10));
            float inv_area = 1.0f / ((2 * patch + 1) * (2 * patch + 1));
            Parallel.range(h, (start, end) => {
                int rows = end - start + 2 * patch;
                var d2 = new float[rows * w];
                var hs = new float[rows * w];
                var sum = new float[(end - start) * w];
                var wsum = new float[(end - start) * w];
                var wmax = new float[(end - start) * w];
                for (int dy = -search; dy <= search; dy++) {
                    for (int dx = -search; dx <= search; dx++) {
                        if (dx == 0 && dy == 0) continue;
                        for (int r = 0; r < rows; r++) {
                            int y = (start - patch + r).clamp(0, h - 1);
                            int yy = (y + dy).clamp(0, h - 1);
                            int ro = r * w;
                            int a0 = y * w, b0 = yy * w;
                            for (int x = 0; x < w; x++) {
                                int xx = x + dx;
                                if (xx < 0) xx = 0;
                                else if (xx >= w) xx = w - 1;
                                float diff = e[a0 + x] - e[b0 + xx];
                                d2[ro + x] = diff * diff;
                            }
                            for (int x = 0; x < w; x++) {
                                float acc = 0;
                                for (int i = -patch; i <= patch; i++) {
                                    int xi = x + i;
                                    if (xi < 0) xi = 0;
                                    else if (xi >= w) xi = w - 1;
                                    acc += d2[ro + xi];
                                }
                                hs[ro + x] = acc;
                            }
                        }
                        for (int y = start; y < end; y++) {
                            int r = y - start + patch;
                            int yy = (y + dy).clamp(0, h - 1);
                            int lo = (y - start) * w;
                            for (int x = 0; x < w; x++) {
                                float acc = 0;
                                for (int j = -patch; j <= patch; j++) acc += hs[(r + j) * w + x];
                                float wt = Math.expf(-acc * inv_area * inv_h2);
                                int xx = x + dx;
                                if (xx < 0) xx = 0;
                                else if (xx >= w) xx = w - 1;
                                sum[lo + x] += wt * e[yy * w + xx];
                                wsum[lo + x] += wt;
                                if (wt > wmax[lo + x]) wmax[lo + x] = wt;
                            }
                        }
                    }
                }
                for (int y = start; y < end; y++) {
                    int lo = (y - start) * w;
                    for (int x = 0; x < w; x++) {
                        float wm = wmax[lo + x] > 0 ? wmax[lo + x] : 1.0f;
                        out_p[y * w + x] = (sum[lo + x] + wm * e[y * w + x]) / (wsum[lo + x] + wm);
                    }
                }
            }, 16);
            return out_p;
        }

        public void luminance(FloatImage img, double amount, double detail, double contrast) {
            if (amount <= 1e-4) return;
            int w = img.width, h = img.height;
            var lin = AlgoUtil.luma(img);
            var e = lin.copy();
            AlgoUtil.encode_plane(e);
            double sigma = estimate_sigma(e, w, h);
            double hh = sigma * (0.6 + 2.4 * amount.clamp(0, 1));
            int search = amount > 0.6 ? 4 : 3;
            var den = nlm_plane(e, w, h, hh, search, 1);
            float keep = (float) (detail.clamp(0, 1) * 0.45);
            if (keep > 0) {
                for (int i = 0; i < den.length; i++) den[i] += (e[i] - den[i]) * keep;
            }
            if (contrast > 1e-4) {
                var blur = Filters.gaussian_plane(den, w, h, 2.5);
                float k = (float) (contrast.clamp(0, 1) * 0.6);
                for (int i = 0; i < den.length; i++) den[i] += (den[i] - blur[i]) * k;
            }
            Parallel.range(h, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    float target = Transfer.srgb_to_linear(den[i]);
                    float l = lin[i];
                    if (l > 1e-5f) {
                        float ratio = (target / l).clamp(0.0f, 8.0f);
                        img.data[i * 4] *= ratio;
                        img.data[i * 4 + 1] *= ratio;
                        img.data[i * 4 + 2] *= ratio;
                    } else {
                        float d = target - l;
                        img.data[i * 4] += d;
                        img.data[i * 4 + 1] += d;
                        img.data[i * 4 + 2] += d;
                    }
                }
            });
        }
    }
}
