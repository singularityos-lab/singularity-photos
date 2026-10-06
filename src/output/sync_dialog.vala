using Gtk;
using Singularity.Widgets;
using Singularity.Accounts;

namespace Singularity.Apps.Photos {

    public class SyncDialog : AppDialog {
        private File library;
        private Gee.ArrayList<Account> accounts = new Gee.ArrayList<Account>();
        private IndexChoiceRow target_dd;
        private ActionRow folder_row;
        private SwitchRow originals_row;
        private SwitchRow catalog_row;
        private Label result;
        private Button sync_button;
        private Button restore_button;
        private string folder = "";
        private EntryRow url_row;
        private EntryRow user_row;
        private PasswordEntry password_entry;
        private ActionRow password_row;
        private bool running = false;

        public SyncDialog(Gtk.Window parent, File library) {
            base(parent.application, true, false);
            this.library = library;
            transient_for = parent;
            set_title(_("Sync Photos"));
            set_default_size(500, 460);
            foreach (var a in Manager.get_default().get_accounts_for(Capability.PHOTOS)) {
                if (PhotoSource.api_of(a) == "nextcloud") accounts.add(a);
            }
            build();
        }

        private void build() {
            var box = new Box(Gtk.Orientation.VERTICAL, 12);
            box.margin_start = box.margin_end = 18;
            box.margin_top = 6;
            box.vexpand = true;
            var group = new PreferencesGroup(_("Sync With"), _("Edits travel as sidecar files; your folders stay the source of truth"));
            string[] names = {};
            foreach (var a in accounts) names += a.display_name;
            names += _("A Folder");
            names += _("A WebDAV Server");
            group.add_row(OutputRows.choice(_("Destination"), names, 0, out target_dd));
            folder_row = new ActionRow(_("Folder"), _("No folder chosen"));
            var choose = new Button.with_label(_("Choose…"));
            choose.valign = Align.CENTER;
            choose.clicked.connect(() => choose_folder());
            folder_row.add_suffix(choose);
            group.add_row(folder_row);
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
            password_entry.valign = Align.CENTER;
            password_entry.hexpand = true;
            password_row.add_suffix(password_entry);
            group.add_row(password_row);
            url_row.notify["text"].connect(() => update());
            box.append(group);
            var what = new PreferencesGroup(_("Content"));
            what.add_row(new ActionRow(_("Edits and Metadata"), library.get_path()));
            originals_row = new SwitchRow(_("Original Files"), _("Copy photos that are missing on either side"));
            what.add_row(originals_row);
            catalog_row = new SwitchRow(_("Catalog Backup"), _("Keep a copy of this device's catalog"), true);
            what.add_row(catalog_row);
            box.append(what);
            result = new Label("");
            result.wrap = true;
            result.xalign = 0;
            result.margin_start = 12;
            result.add_css_class("dim-label");
            box.append(result);
            content_box.append(box);
            target_dd.notify["selected-index"].connect(() => update());
            var bar = new Box(Gtk.Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 18;
            bar.margin_bottom = 16;
            bar.margin_top = 8;
            restore_button = new Button.with_label(_("Restore Catalog…"));
            restore_button.clicked.connect(() => choose_backup.begin());
            bar.append(restore_button);
            var spacer = new Box(Gtk.Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            bar.append(spacer);
            bar.append(add_cancel_button(_("Close")));
            sync_button = new Button.with_label(_("Sync Now"));
            sync_button.add_css_class("suggested-action");
            sync_button.clicked.connect(() => run_sync.begin());
            bar.append(sync_button);
            content_box.append(bar);
            update();
        }

        private bool folder_mode() {
            return (int) target_dd.selected_index == accounts.size;
        }

        private bool dav_mode() {
            return (int) target_dd.selected_index == accounts.size + 1;
        }

        private SyncRemote make_remote() {
            if (folder_mode()) return new FolderRemote(folder);
            if (dav_mode()) {
                SyncSettings.set("url", url_row.text.strip());
                SyncSettings.set("user", user_row.text.strip());
                string url = url_row.text.strip();
                return new DavRemote(new WebDav(url, new BasicDavTransport(user_row.text.strip(), password_entry.text)), "webdav:" + url + "|" + user_row.text.strip());
            }
            return DavRemote.for_account(accounts[(int) target_dd.selected_index]);
        }

        private void update() {
            folder_row.visible = folder_mode();
            url_row.visible = dav_mode();
            user_row.visible = dav_mode();
            password_row.visible = dav_mode();
            bool ready = folder_mode() ? folder != "" : (dav_mode() ? url_row.text.strip().has_prefix("http") : true);
            sync_button.sensitive = !running && ready;
            restore_button.sensitive = !running && ready;
        }

        private void choose_folder() {
            var chooser = new FileDialog();
            chooser.title = _("Sync Folder");
            chooser.select_folder.begin(this, null, (o, res) => {
                try {
                    var f = chooser.select_folder.end(res);
                    if (f == null) return;
                    folder = f.get_path();
                    folder_row.subtitle = folder;
                    update();
                } catch (Error e) {
                }
            });
        }

        private async void choose_backup() {
            var engine = new SyncEngine(library.get_path(), make_remote());
            Gee.List<string> devices;
            try {
                devices = yield engine.catalog_backups(null);
            } catch (Error e) {
                result.label = _("Could not list the backups: %s").printf(e.message);
                return;
            }
            if (devices.size == 0) {
                result.label = _("There is no catalog backup at this destination yet");
                return;
            }
            var dlg = new AppDialog(application, true, false);
            dlg.transient_for = this;
            dlg.set_title(_("Restore Catalog"));
            dlg.set_default_size(420, 260);
            var group = new PreferencesGroup(null, _("The current catalog is kept beside it. Photos uses the restored catalog after a restart."));
            group.margin_start = group.margin_end = 18;
            IndexChoiceRow dd;
            group.add_row(OutputRows.choice(_("From Device"), devices.to_array(), 0, out dd));
            dlg.content_box.append(group);
            var bar = new Box(Gtk.Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 18;
            bar.margin_bottom = 16;
            var spacer = new Box(Gtk.Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            bar.append(spacer);
            bar.append(dlg.add_cancel_button());
            var go = new Button.with_label(_("Restore"));
            go.add_css_class("destructive-action");
            go.clicked.connect(() => {
                string device = devices[((int) dd.selected_index).clamp(0, devices.size - 1)];
                dlg.close_dialog();
                engine.restore_catalog.begin(device, Catalog.default_path(), null, (o, res) => {
                    try {
                        engine.restore_catalog.end(res);
                        result.label = _("Catalog restored from %s. Restart Photos to use it.").printf(device);
                    } catch (Error e) {
                        result.label = _("Could not restore the catalog: %s").printf(e.message);
                    }
                });
            });
            bar.append(go);
            dlg.content_box.append(bar);
            dlg.open_dialog();
        }

        private async void run_sync() {
            running = true;
            update();
            result.label = _("Syncing…");
            var remote = make_remote();
            var engine = new SyncEngine(library.get_path(), remote);
            engine.originals = originals_row.active;
            engine.catalog_snapshot = catalog_row.active;
            try {
                var r = yield engine.sync(null);
                string text = _("%d sent, %d received, %d conflicts kept as copies").printf(r.pushed, r.pulled, r.conflicts);
                if (r.errors.size > 0) text += "\n" + r.errors[0];
                result.label = text;
            } catch (Error e) {
                result.label = _("Sync failed: %s").printf(e.message);
            }
            running = false;
            update();
        }
    }
}
