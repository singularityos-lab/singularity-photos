using GLib;
using Singularity.Accounts;

namespace Singularity.Apps.Photos {

    public class NextcloudPhotosSource : PhotoSource {
        private const string NS_NEXTCLOUD = "http://nextcloud.org/ns";
        private const string ITEM_PROPS = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns"><d:prop><d:resourcetype/><d:displayname/><d:getcontenttype/><d:getcontentlength/><d:getlastmodified/><d:getetag/><oc:fileid/></d:prop></d:propfind>""";
        private const string ALBUM_PROPS = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns"><d:prop><d:resourcetype/><d:displayname/><nc:nbItems/><nc:last-photo/></d:prop></d:propfind>""";
        private const string SEARCH = """<?xml version="1.0" encoding="utf-8"?><d:searchrequest xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns"><d:basicsearch><d:select><d:prop><d:getcontenttype/><d:getcontentlength/><d:getlastmodified/><d:getetag/><d:displayname/><oc:fileid/></d:prop></d:select><d:from><d:scope><d:href>%s</d:href><d:depth>infinity</d:depth></d:scope></d:from><d:where><d:like><d:prop><d:getcontenttype/></d:prop><d:literal>image/%%</d:literal></d:like></d:where><d:orderby><d:order><d:prop><d:getlastmodified/></d:prop><d:descending/></d:order></d:orderby><d:limit><d:nresults>%d</d:nresults></d:limit></d:basicsearch></d:searchrequest>""";

        private string server;
        private string webdav;
        private string photos;
        private DavClient dav;

        public override string title {
            owned get { return _("Nextcloud"); }
        }

        public override string empty_title {
            owned get { return _("No Photos on Nextcloud"); }
        }

        public override string empty_subtitle {
            owned get { return _("Pictures stored in your Nextcloud files show up here"); }
        }

        public override bool has_albums {
            get { return true; }
        }

        public NextcloudPhotosSource(Account account) {
            Object(account: account);
            dav = new DavClient(http);
            server = account.server;
            while (server.has_suffix("/")) server = server.substring(0, server.length - 1);
            string root = account.get_endpoint("webdav") ?? server + "/remote.php/dav/files/" + account.identity + "/";
            webdav = root.has_suffix("/") ? root : root + "/";
            string user_seg = DavClient.last_segment(webdav);
            string p = account.get_endpoint("photos") ?? server + "/remote.php/dav/photos/" + user_seg + "/";
            photos = p.has_suffix("/") ? p : p + "/";
        }

        private string dav_root() {
            int at = webdav.index_of("/remote.php/dav/");
            return at >= 0 ? webdav.substring(0, at) + "/remote.php/dav/" : server + "/remote.php/dav/";
        }

        private string scope_href() {
            int at = webdav.index_of("/remote.php/dav/");
            string path = at >= 0 ? webdav.substring(at + "/remote.php/dav".length) : "/files/" + account.identity + "/";
            return path.has_suffix("/") ? path.substring(0, path.length - 1) : path;
        }

        private string files_path() {
            try {
                return GLib.Uri.parse(webdav, GLib.UriFlags.ENCODED).get_path();
            } catch (GLib.UriError e) {
                return "";
            }
        }

        private OnlinePhoto? photo_of(DavResponse r, bool in_album) {
            if (r.is_type(NS_DAV, "collection")) return null;
            string type = r.text(NS_DAV, "getcontenttype");
            string name = r.text(NS_DAV, "displayname");
            string last = GLib.Uri.unescape_string(DavClient.last_segment(r.href)) ?? DavClient.last_segment(r.href);
            string fileid = r.text(NS_OWNCLOUD, "fileid");
            if (name == "") {
                name = last;
                if (in_album && fileid != "" && name.has_prefix(fileid + "-")) name = name.substring(fileid.length + 1);
            }
            if (!is_image_type(type, name)) return null;
            GLib.DateTime? when = null;
            string modified = r.text(NS_DAV, "getlastmodified");
            if (modified != "") when = WebDavDrive.parse_http_date(modified);
            string size = r.text(NS_DAV, "getcontentlength");
            string url = HttpClient.resolve(server + "/", r.href);
            var p = new OnlinePhoto(this, url, name, when, size != "" ? int64.parse(size) : 0, full_file(url, name));
            p.content_type = type;
            p.media_url = url;
            if (fileid != "") {
                p.thumb_url = server + "/index.php/core/preview?fileId=" + fileid + "&x=256&y=256&a=1";
            } else {
                string prefix = files_path();
                string path = r.href;
                if (prefix != "" && path.has_prefix(prefix)) {
                    string rel = GLib.Uri.unescape_string(path.substring(prefix.length)) ?? path.substring(prefix.length);
                    p.thumb_url = server + "/index.php/core/preview.png?file=" + GLib.Uri.escape_string("/" + rel, "/", false) + "&x=256&y=256&a=1";
                }
            }
            return p;
        }

