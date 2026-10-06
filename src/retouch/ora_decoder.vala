namespace Singularity.Apps.Photos {

    public class OraDecoder : Object, PhotoDecoder {
        public string id { get { return "ora"; } }

        public bool handles(string lower_name, uint8[] head) {
            if (!lower_name.has_suffix(".ora")) return false;
            return head.length >= 4 && head[0] == 'P' && head[1] == 'K';
        }

        public DecodedPhoto decode(File file, int max_side) throws Error {
            uint8[] data;
            FileUtils.get_data(file.get_path(), out data);
            RetouchDocument? doc = null;
            Singularity.Imaging.FloatImage image;
            if (max_side > 0 && max_side <= 1024) {
                image = RetouchOra.merged(data);
            } else {
                doc = RetouchOra.load(data);
                image = doc.composite;
            }
            int fw = image.width, fh = image.height;
            if (max_side > 0) image = image.scaled_to_fit(max_side);
            var photo = new DecodedPhoto(image);
            photo.full_width = fw;
            photo.full_height = fh;
            photo.format = "ora";
            if (doc != null) photo.layers = RetouchDecodedLayers.from_document(doc);
            photo.meta.width = fw;
            photo.meta.height = fh;
            return photo;
        }
    }
}
