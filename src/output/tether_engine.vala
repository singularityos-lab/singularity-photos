namespace Singularity.Apps.Photos {

    public class TetherCamera : Object {
        public string model { get; construct; }
        public string port { get; construct; }

        public TetherCamera(string model, string port) {
            Object(model: model, port: port);
        }
    }

    public class TetherSession : Object {
        private void* handle = null;
        private Mutex mutex = Mutex();
        public TetherCamera camera { get; construct; }

        public TetherSession(TetherCamera camera) {
            Object(camera: camera);
        }

        ~TetherSession() {
            close();
        }

        public static Gee.List<TetherCamera> detect() {
            var list = new Gee.ArrayList<TetherCamera>();
            string[] models, ports;
            int n = SintyTether.list(out models, out ports);
            for (int i = 0; i < n && i < models.length && i < ports.length; i++) list.add(new TetherCamera(models[i], ports[i]));
            return list;
        }

        public void open() throws Error {
            if (handle != null) return;
            string? error;
            handle = SintyTether.open(camera.model, camera.port, out error);
            if (handle == null) throw new IOError.NOT_CONNECTED(error ?? _("The camera did not answer"));
        }

        public void close() {
            if (handle == null) return;
            SintyTether.close(handle);
            handle = null;
        }

        public File capture(File folder) throws Error {
            mutex.lock();
            try {
                return capture_locked(folder);
            } finally {
                mutex.unlock();
            }
        }

        private File capture_locked(File folder) throws Error {
            open();
            DirUtils.create_with_parents(folder.get_path(), 0755);
            string? saved, error;
            if (!SintyTether.capture(handle, folder.get_path(), out saved, out error) || saved == null)
                throw new IOError.FAILED(error ?? _("The camera could not take the photo"));
            return File.new_for_path(saved);
        }

        public bool can_capture() throws Error {
            mutex.lock();
            try {
                open();
                return (SintyTether.operations(handle) & 1) != 0;
            } finally {
                mutex.unlock();
            }
        }

        public bool can_preview() throws Error {
            mutex.lock();
            try {
                open();
                return (SintyTether.operations(handle) & 8) != 0;
            } finally {
                mutex.unlock();
            }
        }

        public Bytes preview() throws Error {
            mutex.lock();
            try {
                open();
                uint8[] data;
                string? error;
                if (!SintyTether.preview(handle, out data, out error) || data.length == 0)
                    throw new IOError.NOT_SUPPORTED(error ?? _("This camera has no live view"));
                return new Bytes.take((owned) data);
            } finally {
                mutex.unlock();
            }
        }

        public string[] camera_files() throws Error {
            mutex.lock();
            try {
                open();
                string[] paths;
                SintyTether.list_files(handle, out paths);
                return paths;
            } finally {
                mutex.unlock();
            }
        }

        public File download(string camera_path, File folder) throws Error {
            mutex.lock();
            try {
                open();
                DirUtils.create_with_parents(folder.get_path(), 0755);
                string? saved, error;
                if (!SintyTether.download(handle, camera_path, folder.get_path(), out saved, out error) || saved == null)
                    throw new IOError.FAILED(error ?? _("The file could not be copied from the camera"));
                return File.new_for_path(saved);
            } finally {
                mutex.unlock();
            }
        }

        public File? wait(File folder, int timeout_ms) throws Error {
            mutex.lock();
            try {
                return wait_locked(folder, timeout_ms);
            } finally {
                mutex.unlock();
            }
        }

        private File? wait_locked(File folder, int timeout_ms) throws Error {
            open();
            DirUtils.create_with_parents(folder.get_path(), 0755);
            string? saved, error;
            int r = SintyTether.wait(handle, timeout_ms, folder.get_path(), out saved, out error);
            if (r < 0) throw new IOError.FAILED(error ?? _("The camera stopped answering"));
            return r > 0 && saved != null ? File.new_for_path(saved) : null;
        }
    }

    namespace TetherImport {

        public string ledger_path(TetherCamera camera) {
            return Path.build_filename(Environment.get_user_data_dir(), "singularity-photos", "camera-imports",
                Checksum.compute_for_string(ChecksumType.SHA1, camera.model + "\n" + camera.port).substring(0, 16) + ".txt");
        }

        public Gee.HashSet<string> imported(TetherCamera camera) {
            var set = new Gee.HashSet<string>();
            try {
                string text;
                FileUtils.get_contents(ledger_path(camera), out text);
                foreach (var line in text.split("\n")) if (line != "") set.add(line);
            } catch (Error e) {
            }
            return set;
        }

        public void remember(TetherCamera camera, Gee.Collection<string> paths) {
            var b = new StringBuilder();
            foreach (var p in paths) b.append(p + "\n");
            try {
                DirUtils.create_with_parents(Path.get_dirname(ledger_path(camera)), 0755);
                FileUtils.set_contents(ledger_path(camera), b.str);
            } catch (Error e) {
            }
        }

        public Gee.List<File> import_new(TetherSession session, File folder, string preset_id) throws Error {
            var done = imported(session.camera);
            var result = new Gee.ArrayList<File>();
            foreach (var path in session.camera_files()) {
                if (path in done || !Codecs.is_supported_name(path)) continue;
                var f = session.download(path, folder);
                apply_preset(f, preset_id);
                result.add(f);
                done.add(path);
            }
            remember(session.camera, done);
            return result;
        }

        public void apply_preset(File captured, string preset_id) throws Error {
            if (preset_id == "") return;
            var preset = DevelopPresets.find(preset_id);
            if (preset == null) throw new IOError.NOT_FOUND(_("The develop preset no longer exists"));
            var p = EditStore.load(captured) ?? new EditParams();
            DevelopPresets.apply(p, preset, 1.0);
            if (!p.is_identity()) EditStore.save(captured, p);
        }
    }
}
