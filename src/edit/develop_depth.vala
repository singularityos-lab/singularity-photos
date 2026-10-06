using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace DepthEstimate {

        public float[] from_defocus(FloatImage img) {
            int w = img.width, h = img.height;
            size_t n = img.pixel_count();
            var l = new float[n];
            for (size_t i = 0; i < n; i++)
                l[i] = Transfer.linear_to_srgb(WorkingSpace.luminance(img.data[i * 4], img.data[i * 4 + 1], img.data[i * 4 + 2]).clamp(0, 1));
            double sigma0 = 1.0;
            var re = Filters.gaussian_plane(l, w, h, sigma0);
            var sparse = new float[n];
            var confidence = new float[n];
            Parallel.range(h, (start, end) => {
                for (int y = start; y < end; y++) {
                    for (int x = 0; x < w; x++) {
                        size_t i = (size_t) y * w + x;
                        int xl = int.max(0, x - 1), xr = int.min(w - 1, x + 1), yu = int.max(0, y - 1), yd = int.min(h - 1, y + 1);
                        float gx = l[(size_t) y * w + xr] - l[(size_t) y * w + xl];
                        float gy = l[(size_t) yd * w + x] - l[(size_t) yu * w + x];
                        float rx = re[(size_t) y * w + xr] - re[(size_t) y * w + xl];
                        float ry = re[(size_t) yd * w + x] - re[(size_t) yu * w + x];
                        float g1 = Math.sqrtf(gx * gx + gy * gy), g2 = Math.sqrtf(rx * rx + ry * ry);
                        if (g1 < 0.02f || g2 < 1e-5f) continue;
                        float ratio = g1 / g2;
                        if (ratio <= 1.001f) continue;
                        float blur = (float) (sigma0 / Math.sqrt(ratio * ratio - 1));
                        sparse[i] = blur.clamp(0, 8) / 8.0f;
                        confidence[i] = g1;
                    }
                }
            });
            int radius = int.max(4, int.min(w, h) / 12);
            var num = new float[n];
            for (size_t i = 0; i < n; i++) num[i] = sparse[i] * confidence[i];
            var sn = Filters.box_plane(num, w, h, radius);
            var sc = Filters.box_plane(confidence, w, h, radius);
            var dense = new float[n];
            for (size_t i = 0; i < n; i++) dense[i] = sc[i] > 1e-5f ? sn[i] / sc[i] : 1.0f;
            var refined = Filters.guided_plane(l, dense, w, h, radius / 2 + 1, 0.01f);
            float lo = float.MAX, hi = -float.MAX;
            for (size_t i = 0; i < n; i++) {
                lo = float.min(lo, refined[i]);
                hi = float.max(hi, refined[i]);
            }
            float range = float.max(hi - lo, 1e-5f);
            for (size_t i = 0; i < n; i++) refined[i] = ((refined[i] - lo) / range).clamp(0, 1);
            return refined;
        }
    }
}
