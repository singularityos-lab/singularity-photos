namespace Singularity.Apps.Photos {

    public interface PublishTarget : Object {
        public abstract string id { owned get; }
        public abstract string title { owned get; }
        public abstract bool can_replace { get; }
        public abstract async string put(string name, File file, bool replace, Cancellable? cancellable) throws Error;
        public abstract async void remove(string name, Cancellable? cancellable) throws Error;
    }

    public class DavPublishTarget : Object, PublishTarget {
        private WebDav dav;
        private string ident;
        private string label;

        public DavPublishTarget(WebDav dav, string ident, string label) {
            this.dav = dav;
            this.ident = ident;
            this.label = label;
        }

        public static DavPublishTarget for_account(Singularity.Accounts.Account account, string collection) {
            string folder = "Singularity Photos/Published/" + PublishSession.safe_name(collection);
            return new DavPublishTarget(WebDav.for_account(account, folder), "dav:" + account.id + ":" + collection, account.display_name);
        }

        public string id {
            owned get { return ident; }
        }

        public string title {
            owned get { return label; }
        }

        public bool can_replace {
            get { return true; }
        }

        public async string put(string name, File file, bool replace, Cancellable? cancellable) throws Error {
            uint8[] data;
            yield file.load_contents_async(cancellable, out data, null);
            yield dav.put(name, new Bytes.take((owned) data), replace, cancellable);
            return name;
        }

        public async void remove(string name, Cancellable? cancellable) throws Error {
            yield dav.delete(name, cancellable);
        }
    }

    public class PublishReport : Object {
        public int published = 0;
        public int replaced = 0;
        public int removed = 0;
        public int unchanged = 0;
        public Gee.ArrayList<string> errors = new Gee.ArrayList<string>();
    }

    public delegate void PublishProgress(int done, int total, string current);

    public class PublishSession : Object {
        public PublishTarget target { get; construct; }
        public ExportSettings settings { get; construct; }
        public PublishLedger ledger { get; private set; }
        public bool remove_missing { get; set; default = false; }

        public PublishSession(PublishTarget target, ExportSettings settings) {
            Object(target: target, settings: settings);
            ledger = new PublishLedger(target.id);
        }

        public static string safe_name(string name) {
            string s = name.strip().replace("/", "_").replace("\\", "_");
            return s == "" || s == "." || s == ".." ? _("Photos") : s;
        }

        private string unique_name(File file, string ext, Gee.Set<string> taken) {
            string name = file.get_basename() ?? "photo";
            int dot = name.last_index_of_char('.');
            string stem = dot > 0 ? name.substring(0, dot) : name;
            string candidate = stem + "." + ext;
            for (int n = 2; candidate in taken; n++) candidate = "%s-%d.%s".printf(stem, n, ext);
            return candidate;
        }

        public async PublishReport run(File[] files, Cancellable? cancellable = null, PublishProgress? progress = null) throws Error {
            var report = new PublishReport();
            var export_settings = settings.copy();
            string staging = Path.build_filename(Environment.get_user_cache_dir(), "singularity-photos", "publish", Uuid.string_random());
            export_settings.destination = "folder";
            export_settings.folder = staging;
            export_settings.subfolder = "";
            export_settings.naming = "{name}";
            export_settings.conflict = "overwrite";
            var taken = new Gee.HashSet<string>();
            foreach (var path in ledger.files()) {
                string? r = ledger.remote_name(File.new_for_path(path));
                if (r != null && r != "") taken.add(r);
            }
            var wanted = new Gee.HashSet<string>();
            int done = 0;
            foreach (var f in files) {
                wanted.add(f.get_path() ?? f.get_uri());
                if (cancellable != null && cancellable.is_cancelled()) break;
                if (progress != null) progress(done, files.length, f.get_basename());
                var state = ledger.state(f, settings);
                if (state == PublishState.PUBLISHED) {
                    report.unchanged++;
                    done++;
                    continue;
                }
                ExportResult? result = null;
                SourceFunc resume = run.callback;
                new Thread<void>("photos-publish", () => {
                    result = ExportEngine.export_one(f, export_settings, done + 1, files.length);
                    Idle.add((owned) resume);
                });
                yield;
                if (!result.ok) {
                    report.errors.add("%s: %s".printf(f.get_basename(), result.error));
                    done++;
                    continue;
                }
                string? previous = ledger.remote_name(f);
                bool replace = state == PublishState.CHANGED && previous != null && previous != "" && target.can_replace;
                string name = replace ? previous : unique_name(f, settings.extension(), taken);
                try {
                    string remote = yield target.put(name, result.target, replace, cancellable);
                    taken.add(remote);
                    ledger.record(f, settings, remote);
                    if (replace) report.replaced++;
                    else report.published++;
                } catch (Error e) {
                    report.errors.add("%s: %s".printf(f.get_basename(), e.message));
                }
                FileUtils.remove(result.target.get_path());
                done++;
            }
            DirUtils.remove(staging);
            if (remove_missing) {
                foreach (var path in ledger.files()) {
                    if (path in wanted) continue;
                    var gone = File.new_for_path(path);
                    string? remote = ledger.remote_name(gone);
                    try {
                        if (remote != null && remote != "") yield target.remove(remote, cancellable);
                        ledger.forget(gone);
                        report.removed++;
                    } catch (Error e) {
                        report.errors.add("%s: %s".printf(remote ?? path, e.message));
                    }
                }
            }
            ledger.save();
            if (progress != null) progress(files.length, files.length, "");
            return report;
        }
    }
}
