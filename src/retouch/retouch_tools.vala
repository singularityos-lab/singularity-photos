using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace RetouchBrush {

        public float falloff(double d, double radius, double hardness) {
            if (d >= radius) return 0;
            double inner = radius * hardness.clamp(0, 0.999);
            if (d <= inner) return 1;
            double t = (d - inner) / (radius - inner);
            return (float) (1 - t * t * (3 - 2 * t));
        }

        public void paint_dab(FloatImage img, int ox, int oy, double cx, double cy, double radius, double hardness,
                              float r, float g, float b, float opacity, float[]? selection, int sel_w, bool erase) {
            int x0 = (int) Math.floor(cx - radius), x1 = (int) Math.ceil(cx + radius);
            int y0 = (int) Math.floor(cy - radius), y1 = (int) Math.ceil(cy + radius);
            for (int y = y0; y <= y1; y++) {
                int ly = y - oy;
                if (ly < 0 || ly >= img.height) continue;
                for (int x = x0; x <= x1; x++) {
                    int lx = x - ox;
                    if (lx < 0 || lx >= img.width) continue;
                    double d = Math.sqrt((x + 0.5 - cx) * (x + 0.5 - cx) + (y + 0.5 - cy) * (y + 0.5 - cy));
                    float wgt = falloff(d, radius, hardness) * opacity;
                    if (selection != null && x >= 0 && y >= 0 && x < sel_w && (size_t) y * sel_w + x < selection.length) wgt *= selection[(size_t) y * sel_w + x];
                    if (wgt <= 0) continue;
                    size_t i = img.offset(lx, ly);
                    if (erase) {
                        img.data[i + 3] *= 1 - wgt;
                        continue;
                    }
                    float a = img.data[i + 3];
                    float na = a + wgt * (1 - a);
                    if (na <= 1e-6f) continue;
                    img.data[i] = (img.data[i] * a * (1 - wgt) + r * wgt) / na;
                    img.data[i + 1] = (img.data[i + 1] * a * (1 - wgt) + g * wgt) / na;
                    img.data[i + 2] = (img.data[i + 2] * a * (1 - wgt) + b * wgt) / na;
                    img.data[i + 3] = na;
                }
            }
        }

        public void mask_dab(float[] mask, int w, int h, double cx, double cy, double radius, double hardness, float value, float opacity) {
            int x0 = int.max(0, (int) Math.floor(cx - radius)), x1 = int.min(w - 1, (int) Math.ceil(cx + radius));
            int y0 = int.max(0, (int) Math.floor(cy - radius)), y1 = int.min(h - 1, (int) Math.ceil(cy + radius));
            for (int y = y0; y <= y1; y++) {
                for (int x = x0; x <= x1; x++) {
                    double d = Math.sqrt((x + 0.5 - cx) * (x + 0.5 - cx) + (y + 0.5 - cy) * (y + 0.5 - cy));
                    float wgt = falloff(d, radius, hardness) * opacity;
                    if (wgt <= 0) continue;
                    size_t i = (size_t) y * w + x;
                    mask[i] = mask[i] + (value - mask[i]) * wgt;
                }
            }
        }

        public void clone_dab(FloatImage dst, int ox, int oy, FloatImage src, double cx, double cy, double sdx, double sdy,
                              double radius, double hardness, float opacity, float[]? selection, int sel_w, float[]? stroke_mask) {
            int x0 = (int) Math.floor(cx - radius), x1 = (int) Math.ceil(cx + radius);
            int y0 = (int) Math.floor(cy - radius), y1 = (int) Math.ceil(cy + radius);
            for (int y = y0; y <= y1; y++) {
                int ly = y - oy;
                if (ly < 0 || ly >= dst.height) continue;
                for (int x = x0; x <= x1; x++) {
                    int lx = x - ox;
                    if (lx < 0 || lx >= dst.width) continue;
                    double sx = x + 0.5 + sdx, sy = y + 0.5 + sdy;
                    if (sx < 0 || sy < 0 || sx >= src.width || sy >= src.height) continue;
                    double d = Math.sqrt((x + 0.5 - cx) * (x + 0.5 - cx) + (y + 0.5 - cy) * (y + 0.5 - cy));
                    float wgt = falloff(d, radius, hardness) * opacity;
                    if (selection != null && x >= 0 && y >= 0 && x < sel_w) wgt *= selection[(size_t) y * sel_w + x];
                    if (wgt <= 0) continue;
                    if (stroke_mask != null) {
                        size_t mi = (size_t) ly * dst.width + lx;
                        stroke_mask[mi] = float.max(stroke_mask[mi], wgt);
                    }
                    float r, g, b, a;
                    src.sample(sx, sy, out r, out g, out b, out a);
                    size_t i = dst.offset(lx, ly);
                    dst.data[i] += (r - dst.data[i]) * wgt;
                    dst.data[i + 1] += (g - dst.data[i + 1]) * wgt;
                    dst.data[i + 2] += (b - dst.data[i + 2]) * wgt;
                    dst.data[i + 3] += (a - dst.data[i + 3]) * wgt;
                }
            }
        }

        public void stroke(double x0, double y0, double x1, double y1, double spacing, owned DabFunc dab) {
            double len = Math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
            int n = int.max(1, (int) Math.ceil(len / double.max(0.5, spacing)));
            for (int i = 1; i <= n; i++) {
                double t = (double) i / n;
                dab(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t);
            }
        }

        public delegate void DabFunc(double x, double y);
    }

    namespace RetouchOps {

        public RetouchLayer[] frequency_separation(RetouchDocument doc, RetouchLayer layer, double radius) {
            var src = doc.render_layer_pixels(layer);
            var encoded = src.copy();
            RetouchColor.working_to_encoded(encoded);
            var low = Filters.gaussian(encoded, radius, false);
            var high = encoded.copy();
            size_t n = high.pixel_count();
            for (size_t i = 0; i < n; i++) {
                for (int c = 0; c < 3; c++) high.data[i * 4 + c] = ((encoded.data[i * 4 + c] - low.data[i * 4 + c]) / 2 + 0.5f).clamp(0, 1);
                high.data[i * 4 + 3] = encoded.data[i * 4 + 3];
                low.data[i * 4 + 3] = encoded.data[i * 4 + 3];
            }
            RetouchColor.encoded_to_working(low);
            RetouchColor.encoded_to_working(high);
            var low_layer = new RetouchLayer(_("Low Frequency"), RetouchLayerKind.RASTER);
            low_layer.pixels = low;
            var high_layer = new RetouchLayer(_("High Frequency"), RetouchLayerKind.RASTER);
            high_layer.pixels = high;
            high_layer.mode = BlendMode.LINEAR_LIGHT;
            return { low_layer, high_layer };
        }

        public float[] selection_in_layer(RetouchDocument doc, RetouchLayer layer, float[] selection) {
            int w = layer.pixels.width, h = layer.pixels.height;
            var plane = new float[(size_t) w * h];
            for (int y = 0; y < h; y++) {
                int dy = y + layer.y;
                if (dy < 0 || dy >= doc.height) continue;
                for (int x = 0; x < w; x++) {
                    int dx = x + layer.x;
                    if (dx < 0 || dx >= doc.width) continue;
                    plane[(size_t) y * w + x] = selection[(size_t) dy * doc.width + dx];
                }
            }
            return plane;
        }

        public void content_aware_fill(RetouchDocument doc, RetouchLayer layer, float[] selection) {
            var mask = selection_in_layer(doc, layer, selection);
            var hard = new float[mask.length];
            for (size_t i = 0; i < mask.length; i++) hard[i] = mask[i] > 0.02f ? 1 : 0;
            var grown = RetouchSelection.expand(hard, layer.pixels.width, layer.pixels.height, 2);
            Heal.fill_region(layer.pixels, grown);
        }

        public FloatImage fill_variant(FloatImage img, float[] mask, int variant, out int ox, out int oy) {
            int w = img.width, h = img.height;
            int bx, by, bw, bh;
            ox = 0;
            oy = 0;
            if (!RetouchSelection.bounds(mask, w, h, out bx, out by, out bw, out bh)) return img.copy();
            if (variant == 0) {
                var full = img.copy();
                Heal.fill_region(full, mask);
                return full;
            }
            var rand = new Rand.with_seed((uint32) (variant * 7919 + bw * 31 + bh));
            double reach = 1.0 + variant * 0.6 + rand.next_double() * 0.8;
            int side = (int) (int.max(bw, bh) * reach) + 24;
            int jx = (int) ((rand.next_double() - 0.5) * side), jy = (int) ((rand.next_double() - 0.5) * side);
            int x0 = (bx - side + jx).clamp(0, bx), y0 = (by - side + jy).clamp(0, by);
            int x1 = (bx + bw + side + jx).clamp(bx + bw, w), y1 = (by + bh + side + jy).clamp(by + bh, h);
            int cw = x1 - x0, ch = y1 - y0;
            var crop = img.cropped(x0, y0, cw, ch);
            var crop_mask = RetouchDocument.crop_plane(mask, w, x0, y0, cw, ch);
            bool flip = variant % 2 == 1;
            if (flip) {
                crop = crop.flipped_horizontal();
                var flipped = new float[crop_mask.length];
                for (int y = 0; y < ch; y++)
                    for (int x = 0; x < cw; x++) flipped[(size_t) y * cw + (cw - 1 - x)] = crop_mask[(size_t) y * cw + x];
                crop_mask = flipped;
            }
            Heal.fill_region(crop, crop_mask);
            if (flip) crop = crop.flipped_horizontal();
            ox = x0;
            oy = y0;
            return crop;
        }

        public void apply_variant(FloatImage img, float[] mask, FloatImage piece, int ox, int oy) {
            int w = img.width;
            for (int y = 0; y < piece.height; y++) {
                for (int x = 0; x < piece.width; x++) {
                    float m = mask[(size_t) (y + oy) * w + x + ox];
                    if (m <= 0) continue;
                    size_t d = img.offset(x + ox, y + oy), s2 = piece.offset(x, y);
                    for (int c = 0; c < 4; c++) img.data[d + c] += (piece.data[s2 + c] - img.data[d + c]) * m;
                }
            }
        }

        public void patch(RetouchDocument doc, RetouchLayer layer, float[] selection, int dx, int dy) {
            var mask = selection_in_layer(doc, layer, selection);
            var before = layer.pixels.copy();
            var img = layer.pixels;
            int w = img.width, h = img.height;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    float m = mask[(size_t) y * w + x];
                    if (m <= 0) continue;
                    int sx = (x + dx).clamp(0, w - 1), sy = (y + dy).clamp(0, h - 1);
                    size_t d = img.offset(x, y), s = before.offset(sx, sy);
                    for (int c = 0; c < 4; c++) img.data[d + c] += (before.data[s + c] - img.data[d + c]) * m;
                }
            }
            var hard = new float[mask.length];
            for (size_t i = 0; i < mask.length; i++) hard[i] = mask[i] > 0.02f ? 1 : 0;
            Heal.heal_region(img, hard, dx, dy);
        }

        public void fill_selection(RetouchLayer layer, RetouchDocument doc, float[] selection, float r, float g, float b, float a) {
            var mask = selection_in_layer(doc, layer, selection);
            var img = layer.pixels;
            for (size_t i = 0; i < mask.length; i++) {
                float m = mask[i];
                if (m <= 0) continue;
                img.data[i * 4] += (r - img.data[i * 4]) * m;
                img.data[i * 4 + 1] += (g - img.data[i * 4 + 1]) * m;
                img.data[i * 4 + 2] += (b - img.data[i * 4 + 2]) * m;
                img.data[i * 4 + 3] += (a - img.data[i * 4 + 3]) * m;
            }
        }

        public void clear_selection(RetouchLayer layer, RetouchDocument doc, float[] selection) {
            var mask = selection_in_layer(doc, layer, selection);
            for (size_t i = 0; i < mask.length; i++) layer.pixels.data[i * 4 + 3] *= 1 - mask[i];
        }

        public RetouchLayer layer_from_selection(RetouchDocument doc, RetouchLayer layer, float[] selection, bool cut) {
            var mask = selection_in_layer(doc, layer, selection);
            var copy_img = layer.pixels.copy();
            for (size_t i = 0; i < mask.length; i++) {
                copy_img.data[i * 4 + 3] *= mask[i];
                if (cut) layer.pixels.data[i * 4 + 3] *= 1 - mask[i];
            }
            var nl = new RetouchLayer(cut ? _("Cut Layer") : _("Layer via Copy"), RetouchLayerKind.RASTER);
            nl.pixels = copy_img;
            nl.x = layer.x;
            nl.y = layer.y;
            return nl;
        }
    }
}
