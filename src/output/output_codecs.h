#ifndef SINTY_OUTPUT_CODECS_H
#define SINTY_OUTPUT_CODECS_H

#include <stdint.h>

int sinty_webp_encode (const uint8_t *rgba, int width, int height, float quality, int lossless,
                       const uint8_t *icc, int icc_len, const uint8_t *exif, int exif_len,
                       const uint8_t *xmp, int xmp_len, uint8_t **out, int *out_len);
int sinty_webp_decode (const uint8_t *data, int len, int *width, int *height, uint8_t **rgba, int *rgba_len,
                       uint8_t **icc, int *icc_len);
int sinty_tiff_write (const char *path, const void *pixels, int width, int height, int channels, int bits,
                      int is_float, const uint8_t *icc, int icc_len, const uint8_t *xmp, int xmp_len,
                      int compress, char **error);
int sinty_tiff_read (const char *path, int *width, int *height, int *bits, int *is_float, float **rgba, int *rgba_len,
                     uint8_t **icc, int *icc_len);
int sinty_heif_can_encode (int avif);
int sinty_heif_can_decode (int avif);
int sinty_heif_encode (const char *path, const uint16_t *rgba, int width, int height, int bit_depth, int avif,
                       int quality, int lossless, const uint8_t *icc, int icc_len, const uint8_t *exif, int exif_len,
                       const uint8_t *xmp, int xmp_len, char **error);
int sinty_heif_decode (const char *path, int *width, int *height, float **rgba, int *rgba_len, uint8_t **icc,
                       int *icc_len, char **error);
int sinty_jxl_available (void);
int sinty_jxl_encode (const char *path, const float *rgba, int width, int height, int bits, float distance,
                      int lossless, const uint8_t *icc, int icc_len, const uint8_t *exif, int exif_len,
                      const uint8_t *xmp, int xmp_len, char **error);
int sinty_jxl_decode (const char *path, int *width, int *height, float **rgba, int *rgba_len, uint8_t **icc,
                      int *icc_len, char **error);

#endif
