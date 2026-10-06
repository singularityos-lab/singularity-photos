#include <glib.h>
#include <gmodule.h>
#include <string.h>
#include <stdint.h>
#include <tiffio.h>
#include <webp/encode.h>
#include <webp/decode.h>
#include <webp/mux.h>

#include "output_codecs.h"

static void
set_error (char **error, const char *message)
{
  if (error != NULL)
    *error = g_strdup (message != NULL ? message : "unknown error");
}

int
sinty_webp_encode (const uint8_t *rgba, int width, int height, float quality, int lossless,
                   const uint8_t *icc, int icc_len, const uint8_t *exif, int exif_len,
                   const uint8_t *xmp, int xmp_len, uint8_t **out, int *out_len)
{
  uint8_t *encoded = NULL;
  size_t size;
  WebPMux *mux;
  WebPData image, chunk, assembled;
  int ok = 0;

  *out = NULL;
  *out_len = 0;
  if (lossless)
    size = WebPEncodeLosslessRGBA (rgba, width, height, width * 4, &encoded);
  else
    size = WebPEncodeRGBA (rgba, width, height, width * 4, quality, &encoded);
  if (size == 0 || encoded == NULL)
    return 0;
  if (icc_len <= 0 && exif_len <= 0 && xmp_len <= 0)
    {
      *out = g_memdup2 (encoded, size);
      *out_len = (int) size;
      WebPFree (encoded);
      return 1;
    }
  mux = WebPMuxNew ();
  image.bytes = encoded;
  image.size = size;
  if (WebPMuxSetImage (mux, &image, 1) != WEBP_MUX_OK)
    goto done;
  if (icc_len > 0)
    {
      chunk.bytes = icc;
      chunk.size = icc_len;
      WebPMuxSetChunk (mux, "ICCP", &chunk, 1);
    }
  if (exif_len > 0)
    {
      chunk.bytes = exif;
      chunk.size = exif_len;
      WebPMuxSetChunk (mux, "EXIF", &chunk, 1);
    }
  if (xmp_len > 0)
    {
      chunk.bytes = xmp;
      chunk.size = xmp_len;
      WebPMuxSetChunk (mux, "XMP ", &chunk, 1);
    }
  WebPDataInit (&assembled);
  if (WebPMuxAssemble (mux, &assembled) == WEBP_MUX_OK)
    {
      *out = g_memdup2 (assembled.bytes, assembled.size);
      *out_len = (int) assembled.size;
      ok = 1;
    }
  WebPDataClear (&assembled);
done:
  WebPMuxDelete (mux);
  WebPFree (encoded);
  return ok;
}

int
sinty_webp_decode (const uint8_t *data, int len, int *width, int *height, uint8_t **rgba, int *rgba_len,
                   uint8_t **icc, int *icc_len)
{
  uint8_t *decoded;
  WebPData input;
  WebPData chunk;
  WebPMux *mux;

  *rgba = NULL;
  *rgba_len = 0;
  *icc = NULL;
  *icc_len = 0;
  decoded = WebPDecodeRGBA (data, len, width, height);
  if (decoded == NULL)
    return 0;
  *rgba_len = *width * *height * 4;
  *rgba = g_memdup2 (decoded, *rgba_len);
  WebPFree (decoded);
  input.bytes = data;
  input.size = len;
  mux = WebPMuxCreate (&input, 0);
  if (mux != NULL)
    {
      if (WebPMuxGetChunk (mux, "ICCP", &chunk) == WEBP_MUX_OK && chunk.size > 0)
        {
          *icc = g_memdup2 (chunk.bytes, chunk.size);
          *icc_len = (int) chunk.size;
        }
      WebPMuxDelete (mux);
    }
  return 1;
}

