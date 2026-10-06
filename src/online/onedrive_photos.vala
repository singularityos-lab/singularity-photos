using GLib;
using Singularity.Accounts;

namespace Singularity.Apps.Photos {

    public class OneDrivePhotosSource : PhotoSource {
        private const string CAMERA_ROLL = "cameraroll";
        private string api;

        public override string title {
            owned get { return _("OneDrive"); }
        }

        public override string empty_title {
            owned get { return _("No Photos in OneDrive"); }
        }

        public override string empty_subtitle {
            owned get { return _("Pictures in your OneDrive and its camera roll show up here"); }
        }

        public OneDrivePhotosSource(Account account) {
            Object(account: account);
            string root = account.get_endpoint("graph") ?? "https://graph.microsoft.com/v1.0/";
            api = root.has_suffix("/") ? root : root + "/";
        }

        public override PhotoAlbum[] fixed_views() {
            var roll = new PhotoAlbum();
            roll.id = CAMERA_ROLL;
            roll.title = _("Camera Roll");
            return { roll };
        }

        private OnlinePhoto? photo_of(Json.Object o) {
            if (o.has_member("folder") || !o.has_member("file")) return null;
            string id = member(o, "id");
            string name = member(o, "name");
            string type = member(o.get_object_member("file"), "mimeType");
            if (!o.has_member("image") && !o.has_member("photo") && !is_image_type(type, name)) return null;
            GLib.DateTime? when = null;
            if (o.has_member("photo") && member(o.get_object_member("photo"), "takenDateTime") != "") {
                when = new GLib.DateTime.from_iso8601(member(o.get_object_member("photo"), "takenDateTime"), null);
            } else if (member(o, "lastModifiedDateTime") != "") {
                when = new GLib.DateTime.from_iso8601(member(o, "lastModifiedDateTime"), null);
            }
            int64 size = o.has_member("size") ? o.get_int_member("size") : 0;
            var p = new OnlinePhoto(this, id, name, when, size, full_file(id, name));
            p.content_type = type;
            if (o.has_member("thumbnails") && o.get_array_member("thumbnails").get_length() > 0) {
                var set = o.get_array_member("thumbnails").get_object_element(0);
                foreach (string size_name in new string[] { "large", "medium", "small" }) {
                    if (set.has_member(size_name) && member(set.get_object_member(size_name), "url") != "") {
                        p.thumb_url = member(set.get_object_member(size_name), "url");
                        break;
                    }
                }
            }
            return p;
        }

        private async void collect(string first, Gee.List<OnlinePhoto> result, Gee.HashSet<string> seen, GLib.Cancellable? cancellable, bool missing_ok) throws GLib.Error {
            string? next = first;
            for (int n = 0; n < 50 && next != null; n++) {
                var response = yield http.send("GET", next, null, null, null, cancellable);
                if (missing_ok && response.status == 404) return;
                HttpClient.check(response, "GET");
                var root = response.json_object();
                if (root.has_member("value")) {
                    foreach (var node in root.get_array_member("value").get_elements()) {
                        var p = photo_of(node.get_object());
                        if (p == null || seen.contains(p.remote_id)) continue;
                        seen.add(p.remote_id);
                        result.add(p);
                    }
                }
                next = root.has_member("@odata.nextLink") ? root.get_string_member("@odata.nextLink") : null;
            }
        }

        public override async Gee.List<OnlinePhoto> list(string view, GLib.Cancellable? cancellable) throws GLib.Error {
            var result = new Gee.ArrayList<OnlinePhoto>();
            var seen = new Gee.HashSet<string>();
            yield collect(api + "me/drive/special/cameraroll/children?$expand=thumbnails&$top=200", result, seen, cancellable, true);
            if (view == CAMERA_ROLL) return result;
            foreach (string ext in new string[] { "jpg", "jpeg", "png", "heic", "webp", "gif" }) {
                string q = GLib.Uri.escape_string("search(q='." + ext + "')", "()'=", false);
                yield collect(api + "me/drive/root/" + q + "?$expand=thumbnails&$top=200", result, seen, cancellable, false);
            }
            return result;
        }

        public override async Gee.List<PhotoAlbum> albums(GLib.Cancellable? cancellable) throws GLib.Error {
            return new Gee.ArrayList<PhotoAlbum>();
        }

        public override async void upload(GLib.File local, GLib.Cancellable? cancellable) throws GLib.Error {
            uint8[] data;
            yield local.load_contents_async(cancellable, out data, null);
            string url = api + "me/drive/special/cameraroll:/" + GLib.Uri.escape_string(local.get_basename(), null, false)
                + ":/content?@microsoft.graph.conflictBehavior=rename";
            yield http.send_ok("PUT", url, content_type_of(local), new GLib.Bytes(data), null, cancellable);
        }

        public override bool can_replace {
            get { return true; }
        }

        public override async string upload_named(GLib.File local, string remote_name, bool replace, GLib.Cancellable? cancellable) throws GLib.Error {
            uint8[] data;
            yield local.load_contents_async(cancellable, out data, null);
            string url = api + "me/drive/special/cameraroll:/" + GLib.Uri.escape_string(remote_name, null, false)
                + ":/content?@microsoft.graph.conflictBehavior=" + (replace ? "replace" : "fail");
            yield http.send_ok("PUT", url, content_type_of(local), new GLib.Bytes(data), null, cancellable);
            return remote_name;
        }

                protected override async GLib.Bytes fetch_thumbnail(OnlinePhoto photo, int size, GLib.Cancellable? cancellable) throws GLib.Error {
            string url = photo.thumb_url;
            if (url == "") {
                var root = (yield http.send_ok("GET", api + "me/drive/items/" + GLib.Uri.escape_string(photo.remote_id, null, false) + "/thumbnails", null, null, null, cancellable)).json_object();
                if (root.has_member("value") && root.get_array_member("value").get_length() > 0) {
                    var set = root.get_array_member("value").get_object_element(0);
                    if (set.has_member("large")) url = member(set.get_object_member("large"), "url");
                }
            }
            if (url == "") return yield fetch_media(photo, cancellable);
            return yield get_plain(url, cancellable);
        }

        protected override async GLib.Bytes fetch_media(OnlinePhoto photo, GLib.Cancellable? cancellable) throws GLib.Error {
            return yield get_authorized(api + "me/drive/items/" + GLib.Uri.escape_string(photo.remote_id, null, false) + "/content", cancellable);
        }
    }
}
