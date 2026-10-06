using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class DngRawData : RawData {
        public double[] color_matrix1 = {};
        public double[] color_matrix2 = {};
        public double[] forward_matrix1 = {};
        public double[] forward_matrix2 = {};
        public double temperature1 = 0;
        public double temperature2 = 0;
        public string camera_model = "";
        public DcpProfile? embedded_profile = null;

        public DngRawData(FloatImage camera) {
            base(camera);
        }
    }

    public class HsvMap : Object {
        public int hue_divisions;
        public int sat_divisions;
        public int val_divisions;
        public float[] data;
        public bool srgb_gamma = false;

        public HsvMap(int h, int s, int v, float[] data) {
            hue_divisions = h;
            sat_divisions = s;
            val_divisions = int.max(1, v);
            this.data = data;
        }

        public bool valid() {
            return hue_divisions > 0 && sat_divisions > 0 && data.length >= hue_divisions * sat_divisions * val_divisions * 3;
        }

        private void entry(int hi, int si, int vi, out float dh, out float ds, out float dv) {
            hi = ((hi % hue_divisions) + hue_divisions) % hue_divisions;
            si = si.clamp(0, sat_divisions - 1);
            vi = vi.clamp(0, val_divisions - 1);
            size_t idx = (((size_t) vi * hue_divisions + hi) * sat_divisions + si) * 3;
            dh = data[idx];
            ds = data[idx + 1];
            dv = data[idx + 2];
        }

        public void lookup(float h, float s, float v, out float dh, out float ds, out float dv) {
            float hf = h / 360.0f * hue_divisions;
            float sf = s * (sat_divisions - 1);
            float vf = val_divisions > 1 ? v.clamp(0, 1) * (val_divisions - 1) : 0;
            int h0 = (int) Math.floorf(hf), s0 = (int) Math.floorf(sf).clamp(0, sat_divisions - 1), v0 = (int) Math.floorf(vf);
            float th = hf - h0, ts = (sf - s0).clamp(0, 1), tv = vf - v0;
            dh = 0;
            ds = 0;
            dv = 0;
            for (int a = 0; a < 2; a++) {
                for (int b = 0; b < 2; b++) {
                    for (int c = 0; c < (val_divisions > 1 ? 2 : 1); c++) {
                        float wgt = (a == 0 ? 1 - th : th) * (b == 0 ? 1 - ts : ts) * (val_divisions > 1 ? (c == 0 ? 1 - tv : tv) : 1);
                        float eh, es, ev;
                        entry(h0 + a, s0 + b, v0 + c, out eh, out es, out ev);
                        dh += eh * wgt;
                        ds += es * wgt;
                        dv += ev * wgt;
                    }
                }
            }
        }
    }

    public class DcpProfile : Object {
        public string name = "";
        public string camera_model = "";
        public string path = "";
        public double[] color_matrix1 = {};
        public double[] color_matrix2 = {};
        public double[] forward_matrix1 = {};
        public double[] forward_matrix2 = {};
        public double temperature1 = 0;
        public double temperature2 = 0;
        public HsvMap? hue_sat_map1 = null;
        public HsvMap? hue_sat_map2 = null;
        public HsvMap? look_table = null;
        public double[] tone_curve = {};

        public static DcpProfile parse(uint8[] bytes) throws Error {
            var r = new TiffReader(bytes);
            var ifds = r.chain();
            if (ifds.size == 0) throw new IOError.INVALID_DATA("Empty camera profile");
            var p = new DcpProfile();
            p.read_tags(r, ifds[0]);
            if (p.color_matrix1.length != 9) throw new IOError.INVALID_DATA("Camera profile without colour matrix");
            return p;
        }

        public static DcpProfile load(string path) throws Error {
            uint8[] data;
            FileUtils.get_data(path, out data);
            var p = parse(data);
            p.path = path;
            if (p.name == "") p.name = Path.get_basename(path).replace(".dcp", "").replace(".DCP", "");
            return p;
        }

        public void read_tags(TiffReader r, TiffIfd ifd) {
            name = r.get_string(ifd, 50936);
            if (camera_model == "") camera_model = r.get_string(ifd, 50708);
            var cm1 = r.get_doubles(ifd, 50721);
            if (cm1.length >= 9) color_matrix1 = cm1[0:9];
            var cm2 = r.get_doubles(ifd, 50722);
            if (cm2.length >= 9) color_matrix2 = cm2[0:9];
            var fm1 = r.get_doubles(ifd, 50964);
            if (fm1.length >= 9) forward_matrix1 = fm1[0:9];
            var fm2 = r.get_doubles(ifd, 50965);
            if (fm2.length >= 9) forward_matrix2 = fm2[0:9];
            temperature1 = Chromaticity.illuminant_temperature((int) r.get_uint(ifd, 50778));
            temperature2 = Chromaticity.illuminant_temperature((int) r.get_uint(ifd, 50779));
            var dims = r.get_uints(ifd, 50937);
            if (dims.length >= 3) {
                hue_sat_map1 = read_map(r, ifd, 50938, dims);
                hue_sat_map2 = read_map(r, ifd, 50939, dims);
            }
            var ldims = r.get_uints(ifd, 50981);
            if (ldims.length >= 3) look_table = read_map(r, ifd, 50982, ldims);
            tone_curve = r.get_doubles(ifd, 50940);
            bool srgb = r.get_uint(ifd, 51107, 0) == 1;
            if (hue_sat_map1 != null) hue_sat_map1.srgb_gamma = srgb;
            if (hue_sat_map2 != null) hue_sat_map2.srgb_gamma = srgb;
            if (look_table != null) look_table.srgb_gamma = r.get_uint(ifd, 51108, 0) == 1;
        }

        private static HsvMap? read_map(TiffReader r, TiffIfd ifd, int tag, uint32[] dims) {
            var values = r.get_doubles(ifd, tag);
            if (values.length == 0) return null;
            var f = new float[values.length];
            for (int i = 0; i < values.length; i++) f[i] = (float) values[i];
            var m = new HsvMap((int) dims[0], (int) dims[1], (int) dims[2], f);
            return m.valid() ? m : null;
        }

        private static void rgb_to_hsv(float r, float g, float b, out float h, out float s, out float v) {
            float mx = float.max(r, float.max(g, b)), mn = float.min(r, float.min(g, b));
            v = mx;
            float d = mx - mn;
            s = mx > 1e-9f ? d / mx : 0;
            if (d <= 1e-9f) {
                h = 0;
                return;
            }
            if (mx == r) h = 60 * ((g - b) / d);
            else if (mx == g) h = 60 * ((b - r) / d + 2);
            else h = 60 * ((r - g) / d + 4);
            if (h < 0) h += 360;
        }

        private static void hsv_to_rgb(float h, float s, float v, out float r, out float g, out float b) {
            h = h % 360.0f;
            if (h < 0) h += 360;
            float c = v * s;
            float x = c * (1 - ((h / 60.0f) % 2.0f - 1).abs());
            float m = v - c;
            float rr = 0, gg = 0, bb = 0;
            if (h < 60) { rr = c; gg = x; }
            else if (h < 120) { rr = x; gg = c; }
            else if (h < 180) { gg = c; bb = x; }
            else if (h < 240) { gg = x; bb = c; }
            else if (h < 300) { rr = x; bb = c; }
            else { rr = c; bb = x; }
            r = rr + m;
            g = gg + m;
            b = bb + m;
        }

        public void apply_looks(FloatImage working) {
            var maps = new Gee.ArrayList<HsvMap>();
            if (hue_sat_map1 != null) maps.add(hue_sat_map1);
            if (look_table != null) maps.add(look_table);
            if (maps.size == 0) return;
            var to_pp = Primaries.conversion(WorkingSpace.primaries(), Primaries.prophoto());
            var from_pp = Matrix3.invert(to_pp);
            Matrix3.apply_image(to_pp, working);
            int w = working.width;
            Parallel.range(working.height, (start, end) => {
                for (size_t i = (size_t) start * w; i < (size_t) end * w; i++) {
                    float r = float.max(0, working.data[i * 4]), g = float.max(0, working.data[i * 4 + 1]), b = float.max(0, working.data[i * 4 + 2]);
                    foreach (var m in maps) {
                        float h, s, v;
                        rgb_to_hsv(r, g, b, out h, out s, out v);
                        float lv = m.srgb_gamma ? Transfer.linear_to_srgb(v) : v;
                        float dh, ds, dv;
                        m.lookup(h, s, lv, out dh, out ds, out dv);
                        h += dh;
                        s = (s * ds).clamp(0, 1);
                        if (m.srgb_gamma) v = Transfer.srgb_to_linear((lv * dv).clamp(0, 1)) * (v > 1 ? v : 1);
                        else v *= dv;
                        hsv_to_rgb(h, s, v, out r, out g, out b);
                    }
                    working.data[i * 4] = r;
                    working.data[i * 4 + 1] = g;
                    working.data[i * 4 + 2] = b;
                }
            });
            Matrix3.apply_image(from_pp, working);
        }
    }

    namespace CameraProfiles {

        public const string MATRIX = "matrix";
        public const string EMBEDDED = "embedded";

        private Gee.HashMap<string, DcpProfile>? cache = null;
        private Mutex cache_lock;

        public string[] search_dirs() {
            string[] dirs = {};
            string? extra = Environment.get_variable("SINGULARITY_PHOTOS_PROFILE_DIRS");
            if (extra != null) foreach (var d in extra.split(":")) if (d != "") dirs += d;
            dirs += Path.build_filename(Environment.get_user_data_dir(), "singularity-photos", "profiles");
            foreach (var d in Environment.get_system_data_dirs()) dirs += Path.build_filename(d, "singularity-photos", "profiles");
            return dirs;
        }

        private string normalize(string s) {
            return s.down().replace(" ", "").replace("-", "").replace("_", "");
        }

        private void scan_locked() {
            if (cache != null) return;
            cache = new Gee.HashMap<string, DcpProfile>();
            foreach (var dir in search_dirs()) {
                Dir d;
                try {
                    d = Dir.open(dir);
                } catch (Error e) {
                    continue;
                }
                string? name;
                while ((name = d.read_name()) != null) {
                    if (!name.down().has_suffix(".dcp")) continue;
                    string path = Path.build_filename(dir, name);
                    try {
                        var p = DcpProfile.load(path);
                        cache[path] = p;
                    } catch (Error e) {
                    }
                }
            }
        }

        public void rescan() {
            cache_lock.lock();
            cache = null;
            scan_locked();
            cache_lock.unlock();
        }

        public string camera_of(RawData raw) {
            var d = raw as DngRawData;
            return d != null ? d.camera_model : "";
        }

        public Gee.List<DcpProfile> for_camera(string camera) {
            var list = new Gee.ArrayList<DcpProfile>();
            cache_lock.lock();
            scan_locked();
            string key = normalize(camera);
            foreach (var p in cache.values) {
                string pk = normalize(p.camera_model);
                if (key != "" && (pk == key || pk.has_suffix(key) || key.has_suffix(pk))) list.add(p);
            }
            cache_lock.unlock();
            list.sort((a, b) => strcmp(a.name, b.name));
            return list;
        }

        public string[] list(RawData raw) {
            string[] names = { MATRIX };
            var d = raw as DngRawData;
            if (d != null && d.embedded_profile != null) names += EMBEDDED;
            foreach (var p in for_camera(camera_of(raw))) names += p.name;
            return names;
        }

        public string label(string name) {
            if (name == MATRIX) return _("Camera Matrix");
            if (name == EMBEDDED) return _("Embedded Profile");
            return name;
        }

        public DcpProfile? find(RawData raw, string name) {
            if (name == "" || name == MATRIX) return null;
            var d = raw as DngRawData;
            if (name == EMBEDDED) return d != null ? d.embedded_profile : null;
            foreach (var p in for_camera(camera_of(raw))) if (p.name == name) return p;
            cache_lock.lock();
            scan_locked();
            DcpProfile? found = null;
            foreach (var p in cache.values) if (p.path == name) found = p;
            cache_lock.unlock();
            return found;
        }
    }
}
