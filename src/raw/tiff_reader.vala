namespace Singularity.Apps.Photos {

    public class TiffEntry : Object {
        public uint16 tag;
        public uint16 kind;
        public uint32 count;
        public size_t data_offset;

        public int unit_size() {
            switch (kind) {
                case 1: case 2: case 6: case 7: return 1;
                case 3: case 8: return 2;
                case 4: case 9: case 11: case 13: return 4;
                case 5: case 10: case 12: return 8;
                default: return 1;
            }
        }
    }

    public class TiffIfd : Object {
        public size_t offset;
        public Gee.HashMap<int, TiffEntry> entries = new Gee.HashMap<int, TiffEntry>();
        public size_t next_offset = 0;

        public bool has(int tag) {
            return entries.has_key(tag);
        }
    }

    public class TiffReader : Object {
        public uint8[] data;
        public bool little = true;
        public size_t base_offset = 0;
        public size_t first_ifd = 0;

        public TiffReader(owned uint8[] data, size_t base_offset = 0) throws Error {
            this.data = (owned) data;
            this.base_offset = base_offset;
            if (this.data.length < base_offset + 8) throw new IOError.INVALID_DATA("Not a TIFF stream");
            uint8 a = this.data[base_offset], b = this.data[base_offset + 1];
            if (a == 'I' && b == 'I') little = true;
            else if (a == 'M' && b == 'M') little = false;
            else throw new IOError.INVALID_DATA("Not a TIFF stream");
            uint16 magic = u16(base_offset + 2);
            if (magic != 42 && magic != 0x4352 && magic != 0x4F52 && magic != 0x5352 && magic != 0x55) throw new IOError.INVALID_DATA("Not a TIFF stream");
            first_ifd = u32(base_offset + 4);
        }

        public static TiffReader from_file(File file) throws Error {
            uint8[] contents;
            file.load_contents(null, out contents, null);
            return new TiffReader((owned) contents);
        }

        public bool in_range(size_t pos, size_t len) {
            return pos + len <= data.length && pos + len >= pos;
        }

        public uint16 u16(size_t pos) {
            if (!in_range(pos, 2)) return 0;
            return little ? (uint16) (data[pos] | (data[pos + 1] << 8)) : (uint16) ((data[pos] << 8) | data[pos + 1]);
        }

        public uint32 u32(size_t pos) {
            if (!in_range(pos, 4)) return 0;
            if (little) return (uint32) data[pos] | ((uint32) data[pos + 1] << 8) | ((uint32) data[pos + 2] << 16) | ((uint32) data[pos + 3] << 24);
            return ((uint32) data[pos] << 24) | ((uint32) data[pos + 1] << 16) | ((uint32) data[pos + 2] << 8) | (uint32) data[pos + 3];
        }

        public float f32(size_t pos) {
            uint32 bits = u32(pos);
            return *((float*) (&bits));
        }

        public double f64(size_t pos) {
            uint64 hi = u32(pos), lo = u32(pos + 4);
            uint64 bits = little ? (lo << 32) | hi : (hi << 32) | lo;
            return *((double*) (&bits));
        }

        public TiffIfd? read_ifd(size_t rel_offset) {
            size_t pos = base_offset + rel_offset;
            if (rel_offset == 0 || !in_range(pos, 2)) return null;
            int n = u16(pos);
            if (!in_range(pos + 2, (size_t) n * 12)) return null;
            var ifd = new TiffIfd();
            ifd.offset = rel_offset;
            for (int i = 0; i < n; i++) {
                size_t e = pos + 2 + (size_t) i * 12;
                var entry = new TiffEntry();
                entry.tag = u16(e);
                entry.kind = u16(e + 2);
                entry.count = u32(e + 4);
                size_t total = (size_t) entry.count * entry.unit_size();
                entry.data_offset = total <= 4 ? e + 8 : base_offset + u32(e + 8);
                if (!in_range(entry.data_offset, total)) continue;
                ifd.entries[entry.tag] = entry;
            }
            ifd.next_offset = u32(pos + 2 + (size_t) n * 12);
            return ifd;
        }

        public Gee.ArrayList<TiffIfd> chain() {
            var list = new Gee.ArrayList<TiffIfd>();
            size_t off = first_ifd;
            int guard = 0;
            while (off != 0 && guard++ < 64) {
                var ifd = read_ifd(off);
                if (ifd == null) break;
                list.add(ifd);
                off = ifd.next_offset;
            }
            return list;
        }

        public Gee.ArrayList<TiffIfd> all_ifds() {
            var list = new Gee.ArrayList<TiffIfd>();
            var seen = new Gee.HashSet<string>();
            foreach (var ifd in chain()) collect(ifd, list, seen, 0);
            return list;
        }

        private void collect(TiffIfd ifd, Gee.ArrayList<TiffIfd> list, Gee.HashSet<string> seen, int depth) {
            if (depth > 4 || seen.contains(ifd.offset.to_string())) return;
            seen.add(ifd.offset.to_string());
            list.add(ifd);
            if (!ifd.has(330)) return;
            var e = ifd.entries[330];
            for (uint i = 0; i < e.count; i++) {
                var sub = read_ifd(uint_at(e, i));
                if (sub != null) collect(sub, list, seen, depth + 1);
            }
        }

        public uint32 uint_at(TiffEntry e, uint index) {
            if (index >= e.count) return 0;
            size_t p = e.data_offset + (size_t) index * e.unit_size();
            switch (e.kind) {
                case 1: case 7: return data[p];
                case 6: return (uint32) (int8) data[p];
                case 3: return u16(p);
                case 8: return (uint32) (int16) u16(p);
                default: return u32(p);
            }
        }

        public double double_at(TiffEntry e, uint index) {
            if (index >= e.count) return 0;
            size_t p = e.data_offset + (size_t) index * e.unit_size();
            switch (e.kind) {
                case 5: {
                    uint32 den = u32(p + 4);
                    return den == 0 ? 0 : (double) u32(p) / den;
                }
                case 10: {
                    int32 den = (int32) u32(p + 4);
                    return den == 0 ? 0 : (double) (int32) u32(p) / den;
                }
                case 11: return f32(p);
                case 12: return f64(p);
                case 8: return (int16) u16(p);
                case 9: return (int32) u32(p);
                case 6: return (int8) data[p];
                default: return uint_at(e, index);
            }
        }

        public uint32 get_uint(TiffIfd ifd, int tag, uint32 fallback = 0, uint index = 0) {
            if (!ifd.has(tag)) return fallback;
            var e = ifd.entries[tag];
            if (index >= e.count) return fallback;
            return uint_at(e, index);
        }

        public double get_double(TiffIfd ifd, int tag, double fallback = 0, uint index = 0) {
            if (!ifd.has(tag)) return fallback;
            var e = ifd.entries[tag];
            if (index >= e.count) return fallback;
            return double_at(e, index);
        }

        public double[] get_doubles(TiffIfd ifd, int tag) {
            if (!ifd.has(tag)) return {};
            var e = ifd.entries[tag];
            var out_v = new double[e.count];
            for (uint i = 0; i < e.count; i++) out_v[i] = double_at(e, i);
            return out_v;
        }

        public uint32[] get_uints(TiffIfd ifd, int tag) {
            if (!ifd.has(tag)) return {};
            var e = ifd.entries[tag];
            var out_v = new uint32[e.count];
            for (uint i = 0; i < e.count; i++) out_v[i] = uint_at(e, i);
            return out_v;
        }

        public string get_string(TiffIfd ifd, int tag) {
            if (!ifd.has(tag)) return "";
            var e = ifd.entries[tag];
            var sb = new StringBuilder();
            for (uint i = 0; i < e.count; i++) {
                uint8 c = data[e.data_offset + i];
                if (c == 0) break;
                sb.append_c((char) c);
            }
            string s = sb.str.strip();
            return s.validate() ? s : s.make_valid();
        }

        public uint8[] get_bytes(TiffIfd ifd, int tag) {
            if (!ifd.has(tag)) return new uint8[0];
            var e = ifd.entries[tag];
            size_t len = (size_t) e.count * e.unit_size();
            return data[e.data_offset:e.data_offset + len];
        }
    }
}
