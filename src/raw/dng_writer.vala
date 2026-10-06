using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class TiffWriter : Object {
        private class Tag {
            public uint16 tag;
            public uint16 kind;
            public uint32 count;
            public uint8[] bytes;
        }

        private Gee.ArrayList<Tag> tags = new Gee.ArrayList<Tag>();
        private uint8[] strip = {};
        private int strip_tag_index = -1;

        private static void put16(ByteArray b, uint16 v) {
            b.append({ (uint8) v, (uint8) (v >> 8) });
        }

        private static void put32(ByteArray b, uint32 v) {
            b.append({ (uint8) v, (uint8) (v >> 8), (uint8) (v >> 16), (uint8) (v >> 24) });
        }

        private void add(uint16 tag, uint16 kind, uint32 count, uint8[] bytes) {
            foreach (var t in tags) {
                if (t.tag == tag) {
                    tags.remove(t);
                    break;
                }
            }
            var t = new Tag();
            t.tag = tag;
            t.kind = kind;
            t.count = count;
            t.bytes = bytes;
            tags.add(t);
        }

        public void set_short(uint16 tag, uint16[] values) {
            var b = new ByteArray();
            foreach (var v in values) put16(b, v);
            add(tag, 3, values.length, b.steal());
        }

        public void set_long(uint16 tag, uint32[] values) {
            var b = new ByteArray();
            foreach (var v in values) put32(b, v);
            add(tag, 4, values.length, b.steal());
        }

        public void set_byte(uint16 tag, uint8[] values) {
            add(tag, 1, values.length, values);
        }

        public void set_ascii(uint16 tag, string value) {
            var b = new ByteArray();
            b.append(value.data);
            b.append({ 0 });
            add(tag, 2, value.length + 1, b.steal());
        }

        public void set_rational(uint16 tag, double[] values) {
            var b = new ByteArray();
            foreach (var v in values) {
                uint32 den = 1000000;
                put32(b, (uint32) Math.round(double.max(0, v) * den));
                put32(b, den);
            }
            add(tag, 5, values.length, b.steal());
        }

        public void set_srational(uint16 tag, double[] values) {
            var b = new ByteArray();
            foreach (var v in values) {
                int32 den = 1000000;
                put32(b, (uint32) (int32) Math.round(v * den));
                put32(b, (uint32) den);
            }
            add(tag, 10, values.length, b.steal());
        }

        public void set_undefined(uint16 tag, uint8[] values) {
            add(tag, 7, values.length, values);
        }

        public void set_strip(owned uint8[] data) {
            strip = (owned) data;
            set_long(273, { 0 });
            set_long(279, { (uint32) strip.length });
            set_long(278, { (uint32) 0xFFFFFFFFu });
        }

        public uint8[] build() {
            tags.sort((a, b) => (int) a.tag - (int) b.tag);
            uint32 ifd_size = (uint32) (2 + tags.size * 12 + 4);
            uint32 data_start = 8 + ifd_size;
            uint32 data_len = 0;
            foreach (var t in tags) if (t.bytes.length > 4) data_len += (uint32) ((t.bytes.length + 1) & ~1);
            uint32 strip_offset = data_start + data_len;
            for (int i = 0; i < tags.size; i++) {
                if (tags[i].tag == 273) {
                    var b = new ByteArray();
                    put32(b, strip_offset);
                    tags[i].bytes = b.steal();
                    strip_tag_index = i;
                }
            }
            var out_b = new ByteArray();
            out_b.append({ 'I', 'I', 42, 0 });
            put32(out_b, 8);
            put16(out_b, (uint16) tags.size);
            uint32 cursor = data_start;
            foreach (var t in tags) {
                put16(out_b, t.tag);
                put16(out_b, t.kind);
                put32(out_b, t.count);
                if (t.bytes.length <= 4) {
                    var inline = new uint8[4];
                    for (int i = 0; i < t.bytes.length; i++) inline[i] = t.bytes[i];
                    out_b.append(inline);
                } else {
                    put32(out_b, cursor);
                    cursor += (uint32) ((t.bytes.length + 1) & ~1);
                }
            }
            put32(out_b, 0);
            foreach (var t in tags) {
                if (t.bytes.length <= 4) continue;
                out_b.append(t.bytes);
                if (t.bytes.length % 2 == 1) out_b.append({ 0 });
            }
            out_b.append(strip);
            return out_b.steal();
        }
    }

    namespace DngWriter {

        private void common(TiffWriter t, PhotoMetadata? meta, string camera) {
            t.set_long(254, { 0 });
            t.set_short(274, { 1 });
            t.set_short(284, { 1 });
            t.set_ascii(305, "Singularity Photos");
            t.set_byte(50706, { 1, 4, 0, 0 });
            t.set_byte(50707, { 1, 1, 0, 0 });
            t.set_ascii(50708, camera);
            if (meta != null) {
                if (meta.make != "") t.set_ascii(271, meta.make);
                if (meta.model != "") t.set_ascii(272, meta.model);
                if (meta.creator != "") t.set_ascii(315, meta.creator);
                if (meta.copyright != "") t.set_ascii(33432, meta.copyright);
            }
        }

        public double[] xyz_to_working() {
            return Matrix3.invert(WorkingSpace.primaries().to_xyz());
        }

        public uint8[] linear_bytes(FloatImage working, PhotoMetadata? meta = null, bool float32 = true) {
            var t = new TiffWriter();
            common(t, meta, meta != null && meta.model != "" ? meta.camera_label() : "Singularity Photos Linear");
            int w = working.width, h = working.height;
            t.set_long(256, { (uint32) w });
            t.set_long(257, { (uint32) h });
            t.set_short(259, { 1 });
            t.set_short(262, { 34892 });
            t.set_short(277, { 3 });
            var b = new ByteArray();
            size_t n = working.pixel_count();
            if (float32) {
                t.set_short(258, { 32, 32, 32 });
                t.set_short(339, { 3, 3, 3 });
                var buf = new uint8[n * 12];
                for (size_t i = 0; i < n; i++) {
                    for (int c = 0; c < 3; c++) {
                        float v = working.data[i * 4 + c];
                        uint32 bits = *((uint32*) (&v));
                        size_t p = (i * 3 + c) * 4;
                        buf[p] = (uint8) bits;
                        buf[p + 1] = (uint8) (bits >> 8);
                        buf[p + 2] = (uint8) (bits >> 16);
                        buf[p + 3] = (uint8) (bits >> 24);
                    }
                }
                t.set_strip((owned) buf);
                t.set_rational(50717, { 1.0 });
            } else {
                t.set_short(258, { 16, 16, 16 });
                var buf = new uint8[n * 6];
                for (size_t i = 0; i < n; i++) {
                    for (int c = 0; c < 3; c++) {
                        uint16 v = (uint16) (working.data[i * 4 + c].clamp(0, 1) * 65535 + 0.5f);
                        size_t p = (i * 3 + c) * 2;
                        buf[p] = (uint8) v;
                        buf[p + 1] = (uint8) (v >> 8);
                    }
                }
                t.set_strip((owned) buf);
                t.set_long(50717, { 65535 });
            }
            b = null;
            t.set_srational(50721, xyz_to_working());
            t.set_short(50778, { 21 });
            t.set_rational(50728, { 1.0, 1.0, 1.0 });
            t.set_srational(50730, { 0.0 });
            return t.build();
        }

        public void write_linear(FloatImage working, File target, PhotoMetadata? meta = null, bool float32 = true) throws Error {
            var data = linear_bytes(working, meta, float32);
            target.replace_contents(data, null, false, FileCreateFlags.REPLACE_DESTINATION, null);
        }

        public uint8[] cfa_bytes(float[] cfa, int w, int h, string pattern, double[] color_matrix, double[] as_shot_neutral, bool lossless_jpeg, PhotoMetadata? meta = null, int black = 0, int white = 65535) {
            var t = new TiffWriter();
            common(t, meta, "Singularity Test CFA");
            t.set_long(256, { (uint32) w });
            t.set_long(257, { (uint32) h });
            t.set_short(258, { 16 });
            t.set_short(262, { 32803 });
            t.set_short(277, { 1 });
            t.set_short(33421, { 2, 2 });
            var pat = new uint8[4];
            for (int i = 0; i < 4; i++) pat[i] = pattern.up()[i] == 'R' ? 0 : (pattern.up()[i] == 'G' ? 1 : 2);
            t.set_byte(33422, pat);
            t.set_byte(50710, { 0, 1, 2 });
            t.set_short(50711, { 1 });
            t.set_long(50714, { (uint32) black });
            t.set_long(50717, { (uint32) white });
            var samples = new uint16[(size_t) w * h];
            for (size_t i = 0; i < samples.length; i++) samples[i] = (uint16) (black + cfa[i].clamp(0, 1) * (white - black) + 0.5f);
            if (lossless_jpeg) {
                t.set_short(259, { 7 });
                t.set_strip(Ljpeg.encode(samples, w, h, 1, 16));
            } else {
                t.set_short(259, { 1 });
                var buf = new uint8[samples.length * 2];
                for (size_t i = 0; i < samples.length; i++) {
                    buf[i * 2] = (uint8) samples[i];
                    buf[i * 2 + 1] = (uint8) (samples[i] >> 8);
                }
                t.set_strip((owned) buf);
            }
            t.set_srational(50721, color_matrix);
            t.set_short(50778, { 21 });
            t.set_rational(50728, as_shot_neutral);
            return t.build();
        }
    }
}
