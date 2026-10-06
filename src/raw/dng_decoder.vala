using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class DngImage : Object {
        public int width;
        public int height;
        public int samples;
        public float[] data;
        public bool cfa = false;
        public CfaPattern pattern = new CfaPattern();
    }

    public class DngDecoder : Object, PhotoDecoder {
        public string id { get { return "dng"; } }

        public bool handles(string lower_name, uint8[] head) {
            if (!lower_name.has_suffix(".dng")) return false;
            return head.length >= 4 && ((head[0] == 'I' && head[1] == 'I') || (head[0] == 'M' && head[1] == 'M'));
        }

        public DecodedPhoto decode(File file, int max_side) throws Error {
            try {
                return decode_reader(TiffReader.from_file(file), file, max_side);
            } catch (IOError.NOT_SUPPORTED e) {
                if (LibRawDecoder.available()) return new LibRawDecoder().decode(file, max_side);
                throw e;
            }
        }

        public static TiffIfd? find_raw_ifd(TiffReader r) {
            TiffIfd? best = null;
            uint64 best_area = 0;
            foreach (var ifd in r.all_ifds()) {
                uint32 photometric = r.get_uint(ifd, 262);
                if (photometric != 32803 && photometric != 34892) continue;
                if ((r.get_uint(ifd, 254) & 1) != 0) continue;
                uint64 area = (uint64) r.get_uint(ifd, 256) * r.get_uint(ifd, 257);
                if (area > best_area) {
                    best = ifd;
                    best_area = area;
                }
            }
            return best;
        }

        public DecodedPhoto decode_reader(TiffReader r, File? file, int max_side) throws Error {
            var ifds = r.chain();
            if (ifds.size == 0) throw new IOError.INVALID_DATA(_("Not a DNG file"));
            var ifd0 = ifds[0];
            var raw_ifd = find_raw_ifd(r);
            if (raw_ifd == null) throw new IOError.INVALID_DATA(_("The DNG file has no raw image"));
            var img = read_samples(r, raw_ifd);
            linearize(r, raw_ifd, img);
            apply_active_area(r, raw_ifd, img);
            if (img.cfa) apply_gain_maps(r, raw_ifd, img);
            FloatImage camera;
            bool half = false;
            if (img.cfa) {
                half = max_side > 0 && img.pattern.is_bayer() && max_side * 2 <= int.max(img.width, img.height);
                camera = half ? superpixel(img) : Demosaic.run(img.data, img.width, img.height, img.pattern, "ppg");
            } else {
                camera = to_rgb(img);
            }
            apply_warp_opcodes(r, raw_ifd, ref camera);
            camera = default_crop(r, raw_ifd, camera, half ? 0.5 : 1.0);
            int orientation = (int) r.get_uint(ifd0, 274, 1);
            camera = ExifOrientation.apply(camera, orientation);
            int full_w = half ? camera.width * 2 : camera.width, full_h = half ? camera.height * 2 : camera.height;
            if (max_side > 0) camera = camera.scaled_to_fit(max_side);
            var raw = new DngRawData(camera);
            fill_color(r, ifd0, raw_ifd, raw);
            raw.decoder = "dng";
            raw.cfa_pattern = img.cfa ? img.pattern.name() : "linear";
            if (r.get_uint(raw_ifd, 339, 1) == 3) raw.clip_level = { float.MAX, float.MAX, float.MAX };
            var working = RawColor.develop(raw, raw.as_shot_multipliers[0], raw.as_shot_multipliers[1], raw.as_shot_multipliers[2], "reconstruct");
            var photo = new DecodedPhoto(working);
            photo.raw = raw;
            photo.format = "dng";
            photo.full_width = full_w;
            photo.full_height = full_h;
            if (file != null) photo.meta = MetadataReader.read(file);
            photo.meta.width = full_w;
            photo.meta.height = full_h;
            photo.meta.orientation = 1;
            return photo;
        }

        private static DngImage read_samples(TiffReader r, TiffIfd ifd) throws Error {
            var img = new DngImage();
            img.width = (int) r.get_uint(ifd, 256);
            img.height = (int) r.get_uint(ifd, 257);
            img.samples = (int) r.get_uint(ifd, 277, 1);
            if (img.width <= 0 || img.height <= 0 || img.samples <= 0 || img.width > 65535 || img.height > 65535) throw new IOError.INVALID_DATA(_("Invalid DNG image size"));
            int bits = (int) r.get_uint(ifd, 258, 16);
            int compression = (int) r.get_uint(ifd, 259, 1);
            int format = (int) r.get_uint(ifd, 339, 1);
            int predictor = (int) r.get_uint(ifd, 317, 1);
            uint32 photometric = r.get_uint(ifd, 262);
            img.cfa = photometric == 32803;
            if (img.cfa) {
                var dims = r.get_uints(ifd, 33421);
                var pat = r.get_bytes(ifd, 33422);
                var planes = r.get_bytes(ifd, 50710);
                int pw = dims.length >= 2 ? (int) dims[1] : 2, ph = dims.length >= 2 ? (int) dims[0] : 2;
                if (pat.length >= pw * ph && pw > 0 && ph > 0) {
                    var colors = new int[pw * ph];
                    for (int i = 0; i < pw * ph; i++) {
                        int c = pat[i];
                        if (planes.length >= 3) {
                            for (int k = 0; k < planes.length; k++) if (planes[k] == pat[i]) c = k;
                        }
                        colors[i] = c.clamp(0, 2);
                    }
                    img.pattern.width = pw;
                    img.pattern.height = ph;
                    img.pattern.colors = colors;
                }
            }
            size_t total = (size_t) img.width * img.height * img.samples;
            img.data = new float[total];
            bool tiled = ifd.has(322);
            int tw = tiled ? (int) r.get_uint(ifd, 322) : img.width;
            int th = tiled ? (int) r.get_uint(ifd, 323) : (int) uint32.min(r.get_uint(ifd, 278, img.height), img.height);
            if (tw <= 0 || th <= 0) throw new IOError.INVALID_DATA(_("Invalid DNG tile size"));
            var offsets = tiled ? r.get_uints(ifd, 324) : r.get_uints(ifd, 273);
            var counts = tiled ? r.get_uints(ifd, 325) : r.get_uints(ifd, 279);
            int across = tiled ? (img.width + tw - 1) / tw : 1;
            int down = (img.height + th - 1) / th;
            for (int t = 0; t < offsets.length && t < across * down; t++) {
                int tx = (t % across) * tw, ty = (t / across) * th;
                size_t off = r.base_offset + offsets[t];
                size_t len = t < counts.length ? counts[t] : r.data.length - off;
                if (!r.in_range(off, len)) continue;
                int rows = tiled ? th : int.min(th, img.height - ty);
                float[] tile = decode_tile(r, off, len, tw, rows, img.samples, bits, compression, format, predictor);
                for (int y = 0; y < rows; y++) {
                    int iy = ty + y;
                    if (iy >= img.height) break;
                    for (int x = 0; x < tw; x++) {
                        int ix = tx + x;
                        if (ix >= img.width) break;
                        for (int s = 0; s < img.samples; s++) {
                            size_t src = ((size_t) y * tw + x) * img.samples + s;
                            if (src < tile.length) img.data[((size_t) iy * img.width + ix) * img.samples + s] = tile[src];
                        }
                    }
                }
            }
            return img;
        }

        private static float[] decode_tile(TiffReader r, size_t off, size_t len, int tw, int th, int spp, int bits, int compression, int format, int predictor) throws Error {
            size_t n = (size_t) tw * th * spp;
            var out_v = new float[n];
            if (compression == 7) {
                int w, h, comps;
                var samples = Ljpeg.decode(r.data, off, len, out w, out h, out comps);
                size_t m = size_t.min(n, samples.length);
                if ((size_t) w * comps == (size_t) tw * spp || (size_t) w * h * comps >= n) {
                    for (size_t i = 0; i < m; i++) out_v[i] = samples[i];
                } else {
                    int row = w * comps;
                    for (int y = 0; y < h; y++)
                        for (int x = 0; x < row; x++) {
                            size_t di = (size_t) y * tw * spp + x;
                            if (di < n) out_v[di] = samples[(size_t) y * row + x];
                        }
                }
                return out_v;
            }
            uint8[] raw;
            if (compression == 8 || compression == 32946) {
                var inflated = IccExtract.inflate(r.data[off:off + len]);
                if (inflated == null) throw new IOError.INVALID_DATA(_("Corrupt compressed DNG tile"));
                raw = (owned) inflated;
            } else if (compression == 1) {
                raw = r.data[off:off + len];
            } else {
                throw new IOError.NOT_SUPPORTED(_("Unsupported DNG compression %d").printf(compression));
            }
            int bytes = bits / 8;
            if (format == 3 && (predictor == 3 || predictor == 34894 || predictor == 34895)) {
                raw = unshuffle_float(raw, tw * spp, th, bytes, r.little);
            }
            if (format == 3) {
                for (size_t i = 0; i < n; i++) {
                    size_t p = i * bytes;
                    if (p + bytes > raw.length) break;
                    if (bytes == 4) {
                        uint32 v = r.little ? (uint32) raw[p] | ((uint32) raw[p + 1] << 8) | ((uint32) raw[p + 2] << 16) | ((uint32) raw[p + 3] << 24)
                                            : ((uint32) raw[p] << 24) | ((uint32) raw[p + 1] << 16) | ((uint32) raw[p + 2] << 8) | (uint32) raw[p + 3];
                        if (predictor == 3 || predictor == 34894 || predictor == 34895) v = ((uint32) raw[p] << 24) | ((uint32) raw[p + 1] << 16) | ((uint32) raw[p + 2] << 8) | (uint32) raw[p + 3];
                        out_v[i] = *((float*) (&v));
                    } else if (bytes == 2) {
                        uint16 v = r.little ? (uint16) (raw[p] | (raw[p + 1] << 8)) : (uint16) ((raw[p] << 8) | raw[p + 1]);
                        if (predictor == 3 || predictor == 34894 || predictor == 34895) v = (uint16) ((raw[p] << 8) | raw[p + 1]);
                        out_v[i] = HalfFloat.to_float(v);
                    }
                }
                return out_v;
            }
            if (bits == 8) {
                for (size_t i = 0; i < n && i < raw.length; i++) out_v[i] = raw[i];
            } else if (bits == 16) {
                for (size_t i = 0; i < n && i * 2 + 1 < raw.length; i++)
                    out_v[i] = r.little ? (int) raw[i * 2] | ((int) raw[i * 2 + 1] << 8) : ((int) raw[i * 2] << 8) | (int) raw[i * 2 + 1];
            } else if (bits == 32) {
                for (size_t i = 0; i < n && i * 4 + 3 < raw.length; i++) {
                    size_t p = i * 4;
                    uint32 v = r.little ? (uint32) raw[p] | ((uint32) raw[p + 1] << 8) | ((uint32) raw[p + 2] << 16) | ((uint32) raw[p + 3] << 24)
                                        : ((uint32) raw[p] << 24) | ((uint32) raw[p + 1] << 16) | ((uint32) raw[p + 2] << 8) | (uint32) raw[p + 3];
                    out_v[i] = v;
                }
            } else {
                size_t row_bits = (size_t) tw * spp * bits;
                size_t row_bytes = (row_bits + 7) / 8;
                for (int y = 0; y < th; y++) {
                    size_t bitpos = (size_t) y * row_bytes * 8;
                    for (int x = 0; x < tw * spp; x++) {
                        uint32 v = 0;
                        for (int b = 0; b < bits; b++) {
                            size_t byte_i = bitpos >> 3;
                            if (byte_i >= raw.length) break;
                            v = (v << 1) | ((raw[byte_i] >> (7 - (int) (bitpos & 7))) & 1);
                            bitpos++;
                        }
                        out_v[(size_t) y * tw * spp + x] = v;
                    }
                }
            }
            if (predictor == 2) {
                for (int y = 0; y < th; y++)
                    for (int x = spp; x < tw * spp; x++) {
                        size_t i = (size_t) y * tw * spp + x;
                        out_v[i] = (float) (((uint32) out_v[i] + (uint32) out_v[i - spp]) & ((bits >= 32) ? 0xFFFFFFFF : ((1u << bits) - 1)));
                    }
            }
            return out_v;
        }

        private static uint8[] unshuffle_float(uint8[] raw, int row_samples, int rows, int bytes, bool little) {
            var out_b = new uint8[raw.length];
            size_t row_len = (size_t) row_samples * bytes;
            for (int y = 0; y < rows; y++) {
                size_t base_i = (size_t) y * row_len;
                if (base_i + row_len > raw.length) break;
                for (size_t i = 1; i < row_len; i++) raw[base_i + i] = raw[base_i + i] + raw[base_i + i - 1];
                for (int x = 0; x < row_samples; x++)
                    for (int b = 0; b < bytes; b++)
                        out_b[base_i + (size_t) x * bytes + b] = raw[base_i + (size_t) b * row_samples + x];
            }
            return out_b;
        }

        private static void linearize(TiffReader r, TiffIfd ifd, DngImage img) {
            var table = r.get_uints(ifd, 50712);
            int spp = img.samples;
            size_t n = (size_t) img.width * img.height;
            if (table.length > 0) {
                for (size_t i = 0; i < n * spp; i++) {
                    int v = ((int) img.data[i]).clamp(0, table.length - 1);
                    img.data[i] = table[v];
                }
            }
            var rep = r.get_uints(ifd, 50713);
            int rep_rows = rep.length >= 2 ? int.max(1, (int) rep[0]) : 1, rep_cols = rep.length >= 2 ? int.max(1, (int) rep[1]) : 1;
            var black = r.get_doubles(ifd, 50714);
            var dh = r.get_doubles(ifd, 50715);
            var dv = r.get_doubles(ifd, 50716);
            var white = r.get_doubles(ifd, 50717);
            int bits = (int) r.get_uint(ifd, 258, 16);
            bool is_float = r.get_uint(ifd, 339, 1) == 3;
            double default_white = is_float ? 1.0 : (bits >= 32 ? 4294967295.0 : (double) ((1u << bits) - 1));
            for (int y = 0; y < img.height; y++) {
                for (int x = 0; x < img.width; x++) {
                    for (int s = 0; s < spp; s++) {
                        size_t i = ((size_t) y * img.width + x) * spp + s;
                        double b = 0;
                        if (black.length > 0) {
                            int bi = ((y % rep_rows) * rep_cols + (x % rep_cols)) * spp + s;
                            b = black[bi % black.length];
                        }
                        if (dh.length > x) b += dh[x];
                        if (dv.length > y) b += dv[y];
                        double wl = white.length > s ? white[s] : (white.length > 0 ? white[0] : default_white);
                        double range = wl - b;
                        img.data[i] = range > 0 ? (float) ((img.data[i] - b) / range) : 0;
                        if (img.data[i] < 0) img.data[i] = 0;
                    }
                }
            }
        }

        private static void apply_active_area(TiffReader r, TiffIfd ifd, DngImage img) {
            var area = r.get_uints(ifd, 50829);
            if (area.length < 4) return;
            int top = (int) area[0], left = (int) area[1], bottom = (int) area[2], right = (int) area[3];
            if (top < 0 || left < 0 || bottom > img.height || right > img.width || bottom <= top || right <= left) return;
            if (top == 0 && left == 0 && bottom == img.height && right == img.width) return;
            int w = right - left, h = bottom - top;
            var data = new float[(size_t) w * h * img.samples];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w * img.samples; x++)
                    data[(size_t) y * w * img.samples + x] = img.data[((size_t) (y + top) * img.width + left) * img.samples + x];
            if (img.cfa) img.pattern = img.pattern.cropped(left % img.pattern.width, top % img.pattern.height);
            img.data = (owned) data;
            img.width = w;
            img.height = h;
        }

        private static FloatImage superpixel(DngImage img) {
            int w = img.width / 2, h = img.height / 2;
            var out_img = new FloatImage(w, h);
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        float r = 0, g = 0, b = 0;
                        int ng = 0;
                        for (int dy = 0; dy < 2; dy++) {
                            for (int dx = 0; dx < 2; dx++) {
                                int sx = x * 2 + dx, sy = y * 2 + dy;
                                float v = img.data[(size_t) sy * img.width + sx];
                                int c = img.pattern.at(sx, sy);
                                if (c == 0) r = v;
                                else if (c == 2) b = v;
                                else { g += v; ng++; }
                            }
                        }
                        size_t o = out_img.offset(x, y);
                        out_img.data[o] = r;
                        out_img.data[o + 1] = ng > 0 ? g / ng : 0;
                        out_img.data[o + 2] = b;
                        out_img.data[o + 3] = 1;
                    }
                }
            });
            return out_img;
        }

        private static FloatImage to_rgb(DngImage img) {
            var out_img = new FloatImage(img.width, img.height);
            size_t n = (size_t) img.width * img.height;
            for (size_t i = 0; i < n; i++) {
                for (int c = 0; c < 3; c++) out_img.data[i * 4 + c] = img.data[i * img.samples + int.min(c, img.samples - 1)];
                out_img.data[i * 4 + 3] = 1;
            }
            return out_img;
        }

        private static FloatImage default_crop(TiffReader r, TiffIfd ifd, FloatImage img, double scale) {
            var origin = r.get_doubles(ifd, 50719);
            var size = r.get_doubles(ifd, 50720);
            if (origin.length < 2 || size.length < 2) return img;
            int x = (int) Math.round(origin[0] * scale), y = (int) Math.round(origin[1] * scale);
            int w = (int) Math.round(size[0] * scale), h = (int) Math.round(size[1] * scale);
            if (w <= 0 || h <= 0 || x + w > img.width || y + h > img.height) return img;
            if (x == 0 && y == 0 && w == img.width && h == img.height) return img;
            return img.cropped(x, y, w, h);
        }

        private static double be_double(uint8[] d, size_t p) {
            uint64 v = 0;
            for (int i = 0; i < 8; i++) v = (v << 8) | d[p + i];
            return *((double*) (&v));
        }

        private static uint32 be_u32(uint8[] d, size_t p) {
            return ((uint32) d[p] << 24) | ((uint32) d[p + 1] << 16) | ((uint32) d[p + 2] << 8) | d[p + 3];
        }

        private static float be_float(uint8[] d, size_t p) {
            uint32 v = be_u32(d, p);
            return *((float*) (&v));
        }

        private static void apply_gain_maps(TiffReader r, TiffIfd ifd, DngImage img) {
            var list = r.get_bytes(ifd, 51009);
            if (list.length < 4) return;
            uint32 count = be_u32(list, 0);
            size_t p = 4;
            for (uint32 k = 0; k < count && p + 16 <= list.length; k++) {
                uint32 opid = be_u32(list, p);
                uint32 size = be_u32(list, p + 12);
                size_t body = p + 16;
                if (body + size > list.length) break;
                if (opid == 9 && size >= 76) {
                    uint32 top = be_u32(list, body), left = be_u32(list, body + 4), bottom = be_u32(list, body + 8), right = be_u32(list, body + 12);
                    uint32 plane = be_u32(list, body + 16), planes = be_u32(list, body + 20);
                    uint32 row_pitch = uint32.max(1, be_u32(list, body + 24)), col_pitch = uint32.max(1, be_u32(list, body + 28));
                    uint32 map_v = be_u32(list, body + 32), map_h = be_u32(list, body + 36);
                    double spacing_v = be_double(list, body + 40), spacing_h = be_double(list, body + 48);
                    double origin_v = be_double(list, body + 56), origin_h = be_double(list, body + 64);
                    uint32 map_planes = be_u32(list, body + 72);
                    size_t gains = body + 76;
                    if (map_v == 0 || map_h == 0 || map_planes == 0 || gains + (size_t) map_v * map_h * map_planes * 4 > body + size) {
                        p = body + size;
                        continue;
                    }
                    for (uint32 y = top; y < bottom && y < img.height; y += row_pitch) {
                        double vv = ((y + 0.5) / img.height - origin_v) / double.max(spacing_v, 1e-9);
                        for (uint32 x = left; x < right && x < img.width; x += col_pitch) {
                            double hh = ((x + 0.5) / img.width - origin_h) / double.max(spacing_h, 1e-9);
                            int iv = (int) Math.floor(vv).clamp(0, map_v - 1), ih = (int) Math.floor(hh).clamp(0, map_h - 1);
                            int iv1 = int.min(iv + 1, (int) map_v - 1), ih1 = int.min(ih + 1, (int) map_h - 1);
                            double tv = (vv - iv).clamp(0, 1), th = (hh - ih).clamp(0, 1);
                            for (uint32 pl = plane; pl < plane + planes && pl < img.samples; pl++) {
                                uint32 mp = uint32.min(pl - plane, map_planes - 1);
                                float g00 = be_float(list, gains + (((size_t) iv * map_h + ih) * map_planes + mp) * 4);
                                float g01 = be_float(list, gains + (((size_t) iv * map_h + ih1) * map_planes + mp) * 4);
                                float g10 = be_float(list, gains + (((size_t) iv1 * map_h + ih) * map_planes + mp) * 4);
                                float g11 = be_float(list, gains + (((size_t) iv1 * map_h + ih1) * map_planes + mp) * 4);
                                double g = (g00 * (1 - th) + g01 * th) * (1 - tv) + (g10 * (1 - th) + g11 * th) * tv;
                                size_t i = ((size_t) y * img.width + x) * img.samples + pl;
                                img.data[i] = (float) (img.data[i] * g);
                            }
                        }
                    }
                }
                p = body + size;
            }
        }

        private static void apply_warp_opcodes(TiffReader r, TiffIfd ifd, ref FloatImage img) {
            var list = r.get_bytes(ifd, 51022);
            if (list.length < 4) return;
            uint32 count = be_u32(list, 0);
            size_t p = 4;
            for (uint32 k = 0; k < count && p + 16 <= list.length; k++) {
                uint32 opid = be_u32(list, p);
                uint32 size = be_u32(list, p + 12);
                size_t body = p + 16;
                if (body + size > list.length) break;
                if (opid == 3 && size >= 56) {
                    double[] k_v = new double[5];
                    for (int i = 0; i < 5; i++) k_v[i] = be_double(list, body + i * 8);
                    double cx = be_double(list, body + 40), cy = be_double(list, body + 48);
                    img = LensCorrection.vignette_radial(img, k_v, cx, cy, 1.0);
                } else if (opid == 1 && size >= 4) {
                    uint32 planes = be_u32(list, body);
                    if (size >= 4 + planes * 48 + 16) {
                        var coeffs = new double[planes * 6];
                        for (uint32 i = 0; i < planes * 6; i++) coeffs[i] = be_double(list, body + 4 + i * 8);
                        double cx = be_double(list, body + 4 + planes * 48), cy = be_double(list, body + 12 + planes * 48);
                        img = LensCorrection.warp_rectilinear(img, coeffs, (int) planes, cx, cy);
                    }
                }
                p = body + size;
            }
        }

        public static void fill_color(TiffReader r, TiffIfd ifd0, TiffIfd raw_ifd, DngRawData raw) {
            raw.camera_model = r.get_string(ifd0, 50708);
            var ab = r.get_doubles(ifd0, 50727);
            var cc1 = r.get_doubles(raw_ifd.has(50723) ? raw_ifd : ifd0, 50723);
            var cc2 = r.get_doubles(raw_ifd.has(50724) ? raw_ifd : ifd0, 50724);
            raw.color_matrix1 = effective(r.get_doubles(ifd0, 50721), cc1, ab);
            raw.color_matrix2 = effective(r.get_doubles(ifd0, 50722), cc2, ab);
            var fm1 = r.get_doubles(ifd0, 50964);
            if (fm1.length >= 9) raw.forward_matrix1 = fm1[0:9];
            var fm2 = r.get_doubles(ifd0, 50965);
            if (fm2.length >= 9) raw.forward_matrix2 = fm2[0:9];
            raw.temperature1 = Chromaticity.illuminant_temperature((int) r.get_uint(ifd0, 50778, 21));
            raw.temperature2 = Chromaticity.illuminant_temperature((int) r.get_uint(ifd0, 50779, 0));
            if (raw.color_matrix1.length != 9) {
                raw.color_matrix1 = { 3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570 };
                raw.temperature1 = 6504;
            }
            if (raw.color_matrix2.length != 9) raw.temperature2 = 0;
            raw.xyz_to_camera = raw.color_matrix1;
            raw.baseline_exposure = r.get_double(ifd0, 50730, 0);
            var inv = Singularity.Imaging.Matrix3.invert(raw.color_matrix1);
            var white = Chromaticity.mul(inv, { 1, 1, 1 });
            if (white[1] > 1e-9) {
                var m = inv;
                for (int i = 0; i < 9; i++) m[i] /= white[1];
                raw.camera_to_xyz = m;
            }
            var neutral = r.get_doubles(ifd0, 50728);
            if (neutral.length >= 3 && neutral[0] > 0 && neutral[1] > 0 && neutral[2] > 0) {
                raw.as_shot_multipliers = { neutral[1] / neutral[0], 1.0, neutral[1] / neutral[2] };
            } else {
                var wxy = r.get_doubles(ifd0, 50729);
                double t = 5500, tint = 0;
                double mr, mg, mb;
                if (wxy.length >= 2 && wxy[1] > 0) {
                    var cm = raw.color_matrix1;
                    var n = Chromaticity.mul(cm, { wxy[0] / wxy[1], 1.0, (1 - wxy[0] - wxy[1]) / wxy[1] });
                    mr = n[0] > 0 ? n[1] / n[0] : 1;
                    mb = n[2] > 0 ? n[1] / n[2] : 1;
                    raw.as_shot_multipliers = { mr, 1.0, mb };
                } else {
                    RawColor.multipliers_at(raw, t, tint, out mr, out mg, out mb);
                    raw.as_shot_multipliers = { mr, mg, mb };
                }
            }
            double at, atint;
            RawColor.temperature_for(raw, raw.as_shot_multipliers[0], raw.as_shot_multipliers[1], raw.as_shot_multipliers[2], out at, out atint);
            raw.as_shot_temperature = at;
            raw.as_shot_tint = atint;
            if (ifd0.has(50936) || ifd0.has(50938) || ifd0.has(50982)) {
                var profile = new DcpProfile();
                profile.read_tags(r, ifd0);
                profile.color_matrix1 = raw.color_matrix1;
                profile.color_matrix2 = raw.color_matrix2;
                if (profile.name == "") profile.name = _("Embedded Profile");
                raw.embedded_profile = profile;
            }
        }

        private static double[] effective(double[] cm, double[] cc, double[] ab) {
            if (cm.length < 9) return {};
            var m = cm[0:9];
            if (cc.length >= 9) m = Singularity.Imaging.Matrix3.multiply(cc[0:9], m);
            if (ab.length >= 3) {
                double[] d = { ab[0], 0, 0, 0, ab[1], 0, 0, 0, ab[2] };
                m = Singularity.Imaging.Matrix3.multiply(d, m);
            }
            return m;
        }
    }
}
