// A grid too large for the heap even one group at a time along its outermost dimension: the runtimes split it along the
// next dimension inward and run the outer dimension's groups one per launch. The stacks are numbered over the whole grid
// (group by group), so each launch's stack and local bases are biased by its first group. ggml-sycl's get_rows
// for 70000 rows in two batches (a 2 x 70000 x 1 grid of 256-wide work-groups) needed 13 GB of stacks in one launch.
// The heap is set to 64 MB here (NFCXX_SYCL_HEAP_MB, before the runtime starts); a 1 KB stack array per work-item makes the
// grid's stacks about 2 GB.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <cstdlib>

int main() {
  setenv("NFCXX_SYCL_HEAP_MB", "64", 1);
  sycl::queue q;
  const size_t nz = 2, ny = 4000, nx = 256;
  const size_t n = nz * ny * nx;
  int *out = sycl::malloc_shared<int>(n, q);
  for (size_t i = 0; i < n; i++) out[i] = -1;
  q.submit([&](sycl::handler &h) {
    sycl::local_accessor<int, 1> t(sycl::range<1>(nx), h);
    h.parallel_for(sycl::nd_range<3>(sycl::range<3>(nz, ny, nx), sycl::range<3>(1, 1, nx)), [=](sycl::nd_item<3> it) {
      const size_t z = it.get_global_id(0), y = it.get_global_id(1), x = it.get_global_id(2);
      volatile int buf[256];   // on the work-item's stack
      for (int i = 0; i < 256; i++) buf[i] = (int)(i + x);
      t[x] = buf[(x * 7) % 256] + (int)(y * 3 + z * 100000);
      it.barrier(sycl::access::fence_space::local_space);
      out[(z * ny + y) * nx + x] = t[nx - 1 - x];   // a neighbour's value: local memory is the group's own
    });
  }).wait();
  long bad = 0;
  for (size_t z = 0; z < nz; z++)
    for (size_t y = 0; y < ny; y++)
      for (size_t x = 0; x < nx; x++) {
        const size_t xr = nx - 1 - x;
        const int want = (int)(((xr * 7) % 256) + xr) + (int)(y * 3 + z * 100000);
        if (out[(z * ny + y) * nx + x] != want) bad++;
      }
  sycl::free(out, q);
  if (bad) { std::printf("slab_inner: %ld of %zu wrong\n", bad, n); return 1; }
  std::printf("slab_inner ok\n");
  return 0;
}
