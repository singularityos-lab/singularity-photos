namespace Singularity.Apps.Photos {

    internal class PhotosIntents : Object {
        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key) : "";
        }

        private static Json.Node obj (Json.Object o) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (o);
            return node;
        }

        private static Catalog catalog () {
            return Catalog.get_default ();
        }

        private static Json.Object brief (PhotoRecord r) {
            var c = catalog ();
            var o = new Json.Object ();
            o.set_int_member ("id", r.id);
            o.set_string_member ("path", r.path);
            if (r.title != "") o.set_string_member ("title", r.title);
            if (r.caption != "") o.set_string_member ("caption", r.caption);
            o.set_string_member ("kind", r.kind);
            if (r.captured > 0) o.set_string_member ("captured", new DateTime.from_unix_local (r.captured).format ("%Y-%m-%d %H:%M"));
            o.set_int_member ("rating", r.rating);
            if (r.flag != 0) o.set_string_member ("flag", r.flag > 0 ? "pick" : "reject");
            if (r.label != "") o.set_string_member ("label", r.label);
            if (r.camera != "") o.set_string_member ("camera", r.camera);
            if (r.location != "") o.set_string_member ("place", r.location);
            var kw = new Json.Array ();
            foreach (string k in c.keyword_names (r)) kw.add_string_element (k);
            o.set_array_member ("keywords", kw);
            o.set_boolean_member ("edited", r.edited);
            return o;
        }

        private static PhotoRecord photo (Json.Node node) throws Error {
            PhotoRecord? r = null;
            if (node.get_value_type () == typeof (int64)) r = catalog ().get_photo (node.get_int ());
            else r = catalog ().find_path (node.get_string ());
            if (r == null) throw new IOError.NOT_FOUND ("no photo %s in the library", node.get_value_type () == typeof (int64) ? node.get_int ().to_string () : node.get_string ());
            return r;
        }

        private static Gee.ArrayList<PhotoRecord> photos_arg (Json.Object args) throws Error {
            var list = new Gee.ArrayList<PhotoRecord> ();
            if (args.has_member ("photos")) {
                foreach (var node in args.get_array_member ("photos").get_elements ()) list.add (photo (node));
            } else if (args.has_member ("photo")) {
                list.add (photo (args.get_member ("photo")));
            }
            if (list.size == 0) throw new IOError.INVALID_ARGUMENT ("give photo or photos, as ids or paths");
            return list;
        }

        private static LibraryFilter filter_from (Json.Object args) {
            var f = new LibraryFilter ();
            f.text = text (args, "text");
            if (args.has_member ("min_rating")) f.rating = (int) args.get_int_member ("min_rating");
            if (args.has_member ("flag")) f.flag = text (args, "flag");
            if (args.has_member ("label")) f.labels = { text (args, "label") };
            if (args.has_member ("kind")) f.kind = text (args, "kind");
            f.camera = text (args, "camera");
            f.place = text (args, "place");
            if (args.has_member ("year")) f.year = (int) args.get_int_member ("year");
            if (args.has_member ("month")) f.month = (int) args.get_int_member ("month");
            if (args.has_member ("keyword")) {
                var k = catalog ().find_keyword (text (args, "keyword"));
                f.keyword_id = k != null ? k.id : -1;
            }
            if (args.has_member ("edited")) f.edited = args.get_boolean_member ("edited") ? "edited" : "unedited";
            f.sort_key = "captured";
            f.ascending = false;
            f.collapse_stacks = false;
            return f;
        }

        private static Json.Node album (CollectionRecord c) {
            var o = new Json.Object ();
            o.set_int_member ("id", c.id);
            o.set_string_member ("name", c.name);
            o.set_string_member ("kind", c.kind);
            o.set_int_member ("photos", catalog ().collection_photos (c).size);
            return obj (o);
        }

        internal static void install (PhotosApp app) {
            var agent = app.agent;

            agent.add_intent ("photos_search", "Find photos in the library by words (title, caption, keywords, file name, people), minimum rating, flag (pick, reject), colour label, kind (photo, video, raw), camera, place, year, month, keyword or edited state.",
                "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"},\"min_rating\":{\"type\":\"integer\"},\"flag\":{\"type\":\"string\"},\"label\":{\"type\":\"string\"},\"kind\":{\"type\":\"string\"},\"camera\":{\"type\":\"string\"},\"place\":{\"type\":\"string\"},\"year\":{\"type\":\"integer\"},\"month\":{\"type\":\"integer\"},\"keyword\":{\"type\":\"string\"},\"edited\":{\"type\":\"boolean\"},\"limit\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var found = catalog ().query (filter_from (args));
                    int64 limit = args.has_member ("limit") ? args.get_int_member ("limit").clamp (1, 500) : 100;
                    var list = new Json.Array ();
                    foreach (var r in found) {
                        if (list.get_length () == limit) break;
                        list.add_object_element (brief (r));
                    }
                    var o = new Json.Object ();
                    o.set_int_member ("matches", found.size);
                    o.set_array_member ("photos", list);
                    return obj (o);
                });

            agent.add_intent ("photos_albums", "List the albums with how many photos each holds.",
                "{\"type\":\"object\",\"properties\":{}}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var list = new Json.Array ();
                    foreach (var c in catalog ().collections.values) list.add_element (album (c));
                    var o = new Json.Object ();
                    o.set_array_member ("albums", list);
                    return obj (o);
                });

            agent.add_intent ("photos_album_create", "Create an album, or add to an existing one with the same name, filled with the given photos (ids or paths).",
                "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"photos\":{\"type\":\"array\"}},\"required\":[\"name\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    string name = text (args, "name").strip ();
                    if (name == "") throw new IOError.INVALID_ARGUMENT ("the album needs a name");
                    var c = catalog ();
                    CollectionRecord? target = null;
                    foreach (var col in c.collections.values) if (!col.is_smart () && col.name == name) target = col;
                    var add = args.has_member ("photos") ? photos_arg (args) : new Gee.ArrayList<PhotoRecord> ();
                    if (target == null) target = c.create_collection (name, "manual");
                    foreach (var r in add) c.add_to_collection (target, r);
                    return album (target);
                });

            agent.add_intent ("photos_tag", "Set rating (0-5), flag (pick, reject, none), colour label, title, caption and add keywords on one or more photos.",
                "{\"type\":\"object\",\"properties\":{\"photos\":{\"type\":\"array\"},\"photo\":{},\"rating\":{\"type\":\"integer\"},\"flag\":{\"type\":\"string\"},\"label\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"caption\":{\"type\":\"string\"},\"keywords\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var c = catalog ();
                    var list = new Json.Array ();
                    foreach (var r in photos_arg (args)) {
                        if (args.has_member ("rating")) r.rating = ((int) args.get_int_member ("rating")).clamp (0, 5);
                        if (args.has_member ("flag")) {
                            string f = text (args, "flag");
                            r.flag = f == "pick" ? 1 : (f == "reject" ? -1 : 0);
                        }
                        if (args.has_member ("label")) r.label = text (args, "label");
                        if (args.has_member ("title")) r.title = text (args, "title");
                        if (args.has_member ("caption")) r.caption = text (args, "caption");
                        if (args.has_member ("keywords")) {
                            foreach (var k in args.get_array_member ("keywords").get_elements ()) {
                                string word = k.get_string ().strip ();
                                if (word != "") c.assign_keyword (r, c.ensure_keyword_path (word).id);
                            }
                        }
                        c.save (r);
                        list.add_object_element (brief (r));
                    }
                    var o = new Json.Object ();
                    o.set_array_member ("photos", list);
                    return obj (o);
                });

            agent.add_intent ("photos_edit", "Apply non-destructive edits to a photo: adjustments by name (exposure -2.5..2.5; brightness, contrast, highlights, shadows, saturation, vibrance, warmth, tint, vignette, whites, blacks, texture, clarity, dehaze -1..1; sharpness 0..1), a filter preset, quarter turns, flip, a crop (x, y, w, h from 0 to 1), or reset to the original.",
                "{\"type\":\"object\",\"properties\":{\"photo\":{},\"adjustments\":{\"type\":\"object\"},\"filter\":{\"type\":\"string\"},\"rotate\":{\"type\":\"integer\"},\"flip\":{\"type\":\"boolean\"},\"crop\":{\"type\":\"object\"},\"reset\":{\"type\":\"boolean\"}},\"required\":[\"photo\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var r = photo (args.get_member ("photo"));
                    var file = File.new_for_path (r.path);
                    if (args.has_member ("reset") && args.get_boolean_member ("reset")) {
                        EditStore.revert (file);
                        r.edited = false;
                        catalog ().save (r);
                        return obj (brief (r));
                    }
                    var p = EditStore.load (file) ?? new EditParams ();
                    var applied = new Json.Object ();
                    if (args.has_member ("adjustments")) {
                        var adj = args.get_object_member ("adjustments");
                        foreach (string key in adj.get_members ()) {
                            var a = Adjustment.from_key (key);
                            if (a == null) throw new IOError.INVALID_ARGUMENT ("unknown adjustment %s", key);
                            double v = adj.get_double_member (key).clamp (a.min_value (), a.max_value ());
                            p.set_value (a, v);
                            applied.set_double_member (key, v);
                        }
                    }
                    if (args.has_member ("filter")) {
                        string id = text (args, "filter");
                        if (id != "none" && FilterPreset.find (id) == null) {
                            string[] ids = {};
                            foreach (unowned FilterPreset fp in FilterPreset.all ()) ids += fp.id;
                            throw new IOError.NOT_FOUND ("no filter %s, use one of %s", id, string.joinv (", ", ids));
                        }
                        p.filter = id;
                        applied.set_string_member ("filter", id);
                    }
                    if (args.has_member ("rotate")) p.quarter_turns = (int) (((p.quarter_turns + args.get_int_member ("rotate")) % 4 + 4) % 4);
                    if (args.has_member ("flip")) p.flip = args.get_boolean_member ("flip");
                    if (args.has_member ("crop")) {
                        var cr = args.get_object_member ("crop");
                        p.set_crop (cr.get_double_member ("x"), cr.get_double_member ("y"), cr.get_double_member ("w"), cr.get_double_member ("h"));
                    }
                    EditStore.save (file, p);
                    r.edited = !p.is_identity ();
                    catalog ().save (r);
                    var copy = p.copy ();
                    new Thread<void> ("photo-agent-render", () => {
                        EditImageIO.render_to_cache (file, copy);
                    });
                    var o = brief (r);
                    o.set_object_member ("applied", applied);
                    o.set_string_member ("sidecar", EditStore.find_sidecar (file) != null ? EditStore.find_sidecar (file).get_path () : "");
                    o.set_boolean_member ("verified", EditStore.has_edits (file));
                    return obj (o);
                });
        }
    }
}
