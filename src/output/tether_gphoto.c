#include <glib.h>
#include <glib/gstdio.h>
#include <string.h>
#include <gphoto2/gphoto2.h>

#include "tether_gphoto.h"

typedef struct {
  Camera *camera;
  GPContext *context;
} SintyCamera;

static void
set_error (char **error, int code)
{
  if (error != NULL)
    *error = g_strdup (gp_result_as_string (code));
}

int
sinty_gp_list (char ***models, int *models_len, char ***ports, int *ports_len)
{
  GPContext *context = gp_context_new ();
  CameraList *list = NULL;
  int n, i;

  *models = NULL;
  *ports = NULL;
  *models_len = 0;
  *ports_len = 0;
  if (gp_list_new (&list) < GP_OK)
    {
      gp_context_unref (context);
      return 0;
    }
  n = gp_camera_autodetect (list, context);
  if (n < 0)
    n = 0;
  *models = g_new0 (char *, n + 1);
  *ports = g_new0 (char *, n + 1);
  for (i = 0; i < n; i++)
    {
      const char *name = NULL, *port = NULL;
      gp_list_get_name (list, i, &name);
      gp_list_get_value (list, i, &port);
      (*models)[i] = g_strdup (name != NULL ? name : "");
      (*ports)[i] = g_strdup (port != NULL ? port : "");
    }
  *models_len = n;
  *ports_len = n;
  gp_list_free (list);
  gp_context_unref (context);
  return n;
}

void *
sinty_gp_open (const char *model, const char *port, char **error)
{
  SintyCamera *c = g_new0 (SintyCamera, 1);
  CameraAbilitiesList *abilities = NULL;
  GPPortInfoList *ports = NULL;
  CameraAbilities a;
  GPPortInfo info;
  int r, i;

  c->context = gp_context_new ();
  if ((r = gp_camera_new (&c->camera)) < GP_OK)
    goto fail;
  if ((r = gp_abilities_list_new (&abilities)) < GP_OK)
    goto fail;
  if ((r = gp_abilities_list_load (abilities, c->context)) < GP_OK)
    goto fail;
  if ((i = gp_abilities_list_lookup_model (abilities, model)) < GP_OK)
    {
      r = i;
      goto fail;
    }
  gp_abilities_list_get_abilities (abilities, i, &a);
  gp_camera_set_abilities (c->camera, a);
  if ((r = gp_port_info_list_new (&ports)) < GP_OK)
    goto fail;
  if ((r = gp_port_info_list_load (ports)) < GP_OK)
    goto fail;
  if ((i = gp_port_info_list_lookup_path (ports, port)) < GP_OK)
    {
      r = i;
      goto fail;
    }
  gp_port_info_list_get_info (ports, i, &info);
  gp_camera_set_port_info (c->camera, info);
  if ((r = gp_camera_init (c->camera, c->context)) < GP_OK)
    goto fail;
  gp_abilities_list_free (abilities);
  gp_port_info_list_free (ports);
  return c;
fail:
  set_error (error, r);
  if (abilities != NULL)
    gp_abilities_list_free (abilities);
  if (ports != NULL)
    gp_port_info_list_free (ports);
  if (c->camera != NULL)
    gp_camera_unref (c->camera);
  gp_context_unref (c->context);
  g_free (c);
  return NULL;
}

void
sinty_gp_close (void *handle)
{
  SintyCamera *c = handle;
  if (c == NULL)
    return;
  gp_camera_exit (c->camera, c->context);
  gp_camera_unref (c->camera);
  gp_context_unref (c->context);
  g_free (c);
}

static int
download (SintyCamera *c, const char *folder, const char *name, const char *dest_dir, char **saved)
{
  CameraFile *file = NULL;
  char *target = g_build_filename (dest_dir, name, NULL);
  int r, n = 2;

  while (g_file_test (target, G_FILE_TEST_EXISTS))
    {
      const char *dot = strrchr (name, '.');
      char *stem = dot != NULL ? g_strndup (name, dot - name) : g_strdup (name);
      char *numbered = g_strdup_printf ("%s-%d%s", stem, n++, dot != NULL ? dot : "");
      g_free (target);
      target = g_build_filename (dest_dir, numbered, NULL);
      g_free (stem);
      g_free (numbered);
    }
  if ((r = gp_file_new (&file)) < GP_OK)
    {
      g_free (target);
      return r;
    }
  r = gp_camera_file_get (c->camera, folder, name, GP_FILE_TYPE_NORMAL, file, c->context);
  if (r >= GP_OK)
    r = gp_file_save (file, target);
  gp_file_unref (file);
  if (r >= GP_OK)
    *saved = target;
  else
    g_free (target);
  return r;
}