int
sinty_tiff_write (const char *path, const void *pixels, int width, int height, int channels, int bits,
                  int is_float, const uint8_t *icc, int icc_len, const uint8_t *xmp, int xmp_len,
                  int compress, char **error)
{
  TIFF *tif;
  int bytes = bits / 8;
  tsize_t row = (tsize_t) width * channels * bytes;
  uint8_t *line;
  int y;

  tif = TIFFOpen (path, "w");
  if (tif == NULL)
    {
      set_error (error, "Cannot create the TIFF file");
      return 0;
    }
  TIFFSetField (tif, TIFFTAG_IMAGEWIDTH, (uint32_t) width);
  TIFFSetField (tif, TIFFTAG_IMAGELENGTH, (uint32_t) height);
  TIFFSetField (tif, TIFFTAG_SAMPLESPERPIXEL, (uint16_t) channels);
  TIFFSetField (tif, TIFFTAG_BITSPERSAMPLE, (uint16_t) bits);
  TIFFSetField (tif, TIFFTAG_SAMPLEFORMAT, (uint16_t) (is_float ? SAMPLEFORMAT_IEEEFP : SAMPLEFORMAT_UINT));
  TIFFSetField (tif, TIFFTAG_PHOTOMETRIC, (uint16_t) PHOTOMETRIC_RGB);
  TIFFSetField (tif, TIFFTAG_PLANARCONFIG, (uint16_t) PLANARCONFIG_CONTIG);
  TIFFSetField (tif, TIFFTAG_ORIENTATION, (uint16_t) ORIENTATION_TOPLEFT);
  TIFFSetField (tif, TIFFTAG_ROWSPERSTRIP, TIFFDefaultStripSize (tif, 0));
  if (compress)
    {
      TIFFSetField (tif, TIFFTAG_COMPRESSION, (uint16_t) COMPRESSION_ADOBE_DEFLATE);
      TIFFSetField (tif, TIFFTAG_PREDICTOR, (uint16_t) (is_float ? PREDICTOR_FLOATINGPOINT : PREDICTOR_HORIZONTAL));
    }
  else
    {
      TIFFSetField (tif, TIFFTAG_COMPRESSION, (uint16_t) COMPRESSION_NONE);
    }
  if (channels == 4)
    {
      uint16_t extra = EXTRASAMPLE_UNASSALPHA;
      TIFFSetField (tif, TIFFTAG_EXTRASAMPLES, (uint16_t) 1, &extra);
    }
  if (icc_len > 0)
    TIFFSetField (tif, TIFFTAG_ICCPROFILE, (uint32_t) icc_len, icc);
  if (xmp_len > 0)
    TIFFSetField (tif, TIFFTAG_XMLPACKET, (uint32_t) xmp_len, xmp);
  TIFFSetField (tif, TIFFTAG_SOFTWARE, "Singularity Photos");
  line = g_malloc (row);
  for (y = 0; y < height; y++)
    {
      memcpy (line, (const uint8_t *) pixels + (size_t) y * row, row);
      if (TIFFWriteScanline (tif, line, y, 0) < 0)
        {
          g_free (line);
          TIFFClose (tif);
          set_error (error, "Cannot write the TIFF data");
          return 0;
        }
    }
  g_free (line);
  TIFFClose (tif);
  return 1;
}

