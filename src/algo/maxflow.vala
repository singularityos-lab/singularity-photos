namespace Singularity.Apps.Photos {

    public class GridCut : Object {
        private const int TERMINAL = -1;
        private const int ORPHAN = -2;
        private const int NONE = -3;
        private const uint8 FREE = 0;
        private const uint8 SOURCE = 1;
        private const uint8 SINK = 2;

        public int width { get; private set; }
        public int height { get; private set; }
        private float[] cap;
        private float[] tr;
        private uint8[] tree;
        private int[] parent;
        private uint8[] active;
        private int[] queue;
        private int qhead;
        private int qtail;
        private int[] orphans;
        private int norphans;

        public GridCut(int width, int height) {
            this.width = width;
            this.height = height;
            int n = width * height;
            cap = new float[n * 4];
            tr = new float[n];
            tree = new uint8[n];
            parent = new int[n];
            active = new uint8[n];
            queue = new int[n + 1];
            orphans = new int[n];
        }

        private int neighbor(int i, int d) {
            int x = i % width;
            switch (d) {
                case 0: return x + 1 < width ? i + 1 : -1;
                case 1: return x > 0 ? i - 1 : -1;
                case 2: return i + width < width * height ? i + width : -1;
                default: return i - width >= 0 ? i - width : -1;
            }
        }

        public void set_terminal(int i, float source_cap, float sink_cap) {
            tr[i] = source_cap - sink_cap;
        }

        public void set_edge(int i, int d, float c) {
            cap[i * 4 + d] = c;
        }

        private void push_active(int i) {
            if (active[i] != 0) return;
            active[i] = 1;
            queue[qtail] = i;
            qtail = (qtail + 1) % queue.length;
        }

        private int pop_active() {
            while (qhead != qtail) {
                int i = queue[qhead];
                qhead = (qhead + 1) % queue.length;
                active[i] = 0;
                if (tree[i] != FREE) return i;
            }
            return -1;
        }

        private float edge_cap_from_parent(int child) {
            int d = parent[child];
            int p = neighbor(child, d);
            return tree[child] == SOURCE ? cap[p * 4 + (d ^ 1)] : cap[child * 4 + d];
        }

        private bool rooted(int i) {
            int guard = 0;
            while (true) {
                int d = parent[i];
                if (d == TERMINAL) return true;
                if (d < 0) return false;
                i = neighbor(i, d);
                if (++guard > width * height) return false;
            }
        }

        public void solve() {
            int n = width * height;
            qhead = 0;
            qtail = 0;
            for (int i = 0; i < n; i++) {
                active[i] = 0;
                if (tr[i] > 0) {
                    tree[i] = SOURCE;
                    parent[i] = TERMINAL;
                    push_active(i);
                } else if (tr[i] < 0) {
                    tree[i] = SINK;
                    parent[i] = TERMINAL;
                    push_active(i);
                } else {
                    tree[i] = FREE;
                    parent[i] = NONE;
                }
            }
            int current = -1;
            while (true) {
                if (current < 0 || tree[current] == FREE) current = pop_active();
                if (current < 0) break;
                int ms = -1, mt = -1;
                int ct = tree[current];
                for (int d = 0; d < 4 && ms < 0; d++) {
                    int j = neighbor(current, d);
                    if (j < 0) continue;
                    float c = ct == SOURCE ? cap[current * 4 + d] : cap[j * 4 + (d ^ 1)];
                    if (c <= 0) continue;
                    if (tree[j] == FREE) {
                        tree[j] = (uint8) ct;
                        parent[j] = d ^ 1;
                        push_active(j);
                    } else if (tree[j] != ct) {
                        if (ct == SOURCE) {
                            ms = current;
                            mt = j;
                        } else {
                            ms = j;
                            mt = current;
                        }
                    }
                }
                if (ms < 0) {
                    current = -1;
                    continue;
                }
                int dir = 0;
                for (int d = 0; d < 4; d++) if (neighbor(ms, d) == mt) dir = d;
                float bottleneck = cap[ms * 4 + dir];
                for (int i = ms; ; ) {
                    if (parent[i] == TERMINAL) {
                        bottleneck = float.min(bottleneck, tr[i]);
                        break;
                    }
                    bottleneck = float.min(bottleneck, edge_cap_from_parent(i));
                    i = neighbor(i, parent[i]);
                }
                for (int i = mt; ; ) {
                    if (parent[i] == TERMINAL) {
                        bottleneck = float.min(bottleneck, -tr[i]);
                        break;
                    }
                    bottleneck = float.min(bottleneck, edge_cap_from_parent(i));
                    i = neighbor(i, parent[i]);
                }
                cap[ms * 4 + dir] -= bottleneck;
                cap[mt * 4 + (dir ^ 1)] += bottleneck;
                norphans = 0;
                for (int i = ms; ; ) {
                    int d = parent[i];
                    if (d == TERMINAL) {
                        tr[i] -= bottleneck;
                        if (tr[i] <= 0) {
                            parent[i] = ORPHAN;
                            orphans[norphans++] = i;
                        }
                        break;
                    }
                    int p = neighbor(i, d);
                    cap[p * 4 + (d ^ 1)] -= bottleneck;
                    cap[i * 4 + d] += bottleneck;
                    if (cap[p * 4 + (d ^ 1)] <= 0) {
                        parent[i] = ORPHAN;
                        orphans[norphans++] = i;
                    }
                    i = p;
                }
                for (int i = mt; ; ) {
                    int d = parent[i];
                    if (d == TERMINAL) {
                        tr[i] += bottleneck;
                        if (tr[i] >= 0) {
                            parent[i] = ORPHAN;
                            orphans[norphans++] = i;
                        }
                        break;
                    }
                    int p = neighbor(i, d);
                    cap[i * 4 + d] -= bottleneck;
                    cap[p * 4 + (d ^ 1)] += bottleneck;
                    if (cap[i * 4 + d] <= 0) {
                        parent[i] = ORPHAN;
                        orphans[norphans++] = i;
                    }
                    i = p;
                }
                while (norphans > 0) {
                    int o = orphans[--norphans];
                    int ot = tree[o];
                    int found = -1;
                    for (int d = 0; d < 4 && found < 0; d++) {
                        int j = neighbor(o, d);
                        if (j < 0 || tree[j] != ot) continue;
                        float c = ot == SOURCE ? cap[j * 4 + (d ^ 1)] : cap[o * 4 + d];
                        if (c <= 0) continue;
                        if (rooted(j)) found = d;
                    }
                    if (found >= 0) {
                        parent[o] = found;
                        continue;
                    }
                    for (int d = 0; d < 4; d++) {
                        int j = neighbor(o, d);
                        if (j < 0 || tree[j] != ot) continue;
                        float c = ot == SOURCE ? cap[j * 4 + (d ^ 1)] : cap[o * 4 + d];
                        if (c > 0) push_active(j);
                        if (parent[j] >= 0 && neighbor(j, parent[j]) == o) {
                            parent[j] = ORPHAN;
                            orphans[norphans++] = j;
                        }
                    }
                    tree[o] = FREE;
                    parent[o] = NONE;
                }
                if (tree[current] == FREE) current = -1;
            }
        }

        public bool is_source(int i) {
            return tree[i] == SOURCE;
        }
    }
}
