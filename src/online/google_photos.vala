using GLib;
using Singularity.Accounts;

namespace Singularity.Apps.Photos {

    public class GooglePhotosSource : PhotoSource {
        private const string APP_ALBUM = "Singularity";
        private string api;
        private string picker_api;
        private Gee.ArrayList<OnlinePhoto>? picked_items = null;

        public override string title {
            owned get { return _("Google Photos"); }
        }

        public override string empty_title {
            owned get { return _("Google Photos"); }
        }

        public override string empty_subtitle {
            owned get { return _("Choose photos from your Google Photos library, or upload some from this computer"); }
        }

        public override bool can_pick {
            get { return true; }
        }

        public override bool has_albums {
            get { return true; }
        }

        public GooglePhotosSource(Account account) {
            Object(account: account);
            api = slash(account.get_endpoint("google-photos") ?? "https://photoslibrary.googleapis.com/v1/");
            picker_api = slash(account.get_endpoint("google-photos-picker") ?? "https://photospicker.googleapis.com/v1/");
        }

        private static string slash(string url) {
            return url.has_suffix("/") ? url : url + "/";
        }

        private static string esc(string s) {
            return GLib.Uri.escape_string(s, null, false);
        }

        private GLib.File index_file() {
            return data_dir().get_child("picked.json");
        }

        private GLib.File picked_dir() {
            return data_dir().get_child("picked");
        }

        private Gee.ArrayList<OnlinePhoto> load_picked() {
            if (picked_items != null) return picked_items;
            picked_items = new Gee.ArrayList<OnlinePhoto>();
            try {
                var parser = new Json.Parser();
                parser.load_from_file(index_file().get_path());
                var root = parser.get_root();
                if (root != null && root.get_node_type() == Json.NodeType.ARRAY) {
                    foreach (var node in root.get_array().get_elements()) {
                        if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                        var o = node.get_object();
                        var local = picked_dir().get_child(member(o, "file"));
                        if (!local.query_exists()) continue;
                        GLib.DateTime? when = member(o, "created") != "" ? new GLib.DateTime.from_iso8601(member(o, "created"), null) : null;
                        int64 size = 0;
                        try {
                            size = local.query_info("standard::size", GLib.FileQueryInfoFlags.NONE).get_size();
                        } catch (GLib.Error e) {
                        }
                        var p = new OnlinePhoto(this, "picked:" + member(o, "id"), member(o, "name"), when, size, local);
                        p.picked = true;
                        p.content_type = member(o, "type");
                        picked_items.add(p);
                    }
                }
            } catch (GLib.Error e) {
            }
            return picked_items;
        }

        private void save_picked() throws GLib.Error {
            var b = new Json.Builder();
            b.begin_array();
            foreach (var p in load_picked()) {
                b.begin_object();
                b.set_member_name("id").add_string_value(p.remote_id.substring(7));
                b.set_member_name("name").add_string_value(p.name);
                b.set_member_name("file").add_string_value(p.file.get_basename());
                b.set_member_name("type").add_string_value(p.content_type);
                b.set_member_name("created").add_string_value(p.modified != null ? p.modified.format_iso8601() : "");
                b.end_object();
            }
            b.end_array();
            var dir = data_dir();
            if (!dir.query_exists()) dir.make_directory_with_parents();
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.set_root(b.get_root());
            GLib.FileUtils.set_contents_full(index_file().get_path(), gen.to_data(null), -1, GLib.FileSetContentsFlags.CONSISTENT, 0600);
        }

        private OnlinePhoto photo_of(Json.Object o) {
            string id = member(o, "id");
            string name = member(o, "filename");
            if (name == "") name = id;
            GLib.DateTime? when = null;
            if (o.has_member("mediaMetadata")) {
                string created = member(o.get_object_member("mediaMetadata"), "creationTime");
                if (created != "") when = new GLib.DateTime.from_iso8601(created, null);
            }
            var p = new OnlinePhoto(this, id, name, when, 0, full_file(id, name));
            p.content_type = member(o, "mimeType");
            p.media_url = member(o, "baseUrl");
            return p;
        }