int
sinty_tiff_read (const char *path, int *width, int *height, int *bits, int *is_float, float **rgba, int *rgba_len,
                 uint8_t **icc, int *icc_len)
{
  TIFF *tif;
  uint32_t w = 0, h = 0;
  uint16_t spp = 1, bps = 8, fmt = SAMPLEFORMAT_UINT, photometric = PHOTOMETRIC_RGB, planar = PLANARCONFIG_CONTIG;
  uint32_t profile_len = 0;
  void *profile = NULL;
  uint8_t *line;
  uint32_t y, x;

  *rgba = NULL;
  *rgba_len = 0;
  *icc = NULL;
  *icc_len = 0;
  tif = TIFFOpen (path, "r");
  if (tif == NULL)
    return 0;
  TIFFGetField (tif, TIFFTAG_IMAGEWIDTH, &w);
  TIFFGetField (tif, TIFFTAG_IMAGELENGTH, &h);
  TIFFGetFieldDefaulted (tif, TIFFTAG_SAMPLESPERPIXEL, &spp);
  TIFFGetFieldDefaulted (tif, TIFFTAG_BITSPERSAMPLE, &bps);
  TIFFGetFieldDefaulted (tif, TIFFTAG_SAMPLEFORMAT, &fmt);
  TIFFGetFieldDefaulted (tif, TIFFTAG_PLANARCONFIG, &planar);
  TIFFGetField (tif, TIFFTAG_PHOTOMETRIC, &photometric);
  if (planar != PLANARCONFIG_CONTIG || (photometric != PHOTOMETRIC_RGB && photometric != PHOTOMETRIC_MINISBLACK)
      || (bps != 8 && bps != 16 && bps != 32) || spp < 1 || spp > 4 || TIFFIsTiled (tif))
    {
      TIFFClose (tif);
      return 0;
    }
  if (TIFFGetField (tif, TIFFTAG_ICCPROFILE, &profile_len, &profile) && profile_len > 0)
    {
      *icc = g_memdup2 (profile, profile_len);
      *icc_len = (int) profile_len;
    }
  *width = (int) w;
  *height = (int) h;
  *bits = bps;
  *is_float = fmt == SAMPLEFORMAT_IEEEFP;
  *rgba_len = (int) (w * h * 4);
  *rgba = g_malloc ((size_t) w * h * 4 * sizeof (float));
  line = g_malloc (TIFFScanlineSize (tif));
  for (y = 0; y < h; y++)
    {
      if (TIFFReadScanline (tif, line, y, 0) < 0)
        break;
      for (x = 0; x < w; x++)
        {
          float v[4] = { 0, 0, 0, 1 };
          int c;
          for (c = 0; c < spp; c++)
            {
              size_t i = (size_t) x * spp + c;
              float s;
              if (bps == 8)
                s = line[i] / 255.0f;
              else if (bps == 16)
                s = ((uint16_t *) line)[i] / 65535.0f;
              else if (fmt == SAMPLEFORMAT_IEEEFP)
                s = ((float *) line)[i];
              else
                s = ((uint32_t *) line)[i] / 4294967295.0f;
              v[c] = s;
            }
          if (spp <= 2)
            {
              if (spp == 2)
                v[3] = v[1];
              v[1] = v[0];
              v[2] = v[0];
            }
          memcpy (*rgba + ((size_t) y * w + x) * 4, v, sizeof (v));
        }
    }
  g_free (line);
  TIFFClose (tif);
  return 1;
}

typedef struct { int code; int subcode; const char *message; } HeifError;
typedef struct heif_context heif_context;
typedef struct heif_image heif_image;
typedef struct heif_image_handle heif_image_handle;
typedef struct heif_encoder heif_encoder;

static struct {
  gboolean tried;
  GModule *module;
  void (*init) (void *);
  heif_context *(*context_alloc) (void);
  void (*context_free) (heif_context *);
  HeifError (*get_encoder_for_format) (heif_context *, int, heif_encoder **);
  HeifError (*encoder_set_lossy_quality) (heif_encoder *, int);
  HeifError (*encoder_set_lossless) (heif_encoder *, int);
  void (*encoder_release) (heif_encoder *);
  HeifError (*image_create) (int, int, int, int, heif_image **);
  HeifError (*image_add_plane) (heif_image *, int, int, int, int);
  uint8_t *(*image_get_plane) (heif_image *, int, int *);
  const uint8_t *(*image_get_plane_readonly) (const heif_image *, int, int *);
  HeifError (*image_set_raw_color_profile) (heif_image *, const char *, const void *, size_t);
  void (*image_release) (const heif_image *);
  HeifError (*context_encode_image) (heif_context *, const heif_image *, heif_encoder *, const void *, heif_image_handle **);
  HeifError (*add_exif) (heif_context *, const heif_image_handle *, const void *, int);
  HeifError (*add_xmp) (heif_context *, const heif_image_handle *, const void *, int);
  HeifError (*write_to_file) (heif_context *, const char *);
  void (*handle_release) (const heif_image_handle *);
  HeifError (*read_from_file) (heif_context *, const char *, const void *);
  HeifError (*get_primary) (heif_context *, heif_image_handle **);
  int (*handle_bits) (const heif_image_handle *);
  int (*handle_has_alpha) (const heif_image_handle *);
  HeifError (*decode_image) (const heif_image_handle *, heif_image **, int, int, const void *);
  int (*image_get_width) (const heif_image *, int);
  int (*image_get_height) (const heif_image *, int);
  size_t (*profile_size) (const heif_image_handle *);
  HeifError (*profile_get) (const heif_image_handle *, void *);
  int (*have_encoder) (int);
  int (*have_decoder) (int);
} heif;

