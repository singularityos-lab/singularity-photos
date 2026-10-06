namespace Singularity.Apps.Photos {

    namespace LivePhoto {

        public const string[] VIDEO_EXTENSIONS = { "mov", "mp4", "m4v", "3gp", "webm", "mkv" };

        public bool is_video_name(string name) {
            return Codecs.extension(name) in VIDEO_EXTENSIONS;
        }

        public File? companion_video(File photo) {
            var parent = photo.get_parent();
            string name = photo.get_basename() ?? "";
            int dot = name.last_index_of_char('.');
            if (parent == null || dot <= 0) return null;
            string stem = name.substring(0, dot);
            foreach (var ext in VIDEO_EXTENSIONS) {
                foreach (var candidate in new string[] { stem + "." + ext, stem + "." + ext.up() }) {
                    var f = parent.get_child(candidate);
                    if (f.query_exists()) return f;
                }
            }
            return null;
        }

        public int64 embedded_video_offset(uint8[] data) {
            if (data.length < 16 || data[0] != 0xFF || data[1] != 0xD8) return -1;
            for (int i = 4; i + 12 < data.length; i++) {
                if (data[i] != 'f' || data[i + 1] != 't' || data[i + 2] != 'y' || data[i + 3] != 'p') continue;
                int start = i - 4;
                uint32 size = ((uint32) data[start] << 24) | ((uint32) data[start + 1] << 16) | ((uint32) data[start + 2] << 8) | data[start + 3];
                if (size < 8 || size > 256) continue;
                string brand = "%c%c%c%c".printf(data[i + 4], data[i + 5], data[i + 6], data[i + 7]);
                if (brand in new string[] { "isom", "mp41", "mp42", "qt  ", "avc1", "iso4", "iso5", "iso6", "heic", "M4V " } || brand.has_prefix("iso") || brand.has_prefix("mp4")) {
                    bool after_eoi = false;
                    for (int k = start - 2; k >= 2 && k >= start - 64; k--) {
                        if (data[k] == 0xFF && data[k + 1] == 0xD9) {
                            after_eoi = true;
                            break;
                        }
                    }
                    if (after_eoi || start > data.length / 4) return start;
                }
            }
            return -1;
        }

        public File cache_file(File photo) {
            return File.new_for_path(Path.build_filename(Environment.get_user_cache_dir(), "singularity-photos", "motion",
                Checksum.compute_for_string(ChecksumType.SHA256, photo.get_uri()) + ".mp4"));
        }

        public File? motion_photo_video(File photo) {
            string name = (photo.get_basename() ?? "").down();
            if (!name.has_suffix(".jpg") && !name.has_suffix(".jpeg")) return null;
            var cached = cache_file(photo);
            try {
                if (cached.query_exists()) {
                    var ci = cached.query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                    var pi = photo.query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                    if (ci.get_modification_date_time().compare(pi.get_modification_date_time()) >= 0) return cached;
                }
                uint8[] data;
                FileUtils.get_data(photo.get_path(), out data);
                int64 at = embedded_video_offset(data);
                if (at < 0) return null;
                DirUtils.create_with_parents(cached.get_parent().get_path(), 0755);
                FileUtils.set_data(cached.get_path(), data[at:data.length]);
                return cached;
            } catch (Error e) {
                return null;
            }
        }

        public File? playable_for(File photo) {
            if (is_video_name(photo.get_basename() ?? "")) return photo;
            return companion_video(photo) ?? motion_photo_video(photo);
        }
    }
}