        private async void collect(string method, string url_base, Json.Builder? body_base, Gee.List<OnlinePhoto> result, GLib.Cancellable? cancellable) throws GLib.Error {
            string token = "";
            for (int n = 0; n < 50; n++) {
                HttpResponse response;
                if (method == "GET") {
                    string url = url_base + "?pageSize=100" + (token != "" ? "&pageToken=" + esc(token) : "");
                    response = yield send_ok("GET", url, null, null, null, cancellable);
                } else {
                    var b = new Json.Builder();
                    b.begin_object();
                    var base_root = body_base.get_root().get_object();
                    foreach (string k in base_root.get_members()) b.set_member_name(k).add_value(base_root.get_member(k).copy());
                    b.set_member_name("pageSize").add_int_value(100);
                    if (token != "") b.set_member_name("pageToken").add_string_value(token);
                    b.end_object();
                    response = yield send_ok("POST", url_base, "application/json", json_bytes(b), null, cancellable);
                }
                var root = response.json_object();
                if (root.has_member("mediaItems")) {
                    foreach (var node in root.get_array_member("mediaItems").get_elements()) {
                        var o = node.get_object();
                        if (o.has_member("mediaMetadata") && o.get_object_member("mediaMetadata").has_member("video")) continue;
                        result.add(photo_of(o));
                    }
                }
                token = member(root, "nextPageToken");
                if (token == "") break;
            }
        }

        public override async Gee.List<OnlinePhoto> list(string view, GLib.Cancellable? cancellable) throws GLib.Error {
            var result = new Gee.ArrayList<OnlinePhoto>();
            if (view != "") {
                var body = new Json.Builder();
                body.begin_object();
                body.set_member_name("albumId").add_string_value(view);
                body.end_object();
                yield collect("POST", api + "mediaItems:search", body, result, cancellable);
                return result;
            }
            result.add_all(load_picked());
            yield collect("GET", api + "mediaItems", null, result, cancellable);
            return result;
        }

        public override async Gee.List<PhotoAlbum> albums(GLib.Cancellable? cancellable) throws GLib.Error {
            var result = new Gee.ArrayList<PhotoAlbum>();
            string token = "";
            for (int n = 0; n < 20; n++) {
                string url = api + "albums?pageSize=50" + (token != "" ? "&pageToken=" + esc(token) : "");
                var root = (yield send_ok("GET", url, null, null, null, cancellable)).json_object();
                if (root.has_member("albums")) {
                    foreach (var node in root.get_array_member("albums").get_elements()) {
                        var o = node.get_object();
                        var a = new PhotoAlbum();
                        a.id = member(o, "id");
                        a.title = member(o, "title");
                        string count = member(o, "mediaItemsCount");
                        a.count = count != "" ? int.parse(count) : -1;
                        result.add(a);
                    }
                }
                token = member(root, "nextPageToken");
                if (token == "") break;
            }
            return result;
        }

        private async string app_album(GLib.Cancellable? cancellable) throws GLib.Error {
            foreach (var a in yield albums(cancellable)) {
                if (a.title == APP_ALBUM) return a.id;
            }
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("album").begin_object();
            b.set_member_name("title").add_string_value(APP_ALBUM);
            b.end_object();
            b.end_object();
            var root = (yield send_ok("POST", api + "albums", "application/json", json_bytes(b), null, cancellable)).json_object();
            return member(root, "id");
        }

        public override async void upload(GLib.File local, GLib.Cancellable? cancellable) throws GLib.Error {
            uint8[] data;
            yield local.load_contents_async(cancellable, out data, null);
            var headers = new GLib.HashTable<string, string>(str_hash, str_equal);
            headers.insert("X-Goog-Upload-Protocol", "raw");
            headers.insert("X-Goog-Upload-Content-Type", content_type_of(local));
            headers.insert("X-Goog-Upload-File-Name", local.get_basename());
            var response = yield send_ok("POST", api + "uploads", "application/octet-stream", new GLib.Bytes(data), headers, cancellable);
            string token = response.text().strip();
            if (token == "") throw new AccountsError.PROTOCOL(_("The server sent an unexpected answer"));
            string album = yield app_album(cancellable);
            var b = new Json.Builder();
            b.begin_object();
            if (album != "") b.set_member_name("albumId").add_string_value(album);
            b.set_member_name("newMediaItems").begin_array();
            b.begin_object();
            b.set_member_name("simpleMediaItem").begin_object();
            b.set_member_name("uploadToken").add_string_value(token);
            b.set_member_name("fileName").add_string_value(local.get_basename());
            b.end_object();
            b.end_object();
            b.end_array();
            b.end_object();
            var root = (yield send_ok("POST", api + "mediaItems:batchCreate", "application/json", json_bytes(b), null, cancellable)).json_object();
            if (root.has_member("newMediaItemResults")) {
                foreach (var node in root.get_array_member("newMediaItemResults").get_elements()) {
                    var o = node.get_object();
                    if (!o.has_member("mediaItem")) {
                        string message = o.has_member("status") ? member(o.get_object_member("status"), "message") : "";
                        throw new AccountsError.PROTOCOL(message != "" ? message : _("The server sent an unexpected answer"));
                    }
                }
            }
        }

