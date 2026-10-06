using Gtk;
using Singularity.Widgets;
using Singularity.Accounts;

namespace Singularity.Apps.Photos {

    public class SourcePublishTarget : Object, PublishTarget {
        private PhotoSource source;
        private string collection;

        public SourcePublishTarget(PhotoSource source, string collection) {
            this.source = source;
            this.collection = collection;
        }

        public string id {
            owned get { return "source:" + source.account.id + ":" + collection; }
        }

        public string title {
            owned get { return "%s (%s)".printf(source.account.display_name, source.title); }
        }

        public bool can_replace {
            get { return source.can_replace; }
        }

        public async string put(string name, File file, bool replace, Cancellable? cancellable) throws Error {
            if (source.can_replace) return yield source.upload_named(file, name, replace, cancellable);
            var named = file.get_parent().get_child(name);
            if (!named.equal(file)) file.move(named, FileCopyFlags.OVERWRITE, cancellable);
            Error? failure = null;
            try {
                yield source.upload(named, cancellable);
            } catch (Error e) {
                failure = e;
            }
            if (!named.equal(file)) named.move(file, FileCopyFlags.OVERWRITE, null);
            if (failure != null) throw failure;
            return name;
        }

        public async void remove(string name, Cancellable? cancellable) throws Error {
        }
    }

    public class PublishDialog : AppDialog {
        private File[] files;
        private Gee.ArrayList<Account> dav_accounts = new Gee.ArrayList<Account>();
        private Gee.ArrayList<PhotoSource> sources = new Gee.ArrayList<PhotoSource>();
        private Gee.List<ExportPreset> presets;
        private IndexChoiceRow account_dd;
        private IndexChoiceRow preset_dd;
        private EntryRow collection_row;
        private SwitchRow remove_row;
        private EntryRow url_row;
        private EntryRow user_row;
        private ActionRow password_row;
        private PasswordEntry password_entry;
        private Label state_label;
        private ProgressBar progress;
        private Button publish_button;
        private Cancellable? running = null;

        public PublishDialog(Gtk.Window parent, File[] files, string collection = "") {
            base(parent.application, true, false);
            this.files = files;
            transient_for = parent;
            set_title(_("Publish Photos"));
            set_default_size(500, 560);
            presets = ExportPresets.all();
            foreach (var account in Manager.get_default().get_accounts_for(Capability.PHOTOS)) {
                if (PhotoSource.api_of(account) == "nextcloud") {
                    dav_accounts.add(account);
                    continue;
                }
                var s = PhotoSource.for_account(account);
                if (s != null) sources.add(s);
            }
            build(collection);
        }

        private int server_index() {
            return dav_accounts.size + sources.size;
        }

