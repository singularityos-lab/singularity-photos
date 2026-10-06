#include <glib.h>
#include "libraw_shim.h"
#include <gmodule.h>
#include <string.h>
#include <stdint.h>

typedef void *(*lr_init_fn)(unsigned int);
typedef int (*lr_path_fn)(void *, const char *);
typedef int (*lr_int_fn)(void *);
typedef void (*lr_void_fn)(void *);
typedef void (*lr_set_int_fn)(void *, int);
typedef void (*lr_set_gamma_fn)(void *, int, float);
typedef void (*lr_set_float_fn)(void *, float);
typedef void (*lr_set_user_mul_fn)(void *, int, float);
typedef float (*lr_get_mul_fn)(void *, int);
typedef float (*lr_get_rgb_cam_fn)(void *, int, int);
typedef void *(*lr_make_image_fn)(void *, int *);
typedef void (*lr_clear_mem_fn)(void *);
typedef const char *(*lr_strerror_fn)(int);
typedef const char *(*lr_version_fn)(void);
typedef void *(*lr_get_iparams_fn)(void *);

static GModule *libraw_module = NULL;
static gboolean libraw_tried = FALSE;
static GMutex libraw_lock;

static struct {
    lr_init_fn init;
    lr_path_fn open_file;
    lr_int_fn unpack;
    lr_int_fn dcraw_process;
    lr_void_fn close;
    lr_set_int_fn set_output_bps;
    lr_set_gamma_fn set_gamma;
    lr_set_int_fn set_no_auto_bright;
    lr_set_int_fn set_output_color;
    lr_set_user_mul_fn set_user_mul;
    lr_set_int_fn set_highlight;
    lr_set_int_fn set_demosaic;
    lr_set_float_fn set_adjust_maximum_thr;
    lr_get_mul_fn get_cam_mul;
    lr_get_mul_fn get_pre_mul;
    lr_get_rgb_cam_fn get_rgb_cam;
    lr_make_image_fn make_mem_image;
    lr_clear_mem_fn clear_mem;
    lr_strerror_fn strerror;
    lr_version_fn version;
    lr_get_iparams_fn get_iparams;
} lr;

static gboolean load_symbol(const char *name, gpointer *slot)
{
    return g_module_symbol(libraw_module, name, slot) && *slot != NULL;
}

int sinty_libraw_available(void)
{
    static const char *names[] = {
        "libraw_r.so.25", "libraw_r.so.24", "libraw_r.so.23", "libraw_r.so",
        "libraw.so.25", "libraw.so.24", "libraw.so.23", "libraw.so", NULL
    };
    g_mutex_lock(&libraw_lock);
    if (!libraw_tried) {
        libraw_tried = TRUE;
        const char *forced = g_getenv("SINGULARITY_PHOTOS_LIBRAW");
        if (forced != NULL && *forced != '\0')
            libraw_module = g_module_open(forced, G_MODULE_BIND_LAZY | G_MODULE_BIND_LOCAL);
        for (int i = 0; libraw_module == NULL && names[i] != NULL; i++)
            libraw_module = g_module_open(names[i], G_MODULE_BIND_LAZY | G_MODULE_BIND_LOCAL);
        if (libraw_module != NULL) {
            gboolean ok = TRUE;
            ok &= load_symbol("libraw_init", (gpointer *) &lr.init);
            ok &= load_symbol("libraw_open_file", (gpointer *) &lr.open_file);
            ok &= load_symbol("libraw_unpack", (gpointer *) &lr.unpack);
            ok &= load_symbol("libraw_dcraw_process", (gpointer *) &lr.dcraw_process);
            ok &= load_symbol("libraw_close", (gpointer *) &lr.close);
            ok &= load_symbol("libraw_set_output_bps", (gpointer *) &lr.set_output_bps);
            ok &= load_symbol("libraw_set_gamma", (gpointer *) &lr.set_gamma);
            ok &= load_symbol("libraw_set_no_auto_bright", (gpointer *) &lr.set_no_auto_bright);
            ok &= load_symbol("libraw_set_output_color", (gpointer *) &lr.set_output_color);
            ok &= load_symbol("libraw_set_user_mul", (gpointer *) &lr.set_user_mul);
            ok &= load_symbol("libraw_set_highlight", (gpointer *) &lr.set_highlight);
            ok &= load_symbol("libraw_get_cam_mul", (gpointer *) &lr.get_cam_mul);
            ok &= load_symbol("libraw_get_pre_mul", (gpointer *) &lr.get_pre_mul);
            ok &= load_symbol("libraw_get_rgb_cam", (gpointer *) &lr.get_rgb_cam);
            ok &= load_symbol("libraw_dcraw_make_mem_image", (gpointer *) &lr.make_mem_image);
            ok &= load_symbol("libraw_dcraw_clear_mem", (gpointer *) &lr.clear_mem);
            ok &= load_symbol("libraw_strerror", (gpointer *) &lr.strerror);
            load_symbol("libraw_set_demosaic", (gpointer *) &lr.set_demosaic);
            load_symbol("libraw_set_adjust_maximum_thr", (gpointer *) &lr.set_adjust_maximum_thr);
            load_symbol("libraw_version", (gpointer *) &lr.version);
            load_symbol("libraw_get_iparams", (gpointer *) &lr.get_iparams);
            if (!ok) {
                g_module_close(libraw_module);
                libraw_module = NULL;
            }
        }
    }
    int available = libraw_module != NULL;
    g_mutex_unlock(&libraw_lock);
    return available;
}

