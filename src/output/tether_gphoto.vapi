[CCode (cheader_filename = "tether_gphoto.h")]
namespace SintyTether {
    [CCode (cname = "sinty_gp_list")]
    public int list(out string[] models, out string[] ports);
    [CCode (cname = "sinty_gp_open")]
    public void* open(string model, string port, out string? error);
    [CCode (cname = "sinty_gp_close")]
    public void close(void* handle);
    [CCode (cname = "sinty_gp_capture")]
    public bool capture(void* handle, string dest_dir, out string? saved, out string? error);
    [CCode (cname = "sinty_gp_wait")]
    public int wait(void* handle, int timeout_ms, string dest_dir, out string? saved, out string? error);
    [CCode (cname = "sinty_gp_operations")]
    public int operations(void* handle);
    [CCode (cname = "sinty_gp_preview")]
    public bool preview(void* handle, out uint8[] data, out string? error);
    [CCode (cname = "sinty_gp_list_files")]
    public int list_files(void* handle, out string[] paths);
    [CCode (cname = "sinty_gp_download")]
    public bool download(void* handle, string camera_path, string dest_dir, out string? saved, out string? error);
}