        private void build(string collection) {
            var box = new Box(Gtk.Orientation.VERTICAL, 12);
            box.margin_start = box.margin_end = 18;
            box.margin_top = 6;
            box.vexpand = true;
            var group = new PreferencesGroup(_("Service"));
            string[] names = {};
            foreach (var a in dav_accounts) names += "%s (Nextcloud)".printf(a.display_name);
            foreach (var s in sources) names += "%s (%s)".printf(s.account.display_name, s.title);
            names += _("A WebDAV Server");
            group.add_row(OutputRows.choice(_("Publish To"), names, 0, out account_dd));
            url_row = new EntryRow(_("Server Address"));
            url_row.text = SyncSettings.get("url");
            group.add_row(url_row);
            user_row = new EntryRow(_("User Name"));
            user_row.text = SyncSettings.get("user");
            group.add_row(user_row);
            password_row = new ActionRow(_("Password"));
            password_row.activatable = false;
            password_entry = new PasswordEntry();
            password_entry.show_peek_icon = true;
            password_entry.hexpand = true;
            password_entry.valign = Align.CENTER;
            password_row.add_suffix(password_entry);
            group.add_row(password_row);
            box.append(group);
            var content = new PreferencesGroup(_("Collection"));
            collection_row = new EntryRow(_("Name"));
            collection_row.text = collection != "" ? collection : _("Photos");
            content.add_row(collection_row);
            string[] preset_names = {};
            int web = 0;
            for (int i = 0; i < presets.size; i++) {
                preset_names += presets[i].settings.name;
                if (presets[i].id == "web") web = i;
            }
            content.add_row(OutputRows.choice(_("Export With"), preset_names, web, out preset_dd));
            remove_row = new SwitchRow(_("Remove Photos No Longer in the Collection"));
            content.add_row(remove_row);
            box.append(content);
            state_label = new Label("");
            state_label.xalign = 0;
            state_label.wrap = true;
            state_label.add_css_class("dim-label");
            state_label.margin_start = 12;
            box.append(state_label);
            content_box.append(box);
            progress = new ProgressBar();
            progress.margin_start = progress.margin_end = 18;
            progress.visible = false;
            progress.show_text = true;
            content_box.append(progress);
            var bar = new Box(Gtk.Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 18;
            bar.margin_bottom = 16;
            bar.margin_top = 8;
            var spacer = new Box(Gtk.Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            bar.append(spacer);
            var cancel = add_cancel_button();
            cancel.clicked.connect(() => { if (running != null) running.cancel(); });
            bar.append(cancel);
            publish_button = new Button.with_label(_("Publish"));
            publish_button.add_css_class("suggested-action");
            publish_button.clicked.connect(() => publish.begin());
            bar.append(publish_button);
            content_box.append(bar);
            account_dd.notify["selected-index"].connect(() => update_state());
            preset_dd.notify["selected-index"].connect(() => update_state());
            collection_row.notify["text"].connect(() => update_state());
            url_row.notify["text"].connect(() => update_state());
            user_row.notify["text"].connect(() => update_state());
            update_state();
        }

        private ExportSettings settings() {
            return presets[((int) preset_dd.selected_index).clamp(0, presets.size - 1)].settings.copy();
        }

        private string collection() {
            return PublishSession.safe_name(collection_row.text);
        }

        private PublishTarget? target() {
            int i = (int) account_dd.selected_index;
            if (i < dav_accounts.size) return DavPublishTarget.for_account(dav_accounts[i], collection());
            if (i < server_index()) return new SourcePublishTarget(sources[i - dav_accounts.size], collection());
            string url = url_row.text.strip();
            if (!url.has_prefix("http")) return null;
            if (!url.has_suffix("/")) url += "/";
            var dav = new WebDav(url + "Singularity Photos/Published/" + WebDav.escape_path(collection()), new BasicDavTransport(user_row.text.strip(), password_entry.text));
            return new DavPublishTarget(dav, "webdav:" + url + "|" + user_row.text.strip() + ":" + collection(), url);
        }

        private void update_state() {
            bool server = (int) account_dd.selected_index == server_index();
            url_row.visible = server;
            user_row.visible = server;
            password_row.visible = server;
            var t = target();
            if (t == null) {
                state_label.label = _("Enter the address of the WebDAV server");
                publish_button.sensitive = false;
                return;
            }
            remove_row.visible = t.can_replace;
            var l = new PublishLedger(t.id);
            var s = settings();
            int fresh = 0, changed = 0, done = 0;
            foreach (var f in files) {
                switch (l.state(f, s)) {
                    case PublishState.NEW: fresh++; break;
                    case PublishState.CHANGED: changed++; break;
                    default: done++; break;
                }
            }
            string text = _("%d new, %d changed since the last publish, %d already published").printf(fresh, changed, done);
            if (!t.can_replace && changed > 0) text += "\n" + _("This service cannot replace a photo, so changed photos are added as new ones");
            state_label.label = text;
            publish_button.sensitive = running == null && (fresh + changed > 0 || (remove_row.active && l.count() > done));
        }

        private async void publish() {
            if (running != null) return;
            var t = target();
            if (t == null) return;
            if ((int) account_dd.selected_index == server_index()) {
                SyncSettings.set("url", url_row.text.strip());
                SyncSettings.set("user", user_row.text.strip());
            }
            running = new Cancellable();
            var cancellable = running;
            var session = new PublishSession(t, settings());
            session.remove_missing = remove_row.visible && remove_row.active;
            publish_button.sensitive = false;
            progress.visible = true;
            PublishReport? report = null;
            string? failure = null;
            try {
                report = yield session.run(files, cancellable, (done, total, current) => {
                    progress.fraction = total > 0 ? (double) done / total : 1;
                    progress.text = current;
                });
            } catch (Error e) {
                failure = e.message;
            }
            running = null;
            progress.visible = false;
            if (report != null && report.errors.size == 0 && !cancellable.is_cancelled()) {
                OutputRows.toast(transient_for, _("Published %d, replaced %d, removed %d on %s").printf(report.published, report.replaced, report.removed, t.title));
                close_dialog();
                return;
            }
            if (report != null) {
                state_label.label = _("%d published, %d replaced, %d failed. %s").printf(report.published, report.replaced, report.errors.size, report.errors.size > 0 ? report.errors[0] : "");
            } else {
                state_label.label = _("Publishing failed: %s").printf(failure ?? "");
            }
            publish_button.sensitive = true;
        }
    }
}
