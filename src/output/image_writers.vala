using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class WriteRequest : Object {
        public FloatImage pixels;
        public string format = "jpeg";
        public int bit_depth = 8;
        public int quality = 90;
        public bool lossless = false;
        public bool compress = true;
        public int ppi = 300;
        public uint8[] icc = {};
        public uint8[] exif = {};
        public string xmp = "";
        public Primaries? primaries = null;
        public PhotoMetadata? meta = null;

        public WriteRequest(FloatImage pixels) {
            this.pixels = pixels;
        }
    }

    namespace ImageWriters {

        private uint32[]? crc_table = null;

        private uint32 crc(uint8[] data, uint32 start = (uint32) 0xFFFFFFFF) {
            if (crc_table == null) {
                var t = new uint32[256];
                for (uint32 n = 0; n < 256; n++) {
                    uint32 c = n;
                    for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? ((uint32) 0xEDB88320) ^ (c >> 1) : c >> 1;
                    t[n] = c;
                }
                crc_table = t;
            }
            uint32 c = start;
            foreach (uint8 b in data) c = crc_table[(c ^ b) & 0xFF] ^ (c >> 8);
            return c;
        }

        private void be32(ByteArray b, uint32 v) {
            uint8[] d = { (uint8) (v >> 24), (uint8) ((v >> 16) & 0xFF), (uint8) ((v >> 8) & 0xFF), (uint8) (v & 0xFF) };
            b.append(d);
        }

        private void png_chunk(ByteArray out_data, string type, uint8[] body) {
            be32(out_data, body.length);
            var typed = new ByteArray();
            typed.append(type.data);
            typed.append(body);
            out_data.append(typed.data);
            be32(out_data, crc(typed.data) ^ (uint32) 0xFFFFFFFF);
        }

        public uint8[] deflate(uint8[] input, int level = 6) {
            var conv = new ZlibCompressor(ZlibCompressorFormat.ZLIB, level);
            var out_data = new ByteArray();
            var buffer = new uint8[1 << 17];
            size_t in_pos = 0;
            try {
                while (true) {
                    size_t r, w;
                    var res = conv.convert(input[in_pos:input.length], buffer, ConverterFlags.INPUT_AT_END, out r, out w);
                    in_pos += r;
                    out_data.append(buffer[0:w]);
                    if (res == ConverterResult.FINISHED) break;
                }
            } catch (Error e) {
                return new uint8[0];
            }
            return out_data.steal();
        }

        private int paeth(int a, int b, int c) {
            int p = a + b - c;
            int pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
            if (pa <= pb && pa <= pc) return a;
            if (pb <= pc) return b;
            return c;
        }

        public uint8[] encode_png(FloatImage encoded, int depth, uint8[] icc, uint8[] exif, string xmp, int ppi) {
            bool alpha = !encoded.is_opaque();
            int channels = alpha ? 4 : 3;
            int bpp = channels * (depth == 16 ? 2 : 1);
            int w = encoded.width, h = encoded.height;
            int stride = w * bpp;
            var raw = new uint8[(size_t) (stride + 1) * h];
            var lines = new uint8[(size_t) stride * h];
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        size_t s = encoded.offset(x, y);
                        for (int c = 0; c < channels; c++) {
                            float v = encoded.data[s + c].clamp(0.0f, 1.0f);
                            size_t d = (size_t) y * stride + x * bpp;
                            if (depth == 16) {
                                uint16 q = (uint16) (v * 65535.0f + 0.5f);
                                lines[d + c * 2] = (uint8) (q >> 8);
                                lines[d + c * 2 + 1] = (uint8) (q & 0xFF);
                            } else {
                                lines[d + c] = (uint8) (v * 255.0f + 0.5f);
                            }
                        }
                    }
                }
            });
            Parallel.range(h, (start, end) => {
                var candidate = new uint8[stride];
                for (int y = start; y < end; y++) {
                    size_t row = (size_t) y * stride;
                    size_t dst = (size_t) y * (stride + 1);
                    long best = long.MAX;
                    for (int f = 0; f < 5; f++) {
                        long sum = 0;
                        for (int i = 0; i < stride; i++) {
                            int cur = lines[row + i];
                            int a = i >= bpp ? lines[row + i - bpp] : 0;
                            int b = y > 0 ? lines[row - stride + i] : 0;
                            int c = i >= bpp && y > 0 ? lines[row - stride + i - bpp] : 0;
                            int v;
                            switch (f) {
                                case 1: v = cur - a; break;
                                case 2: v = cur - b; break;
                                case 3: v = cur - (a + b) / 2; break;
                                case 4: v = cur - paeth(a, b, c); break;
                                default: v = cur; break;
                            }
                            candidate[i] = (uint8) (v & 0xFF);
                            int sv = (int) (int8) candidate[i];
                            sum += sv.abs();
                        }
                        if (sum < best) {
                            best = sum;
                            raw[dst] = (uint8) f;
                            Memory.copy(&raw[dst + 1], candidate, stride);
                        }
                    }
                }
            });
            var out_data = new ByteArray();
            uint8[] sig = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
            out_data.append(sig);
            var ihdr = new ByteArray();
            be32(ihdr, w);
            be32(ihdr, h);
            uint8[] rest = { (uint8) depth, alpha ? 6 : 2, 0, 0, 0 };
            ihdr.append(rest);
            png_chunk(out_data, "IHDR", ihdr.steal());
            if (icc.length > 0) {
                var body = new ByteArray();
                body.append("ICC profile".data);
                uint8[] z = { 0, 0 };
                body.append(z);
                body.append(deflate(icc));
                png_chunk(out_data, "iCCP", body.steal());
            }
            if (ppi > 0) {
                var phys = new ByteArray();
                uint32 ppm = (uint32) Math.round(ppi / 0.0254);
                be32(phys, ppm);
                be32(phys, ppm);
                uint8[] unit = { 1 };
                phys.append(unit);
                png_chunk(out_data, "pHYs", phys.steal());
            }
            if (exif.length > 0) png_chunk(out_data, "eXIf", exif);
            if (xmp != "") {
                var body = new ByteArray();
                body.append("XML:com.adobe.xmp".data);
                uint8[] z = { 0, 0, 0, 0, 0 };
                body.append(z);
                body.append(xmp.data);
                png_chunk(out_data, "iTXt", body.steal());
            }
            png_chunk(out_data, "IDAT", deflate(raw));
            png_chunk(out_data, "IEND", new uint8[0]);
            return out_data.steal();
        }

        public uint8[] encode_jpeg(FloatImage encoded, int quality, uint8[] icc, uint8[] exif, string xmp, int ppi) throws Error {
            int w = encoded.width, h = encoded.height;
            var rgb = new uint8[(size_t) w * h * 3];
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        size_t s = encoded.offset(x, y);
                        float a = encoded.data[s + 3].clamp(0.0f, 1.0f);
                        for (int c = 0; c < 3; c++) {
                            float v = encoded.data[s + c].clamp(0.0f, 1.0f) * a + (1.0f - a);
                            rgb[((size_t) y * w + x) * 3 + c] = (uint8) (v * 255.0f + 0.5f);
                        }
                    }
                }
            });
            var pixbuf = new Gdk.Pixbuf.from_bytes(new Bytes.take((owned) rgb), Gdk.Colorspace.RGB, false, 8, w, h, w * 3);
            string[] keys = { "quality" };
            string[] values = { quality.clamp(1, 100).to_string() };
            if (icc.length > 0) {
                keys += "icc-profile";
                values += Base64.encode(icc);
            }
            uint8[] data;
            pixbuf.save_to_bufferv(out data, "jpeg", keys, values);
            if (data.length > 20 && data[2] == 0xFF && data[3] == 0xE0 && Memory.cmp(&data[6], "JFIF".data, 4) == 0) {
                int d = ppi.clamp(1, 65535);
                data[13] = 1;
                data[14] = (uint8) (d >> 8);
                data[15] = (uint8) (d & 0xFF);
                data[16] = (uint8) (d >> 8);
                data[17] = (uint8) (d & 0xFF);
            }
            var segments = new Gee.ArrayList<Bytes>();
            if (exif.length > 0) {
                var b = new ByteArray();
                b.append("Exif".data);
                uint8[] z = { 0, 0 };
                b.append(z);
                b.append(exif);
                segments.add(ByteArray.free_to_bytes(b));
            }
            if (xmp != "") segments.add(new Bytes(EmbeddedMetadata.jpeg_xmp_segment(xmp)));
            return EmbeddedMetadata.inject_jpeg(data, segments);
        }

        public void write(WriteRequest r, string path) throws Error {
            var img = r.pixels;
            switch (r.format) {
                case "png":
                    FileUtils.set_data(path, encode_png(img, r.bit_depth == 16 ? 16 : 8, r.icc, r.exif, r.xmp, r.ppi));
                    return;
                case "jpeg":
                    FileUtils.set_data(path, encode_jpeg(img, r.quality, r.icc, r.exif, r.xmp, r.ppi));
                    return;
                case "tiff":
                    write_tiff(r, path);
                    return;
                case "webp":
                    var px = img.to_rgba8(false);
                    uint8[] encoded;
                    uint8[] exif = r.exif.length > 0 ? r.exif : new uint8[0];
                    if (!SintyCodecs.webp_encode(px, img.width, img.height, r.quality, r.lossless, r.icc, exif, r.xmp.data, out encoded))
                        throw new IOError.FAILED(_("The WebP encoder failed"));
                    FileUtils.set_data(path, encoded);
                    return;
                case "avif":
                case "heif":
                    string? error;
                    var words = img.to_rgba16(false);
                    int depth = r.bit_depth > 8 ? int.min(r.bit_depth, r.format == "heif" ? 10 : 12) : 8;
                    if (!SintyCodecs.heif_encode(path, words, img.width, img.height, depth, r.format == "avif", r.quality, r.lossless, r.icc, r.exif, r.xmp.data, out error))
                        throw new IOError.NOT_SUPPORTED(error ?? _("This format cannot be written on this system"));
                    return;
                case "jxl":
                    string? jerror;
                    float distance = r.quality >= 100 ? 0.1f : (float) (0.1 + (100 - r.quality) * 0.09);
                    if (!SintyCodecs.jxl_encode(path, img.data, img.width, img.height, r.bit_depth, distance, r.lossless, r.icc, r.exif, r.xmp.data, out jerror))
                        throw new IOError.NOT_SUPPORTED(jerror ?? _("This format cannot be written on this system"));
                    return;
                case "dng":
                    DngWriter.write_linear(img, File.new_for_path(path), r.meta, r.bit_depth == 32);
                    return;
                case "exr":
                    Exr.write(img, path, r.bit_depth != 32, r.compress ? Exr.COMPRESSION_ZIP : Exr.COMPRESSION_NONE, r.primaries);
                    return;
                default:
                    throw new IOError.NOT_SUPPORTED(_("Unknown export format"));
            }
        }

        private void write_tiff(WriteRequest r, string path) throws Error {
            var img = r.pixels;
            bool alpha = !img.is_opaque();
            int channels = alpha ? 4 : 3;
            int depth = r.bit_depth;
            size_t n = img.pixel_count();
            bool ok;
            string? error = null;
            if (depth == 32) {
                var f = new float[n * channels];
                for (size_t i = 0; i < n; i++) for (int c = 0; c < channels; c++) f[i * channels + c] = img.data[i * 4 + c];
                ok = SintyCodecs.tiff_write(path, f, img.width, img.height, channels, 32, true, r.icc, r.xmp.data, r.compress, out error);
            } else if (depth == 16) {
                var words = new uint16[n * channels];
                for (size_t i = 0; i < n; i++) for (int c = 0; c < channels; c++) words[i * channels + c] = (uint16) (img.data[i * 4 + c].clamp(0.0f, 1.0f) * 65535.0f + 0.5f);
                ok = SintyCodecs.tiff_write(path, words, img.width, img.height, channels, 16, false, r.icc, r.xmp.data, r.compress, out error);
            } else {
                var bytes = new uint8[n * channels];
                for (size_t i = 0; i < n; i++) for (int c = 0; c < channels; c++) bytes[i * channels + c] = (uint8) (img.data[i * 4 + c].clamp(0.0f, 1.0f) * 255.0f + 0.5f);
                ok = SintyCodecs.tiff_write(path, bytes, img.width, img.height, channels, 8, false, r.icc, r.xmp.data, r.compress, out error);
            }
            if (!ok) throw new IOError.FAILED(error ?? _("Cannot write the TIFF file"));
        }
    }
}
