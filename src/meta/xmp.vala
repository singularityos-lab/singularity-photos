namespace Singularity.Apps.Photos {

    public class XmpPacket : Object {
        public const string NS_CRS = "http://ns.adobe.com/camera-raw-settings/1.0/";
        public const string NS_XMP = "http://ns.adobe.com/xap/1.0/";
        public const string NS_DC = "http://purl.org/dc/elements/1.1/";
        public const string NS_LR = "http://ns.adobe.com/lightroom/1.0/";
        public const string NS_PHOTOSHOP = "http://ns.adobe.com/photoshop/1.0/";
        public const string NS_IPTC = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/";
        public const string NS_EXIF = "http://ns.adobe.com/exif/1.0/";
        public const string NS_TIFF = "http://ns.adobe.com/tiff/1.0/";
        public const string NS_XMPRIGHTS = "http://ns.adobe.com/xap/1.0/rights/";
        public const string NS_SINTY = "https://sinty.dev/ns/photos/1.0/";
        public const string NS_RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
        public const string NS_AUX = "http://ns.adobe.com/exif/1.0/aux/";
        public const string NS_XMPMM = "http://ns.adobe.com/xap/1.0/mm/";

        private Gee.TreeMap<string, string> prefixes = new Gee.TreeMap<string, string>();
        private Gee.TreeMap<string, string> simple = new Gee.TreeMap<string, string>();
        private Gee.TreeMap<string, string> list_kinds = new Gee.TreeMap<string, string>();
        private Gee.TreeMap<string, Gee.ArrayList<string>> lists = new Gee.TreeMap<string, Gee.ArrayList<string>>();
        private Gee.TreeMap<string, string> raw = new Gee.TreeMap<string, string>();
        private Gee.ArrayList<string> order = new Gee.ArrayList<string>();

        construct {
            prefixes[NS_RDF] = "rdf";
            prefixes[NS_CRS] = "crs";
            prefixes[NS_XMP] = "xmp";
            prefixes[NS_DC] = "dc";
            prefixes[NS_LR] = "lr";
            prefixes[NS_PHOTOSHOP] = "photoshop";
            prefixes[NS_IPTC] = "Iptc4xmpCore";
            prefixes[NS_EXIF] = "exif";
            prefixes[NS_TIFF] = "tiff";
            prefixes[NS_XMPRIGHTS] = "xmpRights";
            prefixes[NS_SINTY] = "sinty";
            prefixes[NS_AUX] = "aux";
            prefixes[NS_XMPMM] = "xmpMM";
        }

        private static string key(string ns, string name) {
            return ns + "\n" + name;
        }

        private void touch(string k) {
            if (!order.contains(k)) order.add(k);
        }

        public void register_prefix(string ns, string prefix) {
            if (!prefixes.has_key(ns)) {
                string p = prefix;
                int n = 1;
                while (prefix_taken(p)) p = prefix + (n++).to_string();
                prefixes[ns] = p;
            }
        }

        private bool prefix_taken(string p) {
            foreach (var v in prefixes.values) if (v == p) return true;
            return false;
        }

        public string? prefix_for(string ns) {
            return prefixes.has_key(ns) ? prefixes[ns] : null;
        }

        private void clear_key(string k) {
            simple.unset(k);
            lists.unset(k);
            list_kinds.unset(k);
            raw.unset(k);
        }

        public void set_simple(string ns, string prefix, string name, string value) {
            register_prefix(ns, prefix);
            string k = key(ns, name);
            clear_key(k);
            simple[k] = value;
            touch(k);
        }

        public string? get_simple(string ns, string name) {
            string k = key(ns, name);
            return simple.has_key(k) ? simple[k] : null;
        }

        public void remove(string ns, string name) {
            string k = key(ns, name);
            clear_key(k);
            order.remove(k);
        }

        public bool has(string ns, string name) {
            string k = key(ns, name);
            return simple.has_key(k) || lists.has_key(k) || raw.has_key(k);
        }

        public void set_list(string ns, string prefix, string name, string kind, string[] items) {
            register_prefix(ns, prefix);
            string k = key(ns, name);
            clear_key(k);
            var l = new Gee.ArrayList<string>();
            foreach (var i in items) l.add(i);
            lists[k] = l;
            list_kinds[k] = kind;
            touch(k);
        }

        public string[] get_list(string ns, string name) {
            string k = key(ns, name);
            if (!lists.has_key(k)) {
                if (simple.has_key(k)) return { simple[k] };
                return {};
            }
            return lists[k].to_array();
        }

        public string list_kind(string ns, string name) {
            string k = key(ns, name);
            return list_kinds.has_key(k) ? list_kinds[k] : "";
        }

        public void set_lang_alt(string ns, string prefix, string name, string value) {
            set_list(ns, prefix, name, "Alt", { value });
        }

        public string? get_lang_alt(string ns, string name) {
            string k = key(ns, name);
            if (lists.has_key(k)) return lists[k].size > 0 ? lists[k][0] : null;
            return get_simple(ns, name);
        }

        public void set_raw(string ns, string prefix, string name, string xml) {
            register_prefix(ns, prefix);
            string k = key(ns, name);
            clear_key(k);
            raw[k] = xml;
            touch(k);
        }

        public string? get_raw(string ns, string name) {
            string k = key(ns, name);
            return raw.has_key(k) ? raw[k] : null;
        }

        public bool is_empty() {
            return simple.size == 0 && lists.size == 0 && raw.size == 0;
        }

        public string[] property_keys() {
            string[] keys = {};
            foreach (var k in order) if (simple.has_key(k) || lists.has_key(k) || raw.has_key(k)) keys += k;
            return keys;
        }

        public void merge(XmpPacket other) {
            foreach (var e in other.prefixes.entries) register_prefix(e.key, e.value);
            foreach (var k in other.order) {
                string ns = k.split("\n")[0], name = k.split("\n")[1];
                string prefix = prefix_for(ns) ?? "ns";
                if (other.simple.has_key(k)) set_simple(ns, prefix, name, other.simple[k]);
                else if (other.lists.has_key(k)) set_list(ns, prefix, name, other.list_kinds[k], other.lists[k].to_array());
                else if (other.raw.has_key(k)) set_raw(ns, prefix, name, other.raw[k]);
            }
        }

        public XmpPacket copy() {
            var p = new XmpPacket();
            p.merge(this);
            return p;
        }

        public string serialize() {
            var sb = new StringBuilder();
            sb.append("<?xpacket begin=\"\xef\xbb\xbf\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n");
            sb.append("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Singularity Photos\"");
            foreach (var e in prefixes.entries) sb.append_printf("\n    xmlns:%s=\"%s\"", e.value, Markup.escape_text(e.key));
            sb.append(">\n <rdf:RDF>\n  <rdf:Description rdf:about=\"\">\n");
            foreach (var k in order) {
                var parts = k.split("\n");
                string tag = prefixes[parts[0]] + ":" + parts[1];
                if (simple.has_key(k)) {
                    sb.append_printf("   <%s>%s</%s>\n", tag, Markup.escape_text(simple[k]), tag);
                } else if (lists.has_key(k)) {
                    string kind = list_kinds[k];
                    sb.append_printf("   <%s>\n    <rdf:%s>\n", tag, kind);
                    foreach (var item in lists[k]) {
                        if (kind == "Alt") sb.append_printf("     <rdf:li xml:lang=\"x-default\">%s</rdf:li>\n", Markup.escape_text(item));
                        else sb.append_printf("     <rdf:li>%s</rdf:li>\n", Markup.escape_text(item));
                    }
                    sb.append_printf("    </rdf:%s>\n   </%s>\n", kind, tag);
                } else if (raw.has_key(k)) {
                    sb.append_printf("   <%s>%s</%s>\n", tag, raw[k], tag);
                }
            }
            sb.append("  </rdf:Description>\n </rdf:RDF>\n</x:xmpmeta>\n");
            for (int i = 0; i < 20; i++) sb.append("                                                                                \n");
            sb.append("<?xpacket end=\"w\"?>");
            return sb.str;
        }

        private static bool is_rdf(Xml.Node* n, string name) {
            return n->type == Xml.ElementType.ELEMENT_NODE && n->name == name && n->ns != null && n->ns->href == NS_RDF;
        }

        private static bool literal_only(Xml.Node* n) {
            for (Xml.Node* c = n->children; c != null; c = c->next) if (c->type == Xml.ElementType.ELEMENT_NODE) return false;
            return true;
        }

        private static bool has_value_attrs(Xml.Node* n) {
            for (Xml.Attr* a = n->properties; a != null; a = a->next) {
                if (a->ns != null && a->ns->href == NS_RDF) continue;
                if (a->ns != null && a->ns->prefix == "xml") continue;
                return true;
            }
            return false;
        }

        private static string inner_xml(Xml.Doc* doc, Xml.Node* n) {
            var sb = new StringBuilder();
            for (Xml.Node* c = n->children; c != null; c = c->next) {
                var buf = new Xml.Buffer();
                buf.node_dump(doc, c, 0, 0);
                sb.append(buf.content());
            }
            return sb.str.strip();
        }

        private void collect_namespaces(Xml.Node* n) {
            for (Xml.Ns* ns = n->ns_def; ns != null; ns = ns->next) {
                if (ns->href != null && ns->prefix != null && ns->prefix != "x" && ns->href != "adobe:ns:meta/") register_prefix(ns->href, ns->prefix);
            }
            for (Xml.Node* c = n->children; c != null; c = c->next) if (c->type == Xml.ElementType.ELEMENT_NODE) collect_namespaces(c);
        }

        private void read_property(Xml.Doc* doc, Xml.Node* prop) {
            if (prop->ns == null) return;
            string ns = prop->ns->href;
            string prefix = prop->ns->prefix ?? "ns";
            string name = prop->name;
            register_prefix(ns, prefix);
            string? resource = prop->get_ns_prop("resource", NS_RDF);
            if (resource != null) {
                set_simple(ns, prefix, name, resource);
                return;
            }
            if (literal_only(prop)) {
                bool has_attrs = false;
                for (Xml.Attr* a = prop->properties; a != null; a = a->next) {
                    if (a->ns != null && a->ns->href == NS_RDF) continue;
                    if (a->ns != null && a->ns->prefix == "xml") continue;
                    has_attrs = true;
                }
                if (!has_attrs) {
                    set_simple(ns, prefix, name, prop->get_content() ?? "");
                    return;
                }
                set_raw(ns, prefix, name, inner_xml(doc, prop));
                return;
            }
            Xml.Node* container = null;
            int elements = 0;
            for (Xml.Node* c = prop->children; c != null; c = c->next) {
                if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
                elements++;
                if (is_rdf(c, "Bag") || is_rdf(c, "Seq") || is_rdf(c, "Alt")) container = c;
            }
            if (container != null && elements == 1) {
                bool literal = true;
                string[] items = {};
                for (Xml.Node* li = container->children; li != null; li = li->next) {
                    if (li->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (!is_rdf(li, "li") || !literal_only(li) || has_value_attrs(li) || li->get_ns_prop("parseType", NS_RDF) != null) {
                        literal = false;
                        break;
                    }
                    items += li->get_content() ?? "";
                }
                if (literal) {
                    if (container->name == "Alt") {
                        string? chosen = null;
                        for (Xml.Node* li = container->children; li != null; li = li->next) {
                            if (li->type != Xml.ElementType.ELEMENT_NODE) continue;
                            string? lang = li->get_prop("lang");
                            if (chosen == null || lang == "x-default") chosen = li->get_content() ?? "";
                        }
                        set_list(ns, prefix, name, "Alt", chosen != null ? new string[] { chosen } : new string[0]);
                    } else {
                        set_list(ns, prefix, name, container->name, items);
                    }
                    return;
                }
            }
            set_raw(ns, prefix, name, inner_xml(doc, prop));
        }

        private void read_description(Xml.Doc* doc, Xml.Node* desc) {
            for (Xml.Attr* a = desc->properties; a != null; a = a->next) {
                if (a->ns == null || a->ns->href == NS_RDF || a->ns->prefix == "xml") continue;
                register_prefix(a->ns->href, a->ns->prefix);
                string value = a->children != null ? (a->children->content ?? "") : "";
                set_simple(a->ns->href, a->ns->prefix, a->name, value);
            }
            for (Xml.Node* c = desc->children; c != null; c = c->next) {
                if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
                read_property(doc, c);
            }
        }

        private void walk(Xml.Doc* doc, Xml.Node* n) {
            for (Xml.Node* c = n->children; c != null; c = c->next) {
                if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (is_rdf(c, "Description")) read_description(doc, c);
                else if (is_rdf(c, "RDF") || c->name == "xmpmeta" || c->name == "xapmeta") walk(doc, c);
            }
        }

        public static XmpPacket parse(string xml) throws Error {
            var p = new XmpPacket();
            string text = xml;
            int start = text.index_of("<x:xmpmeta");
            if (start < 0) start = text.index_of("<rdf:RDF");
            if (start < 0) start = text.index_of("<x:xapmeta");
            if (start > 0) text = text.substring(start);
            int end_meta = text.last_index_of("</x:xmpmeta>");
            if (end_meta > 0) text = text.substring(0, end_meta + 12);
            else {
                int end_rdf = text.last_index_of("</rdf:RDF>");
                if (end_rdf > 0) text = text.substring(0, end_rdf + 10);
            }
            Xml.Doc* doc = Xml.Parser.read_memory(text, text.length, null, null, Xml.ParserOption.NONET | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING | Xml.ParserOption.NOBLANKS);
            if (doc == null) throw new IOError.INVALID_DATA(_("Invalid XMP packet"));
            Xml.Node* root = doc->get_root_element();
            if (root == null) {
                delete doc;
                throw new IOError.INVALID_DATA(_("Invalid XMP packet"));
            }
            p.collect_namespaces(root);
            if (is_rdf(root, "RDF")) p.walk(doc, root);
            else {
                var holder = root;
                if (is_rdf(holder, "Description")) p.read_description(doc, holder);
                else p.walk(doc, holder);
            }
            delete doc;
            return p;
        }

        public static XmpPacket? from_embedded(uint8[] data) {
            string? xml = XmpExtract.find(data);
            if (xml == null) return null;
            var parts = xml.split(XmpExtract.EXTENDED_SEPARATOR);
            XmpPacket? result = null;
            foreach (var part in parts) {
                try {
                    var p = parse(part);
                    if (result == null) result = p;
                    else result.merge(p);
                } catch (Error e) {
                }
            }
            if (result != null) result.remove("http://ns.adobe.com/xmp/note/", "HasExtendedXMP");
            return result;
        }
    }

    namespace XmpExtract {

        public string? find(uint8[] data) {
            if (data.length > 4 && data[0] == 0xFF && data[1] == 0xD8) return from_jpeg(data);
            if (data.length > 8 && data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G') return from_png(data);
            return scan(data);
        }

        public string? from_jpeg(uint8[] data) {
            string? main = null;
            string? extended = jpeg_extended(data);
            int pos = 2;
            const string SIG = "http://ns.adobe.com/xap/1.0/";
            while (pos + 4 <= data.length) {
                if (data[pos] != 0xFF) break;
                uint8 marker = data[pos + 1];
                if (marker == 0xD9 || marker == 0xDA) break;
                int len = (data[pos + 2] << 8) | data[pos + 3];
                if (len < 2 || pos + 2 + len > data.length) break;
                if (marker == 0xE1 && len > SIG.length + 3 && Memory.cmp(&data[pos + 4], SIG.data, SIG.length) == 0 && data[pos + 4 + SIG.length] == 0) {
                    int body = pos + 4 + SIG.length + 1;
                    main = bytes_to_string(data[body:pos + 2 + len]);
                    break;
                }
                pos += 2 + len;
            }
            if (extended == null) return main;
            if (main == null) return extended;
            return main + "\n" + EXTENDED_SEPARATOR + "\n" + extended;
        }

        public const string EXTENDED_SEPARATOR = "<!--sinty-extended-xmp-->";

        public string? jpeg_extended(uint8[] data) {
            const string SIG = "http://ns.adobe.com/xmp/extension/";
            uint8[]? whole = null;
            int pos = 2;
            while (pos + 4 <= data.length) {
                if (data[pos] != 0xFF) break;
                uint8 marker = data[pos + 1];
                if (marker == 0xD9 || marker == 0xDA) break;
                int len = (data[pos + 2] << 8) | data[pos + 3];
                if (len < 2 || pos + 2 + len > data.length) break;
                int header = 4 + SIG.length + 1 + 32 + 8;
                if (marker == 0xE1 && len + 2 > header && Memory.cmp(&data[pos + 4], SIG.data, SIG.length) == 0) {
                    int p = pos + 4 + SIG.length + 1 + 32;
                    uint32 full = ((uint32) data[p] << 24) | ((uint32) data[p + 1] << 16) | ((uint32) data[p + 2] << 8) | data[p + 3];
                    uint32 offset = ((uint32) data[p + 4] << 24) | ((uint32) data[p + 5] << 16) | ((uint32) data[p + 6] << 8) | data[p + 7];
                    if (full > 0 && full < 64 * 1024 * 1024) {
                        if (whole == null || whole.length != full) whole = new uint8[full];
                        int chunk = len + 2 - header;
                        if (offset + chunk <= full) Memory.copy(&whole[offset], &data[pos + header], chunk);
                    }
                }
                pos += 2 + len;
            }
            return whole != null ? bytes_to_string(whole) : null;
        }

        public string? from_png(uint8[] data) {
            int pos = 8;
            while (pos + 12 <= data.length) {
                uint32 len = ((uint32) data[pos] << 24) | ((uint32) data[pos + 1] << 16) | ((uint32) data[pos + 2] << 8) | data[pos + 3];
                if (pos + 12 + (int64) len > data.length) break;
                if (Memory.cmp(&data[pos + 4], "iTXt".data, 4) == 0) {
                    int p = pos + 8, end = p + (int) len;
                    int kw_end = p;
                    while (kw_end < end && data[kw_end] != 0) kw_end++;
                    string keyword = bytes_to_string(data[p:kw_end]);
                    if (keyword == "XML:com.adobe.xmp" && kw_end + 3 < end) {
                        bool compressed = data[kw_end + 1] != 0;
                        int q = kw_end + 3;
                        while (q < end && data[q] != 0) q++;
                        q++;
                        while (q < end && data[q] != 0) q++;
                        q++;
                        if (q >= end) return null;
                        if (compressed) {
                            var inflated = IccExtract.inflate(data[q:end]);
                            return inflated != null ? bytes_to_string(inflated) : null;
                        }
                        return bytes_to_string(data[q:end]);
                    }
                }
                if (Memory.cmp(&data[pos + 4], "IEND".data, 4) == 0) break;
                pos += 12 + (int) len;
            }
            return null;
        }

        public string? scan(uint8[] data) {
            const string START = "<x:xmpmeta";
            const string END = "</x:xmpmeta>";
            int limit = data.length - END.length;
            for (int i = 0; i + START.length < data.length; i++) {
                if (data[i] != '<' || Memory.cmp(&data[i], START.data, START.length) != 0) continue;
                for (int j = i; j < limit; j++) {
                    if (data[j] == '<' && Memory.cmp(&data[j], END.data, END.length) == 0) return bytes_to_string(data[i:j + END.length]);
                }
                return null;
            }
            return null;
        }

        public string bytes_to_string(uint8[] bytes) {
            var copy = new uint8[bytes.length + 1];
            Memory.copy(copy, bytes, bytes.length);
            copy[bytes.length] = 0;
            string s = (string) copy;
            return s.validate() ? s : s.make_valid();
        }
    }
}
