using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace Heal {

        private const int PATCH_RADIUS = 3;

        private struct HealRect {
            public int x;
            public int y;
            public int w;
            public int h;
        }

        private float spot_weight(double d, double r, double feather) {
            double inner = r * (1.0 - feather.clamp(0, 1));
            if (d <= inner) return 1.0f;
            if (d >= r) return 0.0f;
            double t = (d - inner) / double.max(r - inner, 1e-6);
            t = 1.0 - t;
            return (float) (t * t * (3 - 2 * t));
        }

        private float[] spot_mask(SpotEdit s, int iw, int ih, out HealRect box) {
            double r = double.max(1.0, s.radius * int.max(iw, ih));
            double cx = s.x * iw, cy = s.y * ih;
            box = HealRect();
            box.x = ((int) Math.floor(cx - r - 1)).clamp(0, iw - 1);
            box.y = ((int) Math.floor(cy - r - 1)).clamp(0, ih - 1);
            int x1 = ((int) Math.ceil(cx + r + 1)).clamp(box.x + 1, iw);
            int y1 = ((int) Math.ceil(cy + r + 1)).clamp(box.y + 1, ih);
            box.w = x1 - box.x;
            box.h = y1 - box.y;
            var m = new float[box.w * box.h];
            float op = (float) s.opacity.clamp(0, 1);
            for (int y = 0; y < box.h; y++) {
                for (int x = 0; x < box.w; x++) {
                    double dx = box.x + x + 0.5 - cx, dy = box.y + y + 0.5 - cy;
                    m[y * box.w + x] = spot_weight(Math.sqrt(dx * dx + dy * dy), r, s.feather) * op;
                }
            }
            return m;
        }

        private bool mask_box(float[] mask, int w, int h, out HealRect box) {
            int x0 = w, y0 = h, x1 = -1, y1 = -1;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    if (mask[y * w + x] <= 0.001f) continue;
                    if (x < x0) x0 = x;
                    if (x > x1) x1 = x;
                    if (y < y0) y0 = y;
                    if (y > y1) y1 = y;
                }
            }
            box = HealRect();
            if (x1 < 0) return false;
            box.x = x0;
            box.y = y0;
            box.w = x1 - x0 + 1;
            box.h = y1 - y0 + 1;
            return true;
        }

        private float[] crop_mask(float[] mask, int w, HealRect b) {
            var m = new float[b.w * b.h];
            for (int y = 0; y < b.h; y++)
                for (int x = 0; x < b.w; x++) m[y * b.w + x] = mask[(b.y + y) * w + b.x + x];
            return m;
        }

        public void membrane(float[] values, int channels, uint8[] unknown, int w, int h) {
            int count = 0;
            foreach (var u in unknown) if (u != 0) count++;
            if (count == 0) return;
            if (w >= 24 && h >= 24 && count > 256) {
                int cw = (w + 1) / 2, ch = (h + 1) / 2;
                var cv = new float[cw * ch * channels];
                var cu = new uint8[cw * ch];
                for (int y = 0; y < ch; y++) {
                    for (int x = 0; x < cw; x++) {
                        int known = 0;
                        var acc = new float[channels];
                        bool any_unknown = false;
                        for (int j = 0; j < 2; j++) {
                            for (int i = 0; i < 2; i++) {
                                int fx = int.min(x * 2 + i, w - 1), fy = int.min(y * 2 + j, h - 1);
                                int fi = fy * w + fx;
                                if (unknown[fi] != 0) {
                                    any_unknown = true;
                                    continue;
                                }
                                known++;
                                for (int c = 0; c < channels; c++) acc[c] += values[fi * channels + c];
                            }
                        }
                        cu[y * cw + x] = any_unknown || known == 0 ? 1 : 0;
                        for (int c = 0; c < channels; c++) cv[(y * cw + x) * channels + c] = known > 0 ? acc[c] / known : 0;
                    }
                }
                bool border_known = false;
                for (int i = 0; i < cu.length; i++) if (cu[i] == 0) { border_known = true; break; }
                if (border_known) {
                    membrane(cv, channels, cu, cw, ch);
                    for (int y = 0; y < h; y++) {
                        for (int x = 0; x < w; x++) {
                            int i = y * w + x;
                            if (unknown[i] == 0) continue;
                            double fx = ((x + 0.5) / 2 - 0.5).clamp(0, cw - 1), fy = ((y + 0.5) / 2 - 0.5).clamp(0, ch - 1);
                            int x0 = (int) fx, y0 = (int) fy, x1 = int.min(x0 + 1, cw - 1), y1 = int.min(y0 + 1, ch - 1);
                            float tx = (float) (fx - x0), ty = (float) (fy - y0);
                            for (int c = 0; c < channels; c++) {
                                float top = cv[(y0 * cw + x0) * channels + c] * (1 - tx) + cv[(y0 * cw + x1) * channels + c] * tx;
                                float bot = cv[(y1 * cw + x0) * channels + c] * (1 - tx) + cv[(y1 * cw + x1) * channels + c] * tx;
                                values[i * channels + c] = top * (1 - ty) + bot * ty;
                            }
                        }
                    }
                    sor(values, channels, unknown, w, h, 60);
                    return;
                }
            }
            var mean = new double[channels];
            int n = 0;
            for (int i = 0; i < w * h; i++) {
                if (unknown[i] != 0) continue;
                for (int c = 0; c < channels; c++) mean[c] += values[i * channels + c];
                n++;
            }
            for (int i = 0; i < w * h; i++) {
                if (unknown[i] == 0) continue;
                for (int c = 0; c < channels; c++) values[i * channels + c] = n > 0 ? (float) (mean[c] / n) : 0;
            }
            sor(values, channels, unknown, w, h, int.max(80, int.min(3000, 3 * int.max(w, h))));
        }

        private void sor(float[] v, int channels, uint8[] unknown, int w, int h, int iterations) {
            const float OMEGA = 1.85f;
            for (int it = 0; it < iterations; it++) {
                float change = 0;
                for (int color = 0; color < 2; color++) {
                    for (int y = 0; y < h; y++) {
                        for (int x = (y + color) & 1; x < w; x += 2) {
                            int i = y * w + x;
                            if (unknown[i] == 0) continue;
                            for (int c = 0; c < channels; c++) {
                                float sum = 0;
                                int cnt = 0;
                                if (x > 0) { sum += v[(i - 1) * channels + c]; cnt++; }
                                if (x < w - 1) { sum += v[(i + 1) * channels + c]; cnt++; }
                                if (y > 0) { sum += v[(i - w) * channels + c]; cnt++; }
                                if (y < h - 1) { sum += v[(i + w) * channels + c]; cnt++; }
                                if (cnt == 0) continue;
                                float old = v[i * channels + c];
                                float nv = old + OMEGA * (sum / cnt - old);
                                change = float.max(change, (nv - old).abs());
                                v[i * channels + c] = nv;
                            }
                        }
                    }
                }
                if (change < 1e-5f) break;
            }
        }

        private void heal_box(FloatImage img, FloatImage src, HealRect b, float[] m, int dx, int dy) {
            int pad = 2;
            int bx = int.max(0, b.x - pad), by = int.max(0, b.y - pad);
            int bx1 = int.min(img.width, b.x + b.w + pad), by1 = int.min(img.height, b.y + b.h + pad);
            int w = bx1 - bx, h = by1 - by;
            var values = new float[w * h * 3];
            var unknown = new uint8[w * h];
            var soft = new float[w * h];
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int ix = bx + x, iy = by + y;
                    int mx = ix - b.x, my = iy - b.y;
                    float mv = mx >= 0 && my >= 0 && mx < b.w && my < b.h ? m[my * b.w + mx] : 0;
                    soft[y * w + x] = mv;
                    unknown[y * w + x] = mv > 0.001f ? 1 : 0;
                    size_t di = img.offset(ix, iy);
                    size_t si = src.offset((ix + dx).clamp(0, src.width - 1), (iy + dy).clamp(0, src.height - 1));
                    for (int c = 0; c < 3; c++) values[(y * w + x) * 3 + c] = img.data[di + c] - src.data[si + c];
                }
            }
            membrane(values, 3, unknown, w, h);
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    float mv = soft[y * w + x];
                    if (mv <= 0.001f) continue;
                    int ix = bx + x, iy = by + y;
                    size_t di = img.offset(ix, iy);
                    size_t si = src.offset((ix + dx).clamp(0, src.width - 1), (iy + dy).clamp(0, src.height - 1));
                    for (int c = 0; c < 3; c++) {
                        float healed = src.data[si + c] + values[(y * w + x) * 3 + c];
                        img.data[di + c] = img.data[di + c] * (1 - mv) + healed * mv;
                    }
                }
            }
        }

        private void clone_box(FloatImage dst, FloatImage src, HealRect b, float[] m, int dx, int dy) {
            for (int y = 0; y < b.h; y++) {
                for (int x = 0; x < b.w; x++) {
                    float mv = m[y * b.w + x];
                    if (mv <= 0) continue;
                    int ix = b.x + x, iy = b.y + y;
                    size_t di = dst.offset(ix, iy);
                    size_t si = src.offset((ix + dx).clamp(0, src.width - 1), (iy + dy).clamp(0, src.height - 1));
                    for (int c = 0; c < 4; c++) dst.data[di + c] = dst.data[di + c] * (1 - mv) + src.data[si + c] * mv;
                }
            }
        }

        public void find_source(FloatImage img, SpotEdit spot) {
            int iw = img.width, ih = img.height;
            double r = double.max(1.0, spot.radius * int.max(iw, ih));
            double cx = spot.x * iw, cy = spot.y * ih;
            double best = double.MAX;
            double bx = cx + 2.5 * r, by = cy;
            double[] factors = { 2.2, 3.0, 4.0, 5.5 };
            int samples = 48;
            var ring_a = new float[samples * 2 * 3];
            for (int k = 0; k < samples * 2; k++) {
                double ang = 2 * Math.PI * (k % samples) / samples;
                double rr = r * (k < samples ? 1.15 : 1.45);
                float cr, cg, cb, ca;
                img.sample(cx + Math.cos(ang) * rr, cy + Math.sin(ang) * rr, out cr, out cg, out cb, out ca);
                ring_a[k * 3] = Transfer.linear_to_srgb(cr);
                ring_a[k * 3 + 1] = Transfer.linear_to_srgb(cg);
                ring_a[k * 3 + 2] = Transfer.linear_to_srgb(cb);
            }
            foreach (double f in factors) {
                for (int a = 0; a < 32; a++) {
                    double ang = 2 * Math.PI * a / 32;
                    double sx = cx + Math.cos(ang) * r * f, sy = cy + Math.sin(ang) * r * f;
                    if (sx - r * 1.5 < 0 || sy - r * 1.5 < 0 || sx + r * 1.5 > iw || sy + r * 1.5 > ih) continue;
                    double score = 0;
                    for (int k = 0; k < samples * 2; k++) {
                        double ra = 2 * Math.PI * (k % samples) / samples;
                        double rr = r * (k < samples ? 1.15 : 1.45);
                        float pr, pg, pb, pa;
                        img.sample(sx + Math.cos(ra) * rr, sy + Math.sin(ra) * rr, out pr, out pg, out pb, out pa);
                        double d0 = Transfer.linear_to_srgb(pr) - ring_a[k * 3];
                        double d1 = Transfer.linear_to_srgb(pg) - ring_a[k * 3 + 1];
                        double d2 = Transfer.linear_to_srgb(pb) - ring_a[k * 3 + 2];
                        score += d0 * d0 + d1 * d1 + d2 * d2;
                    }
                    double interior = 0;
                    float mr, mg, mb, ma;
                    img.sample(sx, sy, out mr, out mg, out mb, out ma);
                    for (int k = 0; k < 12; k++) {
                        double ra = 2 * Math.PI * k / 12;
                        float pr, pg, pb, pa;
                        img.sample(sx + Math.cos(ra) * r * 0.6, sy + Math.sin(ra) * r * 0.6, out pr, out pg, out pb, out pa);
                        double d = Transfer.linear_to_srgb(pr) - Transfer.linear_to_srgb(mr) + Transfer.linear_to_srgb(pg) - Transfer.linear_to_srgb(mg);
                        interior += d * d;
                    }
                    score = score / (samples * 2) + interior / 12 * 0.5 + 0.0005 * f;
                    if (score < best) {
                        best = score;
                        bx = sx;
                        by = sy;
                    }
                }
            }
            spot.source_x = (bx / iw).clamp(0, 1);
            spot.source_y = (by / ih).clamp(0, 1);
        }

        public void spot(FloatImage img, SpotEdit spot) {
            if (spot.auto_source && (spot.source_x - spot.x).abs() < 1e-9 && (spot.source_y - spot.y).abs() < 1e-9) find_source(img, spot);
            HealRect b;
            var m = spot_mask(spot, img.width, img.height, out b);
            int dx = (int) Math.round((spot.source_x - spot.x) * img.width);
            int dy = (int) Math.round((spot.source_y - spot.y) * img.height);
            switch (spot.mode) {
                case "clone":
                    var src = img.copy();
                    clone_box(img, src, b, m, dx, dy);
                    break;
                case "fill":
                    var full = new float[img.pixel_count()];
                    for (int y = 0; y < b.h; y++)
                        for (int x = 0; x < b.w; x++) full[(b.y + y) * img.width + b.x + x] = m[y * b.w + x];
                    fill_region(img, full);
                    break;
                default:
                    var src2 = img.copy();
                    heal_box(img, src2, b, m, dx, dy);
                    break;
            }
        }

        public void clone_region(FloatImage dst, FloatImage src, float[] mask, int dx, int dy) {
            HealRect b;
            if (!mask_box(mask, dst.width, dst.height, out b)) return;
            clone_box(dst, src, b, crop_mask(mask, dst.width, b), dx, dy);
        }

        public void heal_region(FloatImage img, float[] mask, int dx, int dy) {
            HealRect b;
            if (!mask_box(mask, img.width, img.height, out b)) return;
            var src = img.copy();
            heal_box(img, src, b, crop_mask(mask, img.width, b), dx, dy);
        }

        private class Level : Object {
            public int w;
            public int h;
            public float[] px;
            public uint8[] hole;
            public int[] valid_list;
            public uint8[] valid;
        }

        private Level make_level(int w, int h, float[] px, uint8[] hole) {
            var l = new Level();
            l.w = w;
            l.h = h;
            l.px = px;
            l.hole = hole;
            var integral = new int[(w + 1) * (h + 1)];
            for (int y = 0; y < h; y++) {
                int row = 0;
                for (int x = 0; x < w; x++) {
                    row += hole[y * w + x];
                    integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row;
                }
            }
            l.valid = new uint8[w * h];
            int[] list = {};
            int pr = PATCH_RADIUS;
            for (int y = pr; y < h - pr; y++) {
                for (int x = pr; x < w - pr; x++) {
                    int x0 = x - pr, y0 = y - pr, x1 = x + pr + 1, y1 = y + pr + 1;
                    int s = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0];
                    if (s == 0) {
                        l.valid[y * w + x] = 1;
                        list += y * w + x;
                    }
                }
            }
            l.valid_list = list;
            return l;
        }

        private float patch_distance(Level l, int t, int s, float limit) {
            int w = l.w, h = l.h;
            int tx = t % w, ty = t / w, sx = s % w, sy = s / w;
            float d = 0;
            int pr = PATCH_RADIUS;
            for (int j = -pr; j <= pr; j++) {
                int yt = ty + j;
                if (yt < 0 || yt >= h) continue;
                int ys = sy + j;
                for (int i = -pr; i <= pr; i++) {
                    int xt = tx + i;
                    if (xt < 0 || xt >= w) continue;
                    int a = (yt * w + xt) * 3, b = (ys * w + sx + i) * 3;
                    float d0 = l.px[a] - l.px[b], d1 = l.px[a + 1] - l.px[b + 1], d2 = l.px[a + 2] - l.px[b + 2];
                    d += d0 * d0 + d1 * d1 + d2 * d2;
                }
                if (d > limit) return d;
            }
            return d;
        }

        private void patchmatch(Level l, int[] nnf, float[] dist, int[] targets, int iterations, uint seed) {
            int w = l.w, h = l.h;
            int nvalid = l.valid_list.length;
            for (int it = 0; it < iterations; it++) {
                bool forward = it % 2 == 0;
                int iter = it;
                int nt = targets.length;
                Parallel.range(nt, (start, end) => {
                    uint32 rng = AlgoUtil.hash((uint32) (start * 7919 + iter * 104729) ^ seed);
                    for (int k = 0; k < end - start; k++) {
                        int idx = forward ? start + k : end - 1 - k;
                        int t = targets[idx];
                        int tx = t % w, ty = t / w;
                        int best = nnf[t];
                        float bd = dist[t];
                        int step = forward ? -1 : 1;
                        int[] neigh = { tx + step >= 0 && tx + step < w ? t + step : -1, ty + step >= 0 && ty + step < h ? t + step * w : -1 };
                        for (int q = 0; q < 2; q++) {
                            int n = neigh[q];
                            if (n < 0 || nnf[n] < 0) continue;
                            int cand = nnf[n] - (q == 0 ? step : step * w);
                            int cx = cand % w;
                            if (cand < 0 || cand >= w * h || (cx - (nnf[n] % w)).abs() > 1 && q == 0) continue;
                            if (l.valid[cand] == 0 || cand == best) continue;
                            float cd = patch_distance(l, t, cand, bd);
                            if (cd < bd) {
                                bd = cd;
                                best = cand;
                            }
                        }
                        int radius = int.max(w, h);
                        int bx = best % w, by = best / w;
                        while (radius >= 1) {
                            rng = AlgoUtil.hash(rng + 0x9e3779b9u);
                            int rx = bx + (int) (rng % (uint) (2 * radius + 1)) - radius;
                            rng = AlgoUtil.hash(rng + 0x85ebca6bu);
                            int ry = by + (int) (rng % (uint) (2 * radius + 1)) - radius;
                            if (rx >= 0 && ry >= 0 && rx < w && ry < h) {
                                int cand = ry * w + rx;
                                if (l.valid[cand] != 0 && cand != best) {
                                    float cd = patch_distance(l, t, cand, bd);
                                    if (cd < bd) {
                                        bd = cd;
                                        best = cand;
                                        bx = rx;
                                        by = ry;
                                    }
                                }
                            }
                            radius /= 2;
                        }
                        if (nvalid > 0) {
                            rng = AlgoUtil.hash(rng + 0xc2b2ae35u);
                            int cand = l.valid_list[rng % (uint) nvalid];
                            float cd = patch_distance(l, t, cand, bd);
                            if (cd < bd) {
                                bd = cd;
                                best = cand;
                            }
                        }
                        nnf[t] = best;
                        dist[t] = bd;
                    }
                }, 16);
            }
        }

        private void vote(Level l, int[] nnf) {
            int w = l.w, h = l.h;
            int pr = PATCH_RADIUS;
            var result = l.px.copy();
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        int p = y * w + x;
                        if (l.hole[p] == 0) continue;
                        float r = 0, g = 0, b = 0, wsum = 0;
                        for (int j = -pr; j <= pr; j++) {
                            int ty = y - j;
                            if (ty < 0 || ty >= h) continue;
                            for (int i = -pr; i <= pr; i++) {
                                int tx = x - i;
                                if (tx < 0 || tx >= w) continue;
                                int s = nnf[ty * w + tx];
                                if (s < 0) continue;
                                int sx = s % w + i, sy = s / w + j;
                                int si = (sy * w + sx) * 3;
                                r += l.px[si];
                                g += l.px[si + 1];
                                b += l.px[si + 2];
                                wsum += 1;
                            }
                        }
                        if (wsum > 0) {
                            result[p * 3] = r / wsum;
                            result[p * 3 + 1] = g / wsum;
                            result[p * 3 + 2] = b / wsum;
                        }
                    }
                }
            });
            l.px = result;
        }

        private int[] targets_for(Level l) {
            int w = l.w, h = l.h, pr = PATCH_RADIUS;
            int[] list = {};
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    bool near = false;
                    for (int j = -pr; j <= pr && !near; j++) {
                        int yy = y + j;
                        if (yy < 0 || yy >= h) continue;
                        for (int i = -pr; i <= pr; i++) {
                            int xx = x + i;
                            if (xx >= 0 && xx < w && l.hole[yy * w + xx] != 0) {
                                near = true;
                                break;
                            }
                        }
                    }
                    if (near) list += y * w + x;
                }
            }
            return list;
        }

        public void fill_region(FloatImage img, float[] mask) {
            HealRect hb;
            if (!mask_box(mask, img.width, img.height, out hb)) return;
            int margin = int.max(PATCH_RADIUS * 6, int.max(hb.w, hb.h));
            int wx = int.max(0, hb.x - margin), wy = int.max(0, hb.y - margin);
            int wx1 = int.min(img.width, hb.x + hb.w + margin), wy1 = int.min(img.height, hb.y + hb.h + margin);
            int w = wx1 - wx, h = wy1 - wy;
            var px = new float[w * h * 3];
            var hole = new uint8[w * h];
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    size_t o = img.offset(wx + x, wy + y);
                    for (int c = 0; c < 3; c++) px[(y * w + x) * 3 + c] = Transfer.linear_to_srgb(img.data[o + c]);
                    hole[y * w + x] = mask[(wy + y) * img.width + wx + x] > 0.02f ? 1 : 0;
                }
            }
            var levels = new Gee.ArrayList<Level>();
            levels.add(make_level(w, h, px, hole));
            while (true) {
                var top = levels[levels.size - 1];
                HealRect tb;
                var fm = new float[top.hole.length];
                for (int i = 0; i < fm.length; i++) fm[i] = top.hole[i];
                if (!mask_box(fm, top.w, top.h, out tb)) break;
                if (int.max(tb.w, tb.h) <= 14 || top.w < 40 || top.h < 40) break;
                int nw = (top.w + 1) / 2, nh = (top.h + 1) / 2;
                var npx = new float[nw * nh * 3];
                var nhole = new uint8[nw * nh];
                for (int y = 0; y < nh; y++) {
                    for (int x = 0; x < nw; x++) {
                        float r = 0, g = 0, b = 0;
                        int cnt = 0;
                        uint8 hv = 0;
                        for (int j = 0; j < 2; j++) {
                            for (int i = 0; i < 2; i++) {
                                int fx = int.min(x * 2 + i, top.w - 1), fy = int.min(y * 2 + j, top.h - 1);
                                int fi = fy * top.w + fx;
                                if (top.hole[fi] != 0) hv = 1;
                                r += top.px[fi * 3];
                                g += top.px[fi * 3 + 1];
                                b += top.px[fi * 3 + 2];
                                cnt++;
                            }
                        }
                        npx[(y * nw + x) * 3] = r / cnt;
                        npx[(y * nw + x) * 3 + 1] = g / cnt;
                        npx[(y * nw + x) * 3 + 2] = b / cnt;
                        nhole[y * nw + x] = hv;
                    }
                }
                levels.add(make_level(nw, nh, npx, nhole));
            }
            int[]? prev_nnf = null;
            Level? prev = null;
            for (int li = levels.size - 1; li >= 0; li--) {
                var l = levels[li];
                if (prev == null) {
                    membrane(l.px, 3, l.hole, l.w, l.h);
                } else {
                    for (int y = 0; y < l.h; y++) {
                        for (int x = 0; x < l.w; x++) {
                            int p = y * l.w + x;
                            if (l.hole[p] == 0) continue;
                            double fx = ((x + 0.5) / 2 - 0.5).clamp(0, prev.w - 1), fy = ((y + 0.5) / 2 - 0.5).clamp(0, prev.h - 1);
                            int x0 = (int) fx, y0 = (int) fy, x1 = int.min(x0 + 1, prev.w - 1), y1 = int.min(y0 + 1, prev.h - 1);
                            float tx = (float) (fx - x0), ty = (float) (fy - y0);
                            for (int c = 0; c < 3; c++) {
                                float top = prev.px[(y0 * prev.w + x0) * 3 + c] * (1 - tx) + prev.px[(y0 * prev.w + x1) * 3 + c] * tx;
                                float bot = prev.px[(y1 * prev.w + x0) * 3 + c] * (1 - tx) + prev.px[(y1 * prev.w + x1) * 3 + c] * tx;
                                l.px[p * 3 + c] = top * (1 - ty) + bot * ty;
                            }
                        }
                    }
                }
                if (l.valid_list.length == 0) {
                    prev_nnf = null;
                    prev = l;
                    continue;
                }
                var targets = targets_for(l);
                var nnf = new int[l.w * l.h];
                var dist = new float[l.w * l.h];
                for (int i = 0; i < nnf.length; i++) nnf[i] = -1;
                uint32 rng = 12345u + (uint32) li;
                foreach (int t in targets) {
                    int cand = -1;
                    if (prev_nnf != null && prev != null) {
                        int tx = t % l.w, ty = t / l.w;
                        int cx = int.min(tx / 2, prev.w - 1), cy = int.min(ty / 2, prev.h - 1);
                        int cs = prev_nnf[cy * prev.w + cx];
                        if (cs >= 0) {
                            int sx = (cs % prev.w) * 2 + (tx - cx * 2), sy = (cs / prev.w) * 2 + (ty - cy * 2);
                            if (sx >= 0 && sy >= 0 && sx < l.w && sy < l.h && l.valid[sy * l.w + sx] != 0) cand = sy * l.w + sx;
                        }
                    }
                    if (cand < 0) {
                        if (l.valid[t] != 0 && l.hole[t] == 0) {
                            cand = t;
                        } else {
                            rng = AlgoUtil.hash(rng + (uint32) t);
                            cand = l.valid_list[rng % (uint) l.valid_list.length];
                        }
                    }
                    nnf[t] = cand;
                }
                int iterations = li == levels.size - 1 ? 8 : (li == 0 ? 3 : 5);
                for (int em = 0; em < iterations; em++) {
                    foreach (int t in targets) dist[t] = patch_distance(l, t, nnf[t], float.MAX);
                    patchmatch(l, nnf, dist, targets, 3, (uint) (li * 31 + em));
                    vote(l, nnf);
                }
                prev_nnf = nnf;
                prev = l;
            }
            var fin = levels[0];
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    float mv = mask[(wy + y) * img.width + wx + x].clamp(0, 1);
                    if (mv <= 0.001f) continue;
                    size_t o = img.offset(wx + x, wy + y);
                    for (int c = 0; c < 3; c++) {
                        float v = Transfer.srgb_to_linear(fin.px[(y * w + x) * 3 + c]);
                        img.data[o + c] = img.data[o + c] * (1 - mv) + v * mv;
                    }
                }
            }
        }
    }
}
