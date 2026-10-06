using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    public class RenderedPhoto : Object {
        public FloatImage image;
        public PhotoMetadata meta;
        public File source;

        public RenderedPhoto(File source, FloatImage image, PhotoMetadata meta) {
            this.source = source;
            this.image = image;
            this.meta = meta;
        }
    }

    namespace OutputRender {

        public RenderedPhoto render(File file, int max_side = 0) throws Error {
            var photo = Codecs.load(file, max_side);
            var p = EditStore.load(file);
            FloatImage image;
            if (p == null || p.is_identity()) {
                image = photo.image;
            } else {
                var options = new RenderOptions();
                options.max_side = max_side;
                image = DevelopPipeline.render(photo, p, options);
            }
            return new RenderedPhoto(file, image, photo.meta);
        }

        public Gdk.Texture thumbnail(File file, int max_side) throws Error {
            var r = render(file, max_side);
            return WorkingSpace.to_display_texture(r.image.scaled_to_fit(max_side));
        }
    }
}