const char *sinty_libraw_version(void)
{
    if (!sinty_libraw_available() || lr.version == NULL)
        return "";
    return lr.version();
}

int sinty_libraw_decode(const char *path, int demosaic, guint16 **pixels, int *width, int *height,
                        float *cam_mul, float *pre_mul, float *rgb_cam, char *make, char *model, char **error)
{
    *pixels = NULL;
    *width = 0;
    *height = 0;
    *error = NULL;
    if (!sinty_libraw_available()) {
        *error = g_strdup("LibRaw is not available on this system");
        return -1;
    }
    void *handle = lr.init(0);
    if (handle == NULL) {
        *error = g_strdup("LibRaw could not start");
        return -1;
    }
    int rc = lr.open_file(handle, path);
    if (rc == 0)
        rc = lr.unpack(handle);
    if (rc != 0) {
        *error = g_strdup(lr.strerror(rc));
        lr.close(handle);
        return rc;
    }
    for (int c = 0; c < 4; c++) {
        cam_mul[c] = lr.get_cam_mul(handle, c);
        pre_mul[c] = lr.get_pre_mul(handle, c);
        lr.set_user_mul(handle, c, 1.0f);
    }
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 4; j++)
            rgb_cam[i * 4 + j] = lr.get_rgb_cam(handle, i, j);
    if (lr.get_iparams != NULL) {
        const char *ip = (const char *) lr.get_iparams(handle);
        if (ip != NULL) {
            memcpy(make, ip + 4, 63);
            make[63] = '\0';
            memcpy(model, ip + 68, 63);
            model[63] = '\0';
        }
    }
    lr.set_output_bps(handle, 16);
    lr.set_gamma(handle, 0, 1.0f);
    lr.set_gamma(handle, 1, 1.0f);
    lr.set_no_auto_bright(handle, 1);
    lr.set_output_color(handle, 0);
    lr.set_highlight(handle, 0);
    if (lr.set_adjust_maximum_thr != NULL)
        lr.set_adjust_maximum_thr(handle, 0.0f);
    if (lr.set_demosaic != NULL && demosaic >= 0)
        lr.set_demosaic(handle, demosaic);
    rc = lr.dcraw_process(handle);
    if (rc != 0) {
        *error = g_strdup(lr.strerror(rc));
        lr.close(handle);
        return rc;
    }
    int err = 0;
    unsigned char *image = lr.make_mem_image(handle, &err);
    if (image == NULL || err != 0) {
        *error = g_strdup(lr.strerror(err));
        lr.close(handle);
        return err != 0 ? err : -1;
    }
    guint16 h = *(guint16 *) (image + 4);
    guint16 w = *(guint16 *) (image + 6);
    guint16 colors = *(guint16 *) (image + 8);
    guint16 bits = *(guint16 *) (image + 10);
    const unsigned char *data = image + 16;
    guint16 *out = g_new(guint16, (gsize) w * h * 3);
    for (gsize i = 0; i < (gsize) w * h; i++) {
        for (int c = 0; c < 3; c++) {
            int sc = colors >= 3 ? c : 0;
            guint16 v;
            if (bits == 16)
                v = ((const guint16 *) data)[i * colors + sc];
            else
                v = (guint16) (data[i * colors + sc] * 257);
            out[i * 3 + c] = v;
        }
    }
    lr.clear_mem(image);
    lr.close(handle);
    *pixels = out;
    *width = w;
    *height = h;
    return 0;
}
