namespace Singularity.Apps.Photos {

    namespace XmpSidecar {

        public File beside(File photo) {
            var parent = photo.get_parent() ?? File.new_for_path(Environment.get_home_dir());
            string name = photo.get_basename() ?? "photo";
            int dot = name.last_index_of_char('.');
            string stem = dot > 0 ? name.substring(0, dot) : name;
            return parent.get_child(stem + ".xmp");
        }

        public File fallback(File photo) {
            string key = Checksum.compute_for_string(ChecksumType.SHA256, photo.get_uri(), -1);
            return File.new_for_path(Path.build_filename(Environment.get_user_data_dir(), "singularity-photos", "xmp", key + ".xmp"));
        }

        public File? find(File photo) {
            var b = beside(photo);
            if (b.query_exists()) return b;
            var f = fallback(photo);
            if (f.query_exists()) return f;
            return null;
        }

        public bool exists(File photo) {
            return find(photo) != null;
        }

        public XmpPacket load(File photo) {
            var file = find(photo);
            if (file == null) return new XmpPacket();
            try {
                string text;
                FileUtils.get_contents(file.get_path(), out text);
                return XmpPacket.parse(text);
            } catch (Error e) {
                warning("Photos: cannot read %s: %s", file.get_path(), e.message);
                return new XmpPacket();
            }
        }

        public XmpPacket? load_embedded(File photo) {
            var data = MetadataReader.read_head(photo, 64 * 1024 * 1024);
            if (data.length == 0) return null;
            bool jpeg_or_png = data.length > 4 && ((data[0] == 0xFF && data[1] == 0xD8) || (data[0] == 0x89 && data[1] == 'P'));
            if (!jpeg_or_png) {
                var tiff = MetadataReader.find_tiff(data);
                if (tiff != null) {
                    foreach (var ifd in tiff.all_ifds()) {
                        var bytes = tiff.get_bytes(ifd, 700);
                        if (bytes.length == 0) continue;
                        try {
                            return XmpPacket.parse(XmpExtract.bytes_to_string(bytes));
                        } catch (Error e) {
                        }
                    }
                }
            }
            return XmpPacket.from_embedded(data);
        }

        public XmpPacket load_combined(File photo) {
            var embedded = load_embedded(photo);
            var result = embedded ?? new XmpPacket();
            if (exists(photo)) result.merge(load(photo));
            return result;
        }

        private bool dir_writable(File dir) {
            try {
                var info = dir.query_info(FileAttribute.ACCESS_CAN_WRITE + "," + FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NONE);
                return info.get_file_type() == FileType.DIRECTORY && info.get_attribute_boolean(FileAttribute.ACCESS_CAN_WRITE);
            } catch (Error e) {
                return false;
            }
        }

        public File save(File photo, XmpPacket packet, bool merge = true) throws Error {
            XmpPacket result;
            if (merge) {
                result = load(photo);
                result.merge(packet);
            } else {
                result = packet;
            }
            var b = beside(photo);
            var parent = b.get_parent();
            var target = parent != null && dir_writable(parent) ? b : fallback(photo);
            DirUtils.create_with_parents(target.get_parent().get_path(), 0755);
            string partial = "%s.%u.part".printf(target.get_path(), Random.next_int());
            FileUtils.set_contents(partial, result.serialize());
            if (FileUtils.rename(partial, target.get_path()) != 0) {
                FileUtils.remove(partial);
                throw new IOError.FAILED(_("Cannot write %s").printf(target.get_path()));
            }
            if (target.equal(b)) {
                var stale = fallback(photo);
                if (stale.query_exists()) FileUtils.remove(stale.get_path());
            }
            return target;
        }

        public void remove(File photo) {
            foreach (var f in new File[] { beside(photo), fallback(photo) }) {
                if (f.query_exists()) FileUtils.remove(f.get_path());
            }
        }
    }
}
