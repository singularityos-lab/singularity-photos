using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace RetouchPsd {

        private class Reader {
            public unowned uint8[] data;
            public int pos = 0;

            public Reader(uint8[] data) {
                this.data = data;
            }

            public void need(int n) throws Error {
                if (pos + n > data.length || n < 0) throw new RetouchFormatError.INVALID("Truncated PSD file");
            }

            public uint8 u8() throws Error {
                need(1);
                return data[pos++];
            }

            public uint16 u16() throws Error {
                need(2);
                uint16 v = (uint16) ((data[pos] << 8) | data[pos + 1]);
                pos += 2;
                return v;
            }

            public int16 i16() throws Error {
                return (int16) u16();
            }

            public uint32 u32() throws Error {
                need(4);
                uint32 v = ((uint32) data[pos] << 24) | ((uint32) data[pos + 1] << 16) | ((uint32) data[pos + 2] << 8) | data[pos + 3];
                pos += 4;
                return v;
            }

            public int32 i32() throws Error {
                return (int32) u32();
            }

            public string sig() throws Error {
                need(4);
                string s = RetouchBytes.to_string(data, pos, 4);
                pos += 4;
                return s;
            }
        }

        private class Channel {
            public int id;
            public uint32 length;
            public float[]? plane;
        }

        private class Record {
            public int top;
            public int left;
            public int bottom;
            public int right;
            public Channel[] channels = {};
            public string blend = "norm";
            public int opacity = 255;
            public int flags = 0;
            public string name = "";
            public int mask_top;
            public int mask_left;
            public int mask_bottom;
            public int mask_right;
            public int mask_default = 0;
            public int mask_flags = 0;
            public bool has_mask = false;
            public int section = 0;
            public string? section_blend = null;
        }

        private void unpack_bits(Reader r, uint8[] out_row, int length, int end) throws Error {
            int o = 0;
            while (o < length && r.pos < end) {
                int n = (int8) r.u8();
                if (n >= 0) {
                    int count = n + 1;
                    r.need(count);
                    for (int i = 0; i < count && o < length; i++) out_row[o++] = r.data[r.pos + i];
                    r.pos += count;
                } else if (n != -128) {
                    int count = 1 - n;
                    uint8 v = r.u8();
                    for (int i = 0; i < count && o < length; i++) out_row[o++] = v;
                }
            }
        }

        private float[] read_plane(Reader r, int w, int h, int depth, int compression, int end) throws Error {
            var plane = new float[(size_t) int.max(0, w) * int.max(0, h)];
            if (w <= 0 || h <= 0) return plane;
            int bpr = w * depth / 8;
            var row = new uint8[bpr];
            if (compression == 0) {
                for (int y = 0; y < h; y++) {
                    r.need(bpr);
                    Memory.copy(row, &r.data[r.pos], bpr);
                    r.pos += bpr;
                    decode_row(row, plane, y, w, depth);
                }
            } else if (compression == 1) {
                r.pos += h * 2;
                for (int y = 0; y < h; y++) {
                    unpack_bits(r, row, bpr, end);
                    decode_row(row, plane, y, w, depth);
                }
            } else if (compression == 2 || compression == 3) {
                var converter = new ZlibDecompressor(ZlibCompressorFormat.ZLIB);
                var raw = new uint8[bpr * h];
                size_t read_bytes, written;
                converter.convert(r.data[r.pos:end], raw, ConverterFlags.INPUT_AT_END, out read_bytes, out written);
                if (compression == 3 && depth == 16) {
                    for (int y = 0; y < h; y++) {
                        uint16 prev = 0;
                        for (int x = 0; x < w; x++) {
                            int i = y * bpr + x * 2;
                            uint16 v = (uint16) (((raw[i] << 8) | raw[i + 1]) + prev);
                            raw[i] = (uint8) (v >> 8);
                            raw[i + 1] = (uint8) (v & 0xff);
                            prev = v;
                        }
                    }
                } else if (compression == 3) {
                    for (int y = 0; y < h; y++)
                        for (int x = 1; x < bpr; x++) raw[y * bpr + x] = (uint8) (raw[y * bpr + x] + raw[y * bpr + x - 1]);
                }
                for (int y = 0; y < h; y++) {
                    Memory.copy(row, &raw[y * bpr], bpr);
                    decode_row(row, plane, y, w, depth);
                }
                r.pos = end;
            } else {
                throw new RetouchFormatError.UNSUPPORTED("Unsupported PSD compression");
            }
            return plane;
        }

        private void decode_row(uint8[] row, float[] plane, int y, int w, int depth) {
            size_t base_index = (size_t) y * w;
            if (depth == 8) {
                for (int x = 0; x < w; x++) plane[base_index + x] = row[x] / 255.0f;
            } else if (depth == 16) {
                for (int x = 0; x < w; x++) plane[base_index + x] = ((row[x * 2] << 8) | row[x * 2 + 1]) / 65535.0f;
            } else if (depth == 32) {
                for (int x = 0; x < w; x++) {
                    uint32 bits = ((uint32) row[x * 4] << 24) | ((uint32) row[x * 4 + 1] << 16) | ((uint32) row[x * 4 + 2] << 8) | row[x * 4 + 3];
                    float f = *((float*) (&bits));
                    plane[base_index + x] = f;
                }
            } else {
                for (int x = 0; x < w; x++) plane[base_index + x] = ((row[x / 8] >> (7 - x % 8)) & 1) != 0 ? 0 : 1;
            }
        }

        private string read_pascal(Reader r, int align) throws Error {
            int len = r.u8();
            r.need(len);
            string s = RetouchBytes.to_string(r.data, r.pos, len);
            r.pos += len;
            int total = len + 1;
            while (total % align != 0) {
                r.pos++;
                total++;
            }
            return s.make_valid();
        }

        private class Planes {
            public float[]? p0 = null;
            public float[]? p1 = null;
            public float[]? p2 = null;
            public float[]? p3 = null;

            public void put(int i, float[]? v) {
                if (i == 0) p0 = v;
                else if (i == 1) p1 = v;
                else if (i == 2) p2 = v;
                else if (i == 3) p3 = v;
            }
        }

        private FloatImage compose_image(Planes planes, int w, int h, int mode, bool linear_float) {
            var img = new FloatImage(w, h);
            unowned float[]? q0 = planes.p0;
            unowned float[]? q1 = planes.p1;
            unowned float[]? q2 = planes.p2;
            unowned float[]? q3 = planes.p3;
            for (size_t i = 0; i < (size_t) w * h; i++) {
                float r, g, b, a;
                if (mode == 1 || mode == 8 || mode == 0) {
                    float v = q0 != null ? q0[i] : 0;
                    r = g = b = v;
                } else {
                    r = q0 != null ? q0[i] : 0;
                    g = q1 != null ? q1[i] : 0;
                    b = q2 != null ? q2[i] : 0;
                }
                a = q3 != null ? q3[i] : 1;
                img.data[i * 4] = r;
                img.data[i * 4 + 1] = g;
                img.data[i * 4 + 2] = b;
                img.data[i * 4 + 3] = a;
            }
            if (linear_float) WorkingSpace.from_linear_srgb(img);
            else RetouchColor.encoded_to_working(img);
            return img;
        }

        private int color_index(int id, int mode) {
            if (id == -1) return 3;
            if (id >= 0 && id < 3) return (mode == 1 || mode == 8) ? (id == 0 ? 0 : -1) : id;
            return -1;
        }

        public class Header {
            public int channels;
            public int width;
            public int height;
            public int depth;
            public int mode;
        }

        private Header read_header(Reader r) throws Error {
            if (r.sig() != "8BPS") throw new RetouchFormatError.INVALID("Not a PSD file");
            int version = r.u16();
            if (version != 1) throw new RetouchFormatError.UNSUPPORTED("Large document (PSB) files are not supported");
            r.pos += 6;
            var hd = new Header();
            hd.channels = r.u16();
            hd.height = (int) r.u32();
            hd.width = (int) r.u32();
            hd.depth = r.u16();
            hd.mode = r.u16();
            if (hd.mode != 3 && hd.mode != 1 && hd.mode != 8) throw new RetouchFormatError.UNSUPPORTED("Only RGB and grayscale PSD files are supported");
            if (hd.depth != 8 && hd.depth != 16 && hd.depth != 32 && hd.depth != 1) throw new RetouchFormatError.UNSUPPORTED("Unsupported PSD bit depth");
            return hd;
        }

        public FloatImage read_merged(uint8[] data) throws Error {
            var r = new Reader(data);
            var hd = read_header(r);
            r.pos += (int) r.u32();
            r.pos += (int) r.u32();
            r.pos += (int) r.u32();
            return read_merged_section(r, hd);
        }

        private FloatImage read_merged_section(Reader r, Header hd) throws Error {
            int compression = r.u16();
            var planes = new Planes();
            int w = hd.width, h = hd.height;
            if (compression == 1) {
                int counts_pos = r.pos;
                r.pos += hd.channels * h * 2;
                for (int c = 0; c < hd.channels; c++) {
                    int total = 0;
                    for (int y = 0; y < h; y++) total += (data_u16(r.data, counts_pos + (c * h + y) * 2));
                    int start = r.pos;
                    var plane = new float[(size_t) w * h];
                    var row = new uint8[w * hd.depth / 8];
                    for (int y = 0; y < h; y++) {
                        unpack_bits(r, row, row.length, start + total);
                        decode_row(row, plane, y, w, hd.depth);
                    }
                    r.pos = start + total;
                    int idx = hd.mode == 3 ? c : (c == 0 ? 0 : (c == 1 ? 3 : -1));
                    if (hd.mode == 3 && c == 3) idx = 3;
                    if (idx >= 0 && idx < 4) planes.put(idx, plane);
                }
            } else {
                for (int c = 0; c < hd.channels; c++) {
                    var plane = read_plane(r, w, h, hd.depth, compression == 0 ? 0 : compression, compression == 0 ? r.data.length : r.data.length);
                    int idx = hd.mode == 3 ? c : (c == 0 ? 0 : (c == 1 ? 3 : -1));
                    if (idx >= 0 && idx < 4) planes.put(idx, plane);
                }
            }
            if (hd.mode == 3 && hd.channels < 4) planes.put(3, null);
            return compose_image(planes, w, h, hd.mode, hd.depth == 32);
        }

        private int data_u16(uint8[] d, int p) {
            return (d[p] << 8) | d[p + 1];
        }

        public RetouchDocument read(uint8[] data) throws Error {
            var r = new Reader(data);
            var hd = read_header(r);
            r.pos += (int) r.u32();
            uint32 res_len = r.u32();
            r.pos += (int) res_len;
            uint32 lm_len = r.u32();
            int lm_end = r.pos + (int) lm_len;
            var doc = new RetouchDocument(hd.width, hd.height);
            var records = new Gee.ArrayList<Record>();
            if (lm_len > 0) {
                uint32 li_len = r.u32();
                int li_end = r.pos + (int) li_len;
                if (li_len > 0) {
                    int count = ((int16) r.u16()).abs();
                    for (int i = 0; i < count; i++) records.add(read_record(r));
                    foreach (var rec in records) {
                        foreach (var ch in rec.channels) {
                            int ch_start = r.pos;
                            int ch_end = ch_start + (int) ch.length;
                            if (ch.length < 2) {
                                r.pos = ch_end;
                                continue;
                            }
                            int compression = r.u16();
                            int w, h;
                            if (ch.id == -2 || ch.id == -3) {
                                w = rec.mask_right - rec.mask_left;
                                h = rec.mask_bottom - rec.mask_top;
                            } else {
                                w = rec.right - rec.left;
                                h = rec.bottom - rec.top;
                            }
                            if (w > 0 && h > 0) ch.plane = read_plane(r, w, h, hd.depth, compression, ch_end);
                            r.pos = ch_end;
                        }
                    }
                }
                r.pos = li_end;
            }
            build_tree(doc, records, hd);
            r.pos = lm_end;
            if (records.size == 0) {
                var merged = read_merged_section(r, hd);
                var layer = new RetouchLayer(_("Background"), RetouchLayerKind.RASTER);
                layer.pixels = merged;
                doc.layers.add(layer);
            }
            doc.recomposite();
            return doc;
        }

        private Record read_record(Reader r) throws Error {
            var rec = new Record();
            rec.top = r.i32();
            rec.left = r.i32();
            rec.bottom = r.i32();
            rec.right = r.i32();
            int n = r.u16();
            for (int c = 0; c < n; c++) {
                var ch = new Channel();
                ch.id = r.i16();
                ch.length = r.u32();
                rec.channels += ch;
            }
            if (r.sig() != "8BIM") throw new RetouchFormatError.INVALID("Broken PSD layer record");
            rec.blend = r.sig();
            rec.opacity = r.u8();
            r.u8();
            rec.flags = r.u8();
            r.u8();
            uint32 extra = r.u32();
            int extra_end = r.pos + (int) extra;
            uint32 mask_len = r.u32();
            int mask_end = r.pos + (int) mask_len;
            if (mask_len >= 20) {
                rec.has_mask = true;
                rec.mask_top = r.i32();
                rec.mask_left = r.i32();
                rec.mask_bottom = r.i32();
                rec.mask_right = r.i32();
                rec.mask_default = r.u8();
                rec.mask_flags = r.u8();
            }
            r.pos = mask_end;
            uint32 ranges = r.u32();
            r.pos += (int) ranges;
            rec.name = read_pascal(r, 4);
            while (r.pos + 12 <= extra_end) {
                string s = r.sig();
                if (s != "8BIM" && s != "8B64") break;
                string key = r.sig();
                uint32 len = r.u32();
                int block_end = r.pos + (int) len;
                if (key == "luni" && len >= 4) {
                    uint32 chars = r.u32();
                    var sb = new StringBuilder();
                    for (uint32 i = 0; i < chars && r.pos + 2 <= block_end; i++) {
                        unichar c = r.u16();
                        if (c != 0) sb.append_unichar(c);
                    }
                    rec.name = sb.str;
                } else if ((key == "lsct" || key == "lsdk") && len >= 4) {
                    rec.section = (int) r.u32();
                    if (len >= 12) {
                        r.sig();
                        rec.section_blend = r.sig();
                    }
                }
                r.pos = block_end;
            }
            r.pos = extra_end;
            return rec;
        }

        private RetouchLayer layer_from_record(Record rec, Header hd, RetouchDocument doc) {
            var layer = new RetouchLayer(rec.name, RetouchLayerKind.RASTER);
            layer.opacity = rec.opacity / 255.0f;
            layer.visible = (rec.flags & 2) == 0;
            layer.locked = (rec.flags & 1) != 0;
            layer.mode = rec.blend == "pass" ? BlendMode.NORMAL : BlendMode.from_key(rec.blend);
            int w = rec.right - rec.left, h = rec.bottom - rec.top;
            if (w > 0 && h > 0) {
                var planes = new Planes();
                foreach (var ch in rec.channels) {
                    int idx = color_index(ch.id, hd.mode);
                    if (idx >= 0 && ch.plane != null) planes.put(idx, ch.plane);
                }
                if (planes.p3 == null) {
                    var ones = new float[(size_t) w * h];
                    for (size_t i = 0; i < ones.length; i++) ones[i] = 1;
                    planes.put(3, ones);
                }
                layer.pixels = compose_image(planes, w, h, hd.mode, hd.depth == 32);
                layer.x = rec.left;
                layer.y = rec.top;
            } else {
                layer.pixels = new FloatImage.filled(1, 1, 0, 0, 0, 0);
            }
            foreach (var ch in rec.channels) {
                if (ch.id != -2 || ch.plane == null) continue;
                var mask = doc.full_plane(rec.mask_default / 255.0f);
                int mw = rec.mask_right - rec.mask_left;
                int mh = rec.mask_bottom - rec.mask_top;
                for (int y = 0; y < mh; y++) {
                    int dy = y + rec.mask_top;
                    if (dy < 0 || dy >= doc.height) continue;
                    for (int x = 0; x < mw; x++) {
                        int dx = x + rec.mask_left;
                        if (dx < 0 || dx >= doc.width) continue;
                        mask[(size_t) dy * doc.width + dx] = ch.plane[(size_t) y * mw + x];
                    }
                }
                layer.mask = mask;
                layer.mask_enabled = (rec.mask_flags & 2) == 0;
            }
            return layer;
        }

        private void build_tree(RetouchDocument doc, Gee.ArrayList<Record> records, Header hd) {
            var stack = new Gee.ArrayList<Gee.ArrayList<RetouchLayer>>();
            stack.add(doc.layers);
            foreach (var rec in records) {
                var current = stack[stack.size - 1];
                if (rec.section == 3) {
                    stack.add(new Gee.ArrayList<RetouchLayer>());
                    continue;
                }
                if (rec.section == 1 || rec.section == 2) {
                    var group = new RetouchLayer(rec.name, RetouchLayerKind.GROUP);
                    group.opacity = rec.opacity / 255.0f;
                    group.visible = (rec.flags & 2) == 0;
                    string blend = rec.section_blend ?? rec.blend;
                    group.mode = blend == "pass" ? BlendMode.NORMAL : BlendMode.from_key(blend);
                    group.expanded = rec.section == 1;
                    if (stack.size > 1) {
                        group.children = stack.remove_at(stack.size - 1);
                        current = stack[stack.size - 1];
                    }
                    var masked = layer_from_record(rec, hd, doc);
                    group.mask = masked.mask;
                    current.add(group);
                    continue;
                }
                current.add(layer_from_record(rec, hd, doc));
            }
            while (stack.size > 1) {
                var orphan = stack.remove_at(stack.size - 1);
                stack[stack.size - 1].add_all(orphan);
            }
        }

        private class Writer {
            public ByteArray buf = new ByteArray();

            public void u8(uint v) {
                uint8[] b = { (uint8) v };
                buf.append(b);
            }

            public void u16(uint v) {
                uint8[] b = { (uint8) ((v >> 8) & 0xff), (uint8) (v & 0xff) };
                buf.append(b);
            }

            public void u32(uint32 v) {
                uint8[] b = { (uint8) (v >> 24), (uint8) ((v >> 16) & 0xff), (uint8) ((v >> 8) & 0xff), (uint8) (v & 0xff) };
                buf.append(b);
            }

            public void str(string s) {
                buf.append(s.data);
            }

            public void bytes(uint8[] b) {
                buf.append(b);
            }

            public void set_u32(uint pos, uint32 v) {
                buf.data[pos] = (uint8) (v >> 24);
                buf.data[pos + 1] = (uint8) ((v >> 16) & 0xff);
                buf.data[pos + 2] = (uint8) ((v >> 8) & 0xff);
                buf.data[pos + 3] = (uint8) (v & 0xff);
            }
        }

        public uint8[] pack_bits(uint8[] row) {
            var out_data = new ByteArray();
            int n = row.length, i = 0;
            while (i < n) {
                int run = 1;
                while (i + run < n && run < 128 && row[i + run] == row[i]) run++;
                if (run >= 2) {
                    uint8[] b = { (uint8) (257 - run), row[i] };
                    out_data.append(b);
                    i += run;
                    continue;
                }
                int start = i;
                int lit = 0;
                while (i < n && lit < 128) {
                    if (i + 1 < n && row[i] == row[i + 1] && (i + 2 >= n || row[i + 1] == row[i + 2])) break;
                    i++;
                    lit++;
                }
                if (lit == 0) {
                    i++;
                    lit = 1;
                }
                uint8[] hdr = { (uint8) (lit - 1) };
                out_data.append(hdr);
                out_data.append(row[start:start + lit]);
            }
            return out_data.steal();
        }

        private uint8[] rle_channel(float[] plane, int w, int h, int depth, bool with_compression) {
            var counts = new ByteArray();
            var body = new ByteArray();
            int bpr = w * depth / 8;
            var row = new uint8[bpr];
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    float v = plane[(size_t) y * w + x].clamp(0, 1);
                    if (depth == 16) {
                        uint16 q = (uint16) (v * 65535 + 0.5f);
                        row[x * 2] = (uint8) (q >> 8);
                        row[x * 2 + 1] = (uint8) (q & 0xff);
                    } else {
                        row[x] = (uint8) (v * 255 + 0.5f);
                    }
                }
                var packed = pack_bits(row);
                uint8[] c = { (uint8) (packed.length >> 8), (uint8) (packed.length & 0xff) };
                counts.append(c);
                body.append(packed);
            }
            var out_data = new ByteArray();
            if (with_compression) {
                uint8[] comp = { 0, 1 };
                out_data.append(comp);
            }
            out_data.append(counts.data);
            out_data.append(body.data);
            return out_data.steal();
        }

        private class OutLayer {
            public string name;
            public int top;
            public int left;
            public int bottom;
            public int right;
            public FloatImage? pixels;
            public float[]? mask;
            public bool mask_enabled;
            public string blend;
            public float opacity;
            public bool visible;
            public bool locked;
            public int section;
        }

        private void collect(RetouchDocument doc, Gee.ArrayList<RetouchLayer> list, Gee.ArrayList<OutLayer> out_list) {
            foreach (var layer in list) {
                if (layer.kind == RetouchLayerKind.ADJUSTMENT) continue;
                if (layer.kind == RetouchLayerKind.GROUP) {
                    var divider = new OutLayer();
                    divider.name = "</Layer group>";
                    divider.blend = "norm";
                    divider.opacity = 1;
                    divider.visible = true;
                    divider.section = 3;
                    out_list.add(divider);
                    collect(doc, layer.children, out_list);
                    var folder = new OutLayer();
                    folder.name = layer.name;
                    folder.blend = layer.mode == BlendMode.NORMAL ? "pass" : layer.mode.psd_key();
                    folder.opacity = layer.opacity;
                    folder.visible = layer.visible;
                    folder.locked = layer.locked;
                    folder.section = layer.expanded ? 1 : 2;
                    folder.mask = layer.mask;
                    folder.mask_enabled = layer.mask_enabled;
                    out_list.add(folder);
                    continue;
                }
                var o = new OutLayer();
                o.name = layer.name;
                o.blend = layer.mode.psd_key();
                o.opacity = layer.opacity;
                o.visible = layer.visible;
                o.locked = layer.locked;
                o.mask = layer.mask;
                o.mask_enabled = layer.mask_enabled;
                if (layer.kind == RetouchLayerKind.RASTER && layer.pixels != null) {
                    o.pixels = layer.pixels;
                    o.left = layer.x;
                    o.top = layer.y;
                } else {
                    o.pixels = doc.render_layer_pixels(layer);
                }
                o.right = o.left + o.pixels.width;
                o.bottom = o.top + o.pixels.height;
                out_list.add(o);
            }
        }

        private float[] encoded_plane(FloatImage encoded, int c) {
            return encoded.channel(c);
        }

        public uint8[] write(RetouchDocument doc, int depth = 8) {
            var w = new Writer();
            var composite = doc.composite.copy();
            RetouchColor.working_to_encoded(composite);
            bool alpha = !composite.is_opaque();
            w.str("8BPS");
            w.u16(1);
            for (int i = 0; i < 6; i++) w.u8(0);
            w.u16(alpha ? 4 : 3);
            w.u32(doc.height);
            w.u32(doc.width);
            w.u16(depth);
            w.u16(3);
            w.u32(0);
            var icc = IccProfile.srgb().to_data();
            var res = new Writer();
            res.str("8BIM");
            res.u16(1039);
            res.u16(0);
            res.u32(icc.length);
            res.bytes(icc);
            if (icc.length % 2 == 1) res.u8(0);
            w.u32(res.buf.len);
            w.bytes(res.buf.data);

            var layers = new Gee.ArrayList<OutLayer>();
            collect(doc, doc.layers, layers);
            uint lm_pos = w.buf.len;
            w.u32(0);
            uint li_pos = w.buf.len;
            w.u32(0);
            int count = layers.size;
            w.u16((uint) (alpha ? -count : count) & 0xffff);
            var channel_data = new Gee.ArrayList<Gee.ArrayList<Bytes>>();
            foreach (var o in layers) {
                var chans = new Gee.ArrayList<Bytes>();
                var ids = new Gee.ArrayList<int>();
                if (o.pixels != null) {
                    var enc = o.pixels.copy();
                    RetouchColor.working_to_encoded(enc);
                    int pw = enc.width, ph = enc.height;
                    ids.add(-1);
                    chans.add(new Bytes(rle_channel(encoded_plane(enc, 3), pw, ph, depth, true)));
                    for (int c = 0; c < 3; c++) {
                        ids.add(c);
                        chans.add(new Bytes(rle_channel(encoded_plane(enc, c), pw, ph, depth, true)));
                    }
                } else {
                    for (int c = -1; c < 3; c++) {
                        ids.add(c);
                        uint8[] empty = { 0, 0 };
                        chans.add(new Bytes(empty));
                    }
                }
                if (o.mask != null) {
                    ids.add(-2);
                    chans.add(new Bytes(rle_channel(o.mask, doc.width, doc.height, depth, true)));
                }
                channel_data.add(chans);
                w.u32(o.top);
                w.u32(o.left);
                w.u32(o.bottom);
                w.u32(o.right);
                w.u16(ids.size);
                for (int i = 0; i < ids.size; i++) {
                    w.u16((uint) ids[i] & 0xffff);
                    w.u32(chans[i].length);
                }
                w.str("8BIM");
                w.str(o.blend);
                w.u8((uint) (o.opacity * 255 + 0.5f));
                w.u8(0);
                w.u8((o.visible ? 0 : 2) | 8 | (o.locked ? 1 : 0));
                w.u8(0);
                var extra = new Writer();
                if (o.mask != null) {
                    extra.u32(20);
                    extra.u32(0);
                    extra.u32(0);
                    extra.u32(doc.height);
                    extra.u32(doc.width);
                    extra.u8(0);
                    extra.u8(o.mask_enabled ? 0 : 2);
                    extra.u16(0);
                } else {
                    extra.u32(0);
                }
                extra.u32(0);
                var name_bytes = o.name.data;
                int nlen = int.min(255, name_bytes.length);
                extra.u8(nlen);
                extra.bytes(name_bytes[0:nlen]);
                int total = nlen + 1;
                while (total % 4 != 0) {
                    extra.u8(0);
                    total++;
                }
                extra.str("8BIM");
                extra.str("luni");
                var utf16 = new Writer();
                long chars = o.name.char_count();
                utf16.u32((uint32) chars);
                unichar ch;
                int idx = 0;
                while (o.name.get_next_char(ref idx, out ch)) utf16.u16((uint) ch & 0xffff);
                if (utf16.buf.len % 4 != 0) utf16.u16(0);
                extra.u32(utf16.buf.len);
                extra.bytes(utf16.buf.data);
                if (o.section != 0) {
                    extra.str("8BIM");
                    extra.str("lsct");
                    extra.u32(12);
                    extra.u32(o.section);
                    extra.str("8BIM");
                    extra.str(o.blend);
                }
                w.u32(extra.buf.len);
                w.bytes(extra.buf.data);
            }
            foreach (var chans in channel_data) foreach (var c in chans) w.bytes(c.get_data());
            if ((w.buf.len - li_pos - 4) % 2 == 1) w.u8(0);
            w.set_u32(li_pos, w.buf.len - li_pos - 4);
            w.u32(0);
            w.set_u32(lm_pos, w.buf.len - lm_pos - 4);

            w.u16(1);
            int channels = alpha ? 4 : 3;
            var counts = new Writer();
            var body = new Writer();
            for (int c = 0; c < channels; c++) {
                var data = rle_channel(encoded_plane(composite, c), doc.width, doc.height, depth, false);
                counts.bytes(data[0:doc.height * 2]);
                body.bytes(data[doc.height * 2:data.length]);
            }
            w.bytes(counts.buf.data);
            w.bytes(body.buf.data);
            return w.buf.steal();
        }
    }
}
