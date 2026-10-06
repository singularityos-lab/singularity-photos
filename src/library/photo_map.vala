using Gtk;

namespace Singularity.Apps.Photos {

    public class MapTiles : Object {
        public const string URL = "https://tile.openstreetmap.org/%d/%d/%d.png";
        public const string ATTRIBUTION = "© OpenStreetMap contributors";

        private Soup.Session session;
        private Gee.HashMap<string, Gdk.Texture> memory = new Gee.HashMap<string, Gdk.Texture>();
        private Gee.HashSet<string> pending = new Gee.HashSet<string>();
        private string cache_dir;

        public signal void tile_ready();

        public MapTiles() {
            session = (Soup.Session) Object.new(typeof(Soup.Session), "max-conns", 4, "user-agent", "SingularityPhotos/0.1 (+https://github.com/singularityos-lab)");
            cache_dir = Path.build_filename(Environment.get_user_cache_dir(), "singularity-photos", "tiles");
        }

        public Gdk.Texture? get_tile(int z, int x, int y) {
            int n = 1 << z;
            x = ((x % n) + n) % n;
            if (y < 0 || y >= n) return null;
            string key = "%d/%d/%d".printf(z, x, y);
            if (memory.has_key(key)) return memory[key];
            string path = Path.build_filename(cache_dir, "%d".printf(z), "%d".printf(x), "%d.png".printf(y));
            if (FileUtils.test(path, FileTest.EXISTS)) {
                try {
                    var t = Gdk.Texture.from_filename(path);
                    memory[key] = t;
                    return t;
                } catch (Error e) {
                }
            }
            if (pending.contains(key) || pending.size > 24) return null;
            pending.add(key);
            var msg = new Soup.Message("GET", URL.printf(z, x, y));
            session.send_and_read_async.begin(msg, Priority.LOW, null, (obj, res) => {
                pending.remove(key);
                try {
                    var bytes = session.send_and_read_async.end(res);
                    if (msg.status_code != 200) return;
                    var tex = Gdk.Texture.from_bytes(bytes);
                    memory[key] = tex;
                    DirUtils.create_with_parents(Path.get_dirname(path), 0755);
                    FileUtils.set_data(path, bytes.get_data());
                    tile_ready();
                } catch (Error e) {
                }
            });
            return null;
        }
    }

    public class MapCluster : Object {
        public double x;
        public double y;
        public double lat;
        public double lon;
        public Gee.ArrayList<PhotoRecord> records = new Gee.ArrayList<PhotoRecord>();
    }

    public class PhotoMap : Widget {
        public const int TILE = 256;

        public double zoom { get; private set; default = 2; }
        public double center_x = 0.5;
        public double center_y = 0.5;
        public Gee.ArrayList<PhotoRecord> photos = new Gee.ArrayList<PhotoRecord>();
        public GpxTrack? track = null;

        public signal void cluster_activated(Gee.List<PhotoRecord> records);
        public signal void dropped(File[] files, double lat, double lon);

        private MapTiles tiles;
        private Gee.ArrayList<MapCluster> clusters = new Gee.ArrayList<MapCluster>();
        private Gee.HashMap<string, Gdk.Texture> thumbs = new Gee.HashMap<string, Gdk.Texture>();
        private Gee.HashSet<string> thumb_pending = new Gee.HashSet<string>();
        private double drag_cx;
        private double drag_cy;
        private double last_x = 0;
        private double last_y = 0;

        public PhotoMap() {
            hexpand = true;
            vexpand = true;
            overflow = Overflow.HIDDEN;
            focusable = true;
            tiles = new MapTiles();
            tiles.tile_ready.connect(queue_draw);
            var drag = new GestureDrag();
            drag.drag_begin.connect((x, y) => {
                drag_cx = center_x;
                drag_cy = center_y;
            });
            drag.drag_update.connect((dx, dy) => {
                double world = TILE * Math.pow(2, zoom);
                center_x = drag_cx - dx / world;
                center_y = (drag_cy - dy / world).clamp(0, 1);
                queue_draw();
            });
            add_controller(drag);
            var scroll = new EventControllerScroll(EventControllerScrollFlags.VERTICAL);
            scroll.scroll.connect((dx, dy) => {
                zoom_at(zoom - dy * 0.5, last_x, last_y);
                return true;
            });
            add_controller(scroll);
            var motion = new EventControllerMotion();
            motion.motion.connect((x, y) => {
                last_x = x;
                last_y = y;
            });
            add_controller(motion);
            var click = new GestureClick();
            click.released.connect((n, x, y) => {
                foreach (var c in clusters) {
                    if ((c.x - x).abs() < 26 && (c.y - y).abs() < 26) {
                        if (n == 2) zoom_at(zoom + 2, x, y);
                        else cluster_activated(c.records);
                        return;
                    }
                }
                if (n == 2) zoom_at(zoom + 1, x, y);
            });
            add_controller(click);
            var drop = new DropTarget(typeof(Gdk.FileList), Gdk.DragAction.COPY | Gdk.DragAction.MOVE);
            drop.drop.connect((value, x, y) => {
                var list = (Gdk.FileList) value.get_boxed();
                if (list == null) return false;
                File[] files = {};
                foreach (var f in list.get_files()) files += f;
                double lat, lon;
                to_geo(x, y, out lat, out lon);
                dropped(files, lat, lon);
                return true;
            });
            add_controller(drop);
        }

