namespace Singularity.Apps.Photos {

    namespace MetadataWriter {

        public string gps_coordinate(double value, bool latitude) {
            double a = value.abs();
            int deg = (int) Math.floor(a);
            double minutes = (a - deg) * 60.0;
            string dir = latitude ? (value >= 0 ? "N" : "S") : (value >= 0 ? "E" : "W");
            return "%d,%s%s".printf(deg, "%.6f".printf(minutes).replace(",", "."), dir);
        }

        public double parse_gps(string text) {
            string s = text.strip();
            if (s == "") return 0;
            char dir = s[s.length - 1];
            bool has_dir = dir == 'N' || dir == 'S' || dir == 'E' || dir == 'W';
            if (has_dir) s = s.substring(0, s.length - 1);
            var parts = s.split(",");
            double v = 0;
            if (parts.length >= 3) v = double.parse(parts[0]) + double.parse(parts[1]) / 60.0 + double.parse(parts[2]) / 3600.0;
            else if (parts.length == 2) v = double.parse(parts[0]) + double.parse(parts[1]) / 60.0;
            else v = double.parse(parts[0]);
            if (dir == 'S' || dir == 'W') v = -v;
            return v;
        }

        private void text(XmpPacket p, string ns, string prefix, string name, string value) {
            if (value == "") p.remove(ns, name);
            else p.set_simple(ns, prefix, name, value);
        }

        private void lang(XmpPacket p, string ns, string prefix, string name, string value) {
            if (value == "") p.remove(ns, name);
            else p.set_lang_alt(ns, prefix, name, value);
        }

        public void to_xmp(PhotoMetadata m, XmpPacket p) {
            if (m.rating != 0) p.set_simple(XmpPacket.NS_XMP, "xmp", "Rating", m.rating.to_string());
            else p.remove(XmpPacket.NS_XMP, "Rating");
            text(p, XmpPacket.NS_XMP, "xmp", "Label", m.label);
            lang(p, XmpPacket.NS_DC, "dc", "title", m.title);
            lang(p, XmpPacket.NS_DC, "dc", "description", m.caption);
            lang(p, XmpPacket.NS_DC, "dc", "rights", m.copyright);
            if (m.creator != "") p.set_list(XmpPacket.NS_DC, "dc", "creator", "Seq", { m.creator });
            else p.remove(XmpPacket.NS_DC, "creator");
            var subjects = new Gee.ArrayList<string>();
            foreach (var k in m.keywords) if (k != "" && !subjects.contains(k)) subjects.add(k);
            foreach (var h in m.hierarchical_keywords) {
                var parts = h.split("|");
                string leaf = parts[parts.length - 1];
                if (leaf != "" && !subjects.contains(leaf)) subjects.add(leaf);
            }
            if (subjects.size > 0) p.set_list(XmpPacket.NS_DC, "dc", "subject", "Bag", subjects.to_array());
            else p.remove(XmpPacket.NS_DC, "subject");
            if (m.hierarchical_keywords.length > 0) p.set_list(XmpPacket.NS_LR, "lr", "hierarchicalSubject", "Bag", m.hierarchical_keywords);
            else p.remove(XmpPacket.NS_LR, "hierarchicalSubject");
            text(p, XmpPacket.NS_PHOTOSHOP, "photoshop", "Headline", m.headline);
            text(p, XmpPacket.NS_PHOTOSHOP, "photoshop", "Credit", m.credit);
            text(p, XmpPacket.NS_PHOTOSHOP, "photoshop", "City", m.city);
            text(p, XmpPacket.NS_PHOTOSHOP, "photoshop", "State", m.state);
            text(p, XmpPacket.NS_PHOTOSHOP, "photoshop", "Country", m.country);
            text(p, XmpPacket.NS_IPTC, "Iptc4xmpCore", "Location", m.location);
            text(p, XmpPacket.NS_IPTC, "Iptc4xmpCore", "CountryCode", m.country_code);
            if (m.date_taken != null) p.set_simple(XmpPacket.NS_PHOTOSHOP, "photoshop", "DateCreated", m.date_taken.format_iso8601());
            if (m.has_gps) {
                p.set_simple(XmpPacket.NS_EXIF, "exif", "GPSLatitude", gps_coordinate(m.latitude, true));
                p.set_simple(XmpPacket.NS_EXIF, "exif", "GPSLongitude", gps_coordinate(m.longitude, false));
                if (m.altitude != 0) {
                    p.set_simple(XmpPacket.NS_EXIF, "exif", "GPSAltitude", "%d/1000".printf((int) Math.round(m.altitude.abs() * 1000)));
                    p.set_simple(XmpPacket.NS_EXIF, "exif", "GPSAltitudeRef", m.altitude < 0 ? "1" : "0");
                }
            } else {
                p.remove(XmpPacket.NS_EXIF, "GPSLatitude");
                p.remove(XmpPacket.NS_EXIF, "GPSLongitude");
                p.remove(XmpPacket.NS_EXIF, "GPSAltitude");
                p.remove(XmpPacket.NS_EXIF, "GPSAltitudeRef");
            }
        }

