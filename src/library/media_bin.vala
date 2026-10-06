using Gtk;

namespace Singularity.Apps.Photos {

    public class MediaBin : Box {
        public Box filter_host { get; private set; }
        public Overlay overlay { get; private set; }
        public ScrolledWindow scroller { get; private set; }

        public MediaBin() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("sx-media-bin");
            hexpand = true;
            vexpand = true;
            filter_host = new Box(Orientation.VERTICAL, 0);
            append(filter_host);
            overlay = new Overlay();
            overlay.hexpand = true;
            overlay.vexpand = true;
            scroller = new ScrolledWindow();
            scroller.hexpand = true;
            scroller.vexpand = true;
            overlay.set_child(scroller);
            append(overlay);
        }
    }

    public class ThumbClip : Widget {
        private Widget child;
        public int clip_width { get; set; }
        public int clip_height { get; set; }

        public ThumbClip(Widget child, int width, int height) {
            this.child = child;
            clip_width = width;
            clip_height = height;
            child.set_parent(this);
            overflow = Overflow.HIDDEN;
            notify["clip-width"].connect(() => queue_resize());
            notify["clip-height"].connect(() => queue_resize());
        }

        public void resize(int width, int height) {
            clip_width = width;
            clip_height = height;
        }

        public override void dispose() {
            if (child != null) child.unparent();
            child = null;
            base.dispose();
        }

        public override void measure(Orientation o, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = natural_baseline = -1;
            minimum = natural = o == Orientation.HORIZONTAL ? clip_width : clip_height;
        }

        public override void size_allocate(int width, int height, int baseline) {
            int cw, ch, nat;
            child.measure(Orientation.HORIZONTAL, -1, out cw, out nat, null, null);
            cw = int.max(cw, width);
            child.measure(Orientation.VERTICAL, cw, out ch, out nat, null, null);
            ch = int.max(ch, height);
            var t = new Gsk.Transform().translate(Graphene.Point() { x = (width - cw) / 2.0f, y = (height - ch) / 2.0f });
            child.allocate(cw, ch, -1, t);
        }
    }
}
