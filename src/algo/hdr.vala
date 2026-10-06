using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace Hdr {

        public FloatImage merge(FloatImage[] images, double[] evs, MergeProgress? progress = null) throws Error {
            return merge_full(images, evs, true, true, progress);
        }

        public double[] estimate_evs(FloatImage[] images, int reference) {
            int n = images.length;
            var result = new double[n];
            var ref_l = AlgoUtil.luma(images[reference].scaled_to_fit(512));
            for (int i = 0; i < n; i++) {
                if (i == reference) continue;
                var l = AlgoUtil.luma(images[i].scaled_to_fit(512));
                var ratios = new Gee.ArrayList<double?>();
                int m = int.min(l.length, ref_l.length);
                for (int k = 0; k < m; k++) {
                    if (l[k] > 0.03f && l[k] < 0.85f && ref_l[k] > 0.03f && ref_l[k] < 0.85f) ratios.add(Math.log2(l[k] / ref_l[k]));
                }
                if (ratios.size == 0) continue;
                ratios.sort((a, b) => { double x = a, y = b; return x < y ? -1 : (x > y ? 1 : 0); });
                result[i] = ratios[ratios.size / 2];
            }
            return result;
        }

        private float weight(float m) {
            if (m >= 0.97f || m <= 0.0003f) return 0;
            float e = Transfer.linear_to_srgb(m);
            float t = 2 * e - 1;
            float t2 = t * t;
            float t4 = t2 * t2;
            return 1.0f - t4 * t4 + 1e-4f;
        }

        public FloatImage merge_full(FloatImage[] images, double[] evs, bool align, bool deghost, MergeProgress? progress = null) throws Error {
            int n = images.length;
            if (n < 2) throw new IOError.INVALID_ARGUMENT(_("Select at least two bracketed photos"));
            int w = images[0].width, h = images[0].height;
            foreach (var img in images) {
                if (img.width != w || img.height != h) throw new IOError.INVALID_ARGUMENT(_("The photos must have the same size"));
            }
            double[] ev = new double[n];
            bool given = evs.length == n;
            if (given) {
                bool all_same = true;
                for (int i = 1; i < n; i++) if ((evs[i] - evs[0]).abs() > 1e-6) all_same = false;
                if (all_same) given = false;
            }
            int reference = 0;
            if (given) {
                var order = new int[n];
                for (int i = 0; i < n; i++) order[i] = i;
                for (int i = 0; i < n; i++) for (int j = i + 1; j < n; j++) if (evs[order[j]] < evs[order[i]]) { int t = order[i]; order[i] = order[j]; order[j] = t; }
                reference = order[n / 2];
                for (int i = 0; i < n; i++) ev[i] = evs[i] - evs[reference];
            } else {
                var means = new double[n];
                for (int i = 0; i < n; i++) {
                    var l = AlgoUtil.luma(images[i].scaled_to_fit(256));
                    double s = 0;
                    foreach (float v in l) s += v;
                    means[i] = s / l.length;
                }
                var order = new int[n];
                for (int i = 0; i < n; i++) order[i] = i;
                for (int i = 0; i < n; i++) for (int j = i + 1; j < n; j++) if (means[order[j]] < means[order[i]]) { int t = order[i]; order[i] = order[j]; order[j] = t; }
                reference = order[n / 2];
                ev = estimate_evs(images, reference);
            }
            if (progress != null) progress(0.1, _("Aligning"));
            var aligned = new FloatImage[n];
            var ref_luma = AlgoUtil.perceptual_luma(images[reference]);
            for (int i = 0; i < n; i++) {
                if (i == reference || !align) {
                    aligned[i] = images[i];
                    continue;
                }
                var l = AlgoUtil.luma(images[i]);
                float gain = (float) Math.pow(2.0, -ev[i]);
                for (int k = 0; k < l.length; k++) l[k] = Transfer.linear_to_srgb((l[k] * gain).clamp(0, 1));
                int dx, dy;
                MergeUtil.mtb_offset(ref_luma, l, w, h, out dx, out dy);
                aligned[i] = dx == 0 && dy == 0 ? images[i] : AlgoUtil.translate(images[i], dx, dy);
                if (progress != null) progress(0.1 + 0.4 * (i + 1) / n, _("Aligning"));
            }
            if (progress != null) progress(0.55, _("Merging"));
            var gains = new float[n];
            for (int i = 0; i < n; i++) gains[i] = (float) Math.pow(2.0, -ev[i]);
            int darkest = 0, brightest = 0;
            for (int i = 1; i < n; i++) {
                if (ev[i] < ev[darkest]) darkest = i;
                if (ev[i] > ev[brightest]) brightest = i;
            }
            var out_img = new FloatImage(w, h);
            Parallel.range(h, (start, end) => {
                var wts = new float[n];
                for (size_t p = (size_t) start * w; p < (size_t) end * w; p++) {
                    float ref_r = aligned[reference].data[p * 4], ref_g = aligned[reference].data[p * 4 + 1], ref_b = aligned[reference].data[p * 4 + 2];
                    float ref_m = float.max(ref_r, float.max(ref_g, ref_b));
                    float ref_w = weight(ref_m);
                    float ref_l = (AlgoUtil.LR * ref_r + AlgoUtil.LG * ref_g + AlgoUtil.LB * ref_b) * gains[reference];
                    float wsum = 0;
                    for (int i = 0; i < n; i++) {
                        float r = aligned[i].data[p * 4], g = aligned[i].data[p * 4 + 1], b = aligned[i].data[p * 4 + 2];
                        float m = float.max(r, float.max(g, b));
                        float wt = weight(m);
                        if (deghost && i != reference && ref_w > 0.2f && wt > 0) {
                            float l = (AlgoUtil.LR * r + AlgoUtil.LG * g + AlgoUtil.LB * b) * gains[i];
                            double diff = Math.log2((l + 1e-4) / (ref_l + 1e-4)).abs();
                            if (diff > 0.7) wt *= 0.02f;
                        }
                        wts[i] = wt;
                        wsum += wt;
                    }
                    float orr = 0, og = 0, ob = 0;
                    if (wsum <= 1e-5f) {
                        int pick = ref_m > 0.5f ? darkest : brightest;
                        orr = aligned[pick].data[p * 4] * gains[pick];
                        og = aligned[pick].data[p * 4 + 1] * gains[pick];
                        ob = aligned[pick].data[p * 4 + 2] * gains[pick];
                    } else {
                        for (int i = 0; i < n; i++) {
                            if (wts[i] <= 0) continue;
                            float k = wts[i] * gains[i];
                            orr += aligned[i].data[p * 4] * k;
                            og += aligned[i].data[p * 4 + 1] * k;
                            ob += aligned[i].data[p * 4 + 2] * k;
                        }
                        orr /= wsum;
                        og /= wsum;
                        ob /= wsum;
                    }
                    out_img.data[p * 4] = orr;
                    out_img.data[p * 4 + 1] = og;
                    out_img.data[p * 4 + 2] = ob;
                    out_img.data[p * 4 + 3] = 1;
                }
            });
            if (progress != null) progress(1.0, _("Done"));
            return out_img;
        }
    }
}