        private double rational(string s) {
            var parts = s.split("/");
            if (parts.length == 2) {
                double d = double.parse(parts[1]);
                return d != 0 ? double.parse(parts[0]) / d : 0;
            }
            return double.parse(s);
        }

        public void from_xmp(XmpPacket p, PhotoMetadata m) {
            string? rating = p.get_simple(XmpPacket.NS_XMP, "Rating");
            if (rating != null) m.rating = (int) double.parse(rating);
            string? label = p.get_simple(XmpPacket.NS_XMP, "Label");
            if (label != null) m.label = label;
            string? title = p.get_lang_alt(XmpPacket.NS_DC, "title");
            if (title != null) m.title = title;
            string? desc = p.get_lang_alt(XmpPacket.NS_DC, "description");
            if (desc != null) m.caption = desc;
            string? rights = p.get_lang_alt(XmpPacket.NS_DC, "rights");
            if (rights != null) m.copyright = rights;
            var creators = p.get_list(XmpPacket.NS_DC, "creator");
            if (creators.length > 0) m.creator = string.joinv("; ", creators);
            var subjects = p.get_list(XmpPacket.NS_DC, "subject");
            if (subjects.length > 0) m.keywords = subjects;
            var hier = p.get_list(XmpPacket.NS_LR, "hierarchicalSubject");
            if (hier.length > 0) m.hierarchical_keywords = hier;
            string? v;
            if ((v = p.get_simple(XmpPacket.NS_PHOTOSHOP, "Headline")) != null) m.headline = v;
            if ((v = p.get_simple(XmpPacket.NS_PHOTOSHOP, "Credit")) != null) m.credit = v;
            if ((v = p.get_simple(XmpPacket.NS_PHOTOSHOP, "City")) != null) m.city = v;
            if ((v = p.get_simple(XmpPacket.NS_PHOTOSHOP, "State")) != null) m.state = v;
            if ((v = p.get_simple(XmpPacket.NS_PHOTOSHOP, "Country")) != null) m.country = v;
            if ((v = p.get_simple(XmpPacket.NS_IPTC, "Location")) != null) m.location = v;
            if ((v = p.get_simple(XmpPacket.NS_IPTC, "CountryCode")) != null) m.country_code = v;
            if (m.date_taken == null) {
                v = p.get_simple(XmpPacket.NS_PHOTOSHOP, "DateCreated") ?? p.get_simple(XmpPacket.NS_EXIF, "DateTimeOriginal") ?? p.get_simple(XmpPacket.NS_XMP, "CreateDate");
                if (v != null) {
                    var dt = new DateTime.from_iso8601(v, new TimeZone.local());
                    if (dt == null && v.length == 10) dt = new DateTime.from_iso8601(v + "T00:00:00", new TimeZone.local());
                    if (dt != null) m.date_taken = dt;
                }
            }
            string? lat = p.get_simple(XmpPacket.NS_EXIF, "GPSLatitude"), lon = p.get_simple(XmpPacket.NS_EXIF, "GPSLongitude");
            if (lat != null && lon != null) {
                m.latitude = parse_gps(lat);
                m.longitude = parse_gps(lon);
                m.has_gps = true;
                string? alt = p.get_simple(XmpPacket.NS_EXIF, "GPSAltitude");
                if (alt != null) {
                    m.altitude = rational(alt);
                    if (p.get_simple(XmpPacket.NS_EXIF, "GPSAltitudeRef") == "1") m.altitude = -m.altitude;
                }
            }
            if (m.lens == "" && (v = p.get_simple(XmpPacket.NS_AUX, "Lens")) != null) m.lens = v;
            if (m.make == "" && (v = p.get_simple(XmpPacket.NS_TIFF, "Make")) != null) m.make = v;
            if (m.model == "" && (v = p.get_simple(XmpPacket.NS_TIFF, "Model")) != null) m.model = v;
        }

        public void save_sidecar(File photo, PhotoMetadata m) throws Error {
            var existing = XmpSidecar.load(photo);
            to_xmp(m, existing);
            XmpSidecar.save(photo, existing, false);
        }
    }
}
