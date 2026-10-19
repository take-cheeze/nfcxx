// atomic_fence on OpenCL: each work-item stores its slot, then fences at device and work-group scope with release, acq_rel,
// seq_cst and relaxed orders (relaxed emits nothing). The fences must compile to OpMemoryBarrier and leave the stores intact.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

int main() {
  const int N = 64, WG = 16;
  std::vector<int> out(N, 0);
  {
    sycl::queue q;
    sycl::buffer<int> B(out);
    q.submit([&](sycl::handler &h) {
      sycl::accessor o(B, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::nd_range<1>(sycl::range<1>(N), sycl::range<1>(WG)), [=](sycl::nd_item<1> it) {
        size_t i = it.get_global_id(0);
        o[i] = (int)i + 1;
        sycl::atomic_fence(sycl::memory_order::release, sycl::memory_scope::device);
        sycl::atomic_fence(sycl::memory_order::acq_rel, sycl::memory_scope::work_group);
        sycl::atomic_fence(sycl::memory_order::seq_cst, sycl::memory_scope::device);
        sycl::atomic_fence(sycl::memory_order::relaxed, sycl::memory_scope::device);
      });
    });
  }
  int bad = 0;
  for (int i = 0; i < N; i++)
    if (out[i] != i + 1) bad++;
  std::printf(bad ? "fence FAIL %d\n" : "fence ok\n", bad);
  return bad != 0;
}
