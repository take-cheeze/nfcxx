// A grid too large for the heap whose work-groups are wide in a dimension above the one the runtimes split: ggml-sycl's
// rope (a 1 x 256 x rows grid of 1 x 256 x 1 work-groups, so the groups run along the innermost dimension). The stacks
// used to be numbered by global linear index, where a run of groups along x is not contiguous when the groups are 256
// invocations tall, so such a grid ran in one launch and ran out of heap. They are numbered group by group now.
// The heap is set to 64 MB here (NFCXX_SYCL_HEAP_MB, before the runtime starts); a 1 KB stack array per work-item makes the
// grid's stacks about 2 GB.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <cstdlib>

int main() {
  setenv("NFCXX_SYCL_HEAP_MB", "64", 1);
  sycl::queue q;
  const size_t rows = 8192, ny = 256;
  const size_t n = rows * ny;
  int *out = sycl::malloc_shared<int>(n, q);
  for (size_t i = 0; i < n; i++) out[i] = -1;
  q.submit([&](sycl::handler &h) {
    sycl::local_accessor<int, 1> t(sycl::range<1>(ny), h);
    h.parallel_for(sycl::nd_range<3>(sycl::range<3>(1, ny, rows), sycl::range<3>(1, ny, 1)), [=](sycl::nd_item<3> it) {
      const size_t y = it.get_local_id(1), row = it.get_global_id(2);
      volatile int buf[256];   // on the work-item's stack
      for (int i = 0; i < 256; i++) buf[i] = (int)(i + y);
      t[y] = buf[(y * 7) % 256] + (int)(row * 1000);
      it.barrier(sycl::access::fence_space::local_space);
      out[row * ny + y] = t[ny - 1 - y];   // a neighbour's value: local memory is the group's own
    });
  }).wait();
  long bad = 0;
  for (size_t row = 0; row < rows; row++)
    for (size_t y = 0; y < ny; y++) {
      const size_t yr = ny - 1 - y;
      const int want = (int)(((yr * 7) % 256) + yr) + (int)(row * 1000);
      if (out[row * ny + y] != want) bad++;
    }
  sycl::free(out, q);
  if (bad) { std::printf("slab_wide: %ld of %zu wrong\n", bad, n); return 1; }
  std::printf("slab_wide ok\n");
  return 0;
}
