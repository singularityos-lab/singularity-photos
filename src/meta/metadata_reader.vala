namespace Singularity.Apps.Photos {

    namespace MetadataReader {

        public const size_t HEAD_BYTES = 8 * 1024 * 1024;

        public uint8[] read_head(File file, size_t limit = HEAD_BYTES) {
            try {
                var stream = file.read();
                var buf = new uint8[limit];
                size_t got;
                stream.read_all(buf, out got);
                buf.length = (int) got;
                return buf;
            } catch (Error e) {
                return new uint8[0];
            }
        }

        public PhotoMetadata read(File file) {
            var m = new PhotoMetadata();
            var data = read_head(file);
            if (data.length > 0) read_data(data, m);
            var sidecar = XmpSidecar.find(file);
            if (sidecar != null) MetadataWriter.from_xmp(XmpSidecar.load(file), m);
            return m;
        }

        public PhotoMetadata read_bytes(uint8[] data) {
            var m = new PhotoMetadata();
            read_data(data, m);
            return m;
        }

        private void read_data(uint8[] data, PhotoMetadata m) {
            var tiff = find_tiff(data);
            if (tiff != null) read_exif(tiff, m);
            var xmp = XmpPacket.from_embedded(data);
            if (xmp == null && tiff != null) {
                foreach (var ifd in tiff.chain()) {
                    var bytes = tiff.get_bytes(ifd, 700);
                    if (bytes.length > 0) {
                        try {
                            xmp = XmpPacket.parse(XmpExtract.bytes_to_string(bytes));
                        } catch (Error e) {
                        }
                        break;
                    }
                }
            }
            if (xmp != null) MetadataWriter.from_xmp(xmp, m);
            if (data.length > 24 && data[0] == 0x89 && data[1] == 'P') read_png_size(data, m);
            if (data.length > 4 && data[0] == 0xFF && data[1] == 0xD8) read_jpeg_size(data, m);
        }

        private void read_jpeg_size(uint8[] data, PhotoMetadata m) {
            int pos = 2;
            while (pos + 9 < data.length) {
                if (data[pos] != 0xFF) break;
                uint8 marker = data[pos + 1];
                int len = (data[pos + 2] << 8) | data[pos + 3];
                if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
                    int h = (data[pos + 5] << 8) | data[pos + 6], w = (data[pos + 7] << 8) | data[pos + 8];
                    if (w > 0 && h > 0) {
                        bool swap = m.orientation >= 5 && m.orientation <= 8;
                        m.width = swap ? h : w;
                        m.height = swap ? w : h;
                    }
                    return;
                }
                if (marker == 0xD9 || marker == 0xDA || len < 2) break;
                pos += 2 + len;
            }
        }

        private void read_png_size(uint8[] data, PhotoMetadata m) {
            if (m.width > 0) return;
            m.width = (int) (((uint32) data[16] << 24) | ((uint32) data[17] << 16) | ((uint32) data[18] << 8) | data[19]);
            m.height = (int) (((uint32) data[20] << 24) | ((uint32) data[21] << 16) | ((uint32) data[22] << 8) | data[23]);
        }

        private bool tiff_header_at(uint8[] data, size_t p) {
            if (p + 8 > data.length) return false;
            if (data[p] == 'I' && data[p + 1] == 'I' && (data[p + 2] == 42 || data[p + 2] == 0x52 || data[p + 2] == 0x55) && (data[p + 3] == 0 || data[p + 3] == 0x4F)) return true;
            if (data[p] == 'M' && data[p + 1] == 'M' && data[p + 2] == 0 && data[p + 3] == 42) return true;
            return false;
        }

        public TiffReader? find_tiff(uint8[] data) {
            try {
                if (data.length > 4 && data[0] == 0xFF && data[1] == 0xD8) {
                    int pos = 2;
                    while (pos + 4 <= data.length) {
                        if (data[pos] != 0xFF) break;
                        uint8 marker = data[pos + 1];
                        if (marker == 0xD9 || marker == 0xDA) break;
                        int len = (data[pos + 2] << 8) | data[pos + 3];
                        if (len < 2 || pos + 2 + len > data.length) break;
                        if (marker == 0xE1 && len > 10 && data[pos + 4] == 'E' && data[pos + 5] == 'x' && data[pos + 6] == 'i' && data[pos + 7] == 'f')
                            return new TiffReader(data[pos + 10:pos + 2 + len]);
                        pos += 2 + len;
                    }
                    return null;
                }
                if (data.length > 8 && data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G') {
                    int pos = 8;
                    while (pos + 12 <= data.length) {
                        uint32 len = ((uint32) data[pos] << 24) | ((uint32) data[pos + 1] << 16) | ((uint32) data[pos + 2] << 8) | data[pos + 3];
                        if (pos + 12 + (int64) len > data.length) break;
                        if (Memory.cmp(&data[pos + 4], "eXIf".data, 4) == 0) return new TiffReader(data[pos + 8:pos + 8 + (int) len]);
                        if (Memory.cmp(&data[pos + 4], "IEND".data, 4) == 0) break;
                        pos += 12 + (int) len;
                    }
                    return null;
                }
                if (tiff_header_at(data, 0)) return new TiffReader(data);
                int limit = int.min(data.length - 8, 4 * 1024 * 1024);
                for (int i = 0; i < limit; i++) {
                    if (data[i] == 'E' && data[i + 1] == 'x' && data[i + 2] == 'i' && data[i + 3] == 'f' && data[i + 4] == 0 && data[i + 5] == 0 && tiff_header_at(data, i + 6))
                        return new TiffReader(data[i + 6:data.length]);
                    if (data[i] == 'C' && data[i + 1] == 'M' && data[i + 2] == 'T' && data[i + 3] == '1' && tiff_header_at(data, i + 8))
                        return new TiffReader(data[i + 8:data.length]);
                }
            } catch (Error e) {
            }
            return null;
        }

        private DateTime? parse_date(string text, string offset) {
            string s = text.strip();
            if (s.length < 19) return null;
            int y = int.parse(s.substring(0, 4)), mo = int.parse(s.substring(5, 2)), d = int.parse(s.substring(8, 2));
            int h = int.parse(s.substring(11, 2)), mi = int.parse(s.substring(14, 2)), se = int.parse(s.substring(17, 2));
            if (y < 1800 || mo < 1 || mo > 12 || d < 1 || d > 31) return null;
            TimeZone tz;
            if (offset.length >= 6) {
                try {
                    tz = new TimeZone.identifier(offset.substring(0, 6));
                } catch (Error e) {
                    tz = new TimeZone.local();
                }
            } else {
                tz = new TimeZone.local();
            }
            return new DateTime(tz, y, mo, d, h, mi, se);
        }

        private double gps_value(TiffReader r, TiffIfd ifd, int tag) {
            var v = r.get_doubles(ifd, tag);
            if (v.length >= 3) return v[0] + v[1] / 60.0 + v[2] / 3600.0;
            if (v.length == 1) return v[0];
            return 0;
        }

        public void read_exif(TiffReader r, PhotoMetadata m) {
            var chain = r.chain();
            if (chain.size == 0) return;
            var ifd0 = chain[0];
            m.make = r.get_string(ifd0, 271);
            m.model = r.get_string(ifd0, 272);
            m.software = r.get_string(ifd0, 305);
            int orient = (int) r.get_uint(ifd0, 274, 1);
            if (orient >= 1 && orient <= 8) m.orientation = orient;
            string artist = r.get_string(ifd0, 315);
            if (artist != "") m.creator = artist;
            string copyright = r.get_string(ifd0, 33432);
            if (copyright != "") m.copyright = copyright;
            string description = r.get_string(ifd0, 270);
            if (description != "" && description.down() != "default" && !description.has_prefix("OLYMPUS")) m.caption = description;
            uint32 rating = r.get_uint(ifd0, 18246, 0);
            if (rating > 0 && rating <= 5) m.rating = (int) rating;
            string date = r.get_string(ifd0, 306);
            if (ifd0.has(50706)) {
                string ucm = r.get_string(ifd0, 50708);
                if (m.model == "" && ucm != "") m.model = ucm;
            }
            uint32 exif_off = r.get_uint(ifd0, 34665, 0);
            if (exif_off > 0) {
                var exif = r.read_ifd(exif_off);
                if (exif != null) {
                    m.exposure_time = r.get_double(exif, 33434, 0);
                    m.aperture = r.get_double(exif, 33437, 0);
                    if (m.aperture <= 0) {
                        double av = r.get_double(exif, 37378, 0);
                        if (av > 0) m.aperture = Math.pow(2, av / 2);
                    }
                    int iso = (int) r.get_uint(exif, 34855, 0);
                    if (iso == 0) iso = (int) r.get_uint(exif, 34867, 0);
                    m.iso = iso;
                    m.exposure_bias = r.get_double(exif, 37380, 0);
                    m.flash_fired = (r.get_uint(exif, 37385, 0) & 1) != 0;
                    m.focal_length = r.get_double(exif, 37386, 0);
                    m.focal_length_35 = r.get_uint(exif, 41989, 0);
                    string lens = r.get_string(exif, 42036);
                    string lens_make = r.get_string(exif, 42035);
                    if (lens != "") m.lens = lens_make != "" && !lens.down().has_prefix(lens_make.down()) ? lens_make + " " + lens : lens;
                    string serial = r.get_string(exif, 42033);
                    if (serial != "") m.serial = serial;
                    int pw = (int) r.get_uint(exif, 40962, 0), ph = (int) r.get_uint(exif, 40963, 0);
                    if (pw > 0 && ph > 0) {
                        m.width = pw;
                        m.height = ph;
                    }
                    string original = r.get_string(exif, 36867);
                    if (original == "") original = r.get_string(exif, 36868);
                    if (original != "") date = original;
                    string offset = r.get_string(exif, 36881);
                    if (offset == "") offset = r.get_string(exif, 36880);
                    if (date != "") m.date_taken = parse_date(date, offset);
                }
            } else if (date != "") {
                m.date_taken = parse_date(date, "");
            }
            if (m.width == 0) {
                m.width = (int) r.get_uint(ifd0, 256, 0);
                m.height = (int) r.get_uint(ifd0, 257, 0);
            }
            if (m.lens == "") {
                var lens_info = r.get_doubles(ifd0, 50736);
                if (lens_info.length >= 4 && lens_info[0] > 0) {
                    m.lens = lens_info[0] == lens_info[1] ? "%g mm f/%g".printf(lens_info[0], lens_info[2]) : "%g-%g mm f/%g-%g".printf(lens_info[0], lens_info[1], lens_info[2], lens_info[3]);
                }
            }
            uint32 gps_off = r.get_uint(ifd0, 34853, 0);
            if (gps_off > 0) {
                var gps = r.read_ifd(gps_off);
                if (gps != null && gps.has(2) && gps.has(4)) {
                    double lat = gps_value(r, gps, 2), lon = gps_value(r, gps, 4);
                    if (r.get_string(gps, 1).up() == "S") lat = -lat;
                    if (r.get_string(gps, 3).up() == "W") lon = -lon;
                    if (lat != 0 || lon != 0) {
                        m.has_gps = true;
                        m.latitude = lat;
                        m.longitude = lon;
                        if (gps.has(6)) {
                            m.altitude = r.get_double(gps, 6, 0);
                            if (r.get_uint(gps, 5, 0) == 1) m.altitude = -m.altitude;
                        }
                    }
                }
            }
        }
    }
}
