namespace Singularity.Apps.Photos {

    public errordomain RetouchFormatError {
        INVALID,
        UNSUPPORTED
    }

    namespace RetouchBytes {

        public string to_string(uint8[] data, int start, int length) {
            var buf = new uint8[length + 1];
            if (length > 0) Memory.copy(buf, &data[start], length);
            buf[length] = 0;
            return ((string) buf).dup();
        }
    }

    public class RetouchZipReader : Object {
        private class Entry {
            public string name;
            public int method;
            public uint32 compressed;
            public uint32 size;
            public uint32 offset;
        }

        private uint8[] data;
        private Gee.HashMap<string, Entry> entries = new Gee.HashMap<string, Entry>();

        private uint16 u16(int p) {
            return (uint16) (data[p] | (data[p + 1] << 8));
        }

        private uint32 u32(int p) {
            return (uint32) data[p] | ((uint32) data[p + 1] << 8) | ((uint32) data[p + 2] << 16) | ((uint32) data[p + 3] << 24);
        }

        public RetouchZipReader(uint8[] bytes) throws Error {
            data = bytes;
            int eocd = -1;
            for (int p = data.length - 22; p >= 0 && p >= data.length - 65557; p--) {
                if (u32(p) == 0x06054b50) {
                    eocd = p;
                    break;
                }
            }
            if (eocd < 0) throw new RetouchFormatError.INVALID("Not a zip archive");
            int count = u16(eocd + 10);
            int p = (int) u32(eocd + 16);
            for (int i = 0; i < count; i++) {
                if (p + 46 > data.length || u32(p) != 0x02014b50) throw new RetouchFormatError.INVALID("Broken zip directory");
                var e = new Entry();
                e.method = u16(p + 10);
                e.compressed = u32(p + 20);
                e.size = u32(p + 24);
                int name_len = u16(p + 28), extra_len = u16(p + 30), comment_len = u16(p + 32);
                e.offset = u32(p + 42);
                e.name = RetouchBytes.to_string(data, p + 46, name_len);
                entries[e.name] = e;
                p += 46 + name_len + extra_len + comment_len;
            }
        }

        public bool has(string name) {
            return entries.has_key(name);
        }

        public string[] names() {
            return entries.keys.to_array();
        }

        public uint8[] read(string name) throws Error {
            var e = entries[name];
            if (e == null) throw new RetouchFormatError.INVALID("Missing entry %s".printf(name));
            int p = (int) e.offset;
            if (p + 30 > data.length || u32(p) != 0x04034b50) throw new RetouchFormatError.INVALID("Broken zip entry");
            int start = p + 30 + u16(p + 26) + u16(p + 28);
            int end = start + (int) e.compressed;
            if (end > data.length) throw new RetouchFormatError.INVALID("Truncated zip entry");
            if (e.method == 0) return data[start:end];
            if (e.method != 8) throw new RetouchFormatError.UNSUPPORTED("Unsupported zip compression");
            var converter = new ZlibDecompressor(ZlibCompressorFormat.RAW);
            var out_data = new uint8[int.max(1, (int) e.size)];
            size_t read_bytes, written;
            converter.convert(data[start:end], out_data, ConverterFlags.INPUT_AT_END, out read_bytes, out written);
            out_data.length = (int) written;
            return out_data;
        }

        public string read_text(string name) throws Error {
            var bytes = read(name);
            return RetouchBytes.to_string(bytes, 0, bytes.length);
        }
    }

    public class RetouchZipWriter : Object {
        private ByteArray buffer = new ByteArray();
        private ByteArray directory = new ByteArray();
        private int count = 0;

        private static void put16(ByteArray a, uint v) {
            uint8[] b = { (uint8) (v & 0xff), (uint8) ((v >> 8) & 0xff) };
            a.append(b);
        }

        private static void put32(ByteArray a, uint32 v) {
            uint8[] b = { (uint8) (v & 0xff), (uint8) ((v >> 8) & 0xff), (uint8) ((v >> 16) & 0xff), (uint8) ((v >> 24) & 0xff) };
            a.append(b);
        }

        public void add(string name, uint8[] content, bool compress = true) throws Error {
            uint32 crc = (uint32) ZLib.Utility.crc32(0, content);
            uint8[] stored = content;
            int method = 0;
            if (compress && content.length > 64) {
                var converter = new ZlibCompressor(ZlibCompressorFormat.RAW, 6);
                var out_data = new uint8[content.length + content.length / 100 + 1024];
                size_t read_bytes, written;
                converter.convert(content, out_data, ConverterFlags.INPUT_AT_END, out read_bytes, out written);
                if (written < content.length) {
                    out_data.length = (int) written;
                    stored = out_data;
                    method = 8;
                }
            }
            uint32 offset = buffer.len;
            put32(buffer, 0x04034b50);
            put16(buffer, 20);
            put16(buffer, 0x0800);
            put16(buffer, method);
            put16(buffer, 0);
            put16(buffer, 0x21);
            put32(buffer, crc);
            put32(buffer, stored.length);
            put32(buffer, content.length);
            put16(buffer, name.length);
            put16(buffer, 0);
            buffer.append(name.data);
            buffer.append(stored);

            put32(directory, 0x02014b50);
            put16(directory, 20);
            put16(directory, 20);
            put16(directory, 0x0800);
            put16(directory, method);
            put16(directory, 0);
            put16(directory, 0x21);
            put32(directory, crc);
            put32(directory, stored.length);
            put32(directory, content.length);
            put16(directory, name.length);
            put16(directory, 0);
            put16(directory, 0);
            put16(directory, 0);
            put16(directory, 0);
            put32(directory, 0);
            put32(directory, offset);
            directory.append(name.data);
            count++;
        }

        public void add_text(string name, string text, bool compress = true) throws Error {
            add(name, text.data, compress);
        }

        public uint8[] finish() {
            uint32 dir_offset = buffer.len;
            uint32 dir_size = directory.len;
            buffer.append(directory.data);
            put32(buffer, 0x06054b50);
            put16(buffer, 0);
            put16(buffer, 0);
            put16(buffer, count);
            put16(buffer, count);
            put32(buffer, dir_size);
            put32(buffer, dir_offset);
            put16(buffer, 0);
            return buffer.steal();
        }
    }
}