        public override async Gee.List<OnlinePhoto> list(string view, GLib.Cancellable? cancellable) throws GLib.Error {
            var result = new Gee.ArrayList<OnlinePhoto>();
            if (view != "") {
                var ms = yield dav.propfind(view, "1", ITEM_PROPS, cancellable);
                foreach (var r in ms.responses) {
                    var p = photo_of(r, true);
                    if (p != null) result.add(p);
                }
                return result;
            }
            var headers = new GLib.HashTable<string, string>(str_hash, str_equal);
            headers.insert("Depth", "infinity");
            string body = SEARCH.printf(DavClient.xml_escape(scope_href()), 2000);
            var response = yield http.send_ok("SEARCH", dav_root(), "text/xml; charset=utf-8", new GLib.Bytes(body.data), headers, cancellable);
            var ms = Multistatus.parse(response.text());
            foreach (var r in ms.responses) {
                var p = photo_of(r, false);
                if (p != null) result.add(p);
            }
            return result;
        }

        public override async Gee.List<PhotoAlbum> albums(GLib.Cancellable? cancellable) throws GLib.Error {
            var result = new Gee.ArrayList<PhotoAlbum>();
            Multistatus ms;
            try {
                ms = yield dav.propfind(photos + "albums/", "1", ALBUM_PROPS, cancellable);
            } catch (AccountsError.NOT_FOUND e) {
                return result;
            } catch (AccountsError.PROTOCOL e) {
                return result;
            }
            string self_path = "";
            try {
                self_path = GLib.Uri.parse(photos + "albums/", GLib.UriFlags.ENCODED).get_path();
            } catch (GLib.UriError e) {
            }
            foreach (var r in ms.responses) {
                if (!r.is_type(NS_DAV, "collection")) continue;
                string href = r.href.has_suffix("/") ? r.href : r.href + "/";
                if (href == self_path) continue;
                var a = new PhotoAlbum();
                a.id = HttpClient.resolve(server + "/", href);
                a.title = r.text(NS_DAV, "displayname");
                if (a.title == "") a.title = GLib.Uri.unescape_string(DavClient.last_segment(href)) ?? DavClient.last_segment(href);
                string n = r.text(NS_NEXTCLOUD, "nbItems");
                a.count = n != "" ? int.parse(n) : -1;
                result.add(a);
            }
            result.sort((x, y) => x.title.collate(y.title));
            return result;
        }

        public override async void upload(GLib.File local, GLib.Cancellable? cancellable) throws GLib.Error {
            string folder = webdav + "Photos/";
            try {
                yield dav.propfind(folder, "0", ITEM_PROPS, cancellable);
            } catch (AccountsError.NOT_FOUND e) {
                yield dav.mkcol(folder, cancellable);
            }
            uint8[] data;
            yield local.load_contents_async(cancellable, out data, null);
            string name = local.get_basename();
            string stem = name;
            string ext = "";
            int dot = name.last_index_of(".");
            if (dot > 0) {
                stem = name.substring(0, dot);
                ext = name.substring(dot);
            }
            for (int n = 1; n < 100; n++) {
                try {
                    yield dav.put(folder + GLib.Uri.escape_string(name, null, false), content_type_of(local), new GLib.Bytes(data), null, true, cancellable);
                    return;
                } catch (AccountsError.CONFLICT e) {
                    name = "%s (%d)%s".printf(stem, n, ext);
                }
            }
            throw new AccountsError.CONFLICT(_("%s already exists").printf(local.get_basename()));
        }

        protected override async GLib.Bytes fetch_thumbnail(OnlinePhoto photo, int size, GLib.Cancellable? cancellable) throws GLib.Error {
            if (photo.thumb_url == "") return yield fetch_media(photo, cancellable);
            try {
                return yield get_authorized(photo.thumb_url, cancellable);
            } catch (AccountsError.NOT_FOUND e) {
                return yield fetch_media(photo, cancellable);
            }
        }

        protected override async GLib.Bytes fetch_media(OnlinePhoto photo, GLib.Cancellable? cancellable) throws GLib.Error {
            return yield get_authorized(photo.media_url, cancellable);
        }
    }
}
