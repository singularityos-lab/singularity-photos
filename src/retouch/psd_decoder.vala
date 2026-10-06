namespace Singularity.Apps.Photos {

    public class PsdDecoder : Object, PhotoDecoder {
        public string id { get { return "psd"; } }

        public bool handles(string lower_name, uint8[] head) {
            if (head.length >= 4 && head[0] == '8' && head[1] == 'B' && head[2] == 'P' && head[3] == 'S') return true;
            return lower_name.has_suffix(".psd");
        }

        public DecodedPhoto decode(File file, int max_side) throws Error {
            uint8[] data;
            FileUtils.get_data(file.get_path(), out data);
            var doc = RetouchPsd.read(data);
            var image = doc.composite;
            int fw = image.width, fh = image.height;
            if (max_side > 0) image = image.scaled_to_fit(max_side);
            var photo = new DecodedPhoto(image);
            photo.full_width = fw;
            photo.full_height = fh;
            photo.format = "psd";
            photo.layers = RetouchDecodedLayers.from_document(doc);
            photo.meta = MetadataReader.read(file);
            if (photo.meta.width == 0) {
                photo.meta.width = fw;
                photo.meta.height = fh;
            }
            return photo;
        }
    }

    namespace RetouchDecodedLayers {

        private void walk(RetouchDocument doc, Gee.ArrayList<RetouchLayer> list, int depth, Gee.ArrayList<DecodedLayer> out_list) {
            foreach (var layer in list) {
                var src = layer.kind == RetouchLayerKind.ADJUSTMENT ? null : (layer.kind == RetouchLayerKind.GROUP ? null : doc.layer_source(layer));
                var dl = new DecodedLayer(layer.name, src ?? new Singularity.Imaging.FloatImage.filled(1, 1, 0, 0, 0, 0));
                dl.x = layer.kind == RetouchLayerKind.RASTER ? layer.x : 0;
                dl.y = layer.kind == RetouchLayerKind.RASTER ? layer.y : 0;
                dl.opacity = layer.opacity;
                dl.mode = layer.mode;
                dl.visible = layer.visible;
                dl.group_depth = depth;
                if (layer.mask != null) {
                    dl.mask = layer.mask;
                    dl.mask_width = doc.width;
                    dl.mask_height = doc.height;
                }
                if (layer.kind == RetouchLayerKind.GROUP) {
                    dl.group_start = true;
                    out_list.add(dl);
                    walk(doc, layer.children, depth + 1, out_list);
                    var end = new DecodedLayer(layer.name, new Singularity.Imaging.FloatImage.filled(1, 1, 0, 0, 0, 0));
                    end.group_end = true;
                    end.group_depth = depth;
                    out_list.add(end);
                    continue;
                }
                out_list.add(dl);
            }
        }

        public Gee.ArrayList<DecodedLayer> from_document(RetouchDocument doc) {
            var list = new Gee.ArrayList<DecodedLayer>();
            walk(doc, doc.layers, 0, list);
            return list;
        }
    }
}
