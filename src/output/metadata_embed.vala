namespace Singularity.Apps.Photos {

    public class ExifBuilder : Object {
        private class Entry {
            public uint16 tag;
            public uint16 type;
            public uint32 count;
            public uint8[] data;
        }

        private const uint16 BYTE = 1;
        private const uint16 ASCII = 2;
        private const uint16 SHORT = 3;
        private const uint16 LONG = 4;
        private const uint16 RATIONAL = 5;
        private const uint16 UNDEFINED = 7;
        private const uint16 SRATIONAL = 10;

        private Gee.ArrayList<Entry> ifd0 = new Gee.ArrayList<Entry>();
        private Gee.ArrayList<Entry> exif = new Gee.ArrayList<Entry>();
        private Gee.ArrayList<Entry> gps = new Gee.ArrayList<Entry>();

        private static void put16(ByteArray b, uint16 v) {
            uint8[] d = { (uint8) (v & 0xFF), (uint8) (v >> 8) };
            b.append(d);
        }

        private static void put32(ByteArray b, uint32 v) {
            uint8[] d = { (uint8) (v & 0xFF), (uint8) ((v >> 8) & 0xFF), (uint8) ((v >> 16) & 0xFF), (uint8) (v >> 24) };
            b.append(d);
        }

        private static void add(Gee.ArrayList<Entry> list, uint16 tag, uint16 type, uint32 count, uint8[] data) {
            var e = new Entry();
            e.tag = tag;
            e.type = type;
            e.count = count;
            e.data = data;
            list.add(e);
        }

        private static void ascii(Gee.ArrayList<Entry> list, uint16 tag, string value) {
            if (value.strip() == "") return;
            var b = new ByteArray();
            b.append(value.data);
            uint8[] zero = { 0 };
            b.append(zero);
            uint32 n = b.len;
            add(list, tag, ASCII, n, b.steal());
        }

        private static void short_value(Gee.ArrayList<Entry> list, uint16 tag, uint16 value) {
            var b = new ByteArray();
            put16(b, value);
            add(list, tag, SHORT, 1, b.steal());
        }

        private static void long_value(Gee.ArrayList<Entry> list, uint16 tag, uint32 value) {
            var b = new ByteArray();
            put32(b, value);
            add(list, tag, LONG, 1, b.steal());
        }

        private static void rationals(Gee.ArrayList<Entry> list, uint16 tag, double[] values, bool signed = false) {
            var b = new ByteArray();
            foreach (double v in values) {
                uint32 den = 1;
                double a = v.abs();
                while (den < 1000000 && (a * den - Math.floor(a * den)).abs() > 1e-6 && a * den * 10 < int32.MAX) den *= 10;
                if (!signed && v > 0 && v < 1 && (1.0 / v - Math.round(1.0 / v)).abs() < 1e-6) {
                    put32(b, 1);
                    put32(b, (uint32) Math.round(1.0 / v));
                    continue;
                }
                int64 num = (int64) Math.round(v * den);
                put32(b, (uint32) num);
                put32(b, den);
            }
            add(list, tag, signed ? SRATIONAL : RATIONAL, values.length, b.steal());
        }

        private static string exif_date(DateTime dt) {
            return dt.format("%Y:%m:%d %H:%M:%S");
        }

        public ExifBuilder.from_metadata(PhotoMetadata m, int width, int height, int ppi, bool camera, bool location, bool rights) {
            if (camera) {
                ascii(ifd0, 0x010F, m.make);
                ascii(ifd0, 0x0110, m.model);
            }
            short_value(ifd0, 0x0112, 1);
            rationals(ifd0, 0x011A, { (double) ppi });
            rationals(ifd0, 0x011B, { (double) ppi });
            short_value(ifd0, 0x0128, 2);
            ascii(ifd0, 0x0131, "Singularity Photos");
            ascii(ifd0, 0x0132, exif_date(new DateTime.now_local()));
            if (rights) {
                ascii(ifd0, 0x013B, m.creator);
                ascii(ifd0, 0x8298, m.copyright);
            }
            if (camera) {
                if (m.exposure_time > 0) rationals(exif, 0x829A, { m.exposure_time });
                if (m.aperture > 0) rationals(exif, 0x829D, { m.aperture });
                if (m.iso > 0) short_value(exif, 0x8827, (uint16) int.min(m.iso, 65535));
                if (m.exposure_bias != 0) rationals(exif, 0x9204, { m.exposure_bias }, true);
                short_value(exif, 0x9209, m.flash_fired ? 1 : 0);
                if (m.focal_length > 0) rationals(exif, 0x920A, { m.focal_length });
                if (m.focal_length_35 > 0) short_value(exif, 0xA405, (uint16) Math.round(m.focal_length_35));
                ascii(exif, 0xA431, m.serial);
                ascii(exif, 0xA434, m.lens);
            }
            add(exif, 0x9000, UNDEFINED, 4, "0232".data);
            if (m.date_taken != null) ascii(exif, 0x9003, exif_date(m.date_taken));
            long_value(exif, 0xA002, (uint32) width);
            long_value(exif, 0xA003, (uint32) height);
            if (location && m.has_gps) {
                add(gps, 0x0000, BYTE, 4, new uint8[] { 2, 3, 0, 0 });
                ascii(gps, 0x0001, m.latitude >= 0 ? "N" : "S");
                rationals(gps, 0x0002, dms(m.latitude));
                ascii(gps, 0x0003, m.longitude >= 0 ? "E" : "W");
                rationals(gps, 0x0004, dms(m.longitude));
                add(gps, 0x0005, BYTE, 1, new uint8[] { m.altitude < 0 ? 1 : 0 });
                rationals(gps, 0x0006, { m.altitude.abs() });
            }
        }

        private static double[] dms(double v) {
            double a = v.abs();
            double d = Math.floor(a);
            double mnt = Math.floor((a - d) * 60);
            double s = Math.round(((a - d) * 60 - mnt) * 60 * 1000) / 1000.0;
            return { d, mnt, s };
        }

        private static int ifd_size(Gee.ArrayList<Entry> list) {
            int n = 2 + list.size * 12 + 4;
            foreach (var e in list) if (e.data.length > 4) n += e.data.length + (e.data.length % 2);
            return n;
        }

        private static void write_ifd(ByteArray b, Gee.ArrayList<Entry> list, uint32 start, uint32 next) {
            list.sort((x, y) => (int) x.tag - (int) y.tag);
            put16(b, (uint16) list.size);
            uint32 data_at = start + 2 + list.size * 12 + 4;
            var extra = new ByteArray();
            foreach (var e in list) {
                put16(b, e.tag);
                put16(b, e.type);
                put32(b, e.count);
                if (e.data.length <= 4) {
                    var pad = new uint8[4];
                    for (int i = 0; i < e.data.length; i++) pad[i] = e.data[i];
                    b.append(pad);
                } else {
                    put32(b, data_at + extra.len);
                    extra.append(e.data);
                    if (e.data.length % 2 == 1) {
                        uint8[] z = { 0 };
                        extra.append(z);
                    }
                }
            }
            put32(b, next);
            b.append(extra.data);
        }

        public uint8[] build_tiff() {
            var ifd0_copy = new Gee.ArrayList<Entry>();
            ifd0_copy.add_all(ifd0);
            if (exif.size > 0) long_value(ifd0_copy, 0x8769, 0);
            if (gps.size > 0) long_value(ifd0_copy, 0x8825, 0);
            uint32 ifd0_at = 8;
            uint32 exif_at = ifd0_at + ifd_size(ifd0_copy);
            uint32 gps_at = exif_at + (exif.size > 0 ? ifd_size(exif) : 0);
            foreach (var e in ifd0_copy) {
                if (e.tag == 0x8769) {
                    var b = new ByteArray();
                    put32(b, exif_at);
                    e.data = b.steal();
                } else if (e.tag == 0x8825) {
                    var b = new ByteArray();
                    put32(b, gps_at);
                    e.data = b.steal();
                }
            }
            var out_data = new ByteArray();
            uint8[] header = { 'I', 'I', 42, 0 };
            out_data.append(header);
            put32(out_data, ifd0_at);
            write_ifd(out_data, ifd0_copy, ifd0_at, 0);
            if (exif.size > 0) write_ifd(out_data, exif, exif_at, 0);
            if (gps.size > 0) write_ifd(out_data, gps, gps_at, 0);
            return out_data.steal();
        }

        public uint8[] build_app1() {
            var b = new ByteArray();
            b.append("Exif".data);
            uint8[] z = { 0, 0 };
            b.append(z);
            b.append(build_tiff());
            return b.steal();
        }
    }

    public class EmbeddedMetadata : Object {
        public uint8[] exif_tiff = {};
        public string xmp = "";
        public uint8[] icc = {};

        public static EmbeddedMetadata build(PhotoMetadata m, string mode, int width, int height, int ppi) {
            var e = new EmbeddedMetadata();
            if (mode == "none") return e;
            bool camera = mode == "all";
            bool location = mode == "all";
            bool descriptive = mode == "all" || mode == "all-but-camera-location";
            e.exif_tiff = new ExifBuilder.from_metadata(m, width, height, ppi, camera, location, true).build_tiff();
            var x = new XmpPacket();
            if (m.creator != "") x.set_list(XmpPacket.NS_DC, "dc", "creator", "Seq", { m.creator });
            if (m.copyright != "") x.set_lang_alt(XmpPacket.NS_DC, "dc", "rights", m.copyright);
            if (m.credit != "") x.set_simple(XmpPacket.NS_PHOTOSHOP, "photoshop", "Credit", m.credit);
            if (descriptive) {
                if (m.title != "") x.set_lang_alt(XmpPacket.NS_DC, "dc", "title", m.title);
                if (m.caption != "") x.set_lang_alt(XmpPacket.NS_DC, "dc", "description", m.caption);
                if (m.headline != "") x.set_simple(XmpPacket.NS_PHOTOSHOP, "photoshop", "Headline", m.headline);
                if (m.keywords.length > 0) x.set_list(XmpPacket.NS_DC, "dc", "subject", "Bag", m.keywords);
                if (m.hierarchical_keywords.length > 0) x.set_list(XmpPacket.NS_LR, "lr", "hierarchicalSubject", "Bag", m.hierarchical_keywords);
                if (m.rating != 0) x.set_simple(XmpPacket.NS_XMP, "xmp", "Rating", m.rating.to_string());
                if (m.label != "") x.set_simple(XmpPacket.NS_XMP, "xmp", "Label", m.label);
            }
            if (location) {
                if (m.city != "") x.set_simple(XmpPacket.NS_PHOTOSHOP, "photoshop", "City", m.city);
                if (m.state != "") x.set_simple(XmpPacket.NS_PHOTOSHOP, "photoshop", "State", m.state);
                if (m.country != "") x.set_simple(XmpPacket.NS_PHOTOSHOP, "photoshop", "Country", m.country);
                if (m.country_code != "") x.set_simple(XmpPacket.NS_IPTC, "Iptc4xmpCore", "CountryCode", m.country_code);
                if (m.location != "") x.set_simple(XmpPacket.NS_IPTC, "Iptc4xmpCore", "Location", m.location);
            }
            if (camera) {
                if (m.make != "") x.set_simple(XmpPacket.NS_TIFF, "tiff", "Make", m.make);
                if (m.model != "") x.set_simple(XmpPacket.NS_TIFF, "tiff", "Model", m.model);
                if (m.lens != "") x.set_simple(XmpPacket.NS_AUX, "aux", "Lens", m.lens);
                if (m.exposure_time > 0) x.set_simple(XmpPacket.NS_EXIF, "exif", "ExposureTime", m.exposure_time < 1 ? "1/%d".printf((int) Math.round(1 / m.exposure_time)) : m.exposure_time.to_string());
                if (m.aperture > 0) x.set_simple(XmpPacket.NS_EXIF, "exif", "FNumber", "%d/10".printf((int) Math.round(m.aperture * 10)));
                if (m.iso > 0) x.set_list(XmpPacket.NS_EXIF, "exif", "ISOSpeedRatings", "Seq", { m.iso.to_string() });
                if (m.focal_length > 0) x.set_simple(XmpPacket.NS_EXIF, "exif", "FocalLength", "%d/10".printf((int) Math.round(m.focal_length * 10)));
            }
            if (m.date_taken != null && mode != "copyright") x.set_simple(XmpPacket.NS_EXIF, "exif", "DateTimeOriginal", m.date_taken.format("%Y-%m-%dT%H:%M:%S"));
            if (location && m.has_gps) {
                x.set_simple(XmpPacket.NS_EXIF, "exif", "GPSLatitude", xmp_coordinate(m.latitude, "N", "S"));
                x.set_simple(XmpPacket.NS_EXIF, "exif", "GPSLongitude", xmp_coordinate(m.longitude, "E", "W"));
            }
            x.set_simple(XmpPacket.NS_XMP, "xmp", "CreatorTool", "Singularity Photos");
            e.xmp = x.serialize();
            return e;
        }

        private static string xmp_coordinate(double v, string pos, string neg) {
            double a = v.abs();
            int d = (int) Math.floor(a);
            double minutes = (a - d) * 60;
            var buffer = new char[double.DTOSTR_BUF_SIZE];
            return "%d,%s%s".printf(d, minutes.format(buffer, "%.6f"), v >= 0 ? pos : neg);
        }

        public static uint8[] jpeg_xmp_segment(string xmp) {
            var b = new ByteArray();
            b.append("http://ns.adobe.com/xap/1.0/".data);
            uint8[] z = { 0 };
            b.append(z);
            b.append(xmp.data);
            return b.steal();
        }

        public static uint8[] inject_jpeg(uint8[] jpeg, Gee.List<Bytes> segments) {
            if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;
            int pos = 2;
            if (jpeg[2] == 0xFF && jpeg[3] == 0xE0 && jpeg.length > 6) pos = 4 + ((jpeg[4] << 8) | jpeg[5]);
            var out_data = new ByteArray();
            out_data.append(jpeg[0:pos]);
            foreach (var bytes in segments) {
                unowned uint8[] seg = bytes.get_data();
                if (seg.length == 0 || seg.length + 2 > 65535) continue;
                int len = seg.length + 2;
                uint8[] head = { 0xFF, 0xE1, (uint8) (len >> 8), (uint8) (len & 0xFF) };
                out_data.append(head);
                out_data.append(seg);
            }
            out_data.append(jpeg[pos:jpeg.length]);
            return out_data.steal();
        }
    }
}
