using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public enum LiquifyBrush {
        FORWARD,
        PUCKER,
        BLOAT,
        TWIRL_CLOCKWISE,
        TWIRL_COUNTER,
        RECONSTRUCT,
        SMOOTH,
        FREEZE,
        THAW
    }

    public class RetouchLiquify : Object {
        public FloatImage source { get; construct; }
        public int grid_w { get; private set; }
        public int grid_h { get; private set; }
        public int step { get; private set; }
        public float[] dx;
        public float[] dy;
        public float[] freeze;

        public RetouchLiquify(FloatImage source) {
            Object(source: source);
            step = int.max(1, int.max(source.width, source.height) / 1024);
            grid_w = (source.width + step - 1) / step + 1;
            grid_h = (source.height + step - 1) / step + 1;
            dx = new float[(size_t) grid_w * grid_h];
            dy = new float[(size_t) grid_w * grid_h];
            freeze = new float[(size_t) grid_w * grid_h];
        }

        public bool is_identity() {
            for (size_t i = 0; i < dx.length; i++) if (dx[i] != 0 || dy[i] != 0) return false;
            return true;
        }

        public void reset() {
            for (size_t i = 0; i < dx.length; i++) {
                dx[i] = 0;
                dy[i] = 0;
            }
        }

        public void apply_brush(LiquifyBrush brush, double cx, double cy, double move_x, double move_y, double radius, double pressure) {
            double gr = radius / step;
            double gcx = cx / step, gcy = cy / step;
            int x0 = int.max(0, (int) (gcx - gr)), x1 = int.min(grid_w - 1, (int) (gcx + gr) + 1);
            int y0 = int.max(0, (int) (gcy - gr)), y1 = int.min(grid_h - 1, (int) (gcy + gr) + 1);
            float[]? old_dx = brush == LiquifyBrush.FORWARD || brush == LiquifyBrush.SMOOTH ? dx.copy() : null;
            float[]? old_dy = old_dx != null ? dy.copy() : null;
            for (int y = y0; y <= y1; y++) {
                for (int x = x0; x <= x1; x++) {
                    double ddx = x - gcx, ddy = y - gcy;
                    double d2 = (ddx * ddx + ddy * ddy) / (gr * gr);
                    if (d2 >= 1) continue;
                    size_t i = (size_t) y * grid_w + x;
                    double wgt = (1 - d2) * (1 - d2) * pressure;
                    if (brush == LiquifyBrush.FREEZE) {
                        freeze[i] = (float) double.min(1, freeze[i] + wgt);
                        continue;
                    }
                    if (brush == LiquifyBrush.THAW) {
                        freeze[i] = (float) double.max(0, freeze[i] - wgt);
                        continue;
                    }
                    wgt *= 1 - freeze[i];
                    if (wgt <= 0) continue;
                    double px = ddx * step, py = ddy * step;
                    switch (brush) {
                        case LiquifyBrush.FORWARD:
                            double sx = x - wgt * move_x / step, sy = y - wgt * move_y / step;
                            dx[i] = sample(old_dx, sx, sy) - (float) (wgt * move_x);
                            dy[i] = sample(old_dy, sx, sy) - (float) (wgt * move_y);
                            break;
                        case LiquifyBrush.PUCKER:
                            dx[i] += (float) (wgt * 0.08 * px);
                            dy[i] += (float) (wgt * 0.08 * py);
                            break;
                        case LiquifyBrush.BLOAT:
                            dx[i] -= (float) (wgt * 0.08 * px);
                            dy[i] -= (float) (wgt * 0.08 * py);
                            break;
                        case LiquifyBrush.TWIRL_CLOCKWISE:
                        case LiquifyBrush.TWIRL_COUNTER:
                            double a = (brush == LiquifyBrush.TWIRL_CLOCKWISE ? -1 : 1) * wgt * 0.08;
                            double qx = px + dx[i], qy = py + dy[i];
                            double rx = qx * Math.cos(a) - qy * Math.sin(a), ry = qx * Math.sin(a) + qy * Math.cos(a);
                            dx[i] = (float) (rx - px);
                            dy[i] = (float) (ry - py);
                            break;
                        case LiquifyBrush.RECONSTRUCT:
                            dx[i] *= (float) (1 - wgt * 0.25);
                            dy[i] *= (float) (1 - wgt * 0.25);
                            break;
                        case LiquifyBrush.SMOOTH:
                            float ax = 0, ay = 0;
                            int n = 0;
                            for (int yy = int.max(0, y - 1); yy <= int.min(grid_h - 1, y + 1); yy++) {
                                for (int xx = int.max(0, x - 1); xx <= int.min(grid_w - 1, x + 1); xx++) {
                                    ax += old_dx[(size_t) yy * grid_w + xx];
                                    ay += old_dy[(size_t) yy * grid_w + xx];
                                    n++;
                                }
                            }
                            dx[i] += (float) (wgt * 0.5) * (ax / n - dx[i]);
                            dy[i] += (float) (wgt * 0.5) * (ay / n - dy[i]);
                            break;
                        default:
                            break;
                    }
                }
            }
        }

        private float sample(float[] field, double x, double y) {
            x = x.clamp(0, grid_w - 1);
            y = y.clamp(0, grid_h - 1);
            int x0 = (int) x, y0 = (int) y;
            int x1 = int.min(x0 + 1, grid_w - 1), y1 = int.min(y0 + 1, grid_h - 1);
            float tx = (float) (x - x0), ty = (float) (y - y0);
            float a = field[(size_t) y0 * grid_w + x0] * (1 - tx) + field[(size_t) y0 * grid_w + x1] * tx;
            float b = field[(size_t) y1 * grid_w + x0] * (1 - tx) + field[(size_t) y1 * grid_w + x1] * tx;
            return a * (1 - ty) + b * ty;
        }

        public FloatImage render() {
            int w = source.width, h = source.height;
            var out_img = new FloatImage(w, h);
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        double gx = (double) x / step, gy = (double) y / step;
                        float ox = sample(dx, gx, gy), oy = sample(dy, gx, gy);
                        size_t d = out_img.offset(x, y);
                        if (ox == 0 && oy == 0) {
                            size_t s = source.offset(x, y);
                            out_img.data[d] = source.data[s];
                            out_img.data[d + 1] = source.data[s + 1];
                            out_img.data[d + 2] = source.data[s + 2];
                            out_img.data[d + 3] = source.data[s + 3];
                            continue;
                        }
                        float r, g, b, a;
                        double sx = x + 0.5 + ox, sy = y + 0.5 + oy;
                        if (sx < 0 || sy < 0 || sx > w || sy > h) {
                            out_img.data[d] = out_img.data[d + 1] = out_img.data[d + 2] = out_img.data[d + 3] = 0;
                            continue;
                        }
                        source.sample(sx, sy, out r, out g, out b, out a);
                        out_img.data[d] = r;
                        out_img.data[d + 1] = g;
                        out_img.data[d + 2] = b;
                        out_img.data[d + 3] = a;
                    }
                }
            });
            return out_img;
        }
    }

    namespace RetouchMesh {

        public double[] homography(double[] src, double[] dst) {
            var a = new double[64];
            var bvec = new double[8];
            for (int i = 0; i < 4; i++) {
                double x = src[i * 2], y = src[i * 2 + 1], u = dst[i * 2], v = dst[i * 2 + 1];
                double[] r1 = { x, y, 1, 0, 0, 0, -u * x, -u * y };
                double[] r2 = { 0, 0, 0, x, y, 1, -v * x, -v * y };
                for (int j = 0; j < 8; j++) {
                    a[(i * 2) * 8 + j] = r1[j];
                    a[(i * 2 + 1) * 8 + j] = r2[j];
                }
                bvec[i * 2] = u;
                bvec[i * 2 + 1] = v;
            }
            for (int c = 0; c < 8; c++) {
                int pivot = c;
                for (int r = c + 1; r < 8; r++) if (a[r * 8 + c].abs() > a[pivot * 8 + c].abs()) pivot = r;
                if (pivot != c) {
                    for (int j = 0; j < 8; j++) {
                        double t = a[c * 8 + j];
                        a[c * 8 + j] = a[pivot * 8 + j];
                        a[pivot * 8 + j] = t;
                    }
                    double t2 = bvec[c];
                    bvec[c] = bvec[pivot];
                    bvec[pivot] = t2;
                }
                double diag = a[c * 8 + c];
                if (diag.abs() < 1e-12) return { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
                for (int r = 0; r < 8; r++) {
                    if (r == c) continue;
                    double f = a[r * 8 + c] / diag;
                    if (f == 0) continue;
                    for (int j = c; j < 8; j++) a[r * 8 + j] -= f * a[c * 8 + j];
                    bvec[r] -= f * bvec[c];
                }
            }
            var hm = new double[9];
            for (int i = 0; i < 8; i++) hm[i] = bvec[i] / a[i * 8 + i];
            hm[8] = 1;
            return hm;
        }

        public void project(double[] hm, double x, double y, out double u, out double v) {
            double wz = hm[6] * x + hm[7] * y + hm[8];
            if (wz.abs() < 1e-12) wz = 1e-12;
            u = (hm[0] * x + hm[1] * y + hm[2]) / wz;
            v = (hm[3] * x + hm[4] * y + hm[5]) / wz;
        }

        public double[] mesh_from_quad(double[] corners, int subdivisions) {
            double[] unit = { 0, 0, 1, 0, 1, 1, 0, 1 };
            var hm = homography(unit, corners);
            int n = subdivisions + 1;
            var pts = new double[n * n * 2];
            for (int j = 0; j < n; j++) {
                for (int i = 0; i < n; i++) {
                    double u, v;
                    project(hm, (double) i / subdivisions, (double) j / subdivisions, out u, out v);
                    pts[(j * n + i) * 2] = u;
                    pts[(j * n + i) * 2 + 1] = v;
                }
            }
            return pts;
        }

        public double[] mesh_from_grid(double[] control, int cols, int rows, int subdivisions) {
            int n = subdivisions + 1;
            var pts = new double[n * n * 2];
            for (int j = 0; j < n; j++) {
                for (int i = 0; i < n; i++) {
                    double u = (double) i / subdivisions * cols, v = (double) j / subdivisions * rows;
                    int ci = int.min((int) u, cols - 1), cj = int.min((int) v, rows - 1);
                    double fu = u - ci, fv = v - cj;
                    int stride = cols + 1;
                    for (int k = 0; k < 2; k++) {
                        double p00 = control[(cj * stride + ci) * 2 + k], p10 = control[(cj * stride + ci + 1) * 2 + k];
                        double p01 = control[((cj + 1) * stride + ci) * 2 + k], p11 = control[((cj + 1) * stride + ci + 1) * 2 + k];
                        pts[(j * n + i) * 2 + k] = (p00 * (1 - fu) + p10 * fu) * (1 - fv) + (p01 * (1 - fu) + p11 * fu) * fv;
                    }
                }
            }
            return pts;
        }

        private void triangle(FloatImage src, FloatImage dst, double ax, double ay, double au, double av,
                              double bx, double by, double bu, double bv, double cx, double cy, double cu, double cv) {
            double den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
            if (den.abs() < 1e-9) return;
            int x0 = int.max(0, (int) Math.floor(double.min(ax, double.min(bx, cx))));
            int x1 = int.min(dst.width - 1, (int) Math.ceil(double.max(ax, double.max(bx, cx))));
            int y0 = int.max(0, (int) Math.floor(double.min(ay, double.min(by, cy))));
            int y1 = int.min(dst.height - 1, (int) Math.ceil(double.max(ay, double.max(by, cy))));
            for (int y = y0; y <= y1; y++) {
                double py = y + 0.5;
                for (int x = x0; x <= x1; x++) {
                    double px = x + 0.5;
                    double l1 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / den;
                    double l2 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / den;
                    double l3 = 1 - l1 - l2;
                    if (l1 < -1e-7 || l2 < -1e-7 || l3 < -1e-7) continue;
                    double u = l1 * au + l2 * bu + l3 * cu, v = l1 * av + l2 * bv + l3 * cv;
                    if (u < 0 || v < 0 || u > src.width || v > src.height) continue;
                    float r, g, b, a;
                    src.sample(u, v, out r, out g, out b, out a);
                    size_t d = dst.offset(x, y);
                    dst.data[d] = r;
                    dst.data[d + 1] = g;
                    dst.data[d + 2] = b;
                    dst.data[d + 3] = a;
                }
            }
        }

        public FloatImage render(FloatImage src, double[] mesh, int subdivisions, int out_w, int out_h) {
            var dst = new FloatImage(out_w, out_h);
            dst.fill(0, 0, 0, 0);
            int n = subdivisions + 1;
            double sw = src.width, sh = src.height;
            Parallel.range(subdivisions, (start, end) => {
                for (int j = start; j < end; j++) {
                    for (int i = 0; i < subdivisions; i++) {
                        int a = j * n + i, b = a + 1, c = a + n, d = c + 1;
                        double ua = sw * i / subdivisions, ub = sw * (i + 1) / subdivisions;
                        double va = sh * j / subdivisions, vc = sh * (j + 1) / subdivisions;
                        triangle(src, dst, mesh[a * 2], mesh[a * 2 + 1], ua, va, mesh[b * 2], mesh[b * 2 + 1], ub, va, mesh[d * 2], mesh[d * 2 + 1], ub, vc);
                        triangle(src, dst, mesh[a * 2], mesh[a * 2 + 1], ua, va, mesh[d * 2], mesh[d * 2 + 1], ub, vc, mesh[c * 2], mesh[c * 2 + 1], ua, vc);
                    }
                }
            }, 1);
            return dst;
        }
    }
}
