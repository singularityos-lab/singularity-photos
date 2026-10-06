#ifndef SINTY_TETHER_GPHOTO_H
#define SINTY_TETHER_GPHOTO_H

int sinty_gp_list (char ***models, int *models_len, char ***ports, int *ports_len);
void *sinty_gp_open (const char *model, const char *port, char **error);
void sinty_gp_close (void *handle);
int sinty_gp_capture (void *handle, const char *dest_dir, char **saved, char **error);
int sinty_gp_wait (void *handle, int timeout_ms, const char *dest_dir, char **saved, char **error);

int sinty_gp_operations (void *handle);
int sinty_gp_preview (void *handle, unsigned char **data, int *len, char **error);
int sinty_gp_list_files (void *handle, char ***paths, int *paths_len);
int sinty_gp_download (void *handle, const char *camera_path, const char *dest_dir, char **saved, char **error);

#endif