static gboolean
heif_load (void)
{
  static const char *names[] = { "libheif.so.1", "libheif.so", NULL };
  int i;

  if (heif.tried)
    return heif.module != NULL;
  heif.tried = TRUE;
  for (i = 0; names[i] != NULL && heif.module == NULL; i++)
    heif.module = g_module_open (names[i], G_MODULE_BIND_LAZY | G_MODULE_BIND_LOCAL);
  if (heif.module == NULL)
    return FALSE;
#define SYM(field, name) if (!g_module_symbol (heif.module, name, (gpointer *) &heif.field)) goto fail
  SYM (context_alloc, "heif_context_alloc");
  SYM (context_free, "heif_context_free");
  SYM (get_encoder_for_format, "heif_context_get_encoder_for_format");
  SYM (encoder_set_lossy_quality, "heif_encoder_set_lossy_quality");
  SYM (encoder_set_lossless, "heif_encoder_set_lossless");
  SYM (encoder_release, "heif_encoder_release");
  SYM (image_create, "heif_image_create");
  SYM (image_add_plane, "heif_image_add_plane");
  SYM (image_get_plane, "heif_image_get_plane");
  SYM (image_get_plane_readonly, "heif_image_get_plane_readonly");
  SYM (image_set_raw_color_profile, "heif_image_set_raw_color_profile");
  SYM (image_release, "heif_image_release");
  SYM (context_encode_image, "heif_context_encode_image");
  SYM (add_exif, "heif_context_add_exif_metadata");
  SYM (add_xmp, "heif_context_add_XMP_metadata");
  SYM (write_to_file, "heif_context_write_to_file");
  SYM (handle_release, "heif_image_handle_release");
  SYM (read_from_file, "heif_context_read_from_file");
  SYM (get_primary, "heif_context_get_primary_image_handle");
  SYM (handle_bits, "heif_image_handle_get_luma_bits_per_pixel");
  SYM (handle_has_alpha, "heif_image_handle_has_alpha_channel");
  SYM (decode_image, "heif_decode_image");
  SYM (image_get_width, "heif_image_get_width");
  SYM (image_get_height, "heif_image_get_height");
  SYM (profile_size, "heif_image_handle_get_raw_color_profile_size");
  SYM (profile_get, "heif_image_handle_get_raw_color_profile");
  SYM (have_encoder, "heif_have_encoder_for_format");
  SYM (have_decoder, "heif_have_decoder_for_format");
#undef SYM
  if (g_module_symbol (heif.module, "heif_init", (gpointer *) &heif.init) && heif.init != NULL)
    heif.init (NULL);
  return TRUE;
fail:
  g_module_close (heif.module);
  heif.module = NULL;
  return FALSE;
}

static int
heif_format_code (int avif)
{
  return avif ? 4 : 1;
}

int
sinty_heif_can_encode (int avif)
{
  return heif_load () && heif.have_encoder (heif_format_code (avif));
}

int
sinty_heif_can_decode (int avif)
{
  return heif_load () && heif.have_decoder (heif_format_code (avif));
}

