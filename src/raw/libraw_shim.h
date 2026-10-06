#ifndef SINTY_LIBRAW_SHIM_H
#define SINTY_LIBRAW_SHIM_H

#include <glib.h>

int sinty_libraw_available(void);
const char *sinty_libraw_version(void);
int sinty_libraw_decode(const char *path, int demosaic, guint16 **pixels, int *width, int *height,
                        float *cam_mul, float *pre_mul, float *rgb_cam, char *make, char *model, char **error);

#endif