int
sinty_gp_capture (void *handle, const char *dest_dir, char **saved, char **error)
{
  SintyCamera *c = handle;
  CameraFilePath path;
  int r;

  *saved = NULL;
  memset (&path, 0, sizeof (path));
  if ((r = gp_camera_capture (c->camera, GP_CAPTURE_IMAGE, &path, c->context)) < GP_OK)
    {
      set_error (error, r);
      return 0;
    }
  if ((r = download (c, path.folder, path.name, dest_dir, saved)) < GP_OK)
    {
      set_error (error, r);
      return 0;
    }
  return 1;
}

int
sinty_gp_wait (void *handle, int timeout_ms, const char *dest_dir, char **saved, char **error)
{
  SintyCamera *c = handle;
  CameraEventType type;
  void *data = NULL;
  int r;

  *saved = NULL;
  if ((r = gp_camera_wait_for_event (c->camera, timeout_ms, &type, &data, c->context)) < GP_OK)
    {
      set_error (error, r);
      return -1;
    }
  if (type == GP_EVENT_FILE_ADDED && data != NULL)
    {
      CameraFilePath *p = data;
      r = download (c, p->folder, p->name, dest_dir, saved);
      g_free (data);
      if (r < GP_OK)
        {
          set_error (error, r);
          return -1;
        }
      return 1;
    }
  g_free (data);
  return 0;
}

int
sinty_gp_operations (void *handle)
{
  SintyCamera *c = handle;
  CameraAbilities a;
  if (gp_camera_get_abilities (c->camera, &a) < GP_OK)
    return 0;
  return (int) a.operations;
}

int
sinty_gp_preview (void *handle, uint8_t **data, int *len, char **error)
{
  SintyCamera *c = handle;
  CameraFile *file = NULL;
  const char *bytes = NULL;
  unsigned long size = 0;
  int r;

  *data = NULL;
  *len = 0;
  if ((r = gp_file_new (&file)) < GP_OK)
    {
      set_error (error, r);
      return 0;
    }
  r = gp_camera_capture_preview (c->camera, file, c->context);
  if (r >= GP_OK)
    r = gp_file_get_data_and_size (file, &bytes, &size);
  if (r >= GP_OK && size > 0)
    {
      *data = g_memdup2 (bytes, size);
      *len = (int) size;
    }
  gp_file_unref (file);
  if (r < GP_OK)
    {
      set_error (error, r);
      return 0;
    }
  return 1;
}

static void
walk (SintyCamera *c, const char *folder, GPtrArray *out, int depth)
{
  CameraList *list = NULL;
  int i, n;

  if (depth > 8 || gp_list_new (&list) < GP_OK)
    return;
  if (gp_camera_folder_list_files (c->camera, folder, list, c->context) >= GP_OK)
    {
      n = gp_list_count (list);
      for (i = 0; i < n; i++)
        {
          const char *name = NULL;
          gp_list_get_name (list, i, &name);
          if (name != NULL)
            g_ptr_array_add (out, g_build_path ("/", folder, name, NULL));
        }
    }
  gp_list_reset (list);
  if (gp_camera_folder_list_folders (c->camera, folder, list, c->context) >= GP_OK)
    {
      n = gp_list_count (list);
      for (i = 0; i < n; i++)
        {
          const char *name = NULL;
          gp_list_get_name (list, i, &name);
          if (name != NULL)
            {
              char *sub = g_build_path ("/", folder, name, NULL);
              walk (c, sub, out, depth + 1);
              g_free (sub);
            }
        }
    }
  gp_list_free (list);
}

int
sinty_gp_list_files (void *handle, char ***paths, int *paths_len)
{
  GPtrArray *out = g_ptr_array_new ();
  walk (handle, "/", out, 0);
  *paths_len = (int) out->len;
  g_ptr_array_add (out, NULL);
  *paths = (char **) g_ptr_array_free (out, FALSE);
  return *paths_len;
}

int
sinty_gp_download (void *handle, const char *camera_path, const char *dest_dir, char **saved, char **error)
{
  char *folder = g_path_get_dirname (camera_path);
  char *name = g_path_get_basename (camera_path);
  int r;

  *saved = NULL;
  r = download (handle, folder, name, dest_dir, saved);
  g_free (folder);
  g_free (name);
  if (r < GP_OK)
    {
      set_error (error, r);
      return 0;
    }
  return 1;
}