int
sinty_heif_encode (const char *path, const uint16_t *rgba, int width, int height, int bit_depth, int avif,
                   int quality, int lossless, const uint8_t *icc, int icc_len, const uint8_t *exif, int exif_len,
                   const uint8_t *xmp, int xmp_len, char **error)
{
  heif_context *ctx;
  heif_encoder *encoder = NULL;
  heif_image *image = NULL;
  heif_image_handle *handle = NULL;
  HeifError err;
  int stride = 0, x, y, ok = 0;
  uint8_t *plane;
  int chroma = bit_depth > 8 ? 15 : 11;
  int maxv = (1 << bit_depth) - 1;

  if (!heif_load ())
    {
      set_error (error, "libheif is not installed");
      return 0;
    }
  ctx = heif.context_alloc ();
  err = heif.get_encoder_for_format (ctx, heif_format_code (avif), &encoder);
  if (err.code != 0 || encoder == NULL)
    {
      set_error (error, err.message);
      heif.context_free (ctx);
      return 0;
    }
  if (lossless)
    heif.encoder_set_lossless (encoder, 1);
  else
    heif.encoder_set_lossy_quality (encoder, quality);
  err = heif.image_create (width, height, 1, chroma, &image);
  if (err.code != 0)
    {
      set_error (error, err.message);
      goto done;
    }
  err = heif.image_add_plane (image, 10, width, height, bit_depth);
  if (err.code != 0)
    {
      set_error (error, err.message);
      goto done;
    }
  plane = heif.image_get_plane (image, 10, &stride);
  for (y = 0; y < height; y++)
    for (x = 0; x < width; x++)
      {
        const uint16_t *s = rgba + ((size_t) y * width + x) * 4;
        int c;
        for (c = 0; c < 4; c++)
          {
            int v = (int) ((s[c] * (double) maxv) / 65535.0 + 0.5);
            if (bit_depth > 8)
              {
                plane[(size_t) y * stride + x * 8 + c * 2] = v & 0xFF;
                plane[(size_t) y * stride + x * 8 + c * 2 + 1] = (v >> 8) & 0xFF;
              }
            else
              {
                plane[(size_t) y * stride + x * 4 + c] = (uint8_t) v;
              }
          }
      }
  if (icc_len > 0)
    heif.image_set_raw_color_profile (image, "prof", icc, icc_len);
  err = heif.context_encode_image (ctx, image, encoder, NULL, &handle);
  if (err.code != 0)
    {
      set_error (error, err.message);
      goto done;
    }
  if (exif_len > 0)
    heif.add_exif (ctx, handle, exif, exif_len);
  if (xmp_len > 0)
    heif.add_xmp (ctx, handle, xmp, xmp_len);
  err = heif.write_to_file (ctx, path);
  if (err.code != 0)
    {
      set_error (error, err.message);
      goto done;
    }
  ok = 1;
done:
  if (handle != NULL)
    heif.handle_release (handle);
  if (image != NULL)
    heif.image_release (image);
  if (encoder != NULL)
    heif.encoder_release (encoder);
  heif.context_free (ctx);
  return ok;
}

int
sinty_heif_decode (const char *path, int *width, int *height, float **rgba, int *rgba_len, uint8_t **icc,
                   int *icc_len, char **error)
{
  heif_context *ctx;
  heif_image_handle *handle = NULL;
  heif_image *image = NULL;
  HeifError err;
  int bits, stride = 0, x, y, ok = 0;
  const uint8_t *plane;
  size_t profile;
  float scale;

  *rgba = NULL;
  *rgba_len = 0;
  *icc = NULL;
  *icc_len = 0;
  if (!heif_load ())
    {
      set_error (error, "libheif is not installed");
      return 0;
    }
  ctx = heif.context_alloc ();
  err = heif.read_from_file (ctx, path, NULL);
  if (err.code != 0)
    {
      set_error (error, err.message);
      goto done;
    }
  err = heif.get_primary (ctx, &handle);
  if (err.code != 0)
    {
      set_error (error, err.message);
      goto done;
    }
  bits = heif.handle_bits (handle);
  err = heif.decode_image (handle, &image, 1, bits > 8 ? 15 : 11, NULL);
  if (err.code != 0)
    {
      set_error (error, err.message);
      goto done;
    }
  *width = heif.image_get_width (image, 10);
  *height = heif.image_get_height (image, 10);
  plane = heif.image_get_plane_readonly (image, 10, &stride);
  scale = 1.0f / (float) ((1 << (bits > 8 ? bits : 8)) - 1);
  *rgba_len = *width * *height * 4;
  *rgba = g_malloc ((size_t) *rgba_len * sizeof (float));
  for (y = 0; y < *height; y++)
    for (x = 0; x < *width; x++)
      {
        int c;
        for (c = 0; c < 4; c++)
          {
            int v;
            if (bits > 8)
              v = plane[(size_t) y * stride + x * 8 + c * 2] | (plane[(size_t) y * stride + x * 8 + c * 2 + 1] << 8);
            else
              v = plane[(size_t) y * stride + x * 4 + c];
            (*rgba)[((size_t) y * *width + x) * 4 + c] = v * scale;
          }
      }
  profile = heif.profile_size (handle);
  if (profile > 0)
    {
      *icc = g_malloc (profile);
      heif.profile_get (handle, *icc);
      *icc_len = (int) profile;
    }
  ok = 1;
done:
  if (image != NULL)
    heif.image_release (image);
  if (handle != NULL)
    heif.handle_release (handle);
  heif.context_free (ctx);
  return ok;
}

