using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace RetouchOra {

        public const string MIME = "image/openraster";

        private uint8[] png16(FloatImage working) {
            return RetouchColor.to_texture16(working).save_to_png_bytes().get_data();
        }

        private uint8[] png8(FloatImage working) {
            return RetouchColor.to_texture8(working).save_to_png_bytes().get_data();
        }

        private uint8[] mask_png(float[] plane, int w, int h) {
            var img = new FloatImage(w, h);
            for (size_t i = 0; i < plane.length; i++) {
                float v = plane[i].clamp(0, 1);
                img.data[i * 4] = v;
                img.data[i * 4 + 1] = v;
                img.data[i * 4 + 2] = v;
                img.data[i * 4 + 3] = 1;
            }
            return img.to_texture16(false).save_to_png_bytes().get_data();
        }

        private string attr(string name, string value) {
            return " %s=\"%s\"".printf(name, Markup.escape_text(value));
        }

        private class Writer {
            public RetouchZipWriter zip = new RetouchZipWriter();
            public StringBuilder xml = new StringBuilder();
            public int counter = 0;
            public RetouchDocument doc;
        }

        private void write_list(Writer w, Gee.ArrayList<RetouchLayer> list, int indent) throws Error {
            string pad = string.nfill(indent * 2, ' ');
            for (int i = list.size - 1; i >= 0; i--) {
                var layer = list[i];
                var common = new StringBuilder();
                common.append(attr("name", layer.name));
                common.append(attr("opacity", "%.4f".printf(layer.opacity)));
                common.append(attr("visibility", layer.visible ? "visible" : "hidden"));
                common.append(attr("composite-op", layer.mode.ora_key()));
                common.append(attr("sinty:blend", layer.mode.key()));
                common.append(attr("sinty:kind", layer.kind.key()));
                if (layer.locked) common.append(attr("edit-locked", "true"));
                if (layer.mask != null) {
                    string mask_name = "data/mask-%d.png".printf(w.counter++);
                    w.zip.add(mask_name, mask_png(layer.mask, w.doc.width, w.doc.height), false);
                    common.append(attr("sinty:mask", mask_name));
                    common.append(attr("sinty:mask-enabled", layer.mask_enabled ? "true" : "false"));
                }
                if (layer.kind == RetouchLayerKind.GROUP) {
                    w.xml.append("%s<stack%s%s>\n".printf(pad, common.str, attr("isolation", "isolate")));
                    write_list(w, layer.children, indent + 1);
                    w.xml.append("%s</stack>\n".printf(pad));
                    continue;
                }
                FloatImage pixels;
                int x = 0, y = 0;
                if (layer.kind == RetouchLayerKind.RASTER && layer.pixels != null) {
                    pixels = layer.pixels;
                    x = layer.x;
                    y = layer.y;
                } else if (layer.kind == RetouchLayerKind.ADJUSTMENT) {
                    pixels = new FloatImage.filled(1, 1, 0, 0, 0, 0);
                } else {
                    pixels = w.doc.render_layer_pixels(layer);
                }
                string src = "data/layer-%d.png".printf(w.counter++);
                w.zip.add(src, png16(pixels), false);
                common.append(attr("src", src));
                common.append(attr("x", x.to_string()));
                common.append(attr("y", y.to_string()));
                if (layer.adjustment != null) common.append(attr("sinty:adjustment", layer.adjustment.to_json()));
                if (layer.text != null) common.append(attr("sinty:text", layer.text.to_json()));
                if (layer.kind == RetouchLayerKind.EMBEDDED) {
                    common.append(attr("sinty:source", layer.source_uri));
                    common.append(attr("sinty:edit", layer.source_edit));
                    common.append(attr("sinty:scale", "%.6f".printf(layer.embed_scale)));
                }
                w.xml.append("%s<layer%s/>\n".printf(pad, common.str));
            }
        }

        public uint8[] save(RetouchDocument doc) throws Error {
            var w = new Writer();
            w.doc = doc;
            w.zip.add_text("mimetype", MIME, false);
            w.xml.append("<?xml version='1.0' encoding='UTF-8'?>\n");
            w.xml.append("<image version=\"0.0.5\" w=\"%d\" h=\"%d\" xmlns:sinty=\"%s\"".printf(doc.width, doc.height, XmpPacket.NS_SINTY));
            if (doc.source_file != null) w.xml.append(attr("sinty:original", doc.source_file.get_uri()));
            w.xml.append(">\n  <stack>\n");
            write_list(w, doc.layers, 2);
            w.xml.append("  </stack>\n</image>\n");
            w.zip.add_text("stack.xml", w.xml.str);
            w.zip.add("mergedimage.png", png8(doc.composite), false);
            w.zip.add("Thumbnails/thumbnail.png", png8(doc.composite.scaled_to_fit(256)), false);
            return w.zip.finish();
        }

        private string? prop(Xml.Node* node, string name) {
            string? v = node->get_prop(name);
            return v;
        }

        private FloatImage load_png(RetouchZipReader zip, string name) throws Error {
            var bytes = new Bytes(zip.read(name));
            return RetouchColor.from_texture(Gdk.Texture.from_bytes(bytes));
        }

        private float[] load_mask(RetouchZipReader zip, string name, int w, int h) throws Error {
            var tex = Gdk.Texture.from_bytes(new Bytes(zip.read(name)));
            var img = FloatImage.from_texture(tex, false);
            var plane = new float[(size_t) w * h];
            for (int y = 0; y < int.min(h, img.height); y++)
                for (int x = 0; x < int.min(w, img.width); x++) plane[(size_t) y * w + x] = img.data[img.offset(x, y)];
            return plane;
        }

        private void read_stack(RetouchZipReader zip, Xml.Node* stack, Gee.ArrayList<RetouchLayer> list, int w, int h) throws Error {
            var items = new Gee.ArrayList<RetouchLayer>();
            for (Xml.Node* n = stack->children; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (n->name != "layer" && n->name != "stack") continue;
                string kind_key = prop(n, "kind") ?? (n->name == "stack" ? "group" : "raster");
                var layer = new RetouchLayer(prop(n, "name") ?? _("Layer"), RetouchLayerKind.from_key(kind_key));
                if (n->name == "stack") layer.kind = RetouchLayerKind.GROUP;
                string? op = prop(n, "opacity");
                if (op != null) layer.opacity = (float) double.parse(op).clamp(0, 1);
                layer.visible = (prop(n, "visibility") ?? "visible") != "hidden";
                layer.locked = (prop(n, "edit-locked") ?? "false") == "true";
                string? blend = prop(n, "blend");
                layer.mode = BlendMode.from_key(blend ?? prop(n, "composite-op") ?? "svg:src-over");
                string? mask = prop(n, "mask");
                if (mask != null && zip.has(mask)) {
                    layer.mask = load_mask(zip, mask, w, h);
                    layer.mask_enabled = (prop(n, "mask-enabled") ?? "true") == "true";
                }
                if (layer.kind == RetouchLayerKind.GROUP) {
                    read_stack(zip, n, layer.children, w, h);
                } else {
                    string? src = prop(n, "src");
                    if (src != null && zip.has(src) && layer.kind != RetouchLayerKind.ADJUSTMENT) layer.pixels = load_png(zip, src);
                    layer.x = int.parse(prop(n, "x") ?? "0");
                    layer.y = int.parse(prop(n, "y") ?? "0");
                    string? adj = prop(n, "adjustment");
                    if (adj != null) layer.adjustment = RetouchAdjustment.from_json(adj);
                    string? text = prop(n, "text");
                    if (text != null) layer.text = RetouchText.from_json(text);
                    layer.source_uri = prop(n, "source") ?? "";
                    layer.source_edit = prop(n, "edit") ?? "";
                    string? scale = prop(n, "scale");
                    if (scale != null) layer.embed_scale = double.parse(scale);
                    if (layer.kind == RetouchLayerKind.TEXT && layer.text == null) layer.kind = RetouchLayerKind.RASTER;
                    if (layer.kind == RetouchLayerKind.ADJUSTMENT && layer.adjustment == null) continue;
                }
                items.add(layer);
            }
            for (int i = items.size - 1; i >= 0; i--) list.add(items[i]);
        }

        public RetouchDocument load(uint8[] data) throws Error {
            var zip = new RetouchZipReader(data);
            string xml = zip.read_text("stack.xml");
            Xml.Doc* xdoc = Xml.Parser.read_memory(xml, xml.length, null, null, Xml.ParserOption.NONET);
            if (xdoc == null) throw new RetouchFormatError.INVALID("Invalid stack.xml");
            Xml.Node* root = xdoc->get_root_element();
            if (root == null || root->name != "image") {
                delete xdoc;
                throw new RetouchFormatError.INVALID("Invalid stack.xml");
            }
            int w = int.parse(prop(root, "w") ?? "0"), h = int.parse(prop(root, "h") ?? "0");
            if (w <= 0 || h <= 0) {
                delete xdoc;
                throw new RetouchFormatError.INVALID("Invalid image size");
            }
            var doc = new RetouchDocument(w, h);
            string? original = prop(root, "original");
            if (original != null) doc.source_file = File.new_for_uri(original);
            try {
                for (Xml.Node* n = root->children; n != null; n = n->next) {
                    if (n->type == Xml.ElementType.ELEMENT_NODE && n->name == "stack") {
                        read_stack(zip, n, doc.layers, w, h);
                        break;
                    }
                }
            } finally {
                delete xdoc;
            }
            doc.recomposite();
            return doc;
        }

        public FloatImage merged(uint8[] data) throws Error {
            var zip = new RetouchZipReader(data);
            if (zip.has("mergedimage.png")) return load_png(zip, "mergedimage.png");
            return load(data).composite;
        }
    }
}
