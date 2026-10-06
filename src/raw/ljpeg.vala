namespace Singularity.Apps.Photos {

    namespace Ljpeg {

        private class Huffman {
            public int[] maxcode = new int[18];
            public int[] valptr = new int[17];
            public int[] mincode = new int[17];
            public uint8[] values = {};
            public bool defined = false;

            public void build(uint8[] bits, uint8[] vals) {
                values = vals;
                int code = 0, k = 0;
                for (int l = 1; l <= 16; l++) {
                    int n = bits[l - 1];
                    if (n == 0) {
                        maxcode[l] = -1;
                    } else {
                        valptr[l] = k;
                        mincode[l] = code;
                        code += n;
                        k += n;
                        maxcode[l] = code - 1;
                    }
                    code <<= 1;
                }
                maxcode[17] = int.MAX;
                defined = true;
            }
        }

        private class BitReader {
            private unowned uint8[] data;
            private size_t pos;
            private size_t end;
            private uint32 acc = 0;
            private int bits = 0;
            public bool hit_marker = false;

            public BitReader(uint8[] data, size_t pos, size_t end) {
                this.data = data;
                this.pos = pos;
                this.end = end;
            }

            private void fill() {
                while (bits <= 24) {
                    uint8 b = 0;
                    if (!hit_marker && pos < end) {
                        b = data[pos];
                        if (b == 0xFF) {
                            uint8 next = pos + 1 < end ? data[pos + 1] : 0;
                            if (next == 0x00) {
                                pos += 2;
                            } else {
                                hit_marker = true;
                                b = 0;
                            }
                        } else {
                            pos++;
                        }
                    }
                    acc |= (uint32) b << (24 - bits);
                    bits += 8;
                }
            }

            public int get(int n) {
                if (n == 0) return 0;
                fill();
                int v = (int) (acc >> (32 - n));
                acc <<= n;
                bits -= n;
                return v;
            }

            public int bit() {
                return get(1);
            }

            public void restart() {
                acc = 0;
                bits = 0;
                while (pos + 1 < end) {
                    if (data[pos] == 0xFF && data[pos + 1] >= 0xD0 && data[pos + 1] <= 0xD7) {
                        pos += 2;
                        break;
                    }
                    pos++;
                }
                hit_marker = false;
            }

            public int decode(Huffman h) {
                int code = bit();
                int l = 1;
                while (l <= 16 && code > h.maxcode[l]) {
                    code = (code << 1) | bit();
                    l++;
                }
                if (l > 16) return 0;
                int idx = h.valptr[l] + code - h.mincode[l];
                return idx < h.values.length ? h.values[idx] : 0;
            }
        }

        public uint16[] decode(uint8[] data, size_t offset, size_t length, out int width, out int height, out int components) throws Error {
            width = 0;
            height = 0;
            components = 0;
            size_t end = size_t.min(data.length, offset + length);
            size_t pos = offset;
            if (pos + 2 > end || data[pos] != 0xFF || data[pos + 1] != 0xD8) throw new IOError.INVALID_DATA("Not a lossless JPEG stream");
            pos += 2;
            var tables = new Huffman[4];
            for (int i = 0; i < 4; i++) tables[i] = new Huffman();
            int precision = 16;
            int[] comp_ids = {};
            int restart = 0;
            while (pos + 4 <= end) {
                if (data[pos] != 0xFF) {
                    pos++;
                    continue;
                }
                uint8 marker = data[pos + 1];
                if (marker == 0xFF) {
                    pos++;
                    continue;
                }
                int len = (data[pos + 2] << 8) | data[pos + 3];
                size_t seg = pos + 4;
                if (marker == 0xC4) {
                    size_t p = seg;
                    while (p < pos + 2 + len) {
                        int id = data[p] & 0x0F;
                        var bits = data[p + 1:p + 17];
                        int total = 0;
                        foreach (var b in bits) total += b;
                        var vals = data[p + 17:p + 17 + total];
                        if (id < 4) tables[id].build(bits, vals);
                        p += 17 + total;
                    }
                } else if (marker == 0xC3) {
                    precision = data[seg];
                    height = (data[seg + 1] << 8) | data[seg + 2];
                    width = (data[seg + 3] << 8) | data[seg + 4];
                    components = data[seg + 5];
                    for (int c = 0; c < components; c++) comp_ids += data[seg + 6 + c * 3];
                } else if (marker == 0xDD) {
                    restart = (data[seg] << 8) | data[seg + 1];
                } else if (marker == 0xDA) {
                    int ns = data[seg];
                    var comp_table = new int[ns];
                    for (int c = 0; c < ns; c++) comp_table[c] = (data[seg + 2 + c * 2] >> 4) & 3;
                    int predictor = data[seg + 1 + ns * 2];
                    int pt = data[seg + 3 + ns * 2] & 0x0F;
                    size_t scan = pos + 2 + len;
                    if (width <= 0 || height <= 0 || components <= 0 || ns != components) throw new IOError.INVALID_DATA("Unsupported lossless JPEG layout");
                    return decode_scan(data, scan, end, width, height, components, precision, predictor, pt, restart, tables, comp_table);
                } else if (marker == 0xD9) {
                    break;
                } else if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) {
                    throw new IOError.NOT_SUPPORTED("Lossy JPEG is not a raw stream");
                }
                pos += 2 + len;
            }
            throw new IOError.INVALID_DATA("Lossless JPEG stream without scan");
        }

        private uint16[] decode_scan(uint8[] data, size_t pos, size_t end, int width, int height, int comps, int precision, int predictor, int pt, int restart, Huffman[] tables, int[] comp_table) throws Error {
            var out_v = new uint16[(size_t) width * height * comps];
            var reader = new BitReader(data, pos, end);
            int row_len = width * comps;
            int initial = 1 << (precision - pt - 1);
            int mask = (1 << precision) - 1;
            int mcu = 0;
            bool fresh_line = true;
            bool first_mcu = true;
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    if (restart > 0 && mcu > 0 && mcu % restart == 0) {
                        reader.restart();
                        fresh_line = true;
                        first_mcu = true;
                    }
                    for (int c = 0; c < comps; c++) {
                        var h = tables[comp_table[c]];
                        if (!h.defined) throw new IOError.INVALID_DATA("Missing Huffman table");
                        int ssss = reader.decode(h);
                        int diff;
                        if (ssss == 0) {
                            diff = 0;
                        } else if (ssss == 16) {
                            diff = 32768;
                        } else {
                            diff = reader.get(ssss);
                            if (diff < (1 << (ssss - 1))) diff -= (1 << ssss) - 1;
                        }
                        size_t idx = (size_t) y * row_len + (size_t) x * comps + c;
                        int pred;
                        if (first_mcu) {
                            pred = initial;
                        } else if (fresh_line) {
                            pred = out_v[idx - comps];
                        } else if (x == 0) {
                            pred = out_v[idx - row_len];
                        } else {
                            int ra = out_v[idx - comps], rb = out_v[idx - row_len], rc = out_v[idx - row_len - comps];
                            switch (predictor) {
                                case 2: pred = rb; break;
                                case 3: pred = rc; break;
                                case 4: pred = ra + rb - rc; break;
                                case 5: pred = ra + ((rb - rc) >> 1); break;
                                case 6: pred = rb + ((ra - rc) >> 1); break;
                                case 7: pred = (ra + rb) >> 1; break;
                                default: pred = ra; break;
                            }
                        }
                        out_v[idx] = (uint16) ((pred + diff) & mask);
                    }
                    first_mcu = false;
                    mcu++;
                }
                fresh_line = false;
            }
            return out_v;
        }

        private class BitWriter {
            public ByteArray buffer = new ByteArray();
            private uint32 acc = 0;
            private int bits = 0;

            public void put(uint32 value, int n) {
                for (int i = n - 1; i >= 0; i--) {
                    acc = (acc << 1) | ((value >> i) & 1);
                    bits++;
                    if (bits == 8) {
                        uint8 b = (uint8) acc;
                        buffer.append({ b });
                        if (b == 0xFF) buffer.append({ 0 });
                        acc = 0;
                        bits = 0;
                    }
                }
            }

            public void flush() {
                if (bits > 0) put((1 << (8 - bits)) - 1, 8 - bits);
            }
        }

        public uint8[] encode(uint16[] samples, int width, int height, int comps, int precision) {
            var out_b = new ByteArray();
            out_b.append({ 0xFF, 0xD8 });
            uint8[] bits = new uint8[16];
            bits[4] = 17;
            var dht = new ByteArray();
            dht.append({ 0xFF, 0xC4 });
            int dht_len = 2 + 1 + 16 + 17;
            dht.append({ (uint8) (dht_len >> 8), (uint8) dht_len, 0x00 });
            dht.append(bits);
            for (int i = 0; i <= 16; i++) dht.append({ (uint8) i });
            out_b.append(dht.data);
            int sof_len = 8 + comps * 3;
            out_b.append({ 0xFF, 0xC3, (uint8) (sof_len >> 8), (uint8) sof_len, (uint8) precision,
                (uint8) (height >> 8), (uint8) height, (uint8) (width >> 8), (uint8) width, (uint8) comps });
            for (int c = 0; c < comps; c++) out_b.append({ (uint8) (c + 1), 0x11, 0 });
            int sos_len = 6 + comps * 2;
            out_b.append({ 0xFF, 0xDA, (uint8) (sos_len >> 8), (uint8) sos_len, (uint8) comps });
            for (int c = 0; c < comps; c++) out_b.append({ (uint8) (c + 1), 0x00 });
            out_b.append({ 1, 0, 0 });
            var w = new BitWriter();
            int row_len = width * comps;
            int initial = 1 << (precision - 1);
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    for (int c = 0; c < comps; c++) {
                        size_t idx = (size_t) y * row_len + (size_t) x * comps + c;
                        int pred;
                        if (y == 0 && x == 0) pred = initial;
                        else if (x == 0) pred = samples[idx - row_len];
                        else pred = samples[idx - comps];
                        int diff = (int) samples[idx] - pred;
                        diff = (int) (int16) diff;
                        int ssss = 0;
                        int a = diff.abs();
                        while (a > 0) {
                            ssss++;
                            a >>= 1;
                        }
                        if (diff == -32768) ssss = 16;
                        w.put(ssss, 5);
                        if (ssss > 0 && ssss < 16) {
                            int v = diff >= 0 ? diff : diff + (1 << ssss) - 1;
                            w.put(v, ssss);
                        }
                    }
                }
            }
            w.flush();
            out_b.append(w.buffer.data);
            out_b.append({ 0xFF, 0xD9 });
            return out_b.steal();
        }
    }
}