typedef struct {
  int have_container;
  uint32_t xsize;
  uint32_t ysize;
  uint32_t bits_per_sample;
  uint32_t exponent_bits_per_sample;
  float intensity_target;
  float min_nits;
  int relative_to_max_display;
  float linear_below;
  int uses_original_profile;
  int have_preview;
  int have_animation;
  int orientation;
  uint32_t num_color_channels;
  uint32_t num_extra_channels;
  uint32_t alpha_bits;
  uint32_t alpha_exponent_bits;
  int alpha_premultiplied;
  uint32_t preview_xsize;
  uint32_t preview_ysize;
  uint32_t tps_numerator;
  uint32_t tps_denominator;
  uint32_t num_loops;
  int have_timecodes;
  uint32_t intrinsic_xsize;
  uint32_t intrinsic_ysize;
  uint8_t padding[100];
  uint8_t slack[256];
} JxlInfo;

typedef struct {
  uint32_t num_channels;
  int data_type;
  int endianness;
  size_t align;
} JxlFormat;

static struct {
  gboolean tried;
  GModule *module;
  void *(*enc_create) (const void *);
  void (*enc_destroy) (void *);
  void (*init_basic_info) (JxlInfo *);
  int (*set_basic_info) (void *, const JxlInfo *);
  int (*set_icc) (void *, const uint8_t *, size_t);
  void *(*settings_create) (void *, const void *);
  int (*set_distance) (void *, float);
  int (*set_lossless) (void *, int);
  int (*use_boxes) (void *);
  int (*add_box) (void *, const char *, const uint8_t *, size_t, int);
  void (*close_boxes) (void *);
  int (*add_frame) (void *, const JxlFormat *, const void *, size_t);
  void (*close_input) (void *);
  int (*process_output) (void *, uint8_t **, size_t *);
  void *(*dec_create) (const void *);
  void (*dec_destroy) (void *);
  int (*subscribe) (void *, int);
  int (*set_input) (void *, const uint8_t *, size_t);
  void (*dec_close_input) (void *);
  int (*process_input) (void *);
  int (*get_basic_info) (void *, JxlInfo *);
  int (*icc_size) (void *, int, size_t *);
  int (*icc_get) (void *, int, uint8_t *, size_t);
  int (*out_size) (void *, const JxlFormat *, size_t *);
  int (*set_out) (void *, const JxlFormat *, void *, size_t);
} jxl;

