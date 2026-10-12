#line 1 "rewrite/member_linkage.cu"
// A class member that is __device__ keeps its linkage on the host (no static on a const member or a constructor), and a
// namespace-scope __device__ function gets static (internal linkage, as nvcc gives the host copy).
struct Helper {
   Helper(int v) : x(v) {}
   int get() const { return x; }
   static int twice(int v) { return 2 * v; }
  int x;
};
static int plain(int v) { return v + 1; }
static void k(int *p) { Helper h(3); p[0] = h.get() + plain(1) + Helper::twice(1); }