        public static double lon_to_x(double lon) {
            return (lon + 180.0) / 360.0;
        }

        public static double lat_to_y(double lat) {
            double r = lat.clamp(-85.0511, 85.0511) * Math.PI / 180.0;
            return (1.0 - Math.log(Math.tan(r) + 1.0 / Math.cos(r)) / Math.PI) / 2.0;
        }

        public static double y_to_lat(double y) {
            double n = Math.PI - 2.0 * Math.PI * y;
            return 180.0 / Math.PI * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n)));
        }

        public void to_geo(double sx, double sy, out double lat, out double lon) {
            double world = TILE * Math.pow(2, zoom);
            double wx = center_x + (sx - get_width() / 2.0) / world;
            double wy = center_y + (sy - get_height() / 2.0) / world;
            lon = wx * 360.0 - 180.0;
            lat = y_to_lat(wy.clamp(0, 1));
        }

        public void to_screen(double lat, double lon, out double sx, out double sy) {
            double world = TILE * Math.pow(2, zoom);
            sx = (lon_to_x(lon) - center_x) * world + get_width() / 2.0;
            sy = (lat_to_y(lat) - center_y) * world + get_height() / 2.0;
        }

        public void zoom_at(double z, double sx, double sy) {
            z = z.clamp(1, 18);
            double lat, lon;
            to_geo(sx, sy, out lat, out lon);
            zoom = z;
            double world = TILE * Math.pow(2, zoom);
            center_x = lon_to_x(lon) - (sx - get_width() / 2.0) / world;
            center_y = (lat_to_y(lat) - (sy - get_height() / 2.0) / world).clamp(0, 1);
            queue_draw();
        }

        public void set_photos(Gee.List<PhotoRecord> list) {
            photos.clear();
            foreach (var r in list) if (r.has_gps) photos.add(r);
            queue_draw();
        }

        private bool fit_pending = false;

        public void fit() {
            if (get_width() <= 1) {
                fit_pending = true;
                queue_draw();
                return;
            }
            fit_pending = false;
            if (photos.size == 0) {
                zoom = 2;
                center_x = 0.5;
                center_y = 0.4;
                queue_draw();
                return;
            }
            double minx = 1, maxx = 0, miny = 1, maxy = 0;
            foreach (var r in photos) {
                double x = lon_to_x(r.longitude), y = lat_to_y(r.latitude);
                minx = double.min(minx, x);
                maxx = double.max(maxx, x);
                miny = double.min(miny, y);
                maxy = double.max(maxy, y);
            }
            center_x = (minx + maxx) / 2;
            center_y = (miny + maxy) / 2;
            double span = double.max(maxx - minx, maxy - miny);
            double w = double.min(get_width(), get_height()) * 0.7;
            zoom = span <= 1e-9 ? 12 : Math.log2(w / (span * TILE)).clamp(1, 16);
            queue_draw();
        }

        private void build_clusters() {
            clusters.clear();
            double cell = 56;
            var grid = new Gee.HashMap<string, MapCluster>();
            foreach (var r in photos) {
                double sx, sy;
                to_screen(r.latitude, r.longitude, out sx, out sy);
                if (sx < -40 || sy < -40 || sx > get_width() + 40 || sy > get_height() + 40) continue;
                string key = "%d:%d".printf((int) Math.floor(sx / cell), (int) Math.floor(sy / cell));
                var c = grid[key];
                if (c == null) {
                    c = new MapCluster();
                    c.x = sx;
                    c.y = sy;
                    c.lat = r.latitude;
                    c.lon = r.longitude;
                    grid[key] = c;
                    clusters.add(c);
                }
                c.records.add(r);
            }
        }

        private Gdk.Texture? thumb(PhotoRecord r) {
            if (thumbs.has_key(r.path)) return thumbs[r.path];
            if (thumb_pending.contains(r.path) || thumb_pending.size > 8) return null;
            thumb_pending.add(r.path);
            string path = r.path;
            new Thread<void>("photos-map-thumb", () => {
                Gdk.Texture? tex = null;
                try {
                    var shown = EditImageIO.display_file(File.new_for_path(path));
                    var pb = new Gdk.Pixbuf.from_file_at_scale((shown ?? File.new_for_path(path)).get_path(), 96, 96, true);
                    pb = pb.apply_embedded_orientation() ?? pb;
                    tex = Gdk.Texture.for_pixbuf(pb);
                } catch (Error e) {
                }
                Idle.add(() => {
                    thumb_pending.remove(path);
                    if (tex != null) thumbs[path] = tex;
                    queue_draw();
                    return Source.REMOVE;
                });
            });
            return null;
        }

        public override void snapshot(Snapshot s) {
            if (fit_pending && get_width() > 1) fit();
            int w = get_width(), h = get_height();
            var bg = Gdk.RGBA();
            bg.parse("#dfe6ea");
            var full = Graphene.Rect();
            full.init(0, 0, w, h);
            s.append_color(bg, full);
            int z = (int) Math.floor(zoom);
            double scale = Math.pow(2, zoom - z);
            double tile_px = TILE * scale;
            double world = TILE * Math.pow(2, zoom);
            double left = center_x * world - w / 2.0, top = center_y * world - h / 2.0;
            int tx0 = (int) Math.floor(left / tile_px), ty0 = (int) Math.floor(top / tile_px);
            int tx1 = (int) Math.floor((left + w) / tile_px), ty1 = (int) Math.floor((top + h) / tile_px);
            for (int ty = ty0; ty <= ty1; ty++) {
                for (int tx = tx0; tx <= tx1; tx++) {
                    var tex = tiles.get_tile(z, tx, ty);
                    if (tex == null) continue;
                    var r = Graphene.Rect();
                    r.init((float) (tx * tile_px - left), (float) (ty * tile_px - top), (float) tile_px + 0.5f, (float) tile_px + 0.5f);
                    s.append_texture(tex, r);
                }
            }
            if (track != null && track.points.length > 1) {
                var builder = new Gsk.PathBuilder();
                bool first = true;
                foreach (var p in track.points) {
                    double sx, sy;
                    to_screen(p.latitude, p.longitude, out sx, out sy);
                    if (first) builder.move_to((float) sx, (float) sy);
                    else builder.line_to((float) sx, (float) sy);
                    first = false;
                }
                var stroke = new Gsk.Stroke(3);
                var col = Gdk.RGBA();
                col.parse("#3e8ef7");
                s.append_stroke(builder.to_path(), stroke, col);
            }
            build_clusters();
            var white = Gdk.RGBA();
            white.parse("white");
            var shadow = Gdk.RGBA();
            shadow.parse("rgba(0,0,0,0.35)");
            var accent = Gdk.RGBA();
            accent.parse("#3e8ef7");
            foreach (var c in clusters) {
                var box = Graphene.Rect();
                box.init((float) c.x - 22, (float) c.y - 22, 44, 44);
                var rr = Gsk.RoundedRect();
                rr.init_from_rect(box, 10);
                s.append_outset_shadow(rr, shadow, 0, 2, 0, 6);
                s.push_rounded_clip(rr);
                s.append_color(white, box);
                var inner = Graphene.Rect();
                inner.init((float) c.x - 20, (float) c.y - 20, 40, 40);
                var tex = thumb(c.records[0]);
                if (tex != null) {
                    var ir = Gsk.RoundedRect();
                    ir.init_from_rect(inner, 8);
                    s.push_rounded_clip(ir);
                    double tw = tex.width, th = tex.height, f = double.max(40 / tw, 40 / th);
                    var tr = Graphene.Rect();
                    tr.init((float) (c.x - tw * f / 2), (float) (c.y - th * f / 2), (float) (tw * f), (float) (th * f));
                    s.append_texture(tex, tr);
                    s.pop();
                }
                s.pop();
                if (c.records.size > 1) {
                    var layout = create_pango_layout(c.records.size.to_string());
                    int lw, lh;
                    layout.get_pixel_size(out lw, out lh);
                    float bw = float.max(20, lw + 10);
                    var badge = Graphene.Rect();
                    badge.init((float) c.x + 22 - bw / 2 - 2, (float) c.y - 30, bw, lh + 2);
                    var br = Gsk.RoundedRect();
                    br.init_from_rect(badge, (lh + 2) / 2.0f);
                    s.push_rounded_clip(br);
                    s.append_color(accent, badge);
                    s.pop();
                    s.save();
                    Graphene.Point p = { badge.origin.x + (bw - lw) / 2, badge.origin.y + 1 };
                    s.translate(p);
                    s.append_layout(layout, white);
                    s.restore();
                }
            }
            var attr = create_pango_layout(MapTiles.ATTRIBUTION);
            int aw, ah;
            attr.get_pixel_size(out aw, out ah);
            var ab = Graphene.Rect();
            ab.init(w - aw - 12, h - ah - 6, aw + 8, ah + 2);
            var abg = Gdk.RGBA();
            abg.parse("rgba(255,255,255,0.8)");
            s.append_color(abg, ab);
            s.save();
            Graphene.Point ap = { w - aw - 8, h - ah - 5 };
            s.translate(ap);
            var dark = Gdk.RGBA();
            dark.parse("#333333");
            s.append_layout(attr, dark);
            s.restore();
        }
    }
}