static gboolean
jxl_load (void)
{
  static const char *names[] = { "libjxl.so.0.11", "libjxl.so.0.12", "libjxl.so.0.10", "libjxl.so", NULL };
  int i;

  if (jxl.tried)
    return jxl.module != NULL;
  jxl.tried = TRUE;
  for (i = 0; names[i] != NULL && jxl.module == NULL; i++)
    jxl.module = g_module_open (names[i], G_MODULE_BIND_LAZY | G_MODULE_BIND_LOCAL);
  if (jxl.module == NULL)
    return FALSE;
#define SYM(field, name) if (!g_module_symbol (jxl.module, name, (gpointer *) &jxl.field)) goto fail
  SYM (enc_create, "JxlEncoderCreate");
  SYM (enc_destroy, "JxlEncoderDestroy");
  SYM (init_basic_info, "JxlEncoderInitBasicInfo");
  SYM (set_basic_info, "JxlEncoderSetBasicInfo");
  SYM (set_icc, "JxlEncoderSetICCProfile");
  SYM (settings_create, "JxlEncoderFrameSettingsCreate");
  SYM (set_distance, "JxlEncoderSetFrameDistance");
  SYM (set_lossless, "JxlEncoderSetFrameLossless");
  SYM (use_boxes, "JxlEncoderUseBoxes");
  SYM (add_box, "JxlEncoderAddBox");
  SYM (close_boxes, "JxlEncoderCloseBoxes");
  SYM (add_frame, "JxlEncoderAddImageFrame");
  SYM (close_input, "JxlEncoderCloseInput");
  SYM (process_output, "JxlEncoderProcessOutput");
  SYM (dec_create, "JxlDecoderCreate");
  SYM (dec_destroy, "JxlDecoderDestroy");
  SYM (subscribe, "JxlDecoderSubscribeEvents");
  SYM (set_input, "JxlDecoderSetInput");
  SYM (dec_close_input, "JxlDecoderCloseInput");
  SYM (process_input, "JxlDecoderProcessInput");
  SYM (get_basic_info, "JxlDecoderGetBasicInfo");
  SYM (icc_size, "JxlDecoderGetICCProfileSize");
  SYM (icc_get, "JxlDecoderGetColorAsICCProfile");
  SYM (out_size, "JxlDecoderImageOutBufferSize");
  SYM (set_out, "JxlDecoderSetImageOutBuffer");
#undef SYM
  return TRUE;
fail:
  g_module_close (jxl.module);
  jxl.module = NULL;
  return FALSE;
}

int
sinty_jxl_available (void)
{
  return jxl_load ();
}

int
sinty_jxl_encode (const char *path, const float *rgba, int width, int height, int bits, float distance,
                  int lossless, const uint8_t *icc, int icc_len, const uint8_t *exif, int exif_len,
                  const uint8_t *xmp, int xmp_len, char **error)
{
  void *enc, *settings;
  JxlInfo info;
  JxlFormat format = { 4, 0, 0, 0 };
  size_t cap = 1 << 16, used = 0, avail;
  uint8_t *buffer, *next;
  int status, ok = 0;
  void *pixels = (void *) rgba;
  size_t pixel_bytes = (size_t) width * height * 4 * sizeof (float);
  uint16_t *words = NULL;

  if (!jxl_load ())
    {
      set_error (error, "libjxl is not installed");
      return 0;
    }
  enc = jxl.enc_create (NULL);
  memset (&info, 0, sizeof (info));
  jxl.init_basic_info (&info);
  info.xsize = width;
  info.ysize = height;
  info.num_color_channels = 3;
  info.num_extra_channels = 1;
  info.alpha_bits = bits == 32 ? 32 : bits;
  info.alpha_exponent_bits = bits == 32 ? 8 : 0;
  info.bits_per_sample = bits == 32 ? 32 : bits;
  info.exponent_bits_per_sample = bits == 32 ? 8 : 0;
  info.uses_original_profile = lossless ? 1 : 0;
  if (jxl.set_basic_info (enc, &info) != 0)
    {
      set_error (error, "The JPEG XL encoder rejected the image settings");
      goto done;
    }
  if (icc_len > 0 && jxl.set_icc (enc, icc, icc_len) != 0)
    {
      set_error (error, "The JPEG XL encoder rejected the colour profile");
      goto done;
    }
  if (exif_len > 0 || xmp_len > 0)
    {
      jxl.use_boxes (enc);
      if (exif_len > 0)
        {
          uint8_t *box = g_malloc (exif_len + 4);
          memset (box, 0, 4);
          memcpy (box + 4, exif, exif_len);
          jxl.add_box (enc, "Exif", box, exif_len + 4, 0);
          g_free (box);
        }
      if (xmp_len > 0)
        jxl.add_box (enc, "xml ", xmp, xmp_len, 0);
      jxl.close_boxes (enc);
    }
  settings = jxl.settings_create (enc, NULL);
  if (lossless)
    jxl.set_lossless (settings, 1);
  else
    jxl.set_distance (settings, distance);
  if (bits == 16)
    {
      size_t n = (size_t) width * height * 4, i;
      words = g_malloc (n * sizeof (uint16_t));
      for (i = 0; i < n; i++)
        {
          float v = rgba[i] < 0 ? 0 : (rgba[i] > 1 ? 1 : rgba[i]);
          words[i] = (uint16_t) (v * 65535.0f + 0.5f);
        }
      format.data_type = 3;
      pixels = words;
      pixel_bytes = n * sizeof (uint16_t);
    }
  else if (bits == 8)
    {
      size_t n = (size_t) width * height * 4, i;
      uint8_t *bytes = g_malloc (n);
      for (i = 0; i < n; i++)
        {
          float v = rgba[i] < 0 ? 0 : (rgba[i] > 1 ? 1 : rgba[i]);
          bytes[i] = (uint8_t) (v * 255.0f + 0.5f);
        }
      words = (uint16_t *) bytes;
      format.data_type = 2;
      pixels = bytes;
      pixel_bytes = n;
    }
  if (jxl.add_frame (settings, &format, pixels, pixel_bytes) != 0)
    {
      set_error (error, "The JPEG XL encoder rejected the pixels");
      goto done;
    }
  jxl.close_input (enc);
  buffer = g_malloc (cap);
  do
    {
      next = buffer + used;
      avail = cap - used;
      status = jxl.process_output (enc, &next, &avail);
      used = next - buffer;
      if (status == 2)
        {
          cap *= 2;
          buffer = g_realloc (buffer, cap);
        }
    }
  while (status == 2);
  if (status == 0)
    {
      GError *gerror = NULL;
      if (g_file_set_contents (path, (const char *) buffer, used, &gerror))
        ok = 1;
      else
        {
          set_error (error, gerror->message);
          g_error_free (gerror);
        }
    }
  else
    {
      set_error (error, "The JPEG XL encoder failed");
    }
  g_free (buffer);
done:
  g_free (words);
  jxl.enc_destroy (enc);
  return ok;
}

