using GLib;
using Singularity.Accounts;

namespace Singularity.Apps.Photos {

    public class PhotoAlbum : GLib.Object {
        public string id { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public int count { get; set; default = -1; }
    }

    public class OnlinePhoto : PhotoItem {
        public PhotoSource source { get; private set; }
        public string remote_id { get; private set; }
        public string content_type { get; set; default = ""; }
        public string thumb_url { get; set; default = ""; }
        public string media_url { get; set; default = ""; }
        public bool picked { get; set; default = false; }

        public OnlinePhoto(PhotoSource source, string remote_id, string name, GLib.DateTime? modified, int64 size, GLib.File local) {
            var info = new GLib.FileInfo();
            info.set_name(name);
            info.set_size(size > 0 ? size : 0);
            if (modified != null) info.set_modification_date_time(modified);
            base(local, info);
            this.source = source;
            this.remote_id = remote_id;
        }

        public bool downloaded {
            get { return file.query_exists(); }
        }
    }

    public abstract class PhotoSource : GLib.Object {
        public Account account { get; construct; }
        protected HttpClient http;
        protected Soup.Session plain;

        public abstract string title { owned get; }
        public abstract string empty_title { owned get; }
        public abstract string empty_subtitle { owned get; }

        public virtual bool can_pick {
            get { return false; }
        }

        public virtual bool has_albums {
            get { return false; }
        }

        construct {
            http = new HttpClient(account, Capability.PHOTOS);
            plain = new Soup.Session();
            plain.user_agent = "Singularity/1.0";
            plain.timeout = 60;
        }

        public static string api_of(Account account) {
            string? api = account.get_endpoint("photos-api");
            if (api != null && api != "") return api;
            switch (account.provider) {
                case "google": return "google";
                case "microsoft": return "onedrive";
                case "nextcloud": return "nextcloud";
                default: return "";
            }
        }

        public static PhotoSource? for_account(Account account) {
            if (!account.has_capability(Capability.PHOTOS)) return null;
            switch (api_of(account)) {
                case "google": return new GooglePhotosSource(account);
                case "onedrive": return new OneDrivePhotosSource(account);
                case "nextcloud": return new NextcloudPhotosSource(account);
                default: return null;
            }
        }

        public abstract async Gee.List<OnlinePhoto> list(string view, GLib.Cancellable? cancellable) throws GLib.Error;
        public abstract async Gee.List<PhotoAlbum> albums(GLib.Cancellable? cancellable) throws GLib.Error;
        public abstract async void upload(GLib.File local, GLib.Cancellable? cancellable) throws GLib.Error;

        public virtual bool can_replace {
            get { return false; }
        }

        public virtual async string upload_named(GLib.File local, string remote_name, bool replace, GLib.Cancellable? cancellable) throws GLib.Error {
            if (replace) throw new GLib.IOError.NOT_SUPPORTED(_("%s cannot replace a photo that is already there").printf(title));
            yield upload(local, cancellable);
            return remote_name;
        }
        protected abstract async GLib.Bytes fetch_thumbnail(OnlinePhoto photo, int size, GLib.Cancellable? cancellable) throws GLib.Error;
        protected abstract async GLib.Bytes fetch_media(OnlinePhoto photo, GLib.Cancellable? cancellable) throws GLib.Error;

        public virtual PhotoAlbum[] fixed_views() {
            return {};
        }

        public virtual async int pick(GLib.Cancellable? cancellable) throws GLib.Error {
            return 0;
        }

        public virtual void forget(OnlinePhoto photo) {
        }

        public GLib.File cache_dir() {
            return GLib.File.new_for_path(GLib.Path.build_filename(GLib.Environment.get_user_cache_dir(),
                "singularity", "cloud-files", account.id, "photos"));
        }

        public GLib.File data_dir() {
            return GLib.File.new_for_path(GLib.Path.build_filename(GLib.Environment.get_user_data_dir(),
                "singularity", "accounts", account.id, "photos"));
        }

        protected static string key_of(string id) {
            return GLib.Checksum.compute_for_string(GLib.ChecksumType.SHA1, id).substring(0, 20);
        }

        protected static string safe_name(string name) {
            string s = name.replace("/", "_").replace("\\", "_").strip();
            if (s == "" || s == "." || s == "..") s = "photo";
            return s;
        }

        public GLib.File full_file(string id, string name) {
            return cache_dir().get_child("full").get_child(key_of(id) + "-" + safe_name(name));
        }

