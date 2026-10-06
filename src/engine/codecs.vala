using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class RawData : Object {
        public FloatImage camera;
        public double[] as_shot_multipliers = { 1.0, 1.0, 1.0 };
        public double[] camera_to_xyz = { 0.4124, 0.3576, 0.1805, 0.2126, 0.7152, 0.0722, 0.0193, 0.1192, 0.9505 };
        public double[] xyz_to_camera = { 3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570 };
        public double as_shot_temperature = 5500;
        public double as_shot_tint = 0;
        public float[] clip_level = { 1.0f, 1.0f, 1.0f };
        public string decoder = "";
        public string cfa_pattern = "";
        public double baseline_exposure = 0;
        public string camera_profile_name = "";

        public RawData(FloatImage camera) {
            this.camera = camera;
        }
    }

    public class DecodedPhoto : Object {
        public FloatImage image;
        public RawData? raw = null;
        public IccProfile? profile = null;
        public PhotoMetadata meta = new PhotoMetadata();
        public string format = "";
        public int full_width = 0;
        public int full_height = 0;
        public Gee.ArrayList<DecodedLayer>? layers = null;

        public DecodedPhoto(FloatImage image) {
            this.image = image;
            full_width = image.width;
            full_height = image.height;
        }

        public double scale() {
            return full_width > 0 ? (double) image.width / full_width : 1.0;
        }

        public bool is_raw() {
            return raw != null;
        }
    }

    public class DecodedLayer : Object {
        public string name = "";
        public FloatImage image;
        public int x = 0;
        public int y = 0;
        public float opacity = 1.0f;
        public BlendMode mode = BlendMode.NORMAL;
        public bool visible = true;
        public float[]? mask = null;
        public int mask_x = 0;
        public int mask_y = 0;
        public int mask_width = 0;
        public int mask_height = 0;
        public int group_depth = 0;
        public bool group_start = false;
        public bool group_end = false;

        public DecodedLayer(string name, FloatImage image) {
            this.name = name;
            this.image = image;
        }
    }

    public interface PhotoDecoder : Object {
        public abstract string id { get; }
        public abstract bool handles(string lower_name, uint8[] head);
        public abstract DecodedPhoto decode(File file, int max_side) throws Error;
    }

    namespace Codecs {

        private Gee.ArrayList<PhotoDecoder>? decoders = null;
        private Mutex codec_lock;

        public const string[] STANDARD_EXTENSIONS = { "jpg", "jpeg", "jpe", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif", "jxl", "exr", "psd", "ora", "svg" };
        public const string[] RAW_EXTENSIONS = { "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "raf", "rw2", "rwl", "pef", "srw", "x3f", "3fr", "fff", "iiq", "mos", "mrw", "erf", "kdc", "dcr", "raw", "mef", "gpr" };

        public void register(PhotoDecoder decoder) {
            codec_lock.lock();
            ensure_locked();
            decoders.insert(0, decoder);
            codec_lock.unlock();
        }

        private void ensure_locked() {
            if (decoders != null) return;
            decoders = new Gee.ArrayList<PhotoDecoder>();
            decoders.add(new PsdDecoder());
            decoders.add(new OraDecoder());
            decoders.add(new DngDecoder());
            decoders.add(new LibRawDecoder());
            decoders.add(new HeifDecoder());
            decoders.add(new ExrDecoder());
            decoders.add(new StandardDecoder());
        }

        public string extension(string name) {
            string n = name.down();
            int dot = n.last_index_of_char('.');
            return dot >= 0 ? n.substring(dot + 1) : "";
        }

        public bool is_raw_name(string name) {
            string ext = extension(name);
            foreach (var e in RAW_EXTENSIONS) if (e == ext) return true;
            return false;
        }

        public bool is_supported_name(string name) {
            string ext = extension(name);
            if (ext == "") return false;
            foreach (var e in STANDARD_EXTENSIONS) if (e == ext) return true;
            return is_raw_name(name);
        }

        public uint8[] read_head(File file, int n = 64) {
            try {
                var stream = file.read();
                var buf = new uint8[n];
                size_t got;
                stream.read_all(buf, out got);
                buf.length = (int) got;
                return buf;
            } catch (Error e) {
                return new uint8[0];
            }
        }

        public PhotoDecoder? decoder_for(File file) {
            string name = (file.get_basename() ?? "").down();
            var head = read_head(file);
            codec_lock.lock();
            ensure_locked();
            PhotoDecoder? found = null;
            foreach (var d in decoders) {
                if (d.handles(name, head)) {
                    found = d;
                    break;
                }
            }
            codec_lock.unlock();
            return found;
        }

        public DecodedPhoto load(File file, int max_side = 0) throws Error {
            var d = decoder_for(file);
            if (d == null) throw new IOError.NOT_SUPPORTED(_("This file format is not supported"));
            return d.decode(file, max_side);
        }
    }

    public class StandardDecoder : Object, PhotoDecoder {
        public string id { get { return "standard"; } }

        public bool handles(string lower_name, uint8[] head) {
            return true;
        }

        private static bool may_carry_orientation(string name) {
            return name.has_suffix(".jpg") || name.has_suffix(".jpeg") || name.has_suffix(".jpe") || name.has_suffix(".tif") || name.has_suffix(".tiff") || name.has_suffix(".webp");
        }

        public DecodedPhoto decode(File file, int max_side) throws Error {
            string name = (file.get_basename() ?? "").down();
            FloatImage encoded;
            int full_w, full_h;
            bool wide = name.has_suffix(".png") || name.has_suffix(".tif") || name.has_suffix(".tiff");
            if (!wide || may_carry_orientation(name)) {
                Gdk.Pixbuf pixbuf;
                try {
                    pixbuf = new Gdk.Pixbuf.from_file(file.get_path());
                } catch (Error e) {
                    pixbuf = null;
                    wide = true;
                }
                if (pixbuf != null && !wide) {
                    var oriented = pixbuf.apply_embedded_orientation() ?? pixbuf;
                    full_w = oriented.width;
                    full_h = oriented.height;
                    if (max_side > 0 && int.max(full_w, full_h) > max_side) {
                        double f = (double) max_side / int.max(full_w, full_h);
                        oriented = oriented.scale_simple(int.max(1, (int) Math.round(full_w * f)), int.max(1, (int) Math.round(full_h * f)), Gdk.InterpType.BILINEAR);
                    }
                    unowned uint8[] px = oriented.get_pixels_with_length();
                    encoded = FloatImage.from_rgba8(px, oriented.width, oriented.height, oriented.rowstride, oriented.has_alpha, false);
                    return finish(file, name, encoded, full_w, full_h);
                }
            }
            var texture = Gdk.Texture.from_file(file);
            full_w = texture.get_width();
            full_h = texture.get_height();
            encoded = FloatImage.from_texture(texture, false);
            if (max_side > 0) encoded = encoded.scaled_to_fit(max_side);
            return finish(file, name, encoded, full_w, full_h);
        }

        private DecodedPhoto finish(File file, string name, FloatImage encoded, int full_w, int full_h) {
            IccProfile? embedded = null;
            var icc = IccExtract.from_file(file);
            if (icc != null) {
                try {
                    embedded = IccProfile.from_data(icc);
                    if (!embedded.is_rgb()) embedded = null;
                } catch (Error e) {
                    embedded = null;
                }
            }
            FloatImage working;
            if (embedded != null) {
                working = WorkingSpace.from_profile(encoded, embedded);
            } else {
                working = encoded;
                WorkingSpace.linearize(working);
                WorkingSpace.from_linear_srgb(working);
            }
            var photo = new DecodedPhoto(working);
            photo.profile = embedded;
            photo.full_width = full_w;
            photo.full_height = full_h;
            photo.format = Codecs.extension(name);
            photo.meta = MetadataReader.read(file);
            if (photo.meta.width == 0) {
                photo.meta.width = full_w;
                photo.meta.height = full_h;
            }
            return photo;
        }
    }

    namespace IccExtract {

        public uint8[]? from_file(File file) {
            uint8[] data;
            try {
                var stream = file.read();
                var buf = new uint8[4 * 1024 * 1024];
                size_t got;
                stream.read_all(buf, out got);
                buf.length = (int) got;
                data = (owned) buf;
            } catch (Error e) {
                return null;
            }
            if (data.length > 4 && data[0] == 0xFF && data[1] == 0xD8) return from_jpeg(data);
            if (data.length > 8 && data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G') return from_png(data);
            return null;
        }

        public uint8[]? from_jpeg(uint8[] data) {
            var chunks = new Gee.TreeMap<int, Bytes>();
            int total = 0;
            int pos = 2;
            while (pos + 4 <= data.length) {
                if (data[pos] != 0xFF) break;
                uint8 marker = data[pos + 1];
                if (marker == 0xD9 || marker == 0xDA) break;
                int len = (data[pos + 2] << 8) | data[pos + 3];
                if (len < 2 || pos + 2 + len > data.length) break;
                if (marker == 0xE2 && len > 16 && Memory.cmp(&data[pos + 4], "ICC_PROFILE".data, 11) == 0) {
                    int seq = data[pos + 16];
                    total = data[pos + 17];
                    int body = pos + 18;
                    int body_len = len - 16;
                    chunks[seq] = new Bytes(data[body:body + body_len]);
                }
                pos += 2 + len;
            }
            if (chunks.size == 0) return null;
            var out_data = new ByteArray();
            foreach (var entry in chunks.entries) out_data.append(entry.value.get_data());
            return out_data.steal();
        }

        public uint8[]? from_png(uint8[] data) {
            int pos = 8;
            while (pos + 12 <= data.length) {
                uint32 len = ((uint32) data[pos] << 24) | ((uint32) data[pos + 1] << 16) | ((uint32) data[pos + 2] << 8) | data[pos + 3];
                if (pos + 12 + len > data.length) break;
                if (Memory.cmp(&data[pos + 4], "iCCP".data, 4) == 0) {
                    int p = pos + 8;
                    int end = p + (int) len;
                    while (p < end && data[p] != 0) p++;
                    p += 2;
                    if (p >= end) return null;
                    return inflate(data[p:end]);
                }
                if (Memory.cmp(&data[pos + 4], "IDAT".data, 4) == 0) break;
                pos += 12 + (int) len;
            }
            return null;
        }

        public uint8[]? inflate(uint8[] compressed) {
            var converter = new ZlibDecompressor(ZlibCompressorFormat.ZLIB);
            var out_data = new ByteArray();
            var buffer = new uint8[65536];
            size_t read_total = 0;
            try {
                while (true) {
                    size_t r, w;
                    var result = converter.convert(compressed[read_total:compressed.length], buffer, ConverterFlags.INPUT_AT_END, out r, out w);
                    read_total += r;
                    out_data.append(buffer[0:w]);
                    if (result == ConverterResult.FINISHED) break;
                    if (r == 0 && w == 0) break;
                }
            } catch (Error e) {
                return null;
            }
            return out_data.steal();
        }
    }
}
