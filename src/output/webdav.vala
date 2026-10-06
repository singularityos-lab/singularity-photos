namespace Singularity.Apps.Photos {

    public class DavReply : Object {
        public uint status;
        public Bytes body;
        public string etag = "";

        public DavReply(uint status, Bytes body, string etag) {
            this.status = status;
            this.body = body;
            this.etag = etag;
        }

        public bool ok {
            get { return status >= 200 && status < 300; }
        }
    }

    public interface DavTransport : Object {
        public abstract async DavReply send(string method, string url, HashTable<string, string>? headers, Bytes? body, string? content_type, Cancellable? cancellable) throws Error;
    }

    public class BasicDavTransport : Object, DavTransport {
        private Soup.Session session = new Soup.Session();
        private string user;
        private string password;

        public BasicDavTransport(string user, string password) {
            this.user = user;
            this.password = password;
            session.user_agent = "Singularity Photos";
            session.timeout = 60;
        }

        public async DavReply send(string method, string url, HashTable<string, string>? headers, Bytes? body, string? content_type, Cancellable? cancellable) throws Error {
            var msg = new Soup.Message(method, url);
            if (msg == null) throw new IOError.INVALID_ARGUMENT(_("The address %s is not valid").printf(url));
            if (user != "") msg.request_headers.replace("Authorization", "Basic " + Base64.encode((user + ":" + password).data));
            if (headers != null) headers.foreach((k, v) => msg.request_headers.replace(k, v));
            if (body != null) msg.set_request_body_from_bytes(content_type ?? "application/octet-stream", body);
            var data = yield session.send_and_read_async(msg, Priority.DEFAULT, cancellable);
            if (msg.status_code == 401) throw new IOError.PERMISSION_DENIED(_("The server rejected the user name or password"));
            return new DavReply(msg.status_code, data, msg.response_headers.get_one("ETag") ?? "");
        }
    }

    public class AccountDavTransport : Object, DavTransport {
        private Singularity.Accounts.HttpClient http;

        public AccountDavTransport(Singularity.Accounts.Account account) {
            http = new Singularity.Accounts.HttpClient(account, Singularity.Accounts.Capability.PHOTOS);
        }

        public async DavReply send(string method, string url, HashTable<string, string>? headers, Bytes? body, string? content_type, Cancellable? cancellable) throws Error {
            var r = yield http.send(method, url, content_type, body, headers, cancellable);
            return new DavReply(r.status, r.body, r.header("ETag") ?? "");
        }
    }

    public class WebDav : Object {
        public string base_url { get; construct; }
        public DavTransport transport { get; construct; }
        private Gee.HashSet<string> made = new Gee.HashSet<string>();
        private const string PROPS = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/></d:prop></d:propfind>""";

        public WebDav(string base_url, DavTransport transport) {
            Object(base_url: base_url.has_suffix("/") ? base_url : base_url + "/", transport: transport);
        }

        public static WebDav for_account(Singularity.Accounts.Account account, string folder) {
            string server = account.server;
            while (server.has_suffix("/")) server = server.substring(0, server.length - 1);
            string root = account.get_endpoint("webdav") ?? server + "/remote.php/dav/files/" + account.identity + "/";
            if (!root.has_suffix("/")) root += "/";
            return new WebDav(root + escape_path(folder) + "/", new AccountDavTransport(account));
        }

        public static string escape_path(string rel) {
            string[] parts = {};
            foreach (var p in rel.split("/")) if (p != "") parts += Uri.escape_string(p, null, false);
            return string.joinv("/", parts);
        }

        public string url_for(string rel) {
            return base_url + escape_path(rel);
        }

        private static string clean_etag(string e) {
            return e.replace("\"", "").replace("W/", "").strip();
        }

        public async Gee.Map<string, string> list(Cancellable? cancellable) throws Error {
            var map = new Gee.HashMap<string, string>();
            var headers = new HashTable<string, string>(str_hash, str_equal);
            headers["Depth"] = "infinity";
            var reply = yield transport.send("PROPFIND", base_url, headers, new Bytes(PROPS.data), "application/xml; charset=utf-8", cancellable);
            if (reply.status == 404) return map;
            if (reply.status != 207) throw new IOError.FAILED(_("The server answered %u to a folder listing").printf(reply.status));
            var xml = new StringBuilder();
            xml.append_len((string) reply.body.get_data(), (ssize_t) reply.body.get_size());
            var ms = Singularity.Accounts.Multistatus.parse(xml.str);
            string base_path = Uri.unescape_string(Uri.parse(base_url, UriFlags.ENCODED).get_path()) ?? "";
            foreach (var r in ms.responses) {
                if (r.is_type(Singularity.Accounts.NS_DAV, "collection")) continue;
                string href = r.href.contains("://") ? Uri.parse(r.href, UriFlags.ENCODED).get_path() : r.href;
                string path = Uri.unescape_string(href) ?? href;
                if (!path.has_prefix(base_path)) continue;
                map[path.substring(base_path.length)] = clean_etag(r.text(Singularity.Accounts.NS_DAV, "getetag"));
            }
            return map;
        }

        public async Bytes get(string rel, Cancellable? cancellable) throws Error {
            var reply = yield transport.send("GET", url_for(rel), null, null, null, cancellable);
            if (!reply.ok) throw new IOError.FAILED(_("The server answered %u when reading %s").printf(reply.status, rel));
            return reply.body;
        }

        public async void ensure_parents(string rel, Cancellable? cancellable) throws Error {
            var parts = rel.split("/");
            string acc = "";
            for (int i = -1; i < parts.length - 1; i++) {
                if (i >= 0) acc = acc == "" ? parts[i] : acc + "/" + parts[i];
                string url = i < 0 ? base_url : url_for(acc) + "/";
                if (made.contains(url)) continue;
                yield mkcol(url, 0, cancellable);
                made.add(url);
            }
        }

        private static string? parent_url(string url) {
            string u = url.has_suffix("/") ? url.substring(0, url.length - 1) : url;
            int slash = u.last_index_of_char('/');
            int scheme = u.index_of("://");
            if (slash <= scheme + 3) return null;
            return u.substring(0, slash + 1);
        }

        private async void mkcol(string url, int depth, Cancellable? cancellable) throws Error {
            var reply = yield transport.send("MKCOL", url, null, null, null, cancellable);
            if (reply.ok || reply.status == 405 || reply.status == 301) return;
            if (reply.status == 409 && depth < 16) {
                string? up = parent_url(url);
                if (up != null) {
                    yield mkcol(up, depth + 1, cancellable);
                    reply = yield transport.send("MKCOL", url, null, null, null, cancellable);
                    if (reply.ok || reply.status == 405) return;
                }
            }
            throw new IOError.FAILED(_("The server answered %u when creating a folder").printf(reply.status));
        }

        public async string put(string rel, Bytes data, bool replace, Cancellable? cancellable) throws Error {
            yield ensure_parents(rel, cancellable);
            HashTable<string, string>? headers = null;
            if (!replace) {
                headers = new HashTable<string, string>(str_hash, str_equal);
                headers["If-None-Match"] = "*";
            }
            var reply = yield transport.send("PUT", url_for(rel), headers, data, "application/octet-stream", cancellable);
            if (reply.status == 412) throw new IOError.EXISTS(_("%s already exists on the server").printf(rel));
            if (!reply.ok) throw new IOError.FAILED(_("The server answered %u when saving %s").printf(reply.status, rel));
            return clean_etag(reply.etag);
        }

        public async void delete(string rel, Cancellable? cancellable) throws Error {
            var reply = yield transport.send("DELETE", url_for(rel), null, null, null, cancellable);
            if (!reply.ok && reply.status != 404) throw new IOError.FAILED(_("The server answered %u when deleting %s").printf(reply.status, rel));
        }
    }
}

namespace Singularity.Apps.Photos {

    namespace SyncSettings {

        public string path() {
            return Path.build_filename(Environment.get_user_config_dir(), "singularity-photos", "webdav.ini");
        }

        public string get(string key) {
            var kf = new KeyFile();
            try {
                kf.load_from_file(path(), KeyFileFlags.NONE);
                return kf.get_string("webdav", key);
            } catch (Error e) {
                return "";
            }
        }

        public void set(string key, string value) {
            var kf = new KeyFile();
            try {
                kf.load_from_file(path(), KeyFileFlags.NONE);
            } catch (Error e) {
            }
            kf.set_string("webdav", key, value);
            try {
                DirUtils.create_with_parents(Path.get_dirname(path()), 0700);
                kf.save_to_file(path());
            } catch (Error e) {
            }
        }
    }
}