        public GLib.File thumb_file(OnlinePhoto photo) {
            if (photo.picked) return photo.file;
            return cache_dir().get_child("thumbs").get_child(key_of(photo.remote_id) + ".img");
        }

        protected static async void write_file(GLib.File target, GLib.Bytes data, GLib.Cancellable? cancellable) throws GLib.Error {
            var parent = target.get_parent();
            if (parent != null && !parent.query_exists()) parent.make_directory_with_parents(cancellable);
            var tmp = parent.get_child("." + target.get_basename() + ".part");
            yield tmp.replace_contents_async(data.get_data(), null, false, GLib.FileCreateFlags.REPLACE_DESTINATION, cancellable, null);
            tmp.move(target, GLib.FileCopyFlags.OVERWRITE, cancellable, null);
        }

        public async GLib.File ensure_thumbnail(OnlinePhoto photo, int size, GLib.Cancellable? cancellable) throws GLib.Error {
            var target = thumb_file(photo);
            if (target.query_exists()) return target;
            var data = yield fetch_thumbnail(photo, size, cancellable);
            yield write_file(target, data, cancellable);
            return target;
        }

        public async GLib.File ensure_full(OnlinePhoto photo, GLib.Cancellable? cancellable) throws GLib.Error {
            if (photo.file.query_exists()) return photo.file;
            var data = yield fetch_media(photo, cancellable);
            yield write_file(photo.file, data, cancellable);
            return photo.file;
        }

        protected async GLib.Bytes get_plain(string url, GLib.Cancellable? cancellable) throws GLib.Error {
            var msg = new Soup.Message("GET", url);
            if (msg == null) throw new AccountsError.INVALID(_("The address %s is not valid").printf(url));
            GLib.Bytes data;
            try {
                data = yield plain.send_and_read_async(msg, GLib.Priority.DEFAULT, cancellable);
            } catch (GLib.IOError.CANCELLED e) {
                throw new AccountsError.CANCELLED(e.message);
            } catch (GLib.Error e) {
                throw new AccountsError.NETWORK(_("Could not reach %s: %s").printf(HttpClient.host_of(url), e.message));
            }
            if (msg.status_code < 200 || msg.status_code >= 300) {
                throw new AccountsError.PROTOCOL(_("%s failed with HTTP %u").printf("GET", msg.status_code));
            }
            return data;
        }

        protected async HttpResponse send_ok(string method, string url, string? content_type, GLib.Bytes? body,
                                             GLib.HashTable<string, string>? headers, GLib.Cancellable? cancellable) throws GLib.Error {
            try {
                return yield http.send_ok(method, url, content_type, body, headers, cancellable);
            } catch (AccountsError.AUTH_FAILED e) {
                if (account.auth != "oauth2") throw e;
                yield account.get_credentials(Capability.PHOTOS, true);
                return yield http.send_ok(method, url, content_type, body, headers, cancellable);
            }
        }

        protected async GLib.Bytes get_authorized(string url, GLib.Cancellable? cancellable) throws GLib.Error {
            var response = yield send_ok("GET", url, null, null, null, cancellable);
            return response.body;
        }

        protected static GLib.Bytes json_bytes(Json.Builder b) {
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            return new GLib.Bytes(gen.to_data(null).data);
        }

        protected static string member(Json.Object o, string key) {
            if (!o.has_member(key)) return "";
            var n = o.get_member(key);
            if (n.get_node_type() != Json.NodeType.VALUE) return "";
            var v = n.get_value();
            if (v.type() == typeof(string)) return v.get_string();
            if (v.type() == typeof(int64)) return v.get_int64().to_string();
            return "";
        }

        public static bool is_image_type(string type, string name) {
            if (type.has_prefix("image/")) return true;
            if (type != "" && type != "application/octet-stream") return false;
            string n = name.down();
            return n.has_suffix(".jpg") || n.has_suffix(".jpeg") || n.has_suffix(".png") || n.has_suffix(".gif") ||
                   n.has_suffix(".webp") || n.has_suffix(".heic") || n.has_suffix(".tif") || n.has_suffix(".tiff") || n.has_suffix(".bmp");
        }

        public static string content_type_of(GLib.File file) {
            bool uncertain;
            string guess = GLib.ContentType.guess(file.get_basename(), null, out uncertain);
            return GLib.ContentType.get_mime_type(guess) ?? "application/octet-stream";
        }
    }
}
