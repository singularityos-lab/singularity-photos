namespace Singularity.Apps.Photos {

    public struct TrackPoint {
        public int64 time;
        public double latitude;
        public double longitude;
        public double elevation;
    }

    public class GpxTrack : Object {
        public TrackPoint[] points = {};

        public static GpxTrack parse(string xml) throws Error {
            var track = new GpxTrack();
            var re_pt = new Regex("<(?:trkpt|rtept|wpt)\\b([^>]*)>(.*?)</(?:trkpt|rtept|wpt)>", RegexCompileFlags.DOTALL);
            var re_lat = new Regex("lat\\s*=\\s*[\"']([-0-9.eE+]+)[\"']");
            var re_lon = new Regex("lon\\s*=\\s*[\"']([-0-9.eE+]+)[\"']");
            var re_time = new Regex("<time>\\s*([^<]+?)\\s*</time>");
            var re_ele = new Regex("<ele>\\s*([^<]+?)\\s*</ele>");
            MatchInfo mi;
            TrackPoint[] pts = {};
            if (re_pt.match(xml, 0, out mi)) {
                do {
                    string attrs = mi.fetch(1), body = mi.fetch(2);
                    MatchInfo m2;
                    if (!re_lat.match(attrs, 0, out m2)) continue;
                    double lat = double.parse(m2.fetch(1));
                    if (!re_lon.match(attrs, 0, out m2)) continue;
                    double lon = double.parse(m2.fetch(1));
                    if (!re_time.match(body, 0, out m2)) continue;
                    var dt = new DateTime.from_iso8601(m2.fetch(1), new TimeZone.utc());
                    if (dt == null) continue;
                    double ele = 0;
                    if (re_ele.match(body, 0, out m2)) ele = double.parse(m2.fetch(1));
                    pts += TrackPoint() { time = dt.to_unix(), latitude = lat, longitude = lon, elevation = ele };
                } while (mi.next());
            }
            for (int i = 1; i < pts.length; i++) {
                var key = pts[i];
                int j = i - 1;
                while (j >= 0 && pts[j].time > key.time) {
                    pts[j + 1] = pts[j];
                    j--;
                }
                pts[j + 1] = key;
            }
            track.points = pts;
            return track;
        }

        public bool locate(int64 time, int64 tolerance, out double latitude, out double longitude) {
            latitude = 0;
            longitude = 0;
            int n = points.length;
            if (n == 0) return false;
            if (time <= points[0].time) {
                if (points[0].time - time > tolerance) return false;
                latitude = points[0].latitude;
                longitude = points[0].longitude;
                return true;
            }
            if (time >= points[n - 1].time) {
                if (time - points[n - 1].time > tolerance) return false;
                latitude = points[n - 1].latitude;
                longitude = points[n - 1].longitude;
                return true;
            }
            int lo = 0, hi = n - 1;
            while (hi - lo > 1) {
                int mid = (lo + hi) / 2;
                if (points[mid].time <= time) lo = mid;
                else hi = mid;
            }
            var a = points[lo];
            var b = points[hi];
            if (b.time - a.time > tolerance * 2 && time - a.time > tolerance && b.time - time > tolerance) return false;
            double t = b.time == a.time ? 0 : (double) (time - a.time) / (b.time - a.time);
            latitude = a.latitude + (b.latitude - a.latitude) * t;
            longitude = a.longitude + (b.longitude - a.longitude) * t;
            return true;
        }

        public int tag(Catalog catalog, Gee.List<PhotoRecord> photos, int64 offset_seconds, int64 tolerance = 300) {
            int tagged = 0;
            catalog.begin();
            foreach (var r in photos) {
                if (r.captured <= 0) continue;
                var local = new DateTime.from_unix_local(r.captured);
                int64 utc = local.to_unix() + offset_seconds;
                double lat, lon;
                if (!locate(utc, tolerance, out lat, out lon)) continue;
                r.has_gps = true;
                r.latitude = lat;
                r.longitude = lon;
                catalog.save(r);
                tagged++;
            }
            catalog.commit();
            return tagged;
        }
    }

    namespace PeopleClustering {

        public double distance(float[] a, float[] b) {
            if (a.length == 0 || a.length != b.length) return double.MAX;
            double s = 0;
            for (int i = 0; i < a.length; i++) {
                double d = a[i] - b[i];
                s += d * d;
            }
            return Math.sqrt(s);
        }

        private class Centroid {
            public float[] values;
        }

        public int cluster(Catalog catalog, double threshold) {
            int assigned = 0;
            var centroids = new Gee.HashMap<int64?, Centroid>(id_hash, id_equal);
            var counts = new Gee.HashMap<int64?, int>(id_hash, id_equal);
            var confirmed_people = new Gee.HashSet<int64?>(id_hash, id_equal);
            foreach (var f in catalog.faces.values) if (f.person_id != 0 && f.confirmed()) confirmed_people.add(f.person_id);
            foreach (var f in catalog.faces.values) {
                if (f.person_id == 0 || f.descriptor.length == 0) continue;
                if (confirmed_people.contains(f.person_id) && !f.confirmed()) continue;
                if (!centroids.has_key(f.person_id)) {
                    var fresh = new Centroid();
                    fresh.values = new float[f.descriptor.length];
                    centroids[f.person_id] = fresh;
                    counts[f.person_id] = 0;
                }
                var c = centroids[f.person_id].values;
                if (c.length != f.descriptor.length) continue;
                for (int i = 0; i < c.length; i++) c[i] += f.descriptor[i];
                counts[f.person_id] = counts[f.person_id] + 1;
            }
            foreach (var e in centroids.entries) {
                int n = counts[e.key];
                for (int i = 0; i < e.value.values.length; i++) e.value.values[i] /= n;
            }
            catalog.begin();
            foreach (var f in catalog.faces.values.to_array()) {
                if (f.person_id != 0 || f.rejected() || f.descriptor.length == 0) continue;
                int64 best = 0;
                double best_d = threshold;
                foreach (var e in centroids.entries) {
                    double d = distance(f.descriptor, e.value.values);
                    if (d < best_d) {
                        best_d = d;
                        best = e.key;
                    }
                }
                if (best == 0) {
                    var p = catalog.create_person("");
                    best = p.id;
                    var fresh = new Centroid();
                    fresh.values = f.descriptor.copy();
                    centroids[best] = fresh;
                    counts[best] = 1;
                }
                catalog.set_face_person(f, best);
                assigned++;
            }
            catalog.commit();
            return assigned;
        }
    }
}
