namespace Singularity.Apps.Photos {

    namespace CatalogXmp {

        public string label_to_xmp(string label) {
            switch (label) {
                case "red": return "Red";
                case "yellow": return "Yellow";
                case "green": return "Green";
                case "blue": return "Blue";
                case "purple": return "Purple";
                default: return "";
            }
        }

        public string label_from_xmp(string value) {
            string v = value.strip().down();
            foreach (var l in COLOR_LABELS) if (l == v) return l;
            return "";
        }

        public string format_gps(double value, bool latitude) {
            double a = value.abs();
            int deg = (int) a;
            double minutes = (a - deg) * 60.0;
            string hemi = latitude ? (value >= 0 ? "N" : "S") : (value >= 0 ? "E" : "W");
            return "%d,%.6f%s".printf(deg, minutes, hemi);
        }

        public void fill(XmpPacket packet, PhotoRecord r, Catalog catalog) {
            packet.set_simple(XmpPacket.NS_XMP, "xmp", "Rating", (r.flag == PickFlag.REJECT ? -1 : r.rating).to_string());
            string label = label_to_xmp(r.label);
            if (label != "") packet.set_simple(XmpPacket.NS_XMP, "xmp", "Label", label);
            else packet.remove(XmpPacket.NS_XMP, "Label");
            packet.set_simple(XmpPacket.NS_SINTY, "sinty", "Pick", r.flag.to_string());
            packet.set_list(XmpPacket.NS_DC, "dc", "subject", "Bag", catalog.keyword_names(r));
            packet.set_list(XmpPacket.NS_LR, "lr", "hierarchicalSubject", "Bag", catalog.keyword_paths(r));
            if (r.title != "") packet.set_lang_alt(XmpPacket.NS_DC, "dc", "title", r.title);
            if (r.caption != "") packet.set_lang_alt(XmpPacket.NS_DC, "dc", "description", r.caption);
            if (r.creator != "") packet.set_list(XmpPacket.NS_DC, "dc", "creator", "Seq", { r.creator });
            if (r.copyright != "") packet.set_lang_alt(XmpPacket.NS_DC, "dc", "rights", r.copyright);
            if (r.city != "") packet.set_simple(XmpPacket.NS_PHOTOSHOP, "photoshop", "City", r.city);
            if (r.country != "") packet.set_simple(XmpPacket.NS_PHOTOSHOP, "photoshop", "Country", r.country);
            if (r.location != "") packet.set_simple(XmpPacket.NS_IPTC, "Iptc4xmpCore", "Location", r.location);
            if (r.has_gps) {
                packet.set_simple(XmpPacket.NS_EXIF, "exif", "GPSLatitude", format_gps(r.latitude, true));
                packet.set_simple(XmpPacket.NS_EXIF, "exif", "GPSLongitude", format_gps(r.longitude, false));
            }
        }

        public bool write(PhotoRecord r, Catalog catalog) {
            if (r.is_virtual_copy() || r.missing) return false;
            var file = r.file();
            try {
                var packet = XmpSidecar.load(file);
                fill(packet, r, catalog);
                XmpSidecar.save(file, packet, false);
                return true;
            } catch (Error e) {
                warning("Photos: cannot write metadata for %s: %s", r.path, e.message);
                return false;
            }
        }

        public bool automatic() {
            return EditStore.write_xmp_enabled();
        }
    }
}
