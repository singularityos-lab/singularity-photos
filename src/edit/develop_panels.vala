using Gtk;
using Singularity.Widgets;
using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class DevelopPanel : Box {
        private unowned EditView host;
        private DevelopControls c = new DevelopControls();
        private Label exif_label;
        private Gee.ArrayList<DevelopSection> sections = new Gee.ArrayList<DevelopSection>();
        private Gee.ArrayList<Widget> raw_rows = new Gee.ArrayList<Widget>();
        private Gee.ArrayList<Widget> plain_rows = new Gee.ArrayList<Widget>();
        private Gee.ArrayList<Widget> bw_rows = new Gee.ArrayList<Widget>();
        private Gee.ArrayList<Widget> hsl_rows = new Gee.ArrayList<Widget>();
        private IndexChoiceRow wb_mode;
        private IndexChoiceRow profile_drop;
        private IndexChoiceRow camera_drop;
        private string[] camera_ids = {};
        private Label lut_label;
        private ChoiceRow treatment;
        private ChoiceRow curve_channel;
        private ChoiceRow hsl_mode_switcher;
        private ChoiceRow grade_switcher;
        private CurveEditor curve;
        private ColorWheel wheel;
        private Label lens_status;
        private Switch lens_switch;
        private Switch ca_switch;
        private Switch proof_switch;
        private IndexChoiceRow proof_drop;
        private ChoiceRow proof_intent;
        private Switch gamut_switch;
        private Picture loupe;
        private double loupe_x = 0.5;
        private double loupe_y = 0.5;
        private uint loupe_id = 0;
        private string hsl_mode = "hue";
        private string grade_zone = "shadows";
        private bool syncing = false;
        private string[] wb_ids = { "as-shot", "auto", "custom", "daylight", "cloudy", "shade", "tungsten", "fluorescent", "flash" };
        private string[] proof_ids = {};

        public DevelopPanel(EditView host) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.host = host;
            c.begin_change.connect((label, coalesce) => host.record(label, coalesce));
            c.changed.connect(() => host.changed());
            build();
            host.rendered.connect(() => {
                if (curve != null) curve.histogram = host.histogram.luma_bins();
            });
        }

        private DevelopSection section(string id, string title, bool collapsible) {
            string[] open = host.settings != null ? host.settings.get_strv("develop-panels") : new string[0];
            bool expanded = !collapsible;
            foreach (var o in open) if (o == id) expanded = true;
            var s = new DevelopSection(id, title, collapsible, expanded);
            s.expanded_changed.connect((e) => {
                if (host.settings == null) return;
                var list = new Gee.ArrayList<string>();
                foreach (var o in host.settings.get_strv("develop-panels")) if (o != id) list.add(o);
                if (e) list.add(id);
                host.settings.set_strv("develop-panels", list.to_array());
                sync_visibility();
            });
            sections.add(s);
            append(s.group);
            return s;
        }

        private PreferencesRow adj(Adjustment a, double display_scale = 100, owned ValueFormat? format = null) {
            return c.slider(a.label(), a.min_value(), a.max_value(), 0, display_scale,
                () => host.params.get_value(a), (v) => host.params.set_value(a, v), format != null ? (owned) format : (ValueFormat) DevelopControls.signed);
        }

        private PreferencesRow dev(string key, string title, double display_scale = 100, owned ValueFormat? format = null, double step = 0) {
            var k = DevelopSettings.find_key(key);
            return c.slider(title, k.min, k.max, k.default_value, display_scale,
                () => host.params.develop.get(key), (v) => host.params.develop.set(key, v), format != null ? (owned) format : (ValueFormat) DevelopControls.signed, step);
        }

        private void build() {
            var hist = host.histogram;
            hist.margin_top = 2;
            append(hist);
            exif_label = new Label("");
            exif_label.add_css_class("dim-label");
            exif_label.add_css_class("photo-edit-exif");
            exif_label.halign = Align.CENTER;
            exif_label.ellipsize = Pango.EllipsizeMode.END;
            append(exif_label);

            var light = section("light", _("Light"), false);
            light.add(adj(Adjustment.EXPOSURE, 2, (v) => "%+.2f EV".printf(v)));
            light.add(adj(Adjustment.CONTRAST));
            light.add(adj(Adjustment.HIGHLIGHTS));
            light.add(adj(Adjustment.SHADOWS));
            light.add(adj(Adjustment.WHITES));
            light.add(adj(Adjustment.BLACKS));
            light.add(adj(Adjustment.BRIGHTNESS));

            var color = section("color", _("Color"), false);
            color.group.add_header_suffix(DevelopControls.header_button("color-select-symbolic", _("Pick White Balance from the Photo"), () => {
                host.request_pick(_("Click a neutral gray or white area"), (nx, ny, r, g, b) => host.pick_white_balance(nx, ny));
            }));
            wb_mode = new IndexChoiceRow(_("White Balance"), { _("As Shot"), _("Auto"), _("Custom"), _("Daylight"), _("Cloudy"), _("Shade"), _("Tungsten"), _("Fluorescent"), _("Flash") });
                        wb_mode.notify["selected-index"].connect(() => {
                if (syncing) return;
                string id = wb_ids[wb_mode.selected_index];
                host.record(_("White Balance"));
                double[] temps = { 0, 0, 0, 5500, 6500, 7500, 2850, 3800, 5500 };
                double[] tints = { 0, 0, 0, 10, 10, 10, 0, 10, 0 };
                if (id == "as-shot") host.params.develop.set_string("wb.mode", null);
                else if (id == "auto" || id == "custom") host.params.develop.set_string("wb.mode", id);
                else {
                    host.params.develop.set_string("wb.mode", "custom");
                    host.params.develop.set("wb.temperature", temps[wb_mode.selected_index]);
                    host.params.develop.set("wb.tint", tints[wb_mode.selected_index]);
                }
                host.changed();
            });
            var wb_row = wb_mode;
            color.add(wb_row);
            raw_rows.add(wb_row);
            var temp_row = c.slider(_("Temperature"), 2000, 12000, 5500, 1, () => host.params.develop.get("wb.temperature"), (v) => {
                host.params.develop.set_string("wb.mode", "custom");
                host.params.develop.set("wb.temperature", v);
            }, (v) => "%d K".printf((int) Math.round(v)), 50);
            color.add(temp_row);
            raw_rows.add(temp_row);
            var tint_row = c.slider(_("Tint"), -150, 150, 0, 1, () => host.params.develop.get("wb.tint"), (v) => {
                host.params.develop.set_string("wb.mode", "custom");
                host.params.develop.set("wb.tint", v);
            }, DevelopControls.signed, 1);
            color.add(tint_row);
            raw_rows.add(tint_row);
            var warmth_row = adj(Adjustment.WARMTH);
            var ptint_row = adj(Adjustment.TINT);
            color.add(warmth_row);
            color.add(ptint_row);
            plain_rows.add(warmth_row);
            plain_rows.add(ptint_row);
            color.add(adj(Adjustment.VIBRANCE));
            color.add(adj(Adjustment.SATURATION));
            treatment = new ChoiceRow(_("Treatment"));
            treatment.add_option("color", _("Color"));
            treatment.add_option("bw", _("Black and White"));
            treatment.chosen.connect((name) => {
                if (syncing) return;
                host.record(_("Treatment"));
                host.params.develop.set_string("treatment", name == "bw" ? "bw" : null);
                host.changed();
            });
            color.add(treatment);
            camera_drop = new IndexChoiceRow(_("Camera Profile"), { _("Camera Matrix") });
                        camera_drop.notify["selected-index"].connect(() => {
                if (syncing || camera_ids.length == 0) return;
                host.record(_("Camera Profile"));
                string id = camera_ids[camera_drop.selected_index];
                host.params.develop.set_string("camera.profile", id == CameraProfiles.MATRIX ? null : id);
                host.changed();
            });
            var camera_row = camera_drop;
            color.add(camera_row);
            raw_rows.add(camera_row);
            string[] profile_labels = {};
            foreach (var id in CreativeProfiles.IDS) profile_labels += CreativeProfiles.label(id);
            profile_drop = new IndexChoiceRow(_("Profile"), profile_labels);
                        profile_drop.notify["selected-index"].connect(() => {
                if (syncing) return;
                host.record(_("Profile"));
                host.params.develop.set_string("profile", CreativeProfiles.IDS[profile_drop.selected_index]);
                host.changed();
            });
            var profile_row = profile_drop;
            color.add(profile_row);
            color.add(dev("profile.amount", _("Profile Amount")));
            var lut_row = new ActionRow(_("Look Table"));
            lut_label = new Label("");
            lut_label.add_css_class("dim-label");
            lut_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            lut_label.max_width_chars = 12;
            lut_row.add_suffix(lut_label);
            var lut_button = new Button.with_label(_("Choose…"));
            lut_button.valign = Align.CENTER;
            lut_button.clicked.connect(() => choose_lut());
            lut_row.add_suffix(lut_button);
            var lut_clear = new Button.from_icon_name("edit-clear-symbolic");
            lut_clear.valign = Align.CENTER;
            lut_clear.tooltip_text = _("Remove the Look Table");
            lut_clear.clicked.connect(() => {
                host.record(_("Look Table"));
                host.params.develop.set_string("lut", null);
                host.changed();
            });
            lut_row.add_suffix(lut_clear);
            color.add(lut_row);
            color.add(dev("lut.amount", _("Look Table Amount")));

            var presence = section("presence", _("Presence"), false);
            presence.add(adj(Adjustment.TEXTURE));
            presence.add(adj(Adjustment.CLARITY));
            presence.add(adj(Adjustment.DEHAZE));

            var tone = section("curve", _("Tone Curve"), true);
            curve_channel = new ChoiceRow(_("Channel"));
            curve_channel.add_option("master", "RGB");
            curve_channel.add_option("red", _("Red"));
            curve_channel.add_option("green", _("Green"));
            curve_channel.add_option("blue", _("Blue"));
            curve_channel.chosen.connect((name) => curve.channel = name);
            tone.add(curve_channel);
            curve = new CurveEditor();
            curve.settings = host.params.develop;
            curve.begin_change.connect(() => host.record(_("Tone Curve")));
            curve.changed.connect(() => host.changed());
            tone.add(DevelopControls.static_row(curve));
            tone.add(dev("tone.highlights", _("Highlights")));
            tone.add(dev("tone.lights", _("Lights")));
            tone.add(dev("tone.darks", _("Darks")));
            tone.add(dev("tone.shadows", _("Shadows")));
            tone.add(dev("tone.split1", _("Shadow Split"), 100, DevelopControls.signed));
            tone.add(dev("tone.split2", _("Midtone Split"), 100, DevelopControls.signed));
            tone.add(dev("tone.split3", _("Highlight Split"), 100, DevelopControls.signed));
            tone.add(DevelopControls.action_row(_("Reset Curve"), "edit-undo-symbolic", () => {
                host.record(_("Reset Curve"));
                host.params.develop.curves.clear();
                host.params.develop.reset_prefix("tone.");
                host.changed();
            }));

            var mixer = section("hsl", _("Color Mixer"), true);
            hsl_mode_switcher = new ChoiceRow(_("Adjust"));
            hsl_mode_switcher.add_option("hue", _("Hue"));
            hsl_mode_switcher.add_option("sat", _("Saturation"));
            hsl_mode_switcher.add_option("lum", _("Luminance"));
            hsl_mode_switcher.chosen.connect((name) => {
                hsl_mode = name;
                c.sync();
            });
            var mode_row = hsl_mode_switcher;
            mixer.add(mode_row);
            hsl_rows.add(mode_row);
            string[] band_labels = { _("Red"), _("Orange"), _("Yellow"), _("Green"), _("Aqua"), _("Blue"), _("Purple"), _("Magenta") };
            for (int i = 0; i < 8; i++) {
                string band = HSL_BANDS[i];
                var row = c.slider(band_labels[i], -1, 1, 0, 100, () => host.params.develop.get("hsl." + hsl_mode + "." + band),
                    (v) => host.params.develop.set("hsl." + hsl_mode + "." + band, v), DevelopControls.signed);
                mixer.add(row);
                hsl_rows.add(row);
            }
            for (int i = 0; i < 8; i++) {
                string band = HSL_BANDS[i];
                var row = c.slider(_("%s Gray").printf(band_labels[i]), -1, 1, 0, 100, () => host.params.develop.get("bw." + band),
                    (v) => host.params.develop.set("bw." + band, v), DevelopControls.signed);
                mixer.add(row);
                bw_rows.add(row);
            }

            var grading = section("grading", _("Color Grading"), true);
            grade_switcher = new ChoiceRow(_("Range"));
            grade_switcher.add_option("shadows", _("Shadows"));
            grade_switcher.add_option("midtones", _("Midtones"));
            grade_switcher.add_option("highlights", _("Highlights"));
            grade_switcher.add_option("global", _("Global"));
            grade_switcher.chosen.connect((name) => {
                grade_zone = name;
                sync();
            });
            grading.add(grade_switcher);
            wheel = new ColorWheel();
            wheel.begin_change.connect(() => host.record(_("Color Grading")));
            wheel.changed.connect(() => {
                if (syncing) return;
                host.params.develop.set("grading." + grade_zone + ".hue", wheel.hue);
                host.params.develop.set("grading." + grade_zone + ".sat", wheel.saturation);
                host.changed();
            });
            grading.add(DevelopControls.static_row(wheel));
            grading.add(c.slider(_("Hue"), 0, 360, 0, 1, () => host.params.develop.get("grading." + grade_zone + ".hue"),
                (v) => host.params.develop.set("grading." + grade_zone + ".hue", v), (v) => "%d°".printf((int) Math.round(v)), 1));
            grading.add(c.slider(_("Saturation"), 0, 1, 0, 100, () => host.params.develop.get("grading." + grade_zone + ".sat"),
                (v) => host.params.develop.set("grading." + grade_zone + ".sat", v)));
            grading.add(c.slider(_("Luminance"), -1, 1, 0, 100, () => host.params.develop.get("grading." + grade_zone + ".lum"),
                (v) => host.params.develop.set("grading." + grade_zone + ".lum", v), DevelopControls.signed));
            grading.add(dev("grading.blending", _("Blending"), 100, (v) => "%d".printf((int) Math.round(v))));
            grading.add(dev("grading.balance", _("Balance")));

            var detail = section("detail", _("Detail"), true);
            detail.add(c.slider(_("Sharpening"), 0, 1, 0, 150, () => host.params.get_value(Adjustment.SHARPNESS), (v) => host.params.set_value(Adjustment.SHARPNESS, v)));
            detail.add(dev("detail.sharpen.radius", _("Radius"), 1, (v) => "%.1f".printf(v), 0.1));
            detail.add(dev("detail.sharpen.detail", _("Detail"), 100, (v) => "%d".printf((int) Math.round(v))));
            detail.add(dev("detail.sharpen.masking", _("Masking"), 100, (v) => "%d".printf((int) Math.round(v))));
            detail.add(dev("detail.noise.amount", _("Noise Reduction"), 100, (v) => "%d".printf((int) Math.round(v))));
            detail.add(dev("detail.noise.detail", _("Noise Detail"), 100, (v) => "%d".printf((int) Math.round(v))));
            detail.add(dev("detail.noise.contrast", _("Noise Contrast"), 100, (v) => "%d".printf((int) Math.round(v))));
            detail.add(dev("detail.color.amount", _("Color Noise"), 100, (v) => "%d".printf((int) Math.round(v))));
            detail.add(dev("detail.color.detail", _("Color Detail"), 100, (v) => "%d".printf((int) Math.round(v))));
            detail.add(dev("detail.color.smoothness", _("Color Smoothness"), 100, (v) => "%d".printf((int) Math.round(v))));
            loupe = new Picture();
            loupe.content_fit = ContentFit.COVER;
            loupe.height_request = 180;
            loupe.add_css_class("photo-filter-thumb");
            loupe.overflow = Overflow.HIDDEN;
            loupe.tooltip_text = _("Detail at 100%");
            detail.add(DevelopControls.static_row(loupe));
            detail.add(DevelopControls.action_row(_("Choose Detail Area"), "find-location-symbolic", () => {
                host.request_pick(_("Click the area to inspect at 100%"), (nx, ny, r, g, b) => {
                    loupe_x = nx;
                    loupe_y = ny;
                    schedule_loupe();
                });
            }));

            var lens = section("optics", _("Lens Corrections"), true);
            lens_switch = new Switch();
            lens_switch.valign = Align.CENTER;
            lens_switch.notify["active"].connect(() => {
                if (syncing) return;
                host.record(_("Lens Profile"));
                host.params.develop.set("lens.profile", lens_switch.active ? 1 : 0);
                host.changed();
            });
            var lens_row = new ActionRow(_("Profile Corrections"));
            lens_row.add_suffix(lens_switch);
            lens.add(lens_row);
            lens_status = new Label("");
            lens_status.add_css_class("dim-label");
            lens_status.wrap = true;
            lens_status.xalign = 0;
            lens.add(DevelopControls.static_row(lens_status));
            lens.add(dev("lens.profile.distortion", _("Distortion Amount"), 100, (v) => "%d".printf((int) Math.round(v))));
            lens.add(dev("lens.profile.vignette", _("Vignetting Amount"), 100, (v) => "%d".printf((int) Math.round(v))));
            ca_switch = new Switch();
            ca_switch.valign = Align.CENTER;
            ca_switch.notify["active"].connect(() => {
                if (syncing) return;
                host.record(_("Chromatic Aberration"));
                host.params.develop.set("lens.ca", ca_switch.active ? 1 : 0);
                host.changed();
            });
            var ca_row = new ActionRow(_("Remove Chromatic Aberration"));
            ca_row.add_suffix(ca_switch);
            lens.add(ca_row);
            lens.add(dev("lens.distortion", _("Manual Distortion")));
            lens.add(dev("lens.vignette", _("Manual Vignetting")));
            lens.add(dev("lens.vignette.midpoint", _("Vignetting Midpoint"), 100, (v) => "%d".printf((int) Math.round(v))));
            lens.add(dev("lens.ca.red", _("Red and Cyan Fringe")));
            lens.add(dev("lens.ca.blue", _("Blue and Yellow Fringe")));
            lens.add(dev("lens.defringe", _("Defringe"), 100, (v) => "%d".printf((int) Math.round(v))));

            var effects = section("effects", _("Effects"), true);
            effects.add(adj(Adjustment.VIGNETTE));
            effects.add(dev("effects.vignette.midpoint", _("Vignette Midpoint"), 100, (v) => "%d".printf((int) Math.round(v))));
            effects.add(dev("effects.vignette.roundness", _("Vignette Roundness")));
            effects.add(dev("effects.vignette.feather", _("Vignette Feather"), 100, (v) => "%d".printf((int) Math.round(v))));
            effects.add(dev("effects.vignette.highlights", _("Vignette Highlights"), 100, (v) => "%d".printf((int) Math.round(v))));
            effects.add(dev("effects.grain.amount", _("Grain"), 100, (v) => "%d".printf((int) Math.round(v))));
            effects.add(dev("effects.grain.size", _("Grain Size"), 100, (v) => "%d".printf((int) Math.round(v))));
            effects.add(dev("effects.grain.roughness", _("Grain Roughness"), 100, (v) => "%d".printf((int) Math.round(v))));

            var cal = section("calibration", _("Calibration"), true);
            cal.add(dev("calibration.shadows.tint", _("Shadows Tint")));
            cal.add(dev("calibration.red.hue", _("Red Primary Hue")));
            cal.add(dev("calibration.red.sat", _("Red Primary Saturation")));
            cal.add(dev("calibration.green.hue", _("Green Primary Hue")));
            cal.add(dev("calibration.green.sat", _("Green Primary Saturation")));
            cal.add(dev("calibration.blue.hue", _("Blue Primary Hue")));
            cal.add(dev("calibration.blue.sat", _("Blue Primary Saturation")));

            var proof = section("proof", _("Soft Proofing"), true);
            proof_switch = new Switch();
            proof_switch.valign = Align.CENTER;
            proof_switch.notify["active"].connect(() => {
                if (syncing) return;
                host.proof_enabled = proof_switch.active;
                if (host.proof_profile_id == "") host.proof_profile_id = "srgb";
                host.invalidate_display();
            });
            var proof_row = new ActionRow(_("Soft Proof"));
            proof_row.add_suffix(proof_switch);
            proof.add(proof_row);
            string[] labels = {};
            foreach (var id in IccProfile.builtin_ids()) {
                proof_ids += id;
                labels += IccProfile.builtin_label(id);
            }
            proof_ids += "file";
            labels += _("Profile File…");
            proof_drop = new IndexChoiceRow(_("Proof Profile"), labels);
                        proof_drop.notify["selected-index"].connect(() => {
                if (syncing) return;
                string id = proof_ids[proof_drop.selected_index];
                if (id == "file") {
                    choose_proof_profile();
                    return;
                }
                host.proof_profile_id = id;
                host.invalidate_display();
            });
            var proof_profile_row = proof_drop;
            proof.add(proof_profile_row);
            proof_intent = new ChoiceRow(_("Rendering Intent"));
            proof_intent.add_option("perceptual", _("Perceptual"));
            proof_intent.add_option("relative", _("Relative"));
            proof_intent.chosen.connect((name) => {
                if (syncing) return;
                host.proof_intent = name;
                host.invalidate_display();
            });
            proof.add(proof_intent);
            gamut_switch = new Switch();
            gamut_switch.valign = Align.CENTER;
            gamut_switch.notify["active"].connect(() => {
                if (syncing) return;
                host.gamut_warning = gamut_switch.active;
                host.invalidate_display();
            });
            var gamut_row = new ActionRow(_("Gamut Warning"));
            gamut_row.add_suffix(gamut_switch);
            proof.add(gamut_row);

            var reset = new PreferencesGroup(_("Reset"), _("Restores every adjustment and keeps the filter."));
            reset.add_row(DevelopControls.action_row(_("Reset Adjustments"), "edit-undo-symbolic", () => {
                host.record(_("Reset Adjustments"));
                string f = host.params.filter;
                host.params.reset_color();
                host.params.filter = f;
                host.changed();
            }));
            append(reset);
        }

        private void choose_lut() {
            var dialog = new FileDialog();
            dialog.title = _("Choose a Look Table");
            var filter = new FileFilter();
            filter.name = _("Cube Look Tables");
            filter.add_pattern("*.cube");
            filter.add_pattern("*.CUBE");
            var filters = new GLib.ListStore(typeof(FileFilter));
            filters.append(filter);
            dialog.filters = filters;
            dialog.open.begin(get_root() as Gtk.Window, null, (obj, res) => {
                try {
                    var f = dialog.open.end(res);
                    Lut3D.load(f.get_path());
                    host.record(_("Look Table"));
                    host.params.develop.set_string("lut", f.get_path());
                    host.changed();
                } catch (Error e) {
                    if (!(e is IOError.CANCELLED) && !(e is Gtk.DialogError.DISMISSED)) host.message(_("Cannot use this look table: %s").printf(e.message));
                }
            });
        }

        private void choose_proof_profile() {
            var dialog = new FileDialog();
            dialog.title = _("Choose a Color Profile");
            var filter = new FileFilter();
            filter.name = _("ICC Profiles");
            filter.add_pattern("*.icc");
            filter.add_pattern("*.icm");
            filter.add_pattern("*.ICC");
            filter.add_pattern("*.ICM");
            var filters = new GLib.ListStore(typeof(FileFilter));
            filters.append(filter);
            dialog.filters = filters;
            dialog.open.begin(get_root() as Gtk.Window, null, (obj, res) => {
                try {
                    var f = dialog.open.end(res);
                    IccProfile.from_file(f.get_path());
                    host.proof_profile_id = f.get_path();
                    host.proof_enabled = true;
                    host.invalidate_display();
                    sync();
                } catch (Error e) {
                    if (!(e is IOError.CANCELLED) && !(e is Gtk.DialogError.DISMISSED)) host.message(_("Cannot use this profile: %s").printf(e.message));
                }
            });
        }

        private void schedule_loupe() {
            if (loupe_id != 0) Source.remove(loupe_id);
            loupe_id = Timeout.add(250, () => {
                loupe_id = 0;
                render_loupe();
                return Source.REMOVE;
            });
        }

        private void render_loupe() {
            var photo = host.photo;
            if (photo == null) return;
            var p = host.params.copy();
            double lx = loupe_x, ly = loupe_y;
            var file = host.file;
            new Thread<void>("photo-loupe", () => {
                try {
                    var full = photo.image.width >= photo.full_width ? photo : Codecs.load(file, 0);
                    var g = new GeometryMap(p, full.full_width, full.full_height, 0, false);
                    double ox, oy;
                    g.source_to_output(lx * full.full_width, ly * full.full_height, out ox, out oy);
                    double w = g.oriented_width, h = g.oriented_height;
                    double size = 360;
                    var region = p.copy();
                    region.set_crop((ox - size / 2) / w, (oy - size / 2) / h, size / w, size / h);
                    var img = DevelopPipeline.render(full, region, new RenderOptions());
                    var tex = WorkingSpace.to_display_texture(img);
                    Idle.add(() => {
                        loupe.paintable = tex;
                        return Source.REMOVE;
                    });
                } catch (Error e) {
                    warning("Photos: loupe: %s", e.message);
                }
            });
        }

        public void photo_loaded() {
            var photo = host.photo;
            if (photo == null) return;
            string summary = photo.meta.summary();
            string camera = photo.meta.camera_label();
            exif_label.label = camera != "" && summary != "" ? "%s · %s".printf(camera, summary) : camera + summary;
            exif_label.visible = exif_label.label != "";
            if (photo.raw != null) {
                camera_ids = CameraProfiles.list(photo.raw);
                string[] labels = {};
                foreach (var id in camera_ids) labels += CameraProfiles.label(id);
                syncing = true;
                camera_drop.set_labels(labels);
                syncing = false;
            }
            var profiles = LensCorrection.find_profiles(photo.meta);
            if (profiles.length > 0) lens_status.label = _("Profile: %s").printf(profiles[0]);
            else if (photo.meta.lens != "") lens_status.label = _("No profile found for %s. Use the manual corrections below.").printf(photo.meta.lens);
            else lens_status.label = _("The photo does not name its lens. Use the manual corrections below.");
            sync_visibility();
            schedule_loupe();
        }

        private void sync_visibility() {
            bool raw = host.photo != null && host.photo.is_raw();
            foreach (var s in sections) {
                if (s.id != "color" && s.id != "hsl") continue;
                if (!s.expanded) continue;
                if (s.id == "color") {
                    foreach (var r in raw_rows) r.visible = raw;
                    foreach (var r in plain_rows) r.visible = !raw;
                } else {
                    bool bw = host.params.develop.get_string("treatment") == "bw";
                    foreach (var r in hsl_rows) r.visible = !bw;
                    foreach (var r in bw_rows) r.visible = bw;
                }
            }
        }

        public void sync() {
            syncing = true;
            c.sync();
            curve.settings = host.params.develop;
            curve.queue_draw();
            string mode = host.params.develop.get_string("wb.mode", "as-shot");
            int wi = 0;
            for (int i = 0; i < 3; i++) if (wb_ids[i] == mode) wi = i;
            wb_mode.selected_index = wi;
            treatment.set_active(host.params.develop.get_string("treatment") == "bw" ? "bw" : "color");
            string cam = host.params.develop.get_string("camera.profile", CameraProfiles.MATRIX);
            for (int i = 0; i < camera_ids.length; i++) if (camera_ids[i] == cam) camera_drop.selected_index = i;
            string prof = host.params.develop.get_string("profile");
            for (int i = 0; i < CreativeProfiles.IDS.length; i++) if (CreativeProfiles.IDS[i] == prof) profile_drop.selected_index = i;
            string lut = host.params.develop.get_string("lut");
            lut_label.label = lut != "" ? Path.get_basename(lut) : _("None");
            wheel.hue = host.params.develop.get("grading." + grade_zone + ".hue");
            wheel.saturation = host.params.develop.get("grading." + grade_zone + ".sat");
            lens_switch.active = host.params.develop.get("lens.profile") > 0.5;
            ca_switch.active = host.params.develop.get("lens.ca") > 0.5;
            proof_switch.active = host.proof_enabled;
            gamut_switch.active = host.gamut_warning;
            proof_intent.set_active(host.proof_intent);
            for (int i = 0; i < proof_ids.length; i++) if (proof_ids[i] == host.proof_profile_id) proof_drop.selected_index = i;
            syncing = false;
            sync_visibility();
            if (loupe != null && host.photo != null) schedule_loupe();
        }
    }

    public class MasksPanel : Box {
        private unowned EditView host;
        private DevelopControls c = new DevelopControls();
        private DevelopControls tool_controls = new DevelopControls();
        private PreferencesGroup list_group;
        private PreferencesGroup components_group;
        private PreferencesGroup tool_group;
        private PreferencesGroup adjust_group;
        private Box selected_box;
        private int selected = -1;
        private int component_index = 0;
        private bool syncing = false;
        private Switch erase_switch;
        private Switch overlay_switch;
        private EntryRow name_row;
        private Gee.ArrayList<Widget> brush_rows = new Gee.ArrayList<Widget>();
        private Gee.ArrayList<Widget> radial_rows = new Gee.ArrayList<Widget>();
        private Gee.ArrayList<Widget> color_rows = new Gee.ArrayList<Widget>();
        private Gee.ArrayList<Widget> luma_rows = new Gee.ArrayList<Widget>();
        private Label tool_hint;
        private uint render_id = 0;

        public MasksPanel(EditView host) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.host = host;
            c.begin_change.connect((label, coalesce) => host.record(label, coalesce));
            c.changed.connect(() => host.changed());
            tool_controls.begin_change.connect((label, coalesce) => {
                if (component() != null && component().kind != "brush") host.record(label, coalesce);
            });
            tool_controls.changed.connect(() => {
                host.canvas.brush_radius = brush_radius;
                host.canvas.brush_feather = brush_feather;
                host.canvas.brush_flow = brush_flow;
                host.changed();
            });
            build();
            host.canvas.strokes_changed.connect((finished) => lazy_render(finished));
            host.canvas.gradient_changed.connect((finished) => lazy_render(finished));
        }

        private double brush_radius = 0.03;
        private double brush_feather = 0.5;
        private double brush_flow = 1.0;

        private void lazy_render(bool finished) {
            if (host.current_page() != "masks") return;
            if (finished) {
                if (render_id != 0) {
                    Source.remove(render_id);
                    render_id = 0;
                }
                host.changed();
                return;
            }
            if (render_id != 0) return;
            render_id = Timeout.add(80, () => {
                render_id = 0;
                host.schedule_render();
                return Source.REMOVE;
            });
        }

        private string kind_label(string kind) {
            switch (kind) {
                case "brush": return _("Brush");
                case "linear": return _("Linear Gradient");
                case "radial": return _("Radial Gradient");
                case "color": return _("Color Range");
                case "luminance": return _("Luminance Range");
                case "depth": return _("Depth Range");
                case "sky": return _("Sky");
                case "subject": return _("Subject");
                default: return _("Whole Photo");
            }
        }

        private string kind_icon(string kind) {
            switch (kind) {
                case "brush": return "singularity-photos-brush-symbolic";
                case "linear": return "singularity-photos-linear-symbolic";
                case "radial": return "singularity-photos-radial-symbolic";
                case "color": return "color-select-symbolic";
                case "luminance": return "display-brightness-symbolic";
                case "depth": return "camera-photo-symbolic";
                case "sky": return "weather-few-clouds-symbolic";
                case "subject": return "avatar-default-symbolic";
                default: return "image-x-generic-symbolic";
            }
        }

        private void kind_menu(Widget anchor, bool create) {
            var menu = new ContextMenu(anchor);
            foreach (var kind in new string[] { "brush", "linear", "radial", "color", "luminance", "depth", "sky", "subject", "all" }) {
                string k = kind;
                menu.add_item(kind_label(kind), kind_icon(kind), () => {
                    if (create) create_mask(k);
                    else add_component(k, "add");
                });
            }
            menu.closed.connect(() => Idle.add(() => {
                menu.unparent();
                return Source.REMOVE;
            }));
            menu.popup();
        }

        private void build() {
            list_group = new PreferencesGroup(_("Masks"));
            var new_mask = new Button.with_label(_("New Mask"));
            new_mask.valign = Align.CENTER;
            new_mask.add_css_class("suggested-action");
            new_mask.clicked.connect(() => kind_menu(new_mask, true));
            list_group.add_header_suffix(new_mask);
            append(list_group);

            selected_box = new Box(Orientation.VERTICAL, 12);
            append(selected_box);
            var props = new PreferencesGroup(_("Selected Mask"));
            name_row = new EntryRow(_("Name"));
            name_row.entry_changed.connect(() => {
                var l = local();
                if (l == null || syncing) return;
                l.name = name_row.text;
                rebuild_list();
            });
            props.add_row(name_row);
            overlay_switch = new Switch();
            overlay_switch.active = true;
            overlay_switch.valign = Align.CENTER;
            overlay_switch.notify["active"].connect(() => host.canvas.show_overlay = overlay_switch.active);
            var overlay_row = new ActionRow(_("Show Overlay"), _("Press O to toggle"));
            overlay_row.add_suffix(overlay_switch);
            props.add_row(overlay_row);
            props.add_row(c.slider(_("Amount"), 0, 2, 1, 100, () => local() != null ? local().amount : 1, (v) => { if (local() != null) local().amount = v; }, (v) => "%d".printf((int) Math.round(v))));
            selected_box.append(props);

            components_group = new PreferencesGroup(_("Mask Components"));
            var add_part = new Button.with_label(_("Add"));
            add_part.valign = Align.CENTER;
            add_part.tooltip_text = _("Add to Mask");
            add_part.clicked.connect(() => kind_menu(add_part, false));
            components_group.add_header_suffix(add_part);
            selected_box.append(components_group);

            tool_group = new PreferencesGroup(_("Tool"));
            tool_hint = new Label("");
            tool_hint.wrap = true;
            tool_hint.xalign = 0;
            tool_hint.add_css_class("dim-label");
            tool_group.add_row(DevelopControls.static_row(tool_hint));
            var size = tool_controls.slider(_("Size"), 0.003, 0.2, 0.03, 100, () => brush_radius, (v) => brush_radius = v, (v) => "%.1f".printf(v), 0.001);
            var feather = tool_controls.slider(_("Feather"), 0, 1, 0.5, 100, () => brush_feather, (v) => brush_feather = v);
            var flow_row = tool_controls.slider(_("Flow"), 0.05, 1, 1, 100, () => brush_flow, (v) => brush_flow = v);
            erase_switch = new Switch();
            erase_switch.valign = Align.CENTER;
            erase_switch.notify["active"].connect(() => host.canvas.brush_erase = erase_switch.active);
            var erase_row = new ActionRow(_("Erase"));
            erase_row.add_suffix(erase_switch);
            foreach (var r in new Widget[] { size, feather, flow_row, erase_row }) {
                tool_group.add_row(r);
                brush_rows.add(r);
            }
            var rfeather = tool_controls.slider(_("Feather"), 0, 1, 0.5, 100, () => geo("feather", 0.5), (v) => set_geo("feather", v));
            var angle = tool_controls.slider(_("Angle"), -180, 180, 0, 1, () => geo("angle", 0), (v) => set_geo("angle", v), (v) => "%d°".printf((int) Math.round(v)), 1);
            foreach (var r in new Widget[] { rfeather, angle }) {
                tool_group.add_row(r);
                radial_rows.add(r);
            }
            var pick = new ActionRow(_("Sample Color"), _("Click a color in the photo"), "color-select-symbolic");
            pick.activatable = true;
            pick.activated.connect(() => {
                host.request_pick(_("Click the color to select"), (nx, ny, r, g, b) => {
                    host.record(_("Color Range"));
                    set_geo("r", Transfer.linear_to_srgb(WorkingSpace.luminance(r, 0, 0) > 0 ? r : r));
                    float sr = r, sg = g, sb = b;
                    WorkingSpaceColor.to_encoded(ref sr, ref sg, ref sb);
                    set_geo("r", sr);
                    set_geo("g", sg);
                    set_geo("b", sb);
                    host.changed();
                });
            });
            var range = tool_controls.slider(_("Range"), 0.02, 1, 0.3, 100, () => geo("range", 0.3), (v) => set_geo("range", v));
            foreach (var r in new Widget[] { pick, range }) {
                tool_group.add_row(r);
                color_rows.add(r);
            }
            var low = tool_controls.slider(_("Low"), 0, 1, 0.5, 100, () => geo("low", 0.5), (v) => set_geo("low", v));
            var high = tool_controls.slider(_("High"), 0, 1, 1, 100, () => geo("high", 1), (v) => set_geo("high", v));
            var lfeather = tool_controls.slider(_("Smoothness"), 0.001, 0.5, 0.1, 100, () => geo("feather", 0.1), (v) => set_geo("feather", v));
            foreach (var r in new Widget[] { low, high, lfeather }) {
                tool_group.add_row(r);
                luma_rows.add(r);
            }
            selected_box.append(tool_group);

            adjust_group = new PreferencesGroup(_("Adjustments"));
            string[] labels = { _("Exposure"), _("Contrast"), _("Highlights"), _("Shadows"), _("Whites"), _("Blacks"), _("Temperature"), _("Tint"),
                _("Texture"), _("Clarity"), _("Dehaze"), _("Hue"), _("Saturation"), _("Sharpness"), _("Noise"), _("Defringe") };
            for (int i = 0; i < LocalAdjustment.KEYS.length; i++) {
                string key = LocalAdjustment.KEYS[i];
                double mn = LocalAdjustment.min_for(key), mx = LocalAdjustment.max_for(key);
                double scale = key == "exposure" || key == "hue" ? 1 : 100;
                ValueFormat fmt = DevelopControls.signed;
                if (key == "exposure") fmt = (v) => "%+.2f EV".printf(v);
                else if (key == "hue") fmt = (v) => "%+d°".printf((int) Math.round(v));
                adjust_group.add_row(c.slider(labels[i], mn, mx, 0, scale, () => local() != null ? local().get(key) : 0, (v) => { if (local() != null) local().set(key, v); }, (owned) fmt, key == "exposure" ? 0.01 : 0));
            }
            selected_box.append(adjust_group);
            adjust_group.add_row(DevelopControls.action_row(_("Delete Mask"), "user-trash-symbolic", () => {
                if (local() == null) return;
                host.record(_("Delete Mask"));
                host.params.locals.remove_at(selected);
                selected = host.params.locals.size - 1;
                component_index = 0;
                host.changed();
                activate_tools();
            }));
        }

        private double geo(string key, double fallback) {
            var comp = component();
            return comp != null ? comp.g(key, fallback) : fallback;
        }

        private void set_geo(string key, double v) {
            var comp = component();
            if (comp != null) comp.s(key, v);
        }

        public LocalAdjustment? local() {
            if (selected < 0 || selected >= host.params.locals.size) return null;
            return host.params.locals[selected];
        }

        private MaskComponent? component() {
            var l = local();
            if (l == null || l.components.size == 0) return null;
            return l.components[component_index.clamp(0, l.components.size - 1)];
        }

        public LocalAdjustment? active_local() {
            return local();
        }

        private void create_mask(string kind) {
            host.record(_("New Mask"));
            var l = new LocalAdjustment();
            l.name = "%s %d".printf(kind_label(kind), host.params.locals.size + 1);
            host.params.locals.add(l);
            selected = host.params.locals.size - 1;
            component_index = 0;
            add_component(kind, "add", false);
        }

        private void add_component(string kind, string mode, bool record = true) {
            var l = local();
            if (l == null) return;
            if (record) host.record(_("Add to Mask"));
            var comp = new MaskComponent(kind);
            comp.mode = l.components.size == 0 ? "add" : mode;
            if (kind == "color") {
                comp.s("r", 0.5);
                comp.s("g", 0.5);
                comp.s("b", 0.5);
                comp.s("range", 0.3);
            } else if (kind == "luminance") {
                comp.s("low", 0.5);
                comp.s("high", 1.0);
                comp.s("feather", 0.1);
            } else if (kind == "radial") {
                comp.s("feather", 0.5);
            } else if (kind == "depth") {
                comp.s("low", 0.0);
                comp.s("high", 0.3);
                comp.s("feather", 0.1);
            }
            l.components.add(comp);
            component_index = l.components.size - 1;
            host.changed();
            activate_tools();
            if (kind == "color") host.request_pick(_("Click the color to select"), (nx, ny, r, g, b) => {
                float sr = r, sg = g, sb = b;
                WorkingSpaceColor.to_encoded(ref sr, ref sg, ref sb);
                comp.s("r", sr);
                comp.s("g", sg);
                comp.s("b", sb);
                host.changed();
            });
        }

        public void activate_tools() {
            var comp = component();
            host.canvas.component = comp;
            host.canvas.brush_radius = brush_radius;
            host.canvas.brush_feather = brush_feather;
            host.canvas.brush_flow = brush_flow;
            host.canvas.brush_erase = erase_switch.active;
            host.canvas.show_overlay = overlay_switch.active;
            string tool = "";
            if (comp != null) {
                switch (comp.kind) {
                    case "brush": tool = "brush"; break;
                    case "linear": tool = "linear"; break;
                    case "radial": tool = "radial"; break;
                    default: tool = ""; break;
                }
            }
            host.canvas.tool = tool;
            sync();
            host.schedule_render();
        }

        private void rebuild_list() {
            list_group.clear();
            list_group.description = host.params.locals.size == 0 ? _("Masks apply adjustments to part of the photo. Use New Mask to create one.") : "";
            if (host.params.locals.size == 0) return;
            for (int i = 0; i < host.params.locals.size; i++) {
                var l = host.params.locals[i];
                string sub = "";
                foreach (var comp in l.components) sub += (sub == "" ? "" : ", ") + kind_label(comp.kind);
                var row = new ActionRow(l.name != "" ? l.name : _("Mask %d").printf(i + 1), sub, l.components.size > 0 ? kind_icon(l.components[0].kind) : "image-x-generic-symbolic");
                row.add_css_class("photo-edit-list-row");
                if (i == selected) row.add_css_class("selected-mask");
                row.activatable = true;
                int index = i;
                row.activated.connect(() => {
                    selected = index;
                    component_index = 0;
                    activate_tools();
                });
                var eye = new ToggleButton();
                eye.icon_name = l.enabled ? "view-reveal-symbolic" : "view-conceal-symbolic";
                eye.active = l.enabled;
                eye.add_css_class("flat");
                eye.valign = Align.CENTER;
                eye.tooltip_text = _("Show or hide the effect of this mask");
                eye.toggled.connect(() => {
                    if (syncing) return;
                    host.record(_("Mask Visibility"));
                    l.enabled = eye.active;
                    host.changed();
                });
                row.add_suffix(eye);
                list_group.add_row(row);
            }
        }

        private void rebuild_components() {
            components_group.clear();
            var l = local();
            if (l == null) return;
            for (int i = 0; i < l.components.size; i++) {
                var comp = l.components[i];
                var row = new ActionRow(kind_label(comp.kind), null, kind_icon(comp.kind));
                row.add_css_class("photo-edit-list-row");
                if (i == component_index) row.add_css_class("selected-mask");
                row.activatable = true;
                int index = i;
                row.activated.connect(() => {
                    component_index = index;
                    activate_tools();
                });
                if (i > 0) {
                    string[] ids = { "add", "subtract", "intersect" };
                    string[] names = { _("Add"), _("Subtract"), _("Intersect") };
                    for (int m = 0; m < 3; m++) if (ids[m] == comp.mode) row.subtitle = names[m];
                }
                var invert = new ToggleButton();
                invert.icon_name = "singularity-photos-invert-symbolic";
                invert.tooltip_text = _("Invert");
                invert.active = comp.invert;
                invert.add_css_class("flat");
                invert.valign = Align.CENTER;
                invert.toggled.connect(() => {
                    if (syncing) return;
                    host.record(_("Invert Mask"));
                    comp.invert = invert.active;
                    host.changed();
                });
                row.add_suffix(invert);
                var del = new Button.from_icon_name("user-trash-symbolic");
                del.add_css_class("flat");
                del.valign = Align.CENTER;
                del.tooltip_text = _("Remove");
                del.clicked.connect(() => {
                    host.record(_("Remove from Mask"));
                    l.components.remove(comp);
                    component_index = int.max(0, component_index - 1);
                    host.changed();
                    activate_tools();
                });
                row.add_suffix(del);
                components_group.add_row(row);
            }
            var current = component();
            if (current != null && component_index > 0) {
                string[] ids = { "add", "subtract", "intersect" };
                uint active = 0;
                for (uint m = 0; m < 3; m++) if (ids[m] == current.mode) active = m;
                var mode = new IndexChoiceRow(_("Combine Selected Part"), { _("Add"), _("Subtract"), _("Intersect") }, active);
                mode.notify["selected-index"].connect(() => {
                    if (syncing) return;
                    host.record(_("Mask Mode"));
                    current.mode = ids[mode.selected_index];
                    host.changed();
                });
                components_group.add_row(mode);
            }
        }

        public void sync() {
            syncing = true;
            rebuild_list();
            var l = local();
            selected_box.visible = l != null;
            if (l != null) {
                name_row.text = l.name;
                rebuild_components();
                c.sync();
                tool_controls.sync();
                var comp = component();
                string kind = comp != null ? comp.kind : "";
                foreach (var r in brush_rows) r.visible = kind == "brush";
                foreach (var r in radial_rows) r.visible = kind == "radial";
                foreach (var r in color_rows) r.visible = kind == "color";
                foreach (var r in luma_rows) r.visible = kind == "luminance" || kind == "depth";
                switch (kind) {
                    case "brush": tool_hint.label = _("Paint on the photo. Turn on Erase to remove parts of the mask."); break;
                    case "linear": tool_hint.label = _("Drag on the photo from where the effect is full to where it fades out."); break;
                    case "radial": tool_hint.label = _("Drag on the photo to draw an ellipse. Drag its handles to move and resize it."); break;
                    case "sky": tool_hint.label = _("The sky is found automatically. Refine it by adding or subtracting a brush."); break;
                    case "subject": tool_hint.label = _("The main subject is found automatically. Refine it by adding or subtracting a brush."); break;
                    case "color": tool_hint.label = _("Selects areas with a color similar to the sampled one."); break;
                    case "luminance": tool_hint.label = _("Selects areas within a brightness range."); break;
                    case "depth": tool_hint.label = _("Selects areas by distance from the plane in focus, estimated from how sharp each area is. Low values are the sharpest parts."); break;
                    default: tool_hint.label = _("The whole photo is selected."); break;
                }
            }
            syncing = false;
        }
    }

    namespace WorkingSpaceColor {

        public void to_encoded(ref float r, ref float g, ref float b) {
            r = Transfer.linear_to_srgb(r).clamp(0, 1);
            g = Transfer.linear_to_srgb(g).clamp(0, 1);
            b = Transfer.linear_to_srgb(b).clamp(0, 1);
        }
    }

    public class HealPanel : Box {
        private unowned EditView host;
        private DevelopControls c = new DevelopControls();
        private DevelopControls tool = new DevelopControls();
        private ChoiceRow mode;
        private Box selected_box;
        private bool syncing = false;
        private uint render_id = 0;

        public HealPanel(EditView host) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.host = host;
            c.begin_change.connect((label, coalesce) => host.record(label, coalesce));
            c.changed.connect(() => host.changed());
            tool.changed.connect(() => host.canvas.queue_draw());
            host.canvas.spots_changed.connect((finished) => {
                if (host.current_page() != "heal") return;
                if (finished) {
                    auto_source();
                    host.changed();
                    return;
                }
                if (render_id != 0) return;
                render_id = Timeout.add(120, () => {
                    render_id = 0;
                    host.schedule_render();
                    return Source.REMOVE;
                });
            });
            host.canvas.spot_selected.connect((i) => sync());
            build();
        }

        private void build() {
            var group = new PreferencesGroup(_("Brush"), _("Click a blemish to remove it, or drag to set its size. Drag the dashed circle to choose where the texture comes from."));
            mode = new ChoiceRow(_("Mode"));
            mode.add_option("heal", _("Heal"));
            mode.add_option("clone", _("Clone"));
            mode.add_option("fill", _("Remove"));
            mode.chosen.connect((name) => {
                host.canvas.spot_mode = name;
                var s = selected();
                if (s != null && !syncing) {
                    host.record(_("Spot Mode"));
                    s.mode = name;
                    host.changed();
                }
            });
            group.add_row(mode);
            group.add_row(tool.slider(_("Brush Size"), 0.003, 0.15, 0.02, 100, () => host.canvas.spot_radius, (v) => host.canvas.spot_radius = v, (v) => "%.1f".printf(v), 0.001));
            append(group);

            selected_box = new Box(Orientation.VERTICAL, 12);
            var sel = new PreferencesGroup(_("Selected Spot"));
            sel.add_row(c.slider(_("Size"), 0.003, 0.3, 0.02, 100, () => selected() != null ? selected().radius : 0.02, (v) => { if (selected() != null) selected().radius = v; }, (v) => "%.1f".printf(v), 0.001));
            sel.add_row(c.slider(_("Feather"), 0, 1, 0.5, 100, () => selected() != null ? selected().feather : 0.5, (v) => { if (selected() != null) selected().feather = v; }));
            sel.add_row(c.slider(_("Opacity"), 0, 1, 1, 100, () => selected() != null ? selected().opacity : 1, (v) => { if (selected() != null) selected().opacity = v; }));
            var find = new ActionRow(_("Find a New Source"), null, "system-search-symbolic");
            find.activatable = true;
            find.activated.connect(() => {
                var s = selected();
                if (s == null || host.photo == null) return;
                host.record(_("Spot Source"));
                s.auto_source = true;
                Heal.find_source(host.photo.image, s);
                host.changed();
            });
            sel.add_row(find);
            sel.add_row(DevelopControls.action_row(_("Delete Spot"), "user-trash-symbolic", () => delete_selected()));
            selected_box.append(sel);
            append(selected_box);
            group.add_row(DevelopControls.action_row(_("Remove All Spots"), "edit-clear-all-symbolic", () => {
                if (host.params.spots.size == 0) return;
                host.record(_("Remove All Spots"));
                host.params.spots.clear();
                host.canvas.selected_spot = -1;
                host.changed();
            }));
        }

        private SpotEdit? selected() {
            int i = host.canvas.selected_spot;
            if (i < 0 || i >= host.params.spots.size) return null;
            return host.params.spots[i];
        }

        private void auto_source() {
            var s = selected();
            if (s == null || host.photo == null || !s.auto_source || s.mode == "fill") return;
            if ((s.source_x - s.x).abs() > 1e-9 || (s.source_y - s.y).abs() > 1e-9) return;
            Heal.find_source(host.photo.image, s);
        }

        public void delete_selected() {
            var s = selected();
            if (s == null) return;
            host.record(_("Delete Spot"));
            host.params.spots.remove(s);
            host.canvas.selected_spot = -1;
            host.changed();
        }

        public void activate_tools() {
            host.canvas.spots = host.params.spots;
            host.canvas.tool = "heal";
            sync();
        }

        public void sync() {
            syncing = true;
            if (host.canvas.spots != null && host.canvas.spots != host.params.spots) host.canvas.spots = host.params.spots;
            var s = selected();
            selected_box.visible = s != null;
            mode.set_active(s != null ? s.mode : host.canvas.spot_mode);
            c.sync();
            tool.sync();
            syncing = false;
        }
    }

    public class HistoryPanel : Box {
        private unowned EditView host;
        private PreferencesGroup snapshots;
        private PreferencesGroup steps;

        public HistoryPanel(EditView host) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.host = host;
            snapshots = new PreferencesGroup(_("Snapshots"));
            snapshots.add_header_suffix(DevelopControls.header_button("list-add-symbolic", _("Create a Snapshot"), () => create_snapshot()));
            append(snapshots);
            steps = new PreferencesGroup(_("History"));
            append(steps);
            host.params_changed.connect(() => {
                if (host.current_page() == "history") refresh();
            });
        }

        private void create_snapshot() {
            var now = new DateTime.now_local();
            string name = _("Snapshot %s").printf(now.format("%x %X"));
            host.params.snapshots.add(new EditSnapshot(name, host.params));
            host.message(_("Snapshot created"));
            refresh();
        }

        public void refresh() {
            snapshots.clear();
            if (host.params.snapshots.size == 0) {
                var l = new Label(_("Snapshots keep a version of the edits you can return to at any time."));
                l.wrap = true;
                l.xalign = 0;
                l.add_css_class("dim-label");
                snapshots.add_row(DevelopControls.static_row(l));
            }
            foreach (var snap in host.params.snapshots) {
                var when = new DateTime.from_unix_local(snap.time);
                var row = new ActionRow(snap.name, when != null ? when.format("%x %X") : null, "camera-photo-symbolic");
                row.activatable = true;
                var s = snap;
                row.activated.connect(() => {
                    var restored = s.restore();
                    if (restored == null) return;
                    host.record(_("Snapshot"));
                    var snaps = host.params.snapshots;
                    host.params.assign(restored);
                    host.params.snapshots = snaps;
                    host.changed();
                });
                var del = new Button.from_icon_name("user-trash-symbolic");
                del.add_css_class("flat");
                del.valign = Align.CENTER;
                del.tooltip_text = _("Delete");
                del.clicked.connect(() => {
                    host.params.snapshots.remove(s);
                    refresh();
                });
                row.add_suffix(del);
                snapshots.add_row(row);
            }
            steps.clear();
            var labels = host.history_labels();
            if (labels.size == 0) {
                var l = new Label(_("Every change you make is listed here."));
                l.add_css_class("dim-label");
                l.xalign = 0;
                l.wrap = true;
                steps.add_row(DevelopControls.static_row(l));
                return;
            }
            for (int i = labels.size - 1; i >= 0 && i >= labels.size - 40; i--) {
                var row = new ActionRow(labels[i]);
                row.activatable = true;
                row.tooltip_text = _("Go back to the state before this step");
                int index = i;
                row.activated.connect(() => host.jump_to_history(index));
                steps.add_row(row);
            }
        }
    }

    public class PresetsPanel : Box {
        private unowned EditView host;
        private Box groups_box;
        private double amount = 1.0;
        private DevelopControls c = new DevelopControls();
        private DevelopPreset? last_applied = null;
        private EditParams? before_preset = null;

        public PresetsPanel(EditView host) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.host = host;
            var top = new PreferencesGroup(_("Presets"));
            top.add_header_suffix(DevelopControls.header_button("document-save-symbolic", _("Save Current Settings as a Preset"), () => save_dialog()));
            top.add_header_suffix(DevelopControls.header_button("document-open-symbolic", _("Import a Lightroom or Camera Raw Preset"), () => import_preset()));
            c.changed.connect(() => {
                if (last_applied == null || before_preset == null) return;
                host.record(_("Preset Amount"), true);
                host.params.assign(before_preset);
                DevelopPresets.apply(host.params, last_applied, amount);
                host.changed();
            });
            top.add_row(c.slider(_("Amount"), 0, 2, 1, 100, () => amount, (v) => amount = v, (v) => "%d".printf((int) Math.round(v))));
            var copy = new ActionRow(_("Copy Settings…"), _("Shift+Ctrl+C"), "edit-copy-symbolic");
            copy.activatable = true;
            copy.activated.connect(() => copy_settings());
            top.add_row(copy);
            var paste = new ActionRow(_("Paste Settings"), _("Shift+Ctrl+V"), "edit-paste-symbolic");
            paste.activatable = true;
            paste.activated.connect(() => host.paste_settings());
            top.add_row(paste);
            append(top);
            groups_box = new Box(Orientation.VERTICAL, 12);
            append(groups_box);
            rebuild();
        }

        public void rebuild() {
            Widget? child;
            while ((child = groups_box.get_first_child()) != null) groups_box.remove(child);
            var by_group = new Gee.TreeMap<string, Gee.ArrayList<DevelopPreset>>();
            var order = new Gee.ArrayList<string>();
            foreach (var p in DevelopPresets.all()) {
                if (!by_group.has_key(p.group)) {
                    by_group[p.group] = new Gee.ArrayList<DevelopPreset>();
                    order.add(p.group);
                }
                by_group[p.group].add(p);
            }
            foreach (var g in order) {
                var group = new PreferencesGroup(g);
                foreach (var p in by_group[g]) {
                    var row = new ActionRow(p.name);
                    row.activatable = true;
                    var preset = p;
                    row.activated.connect(() => {
                        host.record(_("Preset: %s").printf(preset.name));
                        before_preset = host.params.copy();
                        last_applied = preset;
                        DevelopPresets.apply(host.params, preset, amount);
                        host.changed();
                    });
                    if (!p.builtin) {
                        var del = new Button.from_icon_name("user-trash-symbolic");
                        del.add_css_class("flat");
                        del.valign = Align.CENTER;
                        del.tooltip_text = _("Delete Preset");
                        del.clicked.connect(() => {
                            DevelopPresets.remove_user(preset);
                            rebuild();
                        });
                        row.add_suffix(del);
                    }
                    group.add_row(row);
                }
                groups_box.append(group);
            }
        }

        public void sync() {
            c.sync();
        }

        private AppDialog groups_dialog(string title, string action, bool with_name, owned GroupsCallback done) {
            var app = (Gtk.Application) GLib.Application.get_default();
            var dlg = new AppDialog(app, true, false);
            dlg.set_title(title);
            dlg.transient_for = host.get_root() as Gtk.Window;
            dlg.set_default_size(420, 0);
            var box = new Box(Orientation.VERTICAL, 12);
            box.margin_top = 16;
            box.margin_bottom = 20;
            box.margin_start = 20;
            box.margin_end = 20;
            EntryRow? name = null;
            if (with_name) {
                var ng = new PreferencesGroup(_("Preset"));
                name = new EntryRow(_("Name"));
                ng.add_row(name);
                box.append(ng);
            }
            var group = new PreferencesGroup(_("Settings to Include"));
            var switches = new Gee.HashMap<string, Switch>();
            foreach (var g in SettingsClipboard.GROUPS) {
                var sw = new Switch();
                sw.active = g != "crop" && g != "spots" && g != "masks";
                sw.valign = Align.CENTER;
                var row = new ActionRow(SettingsClipboard.label(g));
                row.add_suffix(sw);
                group.add_row(row);
                switches[g] = sw;
            }
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.max_content_height = 420;
            scroll.child = group;
            box.append(scroll);
            var buttons = new Box(Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            var cancel = dlg.add_cancel_button();
            cancel.unparent();
            buttons.append(cancel);
            var ok = new Button.with_label(action);
            ok.add_css_class("suggested-action");
            ok.clicked.connect(() => {
                string[] chosen = {};
                foreach (var e in switches.entries) if (e.value.active) chosen += e.key;
                done(chosen, name != null ? name.text.strip() : "");
                dlg.close_dialog();
            });
            buttons.append(ok);
            box.append(buttons);
            dlg.content_box.append(box);
            return dlg;
        }

        private delegate void GroupsCallback(string[] groups, string name);

        public void copy_settings() {
            var dlg = groups_dialog(_("Copy Settings"), _("Copy"), false, (groups, name) => {
                SettingsClipboard.copy(host.params, groups);
                host.message(_("Settings copied"));
            });
            dlg.present();
        }

        private void save_dialog() {
            var dlg = groups_dialog(_("New Preset"), _("Save"), true, (groups, name) => {
                try {
                    DevelopPresets.save_user(name == "" ? _("My Preset") : name, "", host.params, groups);
                    rebuild();
                    host.message(_("Preset saved"));
                } catch (Error e) {
                    host.message(_("Cannot save the preset: %s").printf(e.message));
                }
            });
            dlg.present();
        }

        private void import_preset() {
            var dialog = new FileDialog();
            dialog.title = _("Import Presets");
            var filter = new FileFilter();
            filter.name = _("XMP Presets");
            filter.add_pattern("*.xmp");
            filter.add_pattern("*.XMP");
            var filters = new GLib.ListStore(typeof(FileFilter));
            filters.append(filter);
            dialog.filters = filters;
            dialog.open_multiple.begin(host.get_root() as Gtk.Window, null, (obj, res) => {
                try {
                    var files = dialog.open_multiple.end(res);
                    int ok = 0;
                    string last_error = "";
                    for (uint i = 0; i < files.get_n_items(); i++) {
                        try {
                            DevelopPresets.import_xmp((File) files.get_item(i));
                            ok++;
                        } catch (Error e) {
                            last_error = e.message;
                        }
                    }
                    rebuild();
                    if (ok > 0) host.message(ngettext("Imported %d preset", "Imported %d presets", ok).printf(ok));
                    else host.message(_("No preset was imported: %s").printf(last_error));
                } catch (Error e) {
                }
            });
        }
    }
}
