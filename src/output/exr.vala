using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public errordomain ExrError {
        INVALID,
        UNSUPPORTED
    }

    namespace Exr {

        public const int COMPRESSION_NONE = 0;
        public const int COMPRESSION_ZIPS = 2;
        public const int COMPRESSION_ZIP = 3;

        public uint16 float_to_half(float value) {
            uint32 f = *((uint32*) (&value));
            uint32 sign = (f >> 16) & 0x8000;
            int32 exponent = (int32) ((f >> 23) & 0xFF) - 127 + 15;
            uint32 mantissa = f & 0x7FFFFF;
            if (((f >> 23) & 0xFF) == 0xFF) return (uint16) (sign | 0x7C00 | (mantissa != 0 ? 0x200 : 0));
            if (exponent >= 31) return (uint16) (sign | 0x7C00);
            if (exponent <= 0) {
                if (exponent < -10) return (uint16) sign;
                mantissa |= 0x800000;
                uint32 shift = (uint32) (14 - exponent);
                uint32 half_m = mantissa >> shift;
                if (((mantissa >> (shift - 1)) & 1) != 0) half_m++;
                return (uint16) (sign | half_m);
            }
            uint32 h = sign | ((uint32) exponent << 10) | (mantissa >> 13);
            if ((mantissa & 0x1000) != 0) h++;
            return (uint16) h;
        }

        public float half_to_float(uint16 h) {
            uint32 sign = ((uint32) h & 0x8000) << 16;
            uint32 exponent = ((uint32) h >> 10) & 0x1F;
            uint32 mantissa = (uint32) h & 0x3FF;
            uint32 f;
            if (exponent == 0) {
                if (mantissa == 0) {
                    f = sign;
                } else {
                    exponent = 1;
                    while ((mantissa & 0x400) == 0) {
                        mantissa <<= 1;
                        exponent--;
                    }
                    mantissa &= 0x3FF;
                    f = sign | ((exponent + 112) << 23) | (mantissa << 13);
                }
            } else if (exponent == 31) {
                f = sign | 0x7F800000 | (mantissa << 13);
            } else {
                f = sign | ((exponent + 112) << 23) | (mantissa << 13);
            }
            return *((float*) (&f));
        }

        private void put32(ByteArray b, uint32 v) {
            uint8[] d = { (uint8) (v & 0xFF), (uint8) ((v >> 8) & 0xFF), (uint8) ((v >> 16) & 0xFF), (uint8) (v >> 24) };
            b.append(d);
        }

        private void put64(ByteArray b, uint64 v) {
            put32(b, (uint32) (v & 0xFFFFFFFF));
            put32(b, (uint32) (v >> 32));
        }

        private void putf(ByteArray b, float v) {
            put32(b, *((uint32*) (&v)));
        }

        private void cstr(ByteArray b, string s) {
            b.append(s.data);
            uint8[] z = { 0 };
            b.append(z);
        }

        private void attribute(ByteArray b, string name, string type, uint8[] value) {
            cstr(b, name);
            cstr(b, type);
            put32(b, value.length);
            b.append(value);
        }

        private uint8[] zip_encode(uint8[] raw) {
            int n = raw.length;
            var tmp = new uint8[n];
            int t1 = 0, t2 = (n + 1) / 2;
            for (int i = 0; i < n; i++) {
                if (i % 2 == 0) tmp[t1++] = raw[i];
                else tmp[t2++] = raw[i];
            }
            int p = n > 0 ? tmp[0] : 0;
            for (int i = 1; i < n; i++) {
                int d = (int) tmp[i] - p + (128 + 256);
                p = tmp[i];
                tmp[i] = (uint8) (d & 0xFF);
            }
            return zlib(tmp, true);
        }

        private uint8[] zip_decode(uint8[] packed, int expected) throws Error {
            var tmp = zlib(packed, false);
            if (tmp.length != expected) throw new ExrError.INVALID("Damaged ZIP block");
            for (int i = 1; i < tmp.length; i++) tmp[i] = (uint8) ((tmp[i - 1] + tmp[i] - 128) & 0xFF);
            var raw = new uint8[tmp.length];
            int t1 = 0, t2 = (tmp.length + 1) / 2;
            for (int i = 0; i < raw.length; i++) {
                if (i % 2 == 0) raw[i] = tmp[t1++];
                else raw[i] = tmp[t2++];
            }
            return raw;
        }

        private uint8[] zlib(uint8[] input, bool compress) {
            Converter conv = compress ? (Converter) new ZlibCompressor(ZlibCompressorFormat.ZLIB, 6) : (Converter) new ZlibDecompressor(ZlibCompressorFormat.ZLIB);
            var out_data = new ByteArray();
            var buffer = new uint8[65536];
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

        public void write(FloatImage img, string path, bool half, int compression, Primaries? primaries = null) throws Error {
            int w = img.width, h = img.height;
            bool alpha = !img.is_opaque();
            string[] names = alpha ? new string[] { "A", "B", "G", "R" } : new string[] { "B", "G", "R" };
            int[] source = alpha ? new int[] { 3, 2, 1, 0 } : new int[] { 2, 1, 0 };
            int bytes = half ? 2 : 4;
            int lines = compression == COMPRESSION_ZIP ? 16 : 1;
            var header = new ByteArray();
            put32(header, 20000630);
            put32(header, 2);
            var ch = new ByteArray();
            foreach (var n in names) {
                cstr(ch, n);
                put32(ch, half ? 1 : 2);
                put32(ch, 0);
                put32(ch, 1);
                put32(ch, 1);
            }
            uint8[] z = { 0 };
            ch.append(z);
            attribute(header, "channels", "chlist", ch.steal());
            attribute(header, "compression", "compression", new uint8[] { (uint8) compression });
            var box = new ByteArray();
            put32(box, 0);
            put32(box, 0);
            put32(box, w - 1);
            put32(box, h - 1);
            uint8[] box_data = box.steal();
            attribute(header, "dataWindow", "box2i", box_data);
            attribute(header, "displayWindow", "box2i", box_data);
            attribute(header, "lineOrder", "lineOrder", new uint8[] { 0 });
            var pa = new ByteArray();
            putf(pa, 1.0f);
            attribute(header, "pixelAspectRatio", "float", pa.steal());
            var sc = new ByteArray();
            putf(sc, 0);
            putf(sc, 0);
            attribute(header, "screenWindowCenter", "v2f", sc.steal());
            var sw = new ByteArray();
            putf(sw, 1.0f);
            attribute(header, "screenWindowWidth", "float", sw.steal());
            if (primaries != null) {
                var chroma = new ByteArray();
                double[] v = { primaries.rx, primaries.ry, primaries.gx, primaries.gy, primaries.bx, primaries.by, primaries.wx, primaries.wy };
                foreach (double d in v) putf(chroma, (float) d);
                attribute(header, "chromaticities", "chromaticities", chroma.steal());
            }
            attribute(header, "software", "string", "Singularity Photos".data);
            header.append(z);
            int chunks = (h + lines - 1) / lines;
            var blocks = new Gee.ArrayList<Bytes>();
            for (int c = 0; c < chunks; c++) {
                int y0 = c * lines, y1 = int.min(h, y0 + lines);
                var raw = new ByteArray.sized((uint) ((y1 - y0) * w * names.length * bytes));
                for (int y = y0; y < y1; y++) {
                    for (int k = 0; k < names.length; k++) {
                        var row = new uint8[w * bytes];
                        for (int x = 0; x < w; x++) {
                            float v = img.data[img.offset(x, y) + source[k]];
                            if (half) {
                                uint16 hv = float_to_half(v);
                                row[x * 2] = (uint8) (hv & 0xFF);
                                row[x * 2 + 1] = (uint8) (hv >> 8);
                            } else {
                                uint32 fv = *((uint32*) (&v));
                                row[x * 4] = (uint8) (fv & 0xFF);
                                row[x * 4 + 1] = (uint8) ((fv >> 8) & 0xFF);
                                row[x * 4 + 2] = (uint8) ((fv >> 16) & 0xFF);
                                row[x * 4 + 3] = (uint8) (fv >> 24);
                            }
                        }
                        raw.append(row);
                    }
                }
                uint8[] data = raw.steal();
                if (compression != COMPRESSION_NONE) {
                    var packed = zip_encode(data);
                    if (packed.length > 0 && packed.length < data.length) data = packed;
                }
                var block = new ByteArray();
                put32(block, y0);
                put32(block, data.length);
                block.append(data);
                blocks.add(ByteArray.free_to_bytes(block));
            }
            var out_data = new ByteArray();
            out_data.append(header.data);
            uint64 at = header.len + (uint64) chunks * 8;
            foreach (var b in blocks) {
                put64(out_data, at);
                at += b.get_size();
            }
            foreach (var b in blocks) out_data.append(b.get_data());
            FileUtils.set_data(path, out_data.data);
        }

        public class Image : Object {
            public FloatImage image;
            public Primaries primaries = Primaries.rec709();
            public bool has_chromaticities = false;
        }

        private uint32 get32(uint8[] d, size_t at) throws Error {
            if (at + 4 > d.length) throw new ExrError.INVALID("Truncated file");
            return (uint32) d[at] | ((uint32) d[at + 1] << 8) | ((uint32) d[at + 2] << 16) | ((uint32) d[at + 3] << 24);
        }

        private string read_cstr(uint8[] d, ref size_t at) throws Error {
            var b = new StringBuilder();
            while (at < d.length && d[at] != 0) b.append_c((char) d[at++]);
            if (at >= d.length) throw new ExrError.INVALID("Truncated header");
            at++;
            return b.str;
        }

        public bool is_exr(uint8[] head) {
            return head.length >= 4 && head[0] == 0x76 && head[1] == 0x2F && head[2] == 0x31 && head[3] == 0x01;
        }

        public Image read(string path) throws Error {
            uint8[] d;
            FileUtils.get_data(path, out d);
            if (!is_exr(d)) throw new ExrError.INVALID("Not an OpenEXR file");
            uint32 version = get32(d, 4);
            if ((version & 0x200) != 0 || (version & 0x1000) != 0 || (version & 0x800) != 0)
                throw new ExrError.UNSUPPORTED(_("Tiled, deep or multi-part OpenEXR files are not supported"));
            size_t at = 8;
            string[] names = {};
            int[] types = {};
            int compression = 0;
            int x0 = 0, y0 = 0, x1 = -1, y1 = -1;
            var result = new Image();
            while (true) {
                string name = read_cstr(d, ref at);
                if (name == "") break;
                string type = read_cstr(d, ref at);
                uint32 size = get32(d, at);
                at += 4;
                size_t value = at;
                if (value + size > d.length) throw new ExrError.INVALID("Truncated header");
                if (type == "chlist") {
                    size_t p = value;
                    while (p < value + size && d[p] != 0) {
                        string cn = read_cstr(d, ref p);
                        names += cn;
                        types += (int) get32(d, p);
                        p += 16;
                    }
                } else if (name == "compression") {
                    compression = d[value];
                } else if (name == "dataWindow") {
                    x0 = (int) get32(d, value);
                    y0 = (int) get32(d, value + 4);
                    x1 = (int) get32(d, value + 8);
                    y1 = (int) get32(d, value + 12);
                } else if (name == "chromaticities" && size >= 32) {
                    float[] c = new float[8];
                    for (int i = 0; i < 8; i++) {
                        uint32 u = get32(d, value + i * 4);
                        c[i] = *((float*) (&u));
                    }
                    result.primaries = Primaries(c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]);
                    result.has_chromaticities = true;
                }
                at = value + size;
            }
            if (compression != COMPRESSION_NONE && compression != COMPRESSION_ZIPS && compression != COMPRESSION_ZIP)
                throw new ExrError.UNSUPPORTED(_("This OpenEXR compression is not supported"));
            int w = x1 - x0 + 1, h = y1 - y0 + 1;
            if (w <= 0 || h <= 0 || w > 65535 || h > 65535) throw new ExrError.INVALID("Bad data window");
            int lines = compression == COMPRESSION_ZIP ? 16 : 1;
            int chunks = (h + lines - 1) / lines;
            var img = new FloatImage.filled(w, h, 0, 0, 0, 1);
            int[] target = new int[names.length];
            bool gray = true;
            foreach (var n in names) if (n == "R" || n == "G" || n == "B") gray = false;
            for (int k = 0; k < names.length; k++) {
                switch (names[k]) {
                    case "R": target[k] = 0; break;
                    case "G": target[k] = 1; break;
                    case "B": target[k] = 2; break;
                    case "A": target[k] = 3; break;
                    case "Y": target[k] = gray ? 4 : -1; break;
                    default: target[k] = -1; break;
                }
            }
            int row_bytes = 0;
            foreach (int t in types) row_bytes += w * (t == 1 ? 2 : 4);
            for (int c = 0; c < chunks; c++) {
                uint32 lo = get32(d, at + c * 8), hi = get32(d, at + c * 8 + 4);
                size_t off = (size_t) (((uint64) hi << 32) | lo);
                int cy = (int) get32(d, off) - y0;
                uint32 size = get32(d, off + 4);
                if (off + 8 + size > d.length) throw new ExrError.INVALID("Truncated block");
                int ly = int.min(lines, h - cy);
                int expected = ly * row_bytes;
                uint8[] block = d[off + 8:off + 8 + size];
                if ((int) size < expected) block = zip_decode(block, expected);
                size_t p = 0;
                for (int y = cy; y < cy + ly; y++) {
                    for (int k = 0; k < names.length; k++) {
                        for (int x = 0; x < w; x++) {
                            float v;
                            if (types[k] == 1) {
                                v = half_to_float((uint16) (block[p] | (block[p + 1] << 8)));
                                p += 2;
                            } else {
                                uint32 u = (uint32) block[p] | ((uint32) block[p + 1] << 8) | ((uint32) block[p + 2] << 16) | ((uint32) block[p + 3] << 24);
                                v = types[k] == 2 ? *((float*) (&u)) : (float) u;
                                p += 4;
                            }
                            int t = target[k];
                            if (t < 0 || y < 0 || y >= h) continue;
                            size_t o = img.offset(x, y);
                            if (t == 4) {
                                img.data[o] = v;
                                img.data[o + 1] = v;
                                img.data[o + 2] = v;
                            } else {
                                img.data[o + t] = v;
                            }
                        }
                    }
                }
            }
            result.image = img;
            return result;
        }
    }

    public class ExrDecoder : Object, PhotoDecoder {
        public string id { get { return "exr"; } }

        public bool handles(string lower_name, uint8[] head) {
            return Exr.is_exr(head) || lower_name.has_suffix(".exr");
        }

        public DecodedPhoto decode(File file, int max_side) throws Error {
            var e = Exr.read(file.get_path());
            var img = e.image;
            int fw = img.width, fh = img.height;
            if (max_side > 0) img = img.scaled_to_fit(max_side);
            else img = img.copy();
            Matrix3.apply_image(Primaries.conversion(e.primaries, WorkingSpace.primaries()), img);
            var photo = new DecodedPhoto(img);
            photo.full_width = fw;
            photo.full_height = fh;
            photo.format = "exr";
            photo.meta = MetadataReader.read(file);
            photo.meta.width = fw;
            photo.meta.height = fh;
            return photo;
        }
    }
}
