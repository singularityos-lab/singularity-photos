namespace PhotosPlugin {

    public interface ExportDestination : Object {
        public abstract string id { owned get; }
        public abstract string title { owned get; }
        public abstract async void deliver(File[] files, Cancellable? cancellable) throws Error;
    }

    public interface ImageFilter : Object {
        public abstract string id { owned get; }
        public abstract string title { owned get; }
        public abstract void apply(float[] rgba, int width, int height, double amount);
    }

    public interface MetadataProvider : Object {
        public abstract string id { owned get; }
        public abstract string title { owned get; }
        public abstract string[] fields();
        public abstract string field_title(string field);
        public abstract string? read(File file, string field);
    }
}
