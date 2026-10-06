namespace Singularity.Apps.Photos {

    namespace CrsMapping {

        public const string NS_RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";

        private struct Entry {
            public unowned string target;
            public unowned string crs;
            public double scale;
        }

        private Entry[]? table = null;

        private unowned Entry[] entries() {
            if (table != null) return table;
            Entry[] t = {
                { "adj:exposure", "Exposure2012", 2 },
                { "adj:contrast", "Contrast2012", 100 },
                { "adj:highlights", "Highlights2012", 100 },
                { "adj:shadows", "Shadows2012", 100 },
                { "adj:whites", "Whites2012", 100 },
                { "adj:blacks", "Blacks2012", 100 },
                { "adj:texture", "Texture", 100 },
                { "adj:clarity", "Clarity2012", 100 },
                { "adj:dehaze", "Dehaze", 100 },
                { "adj:vibrance", "Vibrance", 100 },
                { "adj:saturation", "Saturation", 100 },
                { "adj:sharpness", "Sharpness", 150 },
                { "adj:vignette", "PostCropVignetteAmount", -100 },
                { "dev:tone.shadows", "ParametricShadows", 100 },
                { "dev:tone.darks", "ParametricDarks", 100 },
                { "dev:tone.lights", "ParametricLights", 100 },
                { "dev:tone.highlights", "ParametricHighlights", 100 },
                { "dev:tone.split1", "ParametricShadowSplit", 100 },
                { "dev:tone.split2", "ParametricMidtoneSplit", 100 },
                { "dev:tone.split3", "ParametricHighlightSplit", 100 },
                { "dev:grading.shadows.hue", "ColorGradeShadowHue", 1 },
                { "dev:grading.shadows.sat", "ColorGradeShadowSat", 100 },
                { "dev:grading.shadows.lum", "ColorGradeShadowLum", 100 },
                { "dev:grading.midtones.hue", "ColorGradeMidtoneHue", 1 },
                { "dev:grading.midtones.sat", "ColorGradeMidtoneSat", 100 },
                { "dev:grading.midtones.lum", "ColorGradeMidtoneLum", 100 },
                { "dev:grading.highlights.hue", "ColorGradeHighlightHue", 1 },
                { "dev:grading.highlights.sat", "ColorGradeHighlightSat", 100 },
                { "dev:grading.highlights.lum", "ColorGradeHighlightLum", 100 },
                { "dev:grading.global.hue", "ColorGradeGlobalHue", 1 },
                { "dev:grading.global.sat", "ColorGradeGlobalSat", 100 },
                { "dev:grading.global.lum", "ColorGradeGlobalLum", 100 },
                { "dev:grading.blending", "ColorGradeBlending", 100 },
                { "dev:grading.balance", "ColorGradeBalance", 100 },
                { "dev:detail.sharpen.radius", "SharpenRadius", 1 },
                { "dev:detail.sharpen.detail", "SharpenDetail", 100 },
                { "dev:detail.sharpen.masking", "SharpenEdgeMasking", 100 },
                { "dev:detail.noise.amount", "LuminanceSmoothing", 100 },
                { "dev:detail.noise.detail", "LuminanceNoiseReductionDetail", 100 },
                { "dev:detail.noise.contrast", "LuminanceNoiseReductionContrast", 100 },
                { "dev:detail.color.amount", "ColorNoiseReduction", 100 },
                { "dev:detail.color.detail", "ColorNoiseReductionDetail", 100 },
                { "dev:detail.color.smoothness", "ColorNoiseReductionSmoothness", 100 },
                { "dev:lens.profile", "LensProfileEnable", 1 },
                { "dev:lens.profile.distortion", "LensProfileDistortionScale", 100 },
                { "dev:lens.profile.vignette", "LensProfileVignettingScale", 100 },
                { "dev:lens.ca", "AutoLateralCA", 1 },
                { "dev:lens.distortion", "LensManualDistortionAmount", 100 },
                { "dev:lens.vignette", "VignetteAmount", 100 },
                { "dev:lens.vignette.midpoint", "VignetteMidpoint", 100 },
                { "dev:lens.defringe", "DefringePurpleAmount", 20 },
                { "dev:transform.vertical", "PerspectiveVertical", 100 },
                { "dev:transform.horizontal", "PerspectiveHorizontal", 100 },
                { "dev:transform.rotate", "PerspectiveRotate", 1 },
                { "dev:transform.aspect", "PerspectiveAspect", 100 },
                { "dev:transform.scale", "PerspectiveScale", 100 },
                { "dev:transform.x", "PerspectiveX", 100 },
                { "dev:transform.y", "PerspectiveY", 100 },
                { "dev:effects.vignette.midpoint", "PostCropVignetteMidpoint", 100 },
                { "dev:effects.vignette.roundness", "PostCropVignetteRoundness", 100 },
                { "dev:effects.vignette.feather", "PostCropVignetteFeather", 100 },
                { "dev:effects.vignette.highlights", "PostCropVignetteHighlightContrast", 100 },
                { "dev:effects.grain.amount", "GrainAmount", 100 },
                { "dev:effects.grain.size", "GrainSize", 100 },
                { "dev:effects.grain.roughness", "GrainFrequency", 100 },
                { "dev:calibration.shadows.tint", "ShadowTint", 100 },
                { "dev:calibration.red.hue", "RedHue", 100 },
                { "dev:calibration.red.sat", "RedSaturation", 100 },
                { "dev:calibration.green.hue", "GreenHue", 100 },
                { "dev:calibration.green.sat", "GreenSaturation", 100 },
                { "dev:calibration.blue.hue", "BlueHue", 100 },
                { "dev:calibration.blue.sat", "BlueSaturation", 100 }
            };
            string[] names = { "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta" };
            for (int i = 0; i < 8; i++) {
                t += Entry() { target = intern("dev:hsl.hue." + HSL_BANDS[i]), crs = intern("HueAdjustment" + names[i]), scale = 100 };
                t += Entry() { target = intern("dev:hsl.sat." + HSL_BANDS[i]), crs = intern("SaturationAdjustment" + names[i]), scale = 100 };
                t += Entry() { target = intern("dev:hsl.lum." + HSL_BANDS[i]), crs = intern("LuminanceAdjustment" + names[i]), scale = 100 };
                t += Entry() { target = intern("dev:bw." + HSL_BANDS[i]), crs = intern("GrayMixer" + names[i]), scale = 100 };
            }
            table = t;
            return table;
        }

        private unowned string intern(string s) {
            return Quark.from_string(s).to_string();
        }

        private string num(double v) {
            char[] buf = new char[double.DTOSTR_BUF_SIZE];
            string s = Math.round(v * 1e6).abs() < 0.5 ? "0" : ((double) Math.round(v * 1e6) / 1e6).format(buf, "%.6g");
            return v > 0 && !s.has_prefix("+") ? "+" + s : s;
        }

        private double target_value(EditParams p, string target) {
            if (target.has_prefix("adj:")) {
                var a = Adjustment.from_key(target.substring(4));
                return a != null ? p.get_value(a) : 0;
            }
            return p.develop.get(target.substring(4));
        }

        private void set_target(EditParams p, string target, double v) {
            if (target.has_prefix("adj:")) {
                var a = Adjustment.from_key(target.substring(4));
                if (a != null) p.set_value(a, v);
                return;
            }
            p.develop.set(target.substring(4), v);
        }

        private double target_default(string target) {
            if (target.has_prefix("adj:")) return 0;
            var k = DevelopSettings.find_key(target.substring(4));
            return k != null ? k.default_value : 0;
        }

        private string[] curve_items(CurvePoints c) {
            string[] items = {};
            var xs = c.xs;
            var ys = c.ys;
            bool has_start = xs.length > 0 && xs[0] <= 1e-6;
            bool has_end = xs.length > 0 && xs[xs.length - 1] >= 1 - 1e-6;
            if (!has_start) items += "0, 0";
            for (int i = 0; i < xs.length; i++) items += "%d, %d".printf((int) Math.round(xs[i] * 255), (int) Math.round(ys[i] * 255));
            if (!has_end) items += "255, 255";
            return items;
        }

        private CurvePoints parse_curve(string[] items) {
            double[] x = {}, y = {};
            foreach (var it in items) {
                var parts = it.split(",");
                if (parts.length != 2) continue;
                double px = double.parse(parts[0].strip()) / 255.0, py = double.parse(parts[1].strip()) / 255.0;
                if ((px < 1e-6 && py < 1e-6) || (px > 1 - 1e-6 && py > 1 - 1e-6)) continue;
                x += px.clamp(0, 1);
                y += py.clamp(0, 1);
            }
            var c = new CurvePoints();
            c.set_points(x, y);
            return c;
        }

        public void write(EditParams p, XmpPacket x, bool is_raw) {
            const string NS = XmpPacket.NS_CRS;
            x.set_simple(NS, "crs", "Version", "15.0");
            x.set_simple(NS, "crs", "ProcessVersion", "11.0");
            foreach (unowned Entry e in entries()) {
                double v = target_value(p, e.target);
                if ((v - target_default(e.target)).abs() < 1e-9 && e.target != "adj:exposure") {
                    x.remove(NS, e.crs);
                    continue;
                }
                x.set_simple(NS, "crs", e.crs, num(v * e.scale));
            }
            string mode = p.develop.get_string("wb.mode", "as-shot");
            if (is_raw) {
                x.set_simple(NS, "crs", "WhiteBalance", mode == "auto" ? "Auto" : mode == "as-shot" ? "As Shot" : "Custom");
                if (mode != "as-shot" && mode != "auto") {
                    x.set_simple(NS, "crs", "Temperature", "%d".printf((int) Math.round(p.develop.get("wb.temperature"))));
                    x.set_simple(NS, "crs", "Tint", num(p.develop.get("wb.tint")));
                } else {
                    x.remove(NS, "Temperature");
                    x.remove(NS, "Tint");
                }
            } else {
                x.set_simple(NS, "crs", "IncrementalTemperature", num(p.get_value(Adjustment.WARMTH) * 100));
                x.set_simple(NS, "crs", "IncrementalTint", num(p.get_value(Adjustment.TINT) * 100));
            }
            x.set_simple(NS, "crs", "ConvertToGrayscale", p.develop.get_string("treatment") == "bw" || p.filter == "mono" || p.filter == "noir" ? "True" : "False");
            string camera_profile = p.develop.get_string("camera.profile");
            if (camera_profile != "") x.set_simple(NS, "crs", "CameraProfile", camera_profile);
            else x.remove(NS, "CameraProfile");
            string upright = p.develop.get_string("upright", "off");
            string[] modes = { "off", "auto", "level", "vertical", "full", "guided" };
            for (int i = 0; i < modes.length; i++) if (modes[i] == upright) x.set_simple(NS, "crs", "PerspectiveUpright", i.to_string());
            string[] channels = { "master", "red", "green", "blue" };
            string[] names = { "ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue" };
            bool custom = false;
            for (int i = 0; i < 4; i++) {
                if (p.develop.has_curve(channels[i])) {
                    x.set_list(NS, "crs", names[i], "Seq", curve_items(p.develop.curve(channels[i])));
                    custom = true;
                } else {
                    x.set_list(NS, "crs", names[i], "Seq", { "0, 0", "255, 255" });
                }
            }
            x.set_simple(NS, "crs", "ToneCurveName2012", custom ? "Custom" : "Linear");
            if (p.has_crop() || p.straighten.abs() > 1e-9) {
                x.set_simple(NS, "crs", "HasCrop", "True");
                x.set_simple(NS, "crs", "CropLeft", num(p.crop_x));
                x.set_simple(NS, "crs", "CropTop", num(p.crop_y));
                x.set_simple(NS, "crs", "CropRight", num(p.crop_x + p.crop_w));
                x.set_simple(NS, "crs", "CropBottom", num(p.crop_y + p.crop_h));
                x.set_simple(NS, "crs", "CropAngle", num(p.straighten));
            } else {
                x.set_simple(NS, "crs", "HasCrop", "False");
            }
            int orientation = orientation_for(p.quarter_turns, p.flip);
            if (orientation != 1) x.set_simple(XmpPacket.NS_TIFF, "tiff", "Orientation", orientation.to_string());
            else x.remove(XmpPacket.NS_TIFF, "Orientation");
            write_locals(p, x);
            write_spots(p, x);
            x.set_simple(NS, "crs", "HasSettings", "True");
            x.set_simple(XmpPacket.NS_SINTY, "sinty", "Develop", p.to_json());
        }

        public int orientation_for(int turns, bool flip) {
            int t = ((turns % 4) + 4) % 4;
            if (!flip) {
                int[] plain = { 1, 6, 3, 8 };
                return plain[t];
            }
            int[] mirrored = { 2, 7, 4, 5 };
            return mirrored[t];
        }

        public void turns_for(int orientation, out int turns, out bool flip) {
            switch (orientation) {
                case 2: turns = 0; flip = true; return;
                case 3: turns = 2; flip = false; return;
                case 4: turns = 2; flip = true; return;
                case 5: turns = 3; flip = true; return;
                case 6: turns = 1; flip = false; return;
                case 7: turns = 1; flip = true; return;
                case 8: turns = 3; flip = false; return;
                default: turns = 0; flip = false; return;
            }
        }

        private string xml_escape(string s) {
            return Markup.escape_text(s);
        }

        private string local_attributes(LocalAdjustment l) {
            var sb = new StringBuilder();
            sb.append_printf(" crs:What=\"Correction\" crs:CorrectionAmount=\"%s\" crs:CorrectionActive=\"%s\"", num(l.amount), l.enabled ? "true" : "false");
            if (l.name != "") sb.append_printf(" crs:CorrectionName=\"%s\"", xml_escape(l.name));
            string[,] map = {
                { "exposure", "LocalExposure2012", "0.25" }, { "contrast", "LocalContrast2012", "1" }, { "highlights", "LocalHighlights2012", "1" },
                { "shadows", "LocalShadows2012", "1" }, { "whites", "LocalWhites2012", "1" }, { "blacks", "LocalBlacks2012", "1" },
                { "clarity", "LocalClarity2012", "1" }, { "dehaze", "LocalDehaze", "1" }, { "texture", "LocalTexture", "1" },
                { "saturation", "LocalSaturation", "1" }, { "temperature", "LocalTemperature", "1" }, { "tint", "LocalTint", "1" },
                { "sharpness", "LocalSharpness", "1" }, { "noise", "LocalLuminanceNoise", "1" }, { "defringe", "LocalDefringe", "1" },
                { "hue", "LocalHue", "0.005555555555555556" }
            };
            for (int i = 0; i < map.length[0]; i++) {
                double v = l.get(map[i, 0]);
                if (v.abs() < 1e-9) continue;
                sb.append_printf(" crs:%s=\"%s\"", map[i, 1], num(v * double.parse(map[i, 2])));
            }
            return sb.str;
        }

        private void write_locals(EditParams p, XmpPacket x) {
            var gradients = new StringBuilder();
            var circles = new StringBuilder();
            var paints = new StringBuilder();
            foreach (var l in p.locals) {
                if (l.components.size != 1) continue;
                var c = l.components[0];
                if (c.kind == "linear") {
                    gradients.append_printf("<rdf:li><rdf:Description%s><crs:CorrectionMasks><rdf:Seq><rdf:li crs:What=\"Mask/Gradient\" crs:MaskValue=\"1\" crs:ZeroX=\"%s\" crs:ZeroY=\"%s\" crs:FullX=\"%s\" crs:FullY=\"%s\"/></rdf:Seq></crs:CorrectionMasks></rdf:Description></rdf:li>",
                        local_attributes(l), num(c.g("x1", 0.5)), num(c.g("y1", 0.7)), num(c.g("x0", 0.5)), num(c.g("y0", 0.3)));
                } else if (c.kind == "radial") {
                    double cx = c.g("cx", 0.5), cy = c.g("cy", 0.5), rx = c.g("rx", 0.25), ry = c.g("ry", 0.25);
                    circles.append_printf("<rdf:li><rdf:Description%s><crs:CorrectionMasks><rdf:Seq><rdf:li crs:What=\"Mask/CircularGradient\" crs:MaskValue=\"1\" crs:Top=\"%s\" crs:Left=\"%s\" crs:Bottom=\"%s\" crs:Right=\"%s\" crs:Angle=\"%s\" crs:Midpoint=\"50\" crs:Roundness=\"0\" crs:Feather=\"%s\" crs:Flipped=\"%s\"/></rdf:Seq></crs:CorrectionMasks></rdf:Description></rdf:li>",
                        local_attributes(l), num(cy - ry), num(cx - rx), num(cy + ry), num(cx + rx), num(c.g("angle", 0)), num(c.g("feather", 0.5) * 100), c.invert ? "false" : "true");
                } else if (c.kind == "brush") {
                    var masks = new StringBuilder();
                    foreach (var st in c.strokes) {
                        var dabs = new StringBuilder();
                        for (int i = 0; i + 1 < st.points.length; i += 2) dabs.append_printf("<rdf:li>d %s %s</rdf:li>", num(st.points[i]).replace("+", ""), num(st.points[i + 1]).replace("+", ""));
                        masks.append_printf("<rdf:li crs:What=\"Mask/Paint\" crs:MaskValue=\"%s\" crs:Radius=\"%s\" crs:Flow=\"%s\" crs:CenterWeight=\"%s\"><crs:Dabs><rdf:Seq>%s</rdf:Seq></crs:Dabs></rdf:li>",
                            st.erase ? "0" : "1", num(st.radius), num(st.flow), num(1 - st.feather), dabs.str);
                    }
                    paints.append_printf("<rdf:li><rdf:Description%s><crs:CorrectionMasks><rdf:Seq>%s</rdf:Seq></crs:CorrectionMasks></rdf:Description></rdf:li>", local_attributes(l), masks.str);
                }
            }
            const string NS = XmpPacket.NS_CRS;
            if (gradients.len > 0) x.set_raw(NS, "crs", "GradientBasedCorrections", "<rdf:Seq>" + gradients.str + "</rdf:Seq>");
            else x.remove(NS, "GradientBasedCorrections");
            if (circles.len > 0) x.set_raw(NS, "crs", "CircularGradientBasedCorrections", "<rdf:Seq>" + circles.str + "</rdf:Seq>");
            else x.remove(NS, "CircularGradientBasedCorrections");
            if (paints.len > 0) x.set_raw(NS, "crs", "PaintBasedCorrections", "<rdf:Seq>" + paints.str + "</rdf:Seq>");
            else x.remove(NS, "PaintBasedCorrections");
        }

        private void write_spots(EditParams p, XmpPacket x) {
            string[] items = {};
            foreach (var s in p.spots) {
                if (s.mode == "fill") continue;
                items += "centerX = %.6f, centerY = %.6f, radius = %.6f, sourceState = %s, sourceX = %.6f, sourceY = %.6f, spotType = %s, opacity = %.6f".printf(
                    s.x, s.y, s.radius, s.auto_source ? "sourceAutoComputed" : "sourceSetExplicitly", s.source_x, s.source_y, s.mode, s.opacity);
            }
            if (items.length > 0) x.set_list(XmpPacket.NS_CRS, "crs", "RetouchInfo", "Seq", items);
            else x.remove(XmpPacket.NS_CRS, "RetouchInfo");
        }

        public void clear(XmpPacket x) {
            foreach (unowned Entry e in entries()) x.remove(XmpPacket.NS_CRS, e.crs);
            string[] extra = { "Version", "ProcessVersion", "WhiteBalance", "Temperature", "Tint", "IncrementalTemperature", "IncrementalTint",
                "ConvertToGrayscale", "PerspectiveUpright", "CameraProfile", "ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue",
                "ToneCurveName2012", "HasCrop", "CropLeft", "CropTop", "CropRight", "CropBottom", "CropAngle", "GradientBasedCorrections",
                "CircularGradientBasedCorrections", "PaintBasedCorrections", "RetouchInfo", "HasSettings" };
            foreach (var name in extra) x.remove(XmpPacket.NS_CRS, name);
            x.remove(XmpPacket.NS_TIFF, "Orientation");
            x.remove(XmpPacket.NS_SINTY, "Develop");
        }

        public bool has_settings(XmpPacket x) {
            if (x.get_simple(XmpPacket.NS_SINTY, "Develop") != null) return true;
            foreach (unowned Entry e in entries()) if (x.get_simple(XmpPacket.NS_CRS, e.crs) != null) return true;
            return x.get_simple(XmpPacket.NS_CRS, "WhiteBalance") != null || x.get_list(XmpPacket.NS_CRS, "ToneCurvePV2012").length > 0;
        }

        public EditParams read(XmpPacket x, out string[] groups) {
            string? own = x.get_simple(XmpPacket.NS_SINTY, "Develop");
            if (own != null) {
                try {
                    var p = EditParams.from_json(own);
                    groups = SettingsClipboard.GROUPS;
                    return p;
                } catch (Error e) {
                }
            }
            var p = new EditParams();
            var present = new Gee.HashSet<string>();
            const string NS = XmpPacket.NS_CRS;
            foreach (unowned Entry e in entries()) {
                string? v = x.get_simple(NS, e.crs);
                if (v == null) continue;
                set_target(p, e.target, double.parse(v) / e.scale);
                present.add(EditParamsGroups.group_of(e.target));
            }
            string? wb = x.get_simple(NS, "WhiteBalance");
            if (wb != null) {
                present.add("color");
                if (wb == "Auto") p.develop.set_string("wb.mode", "auto");
                else if (wb == "As Shot") p.develop.set_string("wb.mode", null);
                else {
                    p.develop.set_string("wb.mode", "custom");
                    string? t = x.get_simple(NS, "Temperature");
                    string? ti = x.get_simple(NS, "Tint");
                    if (t != null) p.develop.set("wb.temperature", double.parse(t));
                    if (ti != null) p.develop.set("wb.tint", double.parse(ti));
                }
            }
            string? it = x.get_simple(NS, "IncrementalTemperature");
            if (it != null) {
                p.set_value(Adjustment.WARMTH, double.parse(it) / 100);
                present.add("color");
            }
            string? itint = x.get_simple(NS, "IncrementalTint");
            if (itint != null) {
                p.set_value(Adjustment.TINT, double.parse(itint) / 100);
                present.add("color");
            }
            string? gray = x.get_simple(NS, "ConvertToGrayscale");
            if (gray != null) {
                if (gray.down() == "true") p.develop.set_string("treatment", "bw");
                present.add("color");
            }
            string? camera_profile = x.get_simple(NS, "CameraProfile");
            if (camera_profile != null && camera_profile != "" && !camera_profile.has_prefix("Adobe")) {
                p.develop.set_string("camera.profile", camera_profile);
                present.add("color");
            }
            string? upright = x.get_simple(NS, "PerspectiveUpright");
            if (upright != null) {
                string[] modes = { "off", "auto", "level", "vertical", "full", "guided" };
                int u = int.parse(upright);
                if (u > 0 && u < modes.length) p.develop.set_string("upright", modes[u]);
                present.add("geometry");
            }
            string[] channels = { "master", "red", "green", "blue" };
            string[] names = { "ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue" };
            for (int i = 0; i < 4; i++) {
                var items = x.get_list(NS, names[i]);
                if (items.length == 0) continue;
                present.add("curve");
                var c = parse_curve(items);
                if (!c.is_identity()) p.develop.curves[channels[i]] = c;
            }
            string? has_crop = x.get_simple(NS, "HasCrop");
            if (has_crop != null && has_crop.down() == "true") {
                double l = double.parse(x.get_simple(NS, "CropLeft") ?? "0"), t = double.parse(x.get_simple(NS, "CropTop") ?? "0");
                double r = double.parse(x.get_simple(NS, "CropRight") ?? "1"), b = double.parse(x.get_simple(NS, "CropBottom") ?? "1");
                p.set_crop(l, t, r - l, b - t);
                p.straighten = double.parse(x.get_simple(NS, "CropAngle") ?? "0").clamp(-EditParams.MAX_STRAIGHTEN, EditParams.MAX_STRAIGHTEN);
                present.add("crop");
            }
            string? orient = x.get_simple(XmpPacket.NS_TIFF, "Orientation");
            if (orient != null) {
                int turns;
                bool flip;
                turns_for(int.parse(orient), out turns, out flip);
                p.quarter_turns = turns;
                p.flip = flip;
            }
            read_locals(x, p, present);
            var retouch = x.get_list(NS, "RetouchInfo");
            foreach (var item in retouch) {
                var s = new SpotEdit();
                foreach (var part in item.split(",")) {
                    var kv = part.split("=");
                    if (kv.length != 2) continue;
                    string k = kv[0].strip(), v = kv[1].strip();
                    switch (k) {
                        case "centerX": s.x = double.parse(v); break;
                        case "centerY": s.y = double.parse(v); break;
                        case "radius": s.radius = double.parse(v).clamp(0.001, 0.5); break;
                        case "sourceX": s.source_x = double.parse(v); break;
                        case "sourceY": s.source_y = double.parse(v); break;
                        case "spotType": s.mode = v == "clone" ? "clone" : "heal"; break;
                        case "opacity": s.opacity = double.parse(v).clamp(0, 1); break;
                        case "sourceState": s.auto_source = v != "sourceSetExplicitly"; break;
                        default: break;
                    }
                }
                p.spots.add(s);
                present.add("spots");
            }
            groups = present.to_array();
            return p;
        }

        private Xml.Doc* parse_fragment(string raw) {
            string wrapped = "<x xmlns:rdf=\"%s\" xmlns:crs=\"%s\">%s</x>".printf(NS_RDF, XmpPacket.NS_CRS, raw);
            return Xml.Parser.read_memory(wrapped, wrapped.length, null, null, Xml.ParserOption.NONET | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING);
        }

        private string? attr(Xml.Node* n, string name) {
            for (Xml.Attr* a = n->properties; a != null; a = a->next) {
                if (a->name == name && a->ns != null && a->ns->href == XmpPacket.NS_CRS) return a->children != null ? a->children->content : "";
            }
            for (Xml.Node* c = n->children; c != null; c = c->next) {
                if (c->type == Xml.ElementType.ELEMENT_NODE && c->name == name && c->ns != null && c->ns->href == XmpPacket.NS_CRS) return c->get_content();
            }
            return null;
        }

        private double attr_d(Xml.Node* n, string name, double fallback) {
            string? v = attr(n, name);
            return v != null ? double.parse(v) : fallback;
        }

        private void collect(Xml.Node* n, string name, Gee.ArrayList<Xml.Node*> out_list) {
            for (Xml.Node* c = n->children; c != null; c = c->next) {
                if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (c->name == name) out_list.add(c);
                collect(c, name, out_list);
            }
        }

        private Xml.Node* description_of(Xml.Node* li) {
            for (Xml.Node* c = li->children; c != null; c = c->next) {
                if (c->type == Xml.ElementType.ELEMENT_NODE && c->name == "Description") return c;
            }
            return li;
        }

        private void read_local_values(Xml.Node* d, LocalAdjustment l) {
            string[,] map = {
                { "exposure", "LocalExposure2012", "4" }, { "contrast", "LocalContrast2012", "1" }, { "highlights", "LocalHighlights2012", "1" },
                { "shadows", "LocalShadows2012", "1" }, { "whites", "LocalWhites2012", "1" }, { "blacks", "LocalBlacks2012", "1" },
                { "clarity", "LocalClarity2012", "1" }, { "dehaze", "LocalDehaze", "1" }, { "texture", "LocalTexture", "1" },
                { "saturation", "LocalSaturation", "1" }, { "temperature", "LocalTemperature", "1" }, { "tint", "LocalTint", "1" },
                { "sharpness", "LocalSharpness", "1" }, { "noise", "LocalLuminanceNoise", "1" }, { "defringe", "LocalDefringe", "1" },
                { "hue", "LocalHue", "180" }
            };
            for (int i = 0; i < map.length[0]; i++) {
                string? v = attr(d, map[i, 1]);
                if (v != null) l.set(map[i, 0], double.parse(v) * double.parse(map[i, 2]));
            }
            l.amount = attr_d(d, "CorrectionAmount", 1).clamp(0, 2);
            string? active = attr(d, "CorrectionActive");
            l.enabled = active == null || active.down() == "true";
            l.name = attr(d, "CorrectionName") ?? "";
        }

        private void read_locals(XmpPacket x, EditParams p, Gee.HashSet<string> present) {
            string[] props = { "GradientBasedCorrections", "CircularGradientBasedCorrections", "PaintBasedCorrections" };
            foreach (var prop in props) {
                string? raw = x.get_raw(XmpPacket.NS_CRS, prop);
                if (raw == null) continue;
                var doc = parse_fragment(raw);
                if (doc == null) continue;
                var root = doc->get_root_element();
                Xml.Node* seq = null;
                for (Xml.Node* c = root->children; c != null; c = c->next) if (c->type == Xml.ElementType.ELEMENT_NODE) { seq = c; break; }
                if (seq != null) {
                    for (Xml.Node* li = seq->children; li != null; li = li->next) {
                        if (li->type != Xml.ElementType.ELEMENT_NODE) continue;
                        var d = description_of(li);
                        var l = new LocalAdjustment();
                        read_local_values(d, l);
                        var masks = new Gee.ArrayList<Xml.Node*>();
                        collect(d, "li", masks);
                        MaskComponent? brush = null;
                        foreach (var m in masks) {
                            string what = attr(m, "What") ?? "";
                            if (what == "Mask/Gradient") {
                                var c = new MaskComponent("linear");
                                c.s("x0", attr_d(m, "FullX", 0.5));
                                c.s("y0", attr_d(m, "FullY", 0.3));
                                c.s("x1", attr_d(m, "ZeroX", 0.5));
                                c.s("y1", attr_d(m, "ZeroY", 0.7));
                                l.components.add(c);
                            } else if (what == "Mask/CircularGradient") {
                                var c = new MaskComponent("radial");
                                double top = attr_d(m, "Top", 0.25), left = attr_d(m, "Left", 0.25), bottom = attr_d(m, "Bottom", 0.75), right = attr_d(m, "Right", 0.75);
                                c.s("cx", (left + right) / 2);
                                c.s("cy", (top + bottom) / 2);
                                c.s("rx", (right - left).abs() / 2);
                                c.s("ry", (bottom - top).abs() / 2);
                                c.s("angle", attr_d(m, "Angle", 0));
                                c.s("feather", (attr_d(m, "Feather", 50) / 100).clamp(0, 1));
                                string? flipped = attr(m, "Flipped");
                                c.invert = flipped != null && flipped.down() == "false";
                                l.components.add(c);
                            } else if (what == "Mask/Paint") {
                                if (brush == null) {
                                    brush = new MaskComponent("brush");
                                    l.components.add(brush);
                                }
                                var st = new BrushStroke();
                                st.radius = attr_d(m, "Radius", 0.03);
                                st.flow = attr_d(m, "Flow", 1).clamp(0, 1);
                                st.feather = (1 - attr_d(m, "CenterWeight", 0.5)).clamp(0, 1);
                                st.erase = attr_d(m, "MaskValue", 1) < 0.5;
                                var dabs = new Gee.ArrayList<Xml.Node*>();
                                collect(m, "li", dabs);
                                foreach (var dn in dabs) {
                                    var parts = dn->get_content().strip().split(" ");
                                    if (parts.length >= 3 && parts[0] == "d") st.add_point(double.parse(parts[1]), double.parse(parts[2]));
                                }
                                brush.strokes.add(st);
                            }
                        }
                        if (l.components.size > 0) {
                            p.locals.add(l);
                            present.add("masks");
                        }
                    }
                }
                delete doc;
            }
        }
    }
}