int
sinty_jxl_decode (const char *path, int *width, int *height, float **rgba, int *rgba_len, uint8_t **icc,
                  int *icc_len, char **error)
{
  gchar *data = NULL;
  gsize len = 0;
  void *dec;
  JxlInfo info;
  JxlFormat format = { 4, 0, 0, 0 };
  int status, ok = 0;
  size_t size;

  *rgba = NULL;
  *rgba_len = 0;
  *icc = NULL;
  *icc_len = 0;
  if (!jxl_load ())
    {
      set_error (error, "libjxl is not installed");
      return 0;
    }
  if (!g_file_get_contents (path, &data, &len, NULL))
    {
      set_error (error, "Cannot read the file");
      return 0;
    }
  dec = jxl.dec_create (NULL);
  jxl.subscribe (dec, 0x40 | 0x100 | 0x1000);
  jxl.set_input (dec, (const uint8_t *) data, len);
  jxl.dec_close_input (dec);
  memset (&info, 0, sizeof (info));
  for (;;)
    {
      status = jxl.process_input (dec);
      if (status == 1 || status == 2)
        {
          set_error (error, "The JPEG XL data is damaged");
          break;
        }
      if (status == 0x40)
        {
          jxl.get_basic_info (dec, &info);
          *width = info.xsize;
          *height = info.ysize;
        }
      else if (status == 0x100)
        {
          size_t n = 0;
          if (jxl.icc_size (dec, 1, &n) == 0 && n > 0)
            {
              *icc = g_malloc (n);
              if (jxl.icc_get (dec, 1, *icc, n) == 0)
                *icc_len = (int) n;
              else
                {
                  g_free (*icc);
                  *icc = NULL;
                }
            }
        }
      else if (status == 5)
        {
          jxl.out_size (dec, &format, &size);
          *rgba = g_malloc (size);
          *rgba_len = (int) (size / sizeof (float));
          jxl.set_out (dec, &format, *rgba, size);
        }
      else if (status == 0x1000)
        {
          ok = 1;
        }
      else if (status == 0)
        {
          break;
        }
    }
  jxl.dec_destroy (dec);
  g_free (data);
  if (!ok)
    {
      g_free (*rgba);
      *rgba = NULL;
      *rgba_len = 0;
    }
  return ok;
}