        protected override async GLib.Bytes fetch_thumbnail(OnlinePhoto photo, int size, GLib.Cancellable? cancellable) throws GLib.Error {
            return yield get_authorized(photo.media_url + "=w%d-h%d-c".printf(size, size), cancellable);
        }

        protected override async GLib.Bytes fetch_media(OnlinePhoto photo, GLib.Cancellable? cancellable) throws GLib.Error {
            return yield get_authorized(photo.media_url + "=d", cancellable);
        }

        private static uint seconds_of(string duration, uint fallback) {
            if (!duration.has_suffix("s")) return fallback;
            double v = double.parse(duration.substring(0, duration.length - 1));
            return v > 0 ? (uint) v : fallback;
        }

        public override async int pick(GLib.Cancellable? cancellable) throws GLib.Error {
            var root = (yield send_ok("POST", picker_api + "sessions", "application/json", new GLib.Bytes("{}".data), null, cancellable)).json_object();
            string session = member(root, "id");
            string uri = member(root, "pickerUri");
            if (session == "" || uri == "") throw new AccountsError.PROTOCOL(_("The server sent an unexpected answer"));
            uint interval = 5;
            uint timeout = 1800;
            if (root.has_member("pollingConfig")) {
                var pc = root.get_object_member("pollingConfig");
                interval = seconds_of(member(pc, "pollInterval"), 5);
                timeout = seconds_of(member(pc, "timeoutIn"), 1800);
            }
            try {
                GLib.AppInfo.launch_default_for_uri(uri.has_suffix("/") ? uri + "autoclose" : uri + "/autoclose", null);
                int64 deadline = GLib.get_monotonic_time() + (int64) timeout * 1000000;
                bool ready = false;
                while (!ready) {
                    if (GLib.get_monotonic_time() > deadline) throw new AccountsError.CANCELLED(_("Nothing was chosen in time"));
                    GLib.Timeout.add_seconds(interval, pick.callback);
                    yield;
                    if (cancellable != null && cancellable.is_cancelled()) throw new AccountsError.CANCELLED(_("Cancelled"));
                    var state = (yield send_ok("GET", picker_api + "sessions/" + esc(session), null, null, null, cancellable)).json_object();
                    ready = state.has_member("mediaItemsSet") && state.get_boolean_member("mediaItemsSet");
                }
                int added = 0;
                string token = "";
                var known = new Gee.HashSet<string>();
                foreach (var p in load_picked()) known.add(p.remote_id);
                for (int n = 0; n < 50; n++) {
                    string url = picker_api + "mediaItems?sessionId=" + esc(session) + "&pageSize=100" + (token != "" ? "&pageToken=" + esc(token) : "");
                    var page = (yield send_ok("GET", url, null, null, null, cancellable)).json_object();
                    if (page.has_member("mediaItems")) {
                        foreach (var node in page.get_array_member("mediaItems").get_elements()) {
                            var o = node.get_object();
                            if (member(o, "type") == "VIDEO" || !o.has_member("mediaFile")) continue;
                            string id = member(o, "id");
                            if (known.contains("picked:" + id)) continue;
                            var mf = o.get_object_member("mediaFile");
                            string name = member(mf, "filename");
                            if (name == "") name = id;
                            var data = yield get_authorized(member(mf, "baseUrl") + "=d", cancellable);
                            var local = picked_dir().get_child(key_of(id) + "-" + safe_name(name));
                            yield write_file(local, data, cancellable);
                            string created = member(o, "createTime");
                            var p = new OnlinePhoto(this, "picked:" + id, name,
                                created != "" ? new GLib.DateTime.from_iso8601(created, null) : null, (int64) data.get_size(), local);
                            p.picked = true;
                            p.content_type = member(mf, "mimeType");
                            load_picked().add(p);
                            known.add(p.remote_id);
                            added++;
                        }
                    }
                    token = member(page, "nextPageToken");
                    if (token == "") break;
                }
                save_picked();
                return added;
            } finally {
                http.send.begin("DELETE", picker_api + "sessions/" + esc(session), null, null, null, null);
            }
        }

        public override void forget(OnlinePhoto photo) {
            if (!photo.picked) return;
            load_picked().remove(photo);
            try {
                photo.file.delete();
            } catch (GLib.Error e) {
            }
            try {
                save_picked();
            } catch (GLib.Error e) {
                warning("photos: %s", e.message);
            }
        }
    }
}
