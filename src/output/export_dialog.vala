using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Photos {

    public class OutputRows : Object {

        public static DropDown dropdown(string[] labels, int active) {
            var dd = new DropDown.from_strings(labels);
            dd.selected = (uint) active.clamp(0, labels.length - 1);
            dd.valign = Align.CENTER;
            return dd;
        }

        public static int index_of(string[] ids, string id) {
            for (int i = 0; i < ids.length; i++) if (ids[i] == id) return i;
            return 0;
        }

        public static IndexChoiceRow choice(string title, string[] labels, int active, out IndexChoiceRow dd) {
            dd = new IndexChoiceRow(title, labels, (uint) active.clamp(0, labels.length - 1));
            return dd;
        }

        public static void toast(Gtk.Window? parent, string text) {
            var win = parent as Singularity.Widgets.Window;
            if (win != null) win.add_toast(new Toast(text));
        }
    }

    public class ExportDialog : AppDialog {
        private File[] files;
        private ExportSettings settings;
        private Gee.List<ExportPreset> presets;
        private bool syncing = false;
        private Cancellable? running = null;

        private IndexChoiceRow preset_dd;
        private IndexChoiceRow format_dd;
        private SpinRow quality_row;
        private ActionRow depth_row;
        private IndexChoiceRow depth_dd;
        private SwitchRow lossless_row;
        private IndexChoiceRow space_dd;
        private ActionRow space_row;
        private ActionRow icc_row;
        private IndexChoiceRow resize_dd;
        private SpinRow size_row;
        private SpinRow height_row;
        private SpinRow mp_row;
        private SpinRow percent_row;
        private SwitchRow enlarge_row;
        private SpinRow ppi_row;
        private IndexChoiceRow sharpen_dd;
        private ActionRow sharpen_amount_row;
        private IndexChoiceRow sharpen_amount_dd;
        private IndexChoiceRow metadata_dd;
        private SwitchRow watermark_row;
        private ActionRow wm_kind_row;
        private IndexChoiceRow wm_kind_dd;
        private EntryRow wm_text_row;
        private ActionRow wm_image_row;
        private ActionRow wm_position_row;
        private IndexChoiceRow wm_position_dd;
        private SpinRow wm_opacity_row;
        private SpinRow wm_scale_row;
        private EntryRow naming_row;
        private SpinRow start_row;
        private IndexChoiceRow dest_dd;
        private ActionRow folder_row;
        private EntryRow subfolder_row;
        private IndexChoiceRow conflict_dd;
        private ProgressBar progress;
        private Button export_button;
        private Button cancel_button;
        private Label summary;

        private const string[] SPACE_IDS = { "srgb", "display-p3", "adobe-rgb", "prophoto", "rec2020", "custom" };
        private const string[] LINEAR_SPACE_IDS = { "linear-srgb", "linear-rec2020" };
        private const string[] RESIZE_IDS = { "none", "long", "short", "megapixels", "percent", "dimensions" };
        private const string[] SHARPEN_IDS = { "none", "screen", "matte", "glossy" };
        private const string[] AMOUNT_IDS = { "low", "standard", "high" };
        private const string[] METADATA_IDS = { "all", "copyright", "all-but-camera-location", "none" };
        private const string[] POSITION_IDS = { "top-left", "top", "top-right", "left", "center", "right", "bottom-left", "bottom", "bottom-right" };
        private string[] dest_ids = { "same", "folder" };
        private string[] filter_ids = { "" };
        private ActionRow? filter_row = null;
        private IndexChoiceRow? filter_dd = null;
        private SpinRow? filter_amount_row = null;
        private const string[] CONFLICT_IDS = { "unique", "overwrite", "skip" };

        private string[] format_ids = {};

        public ExportDialog(Gtk.Window parent, File[] files) {
            base(parent.application, true, false);
            this.files = files;
            transient_for = parent;
            set_title(files.length == 1 ? _("Export Photo") : _("Export %d Photos").printf(files.length));
            set_default_size(560, 760);
            presets = ExportPresets.all();
            settings = presets[0].settings.copy();
            build();
            load_settings();
        }

        private SpinRow spin(PreferencesGroup group, string title, double min, double max, double step, double value) {
            var row = new SpinRow(title, null, min, max, step, value);
            row.spin_btn.value_changed.connect(() => { if (!syncing) read_settings(); });
            group.add_row(row);
            return row;
        }

        private void on_change(IndexChoiceRow dd) {
            dd.notify["selected-index"].connect(() => { if (!syncing) read_settings(); });
        }

        private void build() {
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            var box = new Box(Gtk.Orientation.VERTICAL, 12);
            box.margin_start = box.margin_end = 18;
            box.margin_top = 6;
            box.margin_bottom = 12;
            scroll.child = box;

            var preset_group = new PreferencesGroup(_("Preset"));
            string[] preset_labels = {};
            foreach (var p in presets) preset_labels += p.settings.name;
            var preset_row = OutputRows.choice(_("Start From"), preset_labels, 0, out preset_dd);
            var save_preset = new Button.from_icon_name("document-save-symbolic");
            save_preset.tooltip_text = _("Save as Preset");
            save_preset.add_css_class("flat");
            save_preset.valign = Align.CENTER;
            save_preset.clicked.connect(() => ask_preset_name());
            preset_row.add_suffix(save_preset);
            preset_dd.notify["selected-index"].connect(() => {
                if (syncing) return;
                uint i = preset_dd.selected_index;
                if (i < presets.size) {
                    settings = presets[(int) i].settings.copy();
                    load_settings();
                }
            });
            preset_group.add_row(preset_row);
            box.append(preset_group);

            var file_group = new PreferencesGroup(_("File Settings"));
            string[] format_labels = {};
            foreach (unowned ExportFormat f in ExportFormat.all()) {
                if (!f.available()) continue;
                format_ids += f.id;
                format_labels += f.label;
            }
            file_group.add_row(OutputRows.choice(_("Format"), format_labels, 0, out format_dd));
            on_change(format_dd);
            quality_row = spin(file_group, _("Quality"), 1, 100, 1, 90);
            depth_row = OutputRows.choice(_("Bit Depth"), { "8" }, 0, out depth_dd);
            on_change(depth_dd);
            file_group.add_row(depth_row);
            lossless_row = new SwitchRow(_("Lossless"));
            lossless_row.switch_btn.notify["active"].connect(() => { if (!syncing) read_settings(); });
            file_group.add_row(lossless_row);
            space_row = OutputRows.choice(_("Color Space"), space_labels(false), 0, out space_dd);
            file_group.add_row(space_row);
            on_change(space_dd);
            icc_row = new ActionRow(_("Profile"), _("Choose an ICC profile"));
            var icc_button = new Button.with_label(_("Choose…"));
            icc_button.valign = Align.CENTER;
            icc_button.clicked.connect(() => choose_icc());
            icc_row.add_suffix(icc_button);
            file_group.add_row(icc_row);
            box.append(file_group);

            var size_group = new PreferencesGroup(_("Image Sizing"));
            size_group.add_row(OutputRows.choice(_("Resize"), { _("Original Size"), _("Long Edge"), _("Short Edge"), _("Megapixels"), _("Percentage"), _("Width and Height") }, 0, out resize_dd));
            on_change(resize_dd);
            size_row = spin(size_group, _("Pixels"), 16, 60000, 1, 2048);
            height_row = spin(size_group, _("Height"), 16, 60000, 1, 2048);
            mp_row = spin(size_group, _("Megapixels"), 0.1, 400, 0.1, 12);
            mp_row.spin_btn.digits = 1;
            percent_row = spin(size_group, _("Percentage"), 1, 1000, 1, 50);
            enlarge_row = new SwitchRow(_("Do Not Enlarge"), null, true);
            enlarge_row.switch_btn.notify["active"].connect(() => { if (!syncing) read_settings(); });
            size_group.add_row(enlarge_row);
            ppi_row = spin(size_group, _("Resolution (ppi)"), 36, 2400, 1, 300);
            box.append(size_group);

            var sharpen_group = new PreferencesGroup(_("Output Sharpening"));
            sharpen_group.add_row(OutputRows.choice(_("Sharpen For"), { _("None"), _("Screen"), _("Matte Paper"), _("Glossy Paper") }, 0, out sharpen_dd));
            on_change(sharpen_dd);
            sharpen_amount_row = OutputRows.choice(_("Amount"), { _("Low"), _("Standard"), _("High") }, 1, out sharpen_amount_dd);
            on_change(sharpen_amount_dd);
            sharpen_group.add_row(sharpen_amount_row);
            box.append(sharpen_group);

            var meta_group = new PreferencesGroup(_("Metadata"));
            meta_group.add_row(OutputRows.choice(_("Include"), { _("All Metadata"), _("Copyright Only"), _("All Except Camera and Location"), _("None") }, 0, out metadata_dd));
            on_change(metadata_dd);
            box.append(meta_group);

            var wm_group = new PreferencesGroup(_("Watermark"));
            watermark_row = new SwitchRow(_("Add Watermark"));
            watermark_row.switch_btn.notify["active"].connect(() => { if (!syncing) read_settings(); });
            wm_group.add_row(watermark_row);
            wm_kind_row = OutputRows.choice(_("Type"), { _("Text"), _("Image") }, 0, out wm_kind_dd);
            on_change(wm_kind_dd);
            wm_group.add_row(wm_kind_row);
            wm_text_row = new EntryRow(_("Text"));
            wm_text_row.notify["text"].connect(() => { if (!syncing) read_settings(); });
            wm_group.add_row(wm_text_row);
            wm_image_row = new ActionRow(_("Image"), _("No image chosen"));
            var wm_button = new Button.with_label(_("Choose…"));
            wm_button.valign = Align.CENTER;
            wm_button.clicked.connect(() => choose_watermark());
            wm_image_row.add_suffix(wm_button);
            wm_group.add_row(wm_image_row);
            wm_position_row = OutputRows.choice(_("Position"), { _("Top Left"), _("Top"), _("Top Right"), _("Left"), _("Center"), _("Right"), _("Bottom Left"), _("Bottom"), _("Bottom Right") }, 8, out wm_position_dd);
            on_change(wm_position_dd);
            wm_group.add_row(wm_position_row);
            wm_opacity_row = spin(wm_group, _("Opacity (%)"), 5, 100, 5, 60);
            wm_scale_row = spin(wm_group, _("Size (% of width)"), 2, 100, 1, 25);
            box.append(wm_group);

            var plugin_filters = PhotosPluginHost.get_default().filters();
            if (plugin_filters.size > 0) {
                var fx_group = new PreferencesGroup(_("Effect"));
                string[] fx_labels = { _("None") };
                foreach (var f in plugin_filters) {
                    filter_ids += f.id;
                    fx_labels += f.title;
                }
                IndexChoiceRow dd;
                filter_row = OutputRows.choice(_("Filter"), fx_labels, 0, out dd);
                filter_dd = dd;
                on_change(dd);
                fx_group.add_row(filter_row);
                filter_amount_row = spin(fx_group, _("Amount (%)"), 0, 100, 5, 100);
                box.append(fx_group);
            }

            var name_group = new PreferencesGroup(_("File Naming"), _("Use {name}, {seq}, {date}, {time}, {year}, {month}, {day}, {camera}, {title} and {rating}"));
            naming_row = new EntryRow(_("Template"));
            naming_row.notify["text"].connect(() => { if (!syncing) read_settings(); });
            name_group.add_row(naming_row);
            start_row = spin(name_group, _("Start Number"), 0, 999999, 1, 1);
            box.append(name_group);

            var dest_group = new PreferencesGroup(_("Location"));
            string[] dest_labels = { _("Same Folder as the Original"), _("Chosen Folder") };
            foreach (var d in PhotosPluginHost.get_default().export_destinations()) {
                dest_ids += "plugin:" + d.id;
                dest_labels += d.title;
            }
            dest_group.add_row(OutputRows.choice(_("Export To"), dest_labels, 0, out dest_dd));
            on_change(dest_dd);
            folder_row = new ActionRow(_("Folder"), "");
            var folder_button = new Button.with_label(_("Choose…"));
            folder_button.valign = Align.CENTER;
            folder_button.clicked.connect(() => choose_folder());
            folder_row.add_suffix(folder_button);
            dest_group.add_row(folder_row);
            subfolder_row = new EntryRow(_("Subfolder"));
            subfolder_row.notify["text"].connect(() => { if (!syncing) read_settings(); });
            dest_group.add_row(subfolder_row);
            dest_group.add_row(OutputRows.choice(_("Existing Files"), { _("Choose a New Name"), _("Overwrite"), _("Skip") }, 0, out conflict_dd));
            on_change(conflict_dd);
            box.append(dest_group);

            content_box.append(scroll);

            summary = new Label("");
            summary.wrap = true;
            summary.xalign = 0;
            summary.margin_start = summary.margin_end = 18;
            summary.visible = false;
            content_box.append(summary);
            progress = new ProgressBar();
            progress.margin_start = progress.margin_end = 18;
            progress.margin_top = 6;
            progress.visible = false;
            content_box.append(progress);

            var bar = new Box(Gtk.Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 18;
            bar.margin_bottom = 16;
            bar.margin_top = 8;
            var spacer = new Box(Gtk.Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            bar.append(spacer);
            cancel_button = add_cancel_button();
            cancel_button.clicked.connect(() => { if (running != null) running.cancel(); });
            bar.append(cancel_button);
            export_button = new Button.with_label(_("Export"));
            export_button.add_css_class("suggested-action");
            export_button.clicked.connect(() => start_export());
            bar.append(export_button);
            content_box.append(bar);
        }

        private string[] space_labels(bool linear) {
            string[] labels = {};
            if (linear) {
                foreach (var id in LINEAR_SPACE_IDS) labels += Singularity.Imaging.IccProfile.builtin_label(id);
                return labels;
            }
            foreach (var id in SPACE_IDS) labels += id == "custom" ? _("Custom Profile") : Singularity.Imaging.IccProfile.builtin_label(id);
            return labels;
        }

        private void set_model(IndexChoiceRow dd, string[] labels, int active) {
            dd.set_labels(labels);
            dd.selected_index = (uint) active.clamp(0, labels.length - 1);
        }

        private void load_settings() {
            syncing = true;
            format_dd.selected_index = (uint) OutputRows.index_of(format_ids, settings.format);
            quality_row.value = settings.quality;
            lossless_row.active = settings.lossless;
            resize_dd.selected_index = (uint) OutputRows.index_of(RESIZE_IDS, settings.resize);
            size_row.value = settings.resize_width;
            height_row.value = settings.resize_height;
            mp_row.value = settings.megapixels;
            percent_row.value = settings.percent;
            enlarge_row.active = settings.no_enlarge;
            ppi_row.value = settings.resolution;
            sharpen_dd.selected_index = (uint) OutputRows.index_of(SHARPEN_IDS, settings.sharpen);
            sharpen_amount_dd.selected_index = (uint) OutputRows.index_of(AMOUNT_IDS, settings.sharpen_amount);
            metadata_dd.selected_index = (uint) OutputRows.index_of(METADATA_IDS, settings.metadata);
            watermark_row.active = settings.watermark;
            wm_kind_dd.selected_index = settings.watermark_kind == "image" ? 1 : 0;
            wm_text_row.text = settings.watermark_text;
            wm_image_row.subtitle = settings.watermark_image != "" ? Path.get_basename(settings.watermark_image) : _("No image chosen");
            wm_position_dd.selected_index = (uint) OutputRows.index_of(POSITION_IDS, settings.watermark_position);
            wm_opacity_row.value = Math.round(settings.watermark_opacity * 100);
            wm_scale_row.value = Math.round(settings.watermark_scale * 100);
            naming_row.text = settings.naming;
            start_row.value = settings.sequence_start;
            dest_dd.selected_index = (uint) OutputRows.index_of(dest_ids, settings.plugin_destination != "" ? "plugin:" + settings.plugin_destination : settings.destination);
            if (filter_dd != null) filter_dd.selected_index = (uint) OutputRows.index_of(filter_ids, settings.filter);
            if (filter_amount_row != null) filter_amount_row.value = Math.round(settings.filter_amount * 100);
            folder_row.subtitle = settings.folder != "" ? settings.folder : _("No folder chosen");
            subfolder_row.text = settings.subfolder;
            conflict_dd.selected_index = (uint) OutputRows.index_of(CONFLICT_IDS, settings.conflict);
            refresh_format_rows();
            syncing = false;
            update_visibility();
        }

        private void refresh_format_rows() {
            var f = settings.format_info();
            string[] depth_labels = {};
            int active = 0;
            for (int i = 0; i < f.depths.length; i++) {
                depth_labels += f.depths[i] == 32 ? _("32-bit float") : _("%d-bit").printf(f.depths[i]);
                if (f.depths[i] == settings.effective_depth()) active = i;
            }
            set_model(depth_dd, depth_labels, active);
            if (f.linear) {
                set_model(space_dd, space_labels(true), settings.color_space == "linear-rec2020" || settings.color_space == "rec2020" ? 1 : 0);
            } else {
                set_model(space_dd, space_labels(false), OutputRows.index_of(SPACE_IDS, settings.color_space));
            }
        }

        private void read_settings() {
            string previous = settings.format;
            settings.format = format_ids[(int) format_dd.selected_index.clamp(0, format_ids.length - 1)];
            var f = settings.format_info();
            if (previous != settings.format) {
                syncing = true;
                refresh_format_rows();
                syncing = false;
            }
            settings.quality = (int) quality_row.value;
            int di = (int) depth_dd.selected_index;
            settings.bit_depth = f.depths[di.clamp(0, f.depths.length - 1)];
            settings.lossless = lossless_row.active;
            if (f.linear) settings.color_space = LINEAR_SPACE_IDS[((int) space_dd.selected_index).clamp(0, 1)];
            else settings.color_space = SPACE_IDS[((int) space_dd.selected_index).clamp(0, SPACE_IDS.length - 1)];
            settings.resize = RESIZE_IDS[((int) resize_dd.selected_index).clamp(0, RESIZE_IDS.length - 1)];
            settings.resize_width = (int) size_row.value;
            settings.resize_height = (int) height_row.value;
            settings.megapixels = mp_row.value;
            settings.percent = percent_row.value;
            settings.no_enlarge = enlarge_row.active;
            settings.resolution = (int) ppi_row.value;
            settings.sharpen = SHARPEN_IDS[((int) sharpen_dd.selected_index).clamp(0, 3)];
            settings.sharpen_amount = AMOUNT_IDS[((int) sharpen_amount_dd.selected_index).clamp(0, 2)];
            settings.metadata = METADATA_IDS[((int) metadata_dd.selected_index).clamp(0, 3)];
            settings.watermark = watermark_row.active;
            settings.watermark_kind = wm_kind_dd.selected_index == 1 ? "image" : "text";
            settings.watermark_text = wm_text_row.text;
            settings.watermark_position = POSITION_IDS[((int) wm_position_dd.selected_index).clamp(0, 8)];
            settings.watermark_opacity = wm_opacity_row.value / 100.0;
            settings.watermark_scale = wm_scale_row.value / 100.0;
            settings.naming = naming_row.text;
            settings.sequence_start = (int) start_row.value;
            string dest = dest_ids[((int) dest_dd.selected_index).clamp(0, dest_ids.length - 1)];
            settings.plugin_destination = dest.has_prefix("plugin:") ? dest.substring(7) : "";
            settings.destination = dest.has_prefix("plugin:") ? "same" : dest;
            if (filter_dd != null) settings.filter = filter_ids[((int) filter_dd.selected_index).clamp(0, filter_ids.length - 1)];
            if (filter_amount_row != null) settings.filter_amount = filter_amount_row.value / 100.0;
            settings.subfolder = subfolder_row.text;
            settings.conflict = CONFLICT_IDS[((int) conflict_dd.selected_index).clamp(0, 2)];
            update_visibility();
        }

        private void update_visibility() {
            var f = settings.format_info();
            quality_row.visible = f.has_quality && !settings.lossless;
            lossless_row.visible = f.can_lossless;
            depth_row.visible = f.depths.length > 1;
            space_row.visible = settings.format != "dng";
            icc_row.visible = settings.color_space == "custom";
            if (settings.icc_path != "") icc_row.subtitle = Path.get_basename(settings.icc_path);
            string r = settings.resize;
            size_row.visible = r == "long" || r == "short" || r == "dimensions";
            size_row.title = r == "dimensions" ? _("Width") : _("Pixels");
            height_row.visible = r == "dimensions";
            mp_row.visible = r == "megapixels";
            percent_row.visible = r == "percent";
            enlarge_row.visible = r != "none";
            sharpen_amount_row.visible = settings.sharpen != "none";
            bool wm = settings.watermark;
            wm_kind_row.visible = wm;
            wm_text_row.visible = wm && settings.watermark_kind == "text";
            wm_image_row.visible = wm && settings.watermark_kind == "image";
            wm_position_row.visible = wm;
            wm_opacity_row.visible = wm;
            wm_scale_row.visible = wm;
            folder_row.visible = settings.destination == "folder" && settings.plugin_destination == "";
            if (filter_amount_row != null) filter_amount_row.visible = settings.filter != "";
            export_button.sensitive = running == null && (settings.destination != "folder" || settings.folder != "") && files.length > 0;
        }

        private void choose_folder() {
            var chooser = new FileDialog();
            chooser.title = _("Export To");
            chooser.select_folder.begin(this, null, (obj, res) => {
                try {
                    var f = chooser.select_folder.end(res);
                    if (f == null) return;
                    settings.folder = f.get_path();
                    folder_row.subtitle = settings.folder;
                    update_visibility();
                } catch (Error e) {
                }
            });
        }

        private void choose_icc() {
            var chooser = new FileDialog();
            chooser.title = _("Choose a Color Profile");
            var filter = new FileFilter();
            filter.name = _("ICC Profiles");
            filter.add_suffix("icc");
            filter.add_suffix("icm");
            var filters = new GLib.ListStore(typeof(FileFilter));
            filters.append(filter);
            chooser.filters = filters;
            chooser.open.begin(this, null, (obj, res) => {
                try {
                    var f = chooser.open.end(res);
                    if (f == null) return;
                    Singularity.Imaging.IccProfile.from_file(f.get_path());
                    settings.icc_path = f.get_path();
                    update_visibility();
                } catch (Error e) {
                    OutputRows.toast(transient_for, _("This is not a usable color profile"));
                }
            });
        }

        private void choose_watermark() {
            var chooser = new FileDialog();
            chooser.title = _("Choose a Watermark Image");
            var filter = new FileFilter();
            filter.name = _("Images");
            filter.add_pixbuf_formats();
            var filters = new GLib.ListStore(typeof(FileFilter));
            filters.append(filter);
            chooser.filters = filters;
            chooser.open.begin(this, null, (obj, res) => {
                try {
                    var f = chooser.open.end(res);
                    if (f == null) return;
                    settings.watermark_image = f.get_path();
                    wm_image_row.subtitle = f.get_basename();
                } catch (Error e) {
                }
            });
        }

        private void ask_preset_name() {
            var dlg = new AppDialog(application, true, false);
            dlg.transient_for = this;
            dlg.set_title(_("Save Preset"));
            dlg.set_default_size(420, 200);
            var group = new PreferencesGroup();
            group.margin_start = group.margin_end = 18;
            var entry = new EntryRow(_("Name"));
            entry.text = settings.name;
            group.add_row(entry);
            dlg.content_box.append(group);
            var bar = new Box(Gtk.Orientation.HORIZONTAL, 8);
            bar.margin_start = bar.margin_end = 18;
            bar.margin_bottom = 16;
            var spacer = new Box(Gtk.Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            bar.append(spacer);
            bar.append(dlg.add_cancel_button());
            var save = new Button.with_label(_("Save"));
            save.add_css_class("suggested-action");
            save.clicked.connect(() => {
                string name = entry.text.strip();
                if (name == "") return;
                var s = settings.copy();
                s.name = name;
                try {
                    ExportPresets.save(s);
                    presets = ExportPresets.all();
                    string[] labels = {};
                    int active = 0;
                    for (int i = 0; i < presets.size; i++) {
                        labels += presets[i].settings.name;
                        if (presets[i].settings.name == name && !presets[i].builtin) active = i;
                    }
                    syncing = true;
                    set_model(preset_dd, labels, active);
                    syncing = false;
                    settings.name = name;
                } catch (Error e) {
                    OutputRows.toast(transient_for, _("Could not save the preset: %s").printf(e.message));
                }
                dlg.close_dialog();
            });
            bar.append(save);
            dlg.content_box.append(bar);
            dlg.open_dialog();
        }

        private void start_export() {
            if (running != null) return;
            read_settings();
            running = new Cancellable();
            var cancellable = running;
            var s = settings.copy();
            if (s.plugin_destination != "") {
                s.destination = "folder";
                s.folder = Path.build_filename(Environment.get_user_cache_dir(), "singularity-photos", "deliver", Uuid.string_random());
                s.subfolder = "";
                s.conflict = "overwrite";
            }
            var list = files;
            export_button.sensitive = false;
            progress.visible = true;
            progress.fraction = 0;
            summary.visible = false;
            new Thread<void>("photos-export", () => {
                var results = ExportEngine.run(list, s, cancellable, (done, total, current) => {
                    Idle.add(() => {
                        progress.fraction = total > 0 ? (double) done / total : 1;
                        progress.text = current.get_basename();
                        return Source.REMOVE;
                    });
                });
                Idle.add(() => {
                    if (s.plugin_destination != "") deliver.begin(results, s, cancellable);
                    else finish(results, cancellable.is_cancelled());
                    return Source.REMOVE;
                });
            });
        }

        private async void deliver(Gee.List<ExportResult> results, ExportSettings s, Cancellable cancellable) {
            var dest = PhotosPluginHost.get_default().find_destination(s.plugin_destination);
            File[] ready = {};
            foreach (var r in results) if (r.ok) ready += r.target;
            if (dest != null && ready.length > 0) {
                progress.text = dest.title;
                try {
                    yield dest.deliver(ready, cancellable);
                } catch (Error e) {
                    foreach (var r in results) if (r.ok) r.error = e.message;
                }
            }
            foreach (var f in ready) FileUtils.remove(f.get_path());
            DirUtils.remove(s.folder);
            finish(results, cancellable.is_cancelled());
        }

        private void finish(Gee.List<ExportResult> results, bool cancelled) {
            running = null;
            int ok = 0, failed = 0, skipped = 0;
            string first_error = "";
            foreach (var r in results) {
                if (r.ok) ok++;
                else if (r.skipped) skipped++;
                else {
                    failed++;
                    if (first_error == "") first_error = "%s: %s".printf(r.source.get_basename(), r.error);
                }
            }
            progress.visible = false;
            if (failed == 0 && !cancelled) {
                string text = ok == 1 ? _("Exported 1 photo") : _("Exported %d photos").printf(ok);
                if (skipped > 0) text += " · " + _("%d skipped").printf(skipped);
                OutputRows.toast(transient_for, text);
                close_dialog();
                return;
            }
            summary.label = cancelled ? _("Export stopped after %d photos").printf(ok) : _("%d exported, %d failed. %s").printf(ok, failed, first_error);
            summary.visible = true;
            update_visibility();
        }
    }
}
