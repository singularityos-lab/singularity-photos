using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public enum RetouchLayerKind {
        RASTER,
        GROUP,
        ADJUSTMENT,
        TEXT,
        EMBEDDED;

        public string key() {
            switch (this) {
                case GROUP: return "group";
                case ADJUSTMENT: return "adjustment";
                case TEXT: return "text";
                case EMBEDDED: return "embedded";
                default: return "raster";
            }
        }

        public static RetouchLayerKind from_key(string key) {
            switch (key) {
                case "group": return GROUP;
                case "adjustment": return ADJUSTMENT;
                case "text": return TEXT;
                case "embedded": return EMBEDDED;
                default: return RASTER;
            }
        }
    }

    public class RetouchText : Object {
        public string text = "";
        public string font = "Sans Bold 48";
        public float r = 1;
        public float g = 1;
        public float b = 1;
        public float a = 1;
        public int x = 0;
        public int y = 0;
        public int width = 0;
        public string align = "left";
        public bool shadow = false;

        public RetouchText copy() {
            var t = new RetouchText();
            t.text = text;
            t.font = font;
            t.r = r;
            t.g = g;
            t.b = b;
            t.a = a;
            t.x = x;
            t.y = y;
            t.width = width;
            t.align = align;
            t.shadow = shadow;
            return t;
        }

        public string to_json() {
            var b2 = new Json.Builder();
            b2.begin_object();
            b2.set_member_name("text");
            b2.add_string_value(text);
            b2.set_member_name("font");
            b2.add_string_value(font);
            b2.set_member_name("color");
            b2.begin_array();
            b2.add_double_value(r);
            b2.add_double_value(g);
            b2.add_double_value(b);
            b2.add_double_value(a);
            b2.end_array();
            b2.set_member_name("x");
            b2.add_int_value(x);
            b2.set_member_name("y");
            b2.add_int_value(y);
            b2.set_member_name("width");
            b2.add_int_value(width);
            b2.set_member_name("align");
            b2.add_string_value(align);
            b2.set_member_name("shadow");
            b2.add_boolean_value(shadow);
            b2.end_object();
            var gen = new Json.Generator();
            gen.set_root(b2.get_root());
            return gen.to_data(null);
        }

        public static RetouchText from_json(string json) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(json);
            var o = parser.get_root().get_object();
            var t = new RetouchText();
            if (o.has_member("text")) t.text = o.get_string_member("text");
            if (o.has_member("font")) t.font = o.get_string_member("font");
            if (o.has_member("color")) {
                var c = o.get_array_member("color");
                if (c.get_length() >= 4) {
                    t.r = (float) json_double(c.get_element(0));
                    t.g = (float) json_double(c.get_element(1));
                    t.b = (float) json_double(c.get_element(2));
                    t.a = (float) json_double(c.get_element(3));
                }
            }
            if (o.has_member("x")) t.x = (int) o.get_int_member("x");
            if (o.has_member("y")) t.y = (int) o.get_int_member("y");
            if (o.has_member("width")) t.width = (int) o.get_int_member("width");
            if (o.has_member("align")) t.align = o.get_string_member("align");
            if (o.has_member("shadow")) t.shadow = o.get_boolean_member("shadow");
            return t;
        }

        public FloatImage render(int canvas_w, int canvas_h) {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, canvas_w, canvas_h);
            var cr = new Cairo.Context(surface);
            var layout = Pango.cairo_create_layout(cr);
            layout.set_text(text, -1);
            layout.set_font_description(Pango.FontDescription.from_string(font));
            if (width > 0) {
                layout.set_width(width * Pango.SCALE);
                layout.set_wrap(Pango.WrapMode.WORD_CHAR);
            }
            layout.set_alignment(align == "center" ? Pango.Alignment.CENTER : align == "right" ? Pango.Alignment.RIGHT : Pango.Alignment.LEFT);
            if (shadow) {
                cr.move_to(x + 2, y + 2);
                cr.set_source_rgba(0, 0, 0, a * 0.55);
                Pango.cairo_show_layout(cr, layout);
            }
            cr.move_to(x, y);
            cr.set_source_rgba(r, g, b, a);
            Pango.cairo_show_layout(cr, layout);
            surface.flush();
            return RetouchSurface.to_float(surface);
        }
    }

    namespace RetouchSurface {

        public FloatImage to_float(Cairo.ImageSurface surface) {
            int w = surface.get_width(), h = surface.get_height(), stride = surface.get_stride();
            unowned uint8[] px = surface.get_data();
            var img = new FloatImage(w, h);
            unowned float[] table = Transfer.srgb_decode_table();
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int s = y * stride + x * 4;
                    float a = px[s + 3] / 255.0f;
                    size_t d = img.offset(x, y);
                    if (a <= 0) {
                        img.data[d] = img.data[d + 1] = img.data[d + 2] = img.data[d + 3] = 0;
                        continue;
                    }
                    int rr = (int) (px[s + 2] / a + 0.5).clamp(0, 255);
                    int gg = (int) (px[s + 1] / a + 0.5).clamp(0, 255);
                    int bb = (int) (px[s] / a + 0.5).clamp(0, 255);
                    img.data[d] = table[rr];
                    img.data[d + 1] = table[gg];
                    img.data[d + 2] = table[bb];
                    img.data[d + 3] = a;
                }
            }
            WorkingSpace.from_linear_srgb(img);
            return img;
        }
    }

    public class RetouchLayer : Object {
        public string id { get; set; }
        public string name { get; set; default = ""; }
        public RetouchLayerKind kind { get; set; default = RetouchLayerKind.RASTER; }
        public float opacity { get; set; default = 1.0f; }
        public BlendMode mode { get; set; default = BlendMode.NORMAL; }
        public bool visible { get; set; default = true; }
        public bool locked { get; set; default = false; }
        public bool mask_enabled { get; set; default = true; }
        public bool expanded { get; set; default = true; }

        public FloatImage? pixels = null;
        public int x = 0;
        public int y = 0;
        public float[]? mask = null;
        public Gee.ArrayList<RetouchLayer> children = new Gee.ArrayList<RetouchLayer>();
        public RetouchAdjustment? adjustment = null;
        public RetouchText? text = null;
        public string source_uri = "";
        public string source_edit = "";
        public double embed_scale = 1.0;

        public RetouchLayer(string name, RetouchLayerKind kind) {
            this.name = name;
            this.kind = kind;
            id = Uuid.string_random();
        }

        public RetouchLayer shallow_copy() {
            var l = new RetouchLayer(name, kind);
            l.id = id;
            l.opacity = opacity;
            l.mode = mode;
            l.visible = visible;
            l.locked = locked;
            l.mask_enabled = mask_enabled;
            l.expanded = expanded;
            l.pixels = pixels;
            l.x = x;
            l.y = y;
            l.mask = mask;
            foreach (var c in children) l.children.add(c.shallow_copy());
            l.adjustment = adjustment;
            l.text = text;
            l.source_uri = source_uri;
            l.source_edit = source_edit;
            l.embed_scale = embed_scale;
            return l;
        }

        public RetouchLayer deep_copy() {
            var l = shallow_copy();
            l.id = Uuid.string_random();
            l.name = _("%s Copy").printf(name);
            if (pixels != null) l.pixels = pixels.copy();
            if (mask != null) l.mask = mask.copy();
            l.children.clear();
            foreach (var c in children) l.children.add(c.deep_copy());
            if (adjustment != null) l.adjustment = adjustment.copy();
            if (text != null) l.text = text.copy();
            return l;
        }

        public bool is_pixel_layer() {
            return kind == RetouchLayerKind.RASTER && pixels != null;
        }
    }

    public class RetouchUndoStep : Object {
        public string label;
        public Gee.ArrayList<RetouchLayer>? structure = null;
        public float[]? selection = null;
        public bool has_selection = false;
        public RetouchLayer? pixel_layer = null;
        public int rx;
        public int ry;
        public FloatImage? region = null;
        public float[]? mask_region = null;
        public bool mask_step = false;

        public RetouchUndoStep(string label) {
            this.label = label;
        }
    }

    public class RetouchDocument : Object {
        public int width { get; private set; }
        public int height { get; private set; }
        public Gee.ArrayList<RetouchLayer> layers = new Gee.ArrayList<RetouchLayer>();
        public float[]? selection = null;
        public FloatImage composite;
        public File? source_file = null;
        public string source_edit = "";

        private Gee.ArrayList<RetouchUndoStep> undo_stack = new Gee.ArrayList<RetouchUndoStep>();
        private Gee.ArrayList<RetouchUndoStep> redo_stack = new Gee.ArrayList<RetouchUndoStep>();
        private Gee.HashMap<string, FloatImage> text_cache = new Gee.HashMap<string, FloatImage>();
        private Gee.HashMap<string, string> text_keys = new Gee.HashMap<string, string>();
        private Gee.HashMap<string, FloatImage> embed_cache = new Gee.HashMap<string, FloatImage>();
        public int modifications { get; private set; default = 0; }

        public signal void changed(int x, int y, int w, int h);
        public signal void structure_changed();

        public RetouchDocument(int width, int height) {
            this.width = width;
            this.height = height;
            composite = new FloatImage(width, height);
        }

        public static RetouchDocument from_image(FloatImage image, string name) {
            var doc = new RetouchDocument(image.width, image.height);
            var layer = new RetouchLayer(name, RetouchLayerKind.RASTER);
            layer.pixels = image;
            doc.layers.add(layer);
            doc.recomposite();
            return doc;
        }

        public static RetouchDocument open(File f) throws Error {
            string name = (f.get_basename() ?? "").down();
            uint8[] data;
            if (name.has_suffix(".ora")) {
                FileUtils.get_data(f.get_path(), out data);
                return RetouchOra.load(data);
            }
            if (name.has_suffix(".psd")) {
                FileUtils.get_data(f.get_path(), out data);
                var psd = RetouchPsd.read(data);
                psd.source_file = f;
                return psd;
            }
            var photo = Codecs.load(f, 0);
            var edits = EditStore.load(f);
            string edit_json = "";
            if (edits != null && edits.is_identity()) edits = null;
            if (edits != null) edit_json = edits.to_json();
            var image = RetouchDevelop.render(photo, edits);
            var doc = RetouchDocument.from_image(image, _("Background"));
            doc.source_file = f;
            doc.source_edit = edit_json;
            return doc;
        }

        public bool can_undo() {
            return undo_stack.size > 0;
        }

        public bool can_redo() {
            return redo_stack.size > 0;
        }

        private Gee.ArrayList<RetouchLayer> snapshot_structure() {
            var list = new Gee.ArrayList<RetouchLayer>();
            foreach (var l in layers) list.add(l.shallow_copy());
            return list;
        }

        private void push(RetouchUndoStep step) {
            undo_stack.add(step);
            if (undo_stack.size > 60) undo_stack.remove_at(0);
            redo_stack.clear();
            modifications++;
        }

        public void record_structure(string label) {
            var step = new RetouchUndoStep(label);
            step.structure = snapshot_structure();
            step.selection = selection != null ? selection.copy() : null;
            step.has_selection = true;
            push(step);
        }

        public void record_selection(string label) {
            var step = new RetouchUndoStep(label);
            step.selection = selection != null ? selection.copy() : null;
            step.has_selection = true;
            push(step);
        }

        public void record_pixels(RetouchLayer layer, int x, int y, int w, int h) {
            var step = new RetouchUndoStep(_("Paint"));
            step.pixel_layer = layer;
            clip_rect(ref x, ref y, ref w, ref h, layer.pixels.width, layer.pixels.height);
            if (w <= 0 || h <= 0) return;
            step.rx = x;
            step.ry = y;
            step.region = layer.pixels.cropped(x, y, w, h);
            push(step);
        }

        public void push_pixel_step(RetouchLayer layer, int x, int y, FloatImage before) {
            var step = new RetouchUndoStep(_("Paint"));
            step.pixel_layer = layer;
            step.rx = x;
            step.ry = y;
            step.region = before;
            push(step);
        }

        public void push_mask_step(RetouchLayer layer, int x, int y, int w, int h, float[] before) {
            var step = new RetouchUndoStep(_("Mask"));
            step.pixel_layer = layer;
            step.mask_step = true;
            step.rx = x;
            step.ry = y;
            step.region = new FloatImage(w, h);
            step.mask_region = before;
            push(step);
        }

        public void record_mask(RetouchLayer layer, int x, int y, int w, int h) {
            var step = new RetouchUndoStep(_("Mask"));
            step.pixel_layer = layer;
            step.mask_step = true;
            clip_rect(ref x, ref y, ref w, ref h, width, height);
            if (w <= 0 || h <= 0) return;
            step.rx = x;
            step.ry = y;
            if (layer.mask == null) layer.mask = full_plane(1.0f);
            step.mask_region = crop_plane(layer.mask, width, x, y, w, h);
            step.region = new FloatImage(w, h);
            push(step);
        }

        public static void clip_rect(ref int x, ref int y, ref int w, ref int h, int maxw, int maxh) {
            int x1 = int.min(maxw, x + w), y1 = int.min(maxh, y + h);
            x = int.max(0, x);
            y = int.max(0, y);
            w = x1 - x;
            h = y1 - y;
        }

        public float[] full_plane(float v) {
            var p = new float[(size_t) width * height];
            if (v != 0) for (size_t i = 0; i < p.length; i++) p[i] = v;
            return p;
        }

        public static float[] crop_plane(float[] plane, int pw, int x, int y, int w, int h) {
            var out_plane = new float[(size_t) w * h];
            for (int yy = 0; yy < h; yy++)
                for (int xx = 0; xx < w; xx++) out_plane[(size_t) yy * w + xx] = plane[(size_t) (y + yy) * pw + x + xx];
            return out_plane;
        }

        public static void paste_plane(float[] plane, int pw, float[] region, int x, int y, int w, int h) {
            for (int yy = 0; yy < h; yy++)
                for (int xx = 0; xx < w; xx++) plane[(size_t) (y + yy) * pw + x + xx] = region[(size_t) yy * w + xx];
        }

        private RetouchUndoStep swap(RetouchUndoStep step) {
            var inverse = new RetouchUndoStep(step.label);
            if (step.structure != null) {
                inverse.structure = snapshot_structure();
                layers.clear();
                layers.add_all(step.structure);
            }
            if (step.has_selection) {
                inverse.has_selection = true;
                inverse.selection = selection;
                selection = step.selection;
            }
            if (step.pixel_layer != null) {
                inverse.pixel_layer = step.pixel_layer;
                inverse.rx = step.rx;
                inverse.ry = step.ry;
                inverse.mask_step = step.mask_step;
                if (step.mask_step) {
                    int w = step.region.width, h = step.region.height;
                    inverse.region = step.region;
                    inverse.mask_region = crop_plane(step.pixel_layer.mask, width, step.rx, step.ry, w, h);
                    paste_plane(step.pixel_layer.mask, width, step.mask_region, step.rx, step.ry, w, h);
                } else {
                    inverse.region = step.pixel_layer.pixels.cropped(step.rx, step.ry, step.region.width, step.region.height);
                    step.pixel_layer.pixels.paste(step.region, step.rx, step.ry);
                }
            }
            return inverse;
        }

        public void undo() {
            if (undo_stack.size == 0) return;
            var step = undo_stack.remove_at(undo_stack.size - 1);
            redo_stack.add(swap(step));
            modifications++;
            after_history(step);
        }

        public void redo() {
            if (redo_stack.size == 0) return;
            var step = redo_stack.remove_at(redo_stack.size - 1);
            undo_stack.add(swap(step));
            modifications++;
            after_history(step);
        }

        private void after_history(RetouchUndoStep step) {
            if (step.structure != null) structure_changed();
            recomposite();
        }

        public void mark_modified() {
            modifications++;
        }

        public RetouchLayer? find(string id, Gee.ArrayList<RetouchLayer>? list = null) {
            foreach (var l in list ?? layers) {
                if (l.id == id) return l;
                var c = find(id, l.children);
                if (c != null) return c;
            }
            return null;
        }

        public Gee.ArrayList<RetouchLayer>? parent_list(RetouchLayer layer, Gee.ArrayList<RetouchLayer>? list = null) {
            var l = list ?? layers;
            if (l.contains(layer)) return l;
            foreach (var c in l) {
                var found = parent_list(layer, c.children);
                if (found != null) return found;
            }
            return null;
        }

        public void flatten_list(Gee.ArrayList<RetouchLayer> out_list, int depth, Gee.ArrayList<int> depths, Gee.ArrayList<RetouchLayer>? list = null) {
            var l = list ?? layers;
            for (int i = l.size - 1; i >= 0; i--) {
                out_list.add(l[i]);
                depths.add(depth);
                if (l[i].kind == RetouchLayerKind.GROUP && l[i].expanded) flatten_list(out_list, depth + 1, depths, l[i].children);
            }
        }

        public void invalidate_layer(RetouchLayer layer) {
            text_cache.unset(layer.id);
            embed_cache.unset(layer.id);
        }

        public void recomposite() {
            composite_rect(0, 0, width, height);
            changed(0, 0, width, height);
        }

        public void update_rect(int x, int y, int w, int h) {
            clip_rect(ref x, ref y, ref w, ref h, width, height);
            if (w <= 0 || h <= 0) return;
            composite_rect(x, y, w, h);
            changed(x, y, w, h);
        }

        private FloatImage? text_pixels(RetouchLayer layer) {
            if (layer.text == null) return null;
            string key = layer.text.to_json();
            if (text_cache.has_key(layer.id) && text_keys[layer.id] == key) return text_cache[layer.id];
            var img = layer.text.render(width, height);
            text_cache[layer.id] = img;
            text_keys[layer.id] = key;
            return img;
        }

        private FloatImage? embed_pixels(RetouchLayer layer) {
            if (embed_cache.has_key(layer.id)) return embed_cache[layer.id];
            if (layer.source_uri == "") return layer.pixels;
            try {
                var file = File.new_for_uri(layer.source_uri);
                var photo = Codecs.load(file, 0);
                var img = RetouchDevelop.render(photo, layer.source_edit != "" ? EditParams.from_json(layer.source_edit) : null);
                if ((layer.embed_scale - 1.0).abs() > 1e-6)
                    img = img.resized(int.max(1, (int) (img.width * layer.embed_scale)), int.max(1, (int) (img.height * layer.embed_scale)));
                embed_cache[layer.id] = img;
                layer.pixels = img;
                return img;
            } catch (Error e) {
                warning("Retouch: cannot render embedded photo: %s", e.message);
                return layer.pixels;
            }
        }

        public FloatImage? layer_source(RetouchLayer layer) {
            switch (layer.kind) {
                case RetouchLayerKind.TEXT: return text_pixels(layer);
                case RetouchLayerKind.EMBEDDED: return embed_pixels(layer);
                default: return layer.pixels;
            }
        }

        private void composite_rect(int rx, int ry, int rw, int rh) {
            var canvas = new FloatImage(rw, rh);
            canvas.fill(0, 0, 0, 0);
            composite_list(layers, canvas, rx, ry);
            RetouchColor.encoded_to_working(canvas);
            composite.paste(canvas, rx, ry);
        }

        private void composite_list(Gee.ArrayList<RetouchLayer> list, FloatImage canvas, int rx, int ry) {
            foreach (var layer in list) {
                if (!layer.visible) continue;
                float[]? mask = layer.mask_enabled && layer.mask != null ? crop_plane(layer.mask, width, rx, ry, canvas.width, canvas.height) : null;
                switch (layer.kind) {
                    case RetouchLayerKind.GROUP:
                        var sub = new FloatImage(canvas.width, canvas.height);
                        sub.fill(0, 0, 0, 0);
                        composite_list(layer.children, sub, rx, ry);
                        Blend.composite(canvas, sub, 0, 0, layer.mode, layer.opacity, mask, false);
                        break;
                    case RetouchLayerKind.ADJUSTMENT:
                        if (layer.adjustment == null) break;
                        var adjusted = canvas.copy();
                        layer.adjustment.apply_encoded(adjusted, 0, 0, adjusted.width, adjusted.height);
                        Blend.composite(canvas, adjusted, 0, 0, layer.mode, layer.opacity, mask, false);
                        break;
                    default:
                        var src = layer_source(layer);
                        if (src == null) break;
                        int lx = layer.kind == RetouchLayerKind.RASTER || layer.kind == RetouchLayerKind.EMBEDDED ? layer.x : 0;
                        int ly = layer.kind == RetouchLayerKind.RASTER || layer.kind == RetouchLayerKind.EMBEDDED ? layer.y : 0;
                        int sx = rx - lx, sy = ry - ly, sw = canvas.width, sh = canvas.height;
                        int ox = 0, oy = 0;
                        if (sx < 0) { ox = -sx; sw += sx; sx = 0; }
                        if (sy < 0) { oy = -sy; sh += sy; sy = 0; }
                        sw = int.min(sw, src.width - sx);
                        sh = int.min(sh, src.height - sy);
                        if (sw <= 0 || sh <= 0) break;
                        var piece = src.cropped(sx, sy, sw, sh);
                        RetouchColor.working_to_encoded(piece);
                        float[]? piece_mask = mask != null ? crop_plane(mask, canvas.width, ox, oy, sw, sh) : null;
                        Blend.composite(canvas, piece, ox, oy, layer.mode, layer.opacity, piece_mask, false);
                        break;
                }
            }
        }

        public FloatImage flatten() {
            return composite.copy();
        }

        public void add_layer(RetouchLayer layer, RetouchLayer? above = null) {
            var list = above != null ? parent_list(above) ?? layers : layers;
            int index = above != null ? list.index_of(above) + 1 : list.size;
            list.insert(int.max(0, index), layer);
        }

        public void remove_layer(RetouchLayer layer) {
            var list = parent_list(layer);
            if (list != null) list.remove(layer);
            invalidate_layer(layer);
        }

        public bool move_layer(RetouchLayer layer, int delta) {
            var list = parent_list(layer);
            if (list == null) return false;
            int i = list.index_of(layer);
            int j = i + delta;
            if (j < 0 || j >= list.size) return false;
            list.remove_at(i);
            list.insert(j, layer);
            return true;
        }

        public RetouchLayer? layer_below(RetouchLayer layer) {
            var list = parent_list(layer);
            if (list == null) return null;
            int i = list.index_of(layer);
            return i > 0 ? list[i - 1] : null;
        }

        public FloatImage render_layer_pixels(RetouchLayer layer) {
            var canvas = new FloatImage(width, height);
            canvas.fill(0, 0, 0, 0);
            var list = new Gee.ArrayList<RetouchLayer>();
            var copy = layer.shallow_copy();
            copy.visible = true;
            copy.opacity = 1;
            copy.mode = BlendMode.NORMAL;
            copy.mask = null;
            list.add(copy);
            composite_list(list, canvas, 0, 0);
            RetouchColor.encoded_to_working(canvas);
            return canvas;
        }

        public RetouchLayer? merge_down(RetouchLayer layer) {
            var below = layer_below(layer);
            if (below == null || below.kind != RetouchLayerKind.RASTER || below.pixels == null) return null;
            var list = parent_list(layer);
            var base_img = new FloatImage(width, height);
            base_img.fill(0, 0, 0, 0);
            var pair = new Gee.ArrayList<RetouchLayer>();
            var b = below.shallow_copy();
            b.opacity = 1;
            b.mode = BlendMode.NORMAL;
            b.visible = true;
            pair.add(b);
            pair.add(layer);
            composite_list(pair, base_img, 0, 0);
            RetouchColor.encoded_to_working(base_img);
            below.pixels = base_img;
            below.mask = null;
            below.x = 0;
            below.y = 0;
            list.remove(layer);
            invalidate_layer(layer);
            return below;
        }

        public RetouchLayer flatten_to_layer() {
            var layer = new RetouchLayer(_("Background"), RetouchLayerKind.RASTER);
            layer.pixels = composite.copy();
            return layer;
        }

        public RetouchLayer stamp_visible() {
            var layer = new RetouchLayer(_("Merged"), RetouchLayerKind.RASTER);
            layer.pixels = composite.copy();
            return layer;
        }
    }

    namespace RetouchDevelop {

        public FloatImage render(DecodedPhoto photo, EditParams? p) {
            if (p == null && !photo.is_raw()) return photo.image;
            return DevelopPipeline.render(photo, p ?? new EditParams(), new RenderOptions());
        }

        public void apply_layer(FloatImage encoded, EditParams p) {
            RetouchColor.encoded_to_working(encoded);
            Tone.render(encoded, p, 1.0);
            RetouchColor.working_to_encoded(encoded);
        }
    }
}
