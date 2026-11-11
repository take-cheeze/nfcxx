// A 3-D nd_range whose stacks (about 150 MB) do not fit a 64 MB Vulkan heap: the dispatch must run as slabs (rt_vulkan.hpp,
// dispatch()) and every element must be written. Expected output: "vulkan_slab ok". Before the slab split the run fails with
// "out of device memory". The heap size is the NFCXX_SYCL_HEAP_MB override, read when the queue creates the runtime.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <cstdlib>
#include <vector>

int main() {
  const size_t X = 256, Y = 128, Z = 64;
  setenv("NFCXX_SYCL_HEAP_MB", "64", 1);
  std::vector<int> out(X * Y * Z, -1);
  {
    sycl::queue q;
    sycl::buffer<int, 3> O(out.data(), sycl::range<3>(X, Y, Z));
    q.submit([&](sycl::handler &h) {
      sycl::accessor w(O, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::nd_range<3>(sycl::range<3>(X, Y, Z), sycl::range<3>(4, 4, 1)), [=](sycl::nd_item<3> it) {
        sycl::id<3> g = it.get_global_id();
        w[g] = (int)(g[0] * 1000003u + g[1] * 131u + g[2]);
      });
    });
    q.wait();
  }
  size_t bad = 0;
  for (size_t x = 0; x < X; x++)
    for (size_t y = 0; y < Y; y++)
      for (size_t z = 0; z < Z; z++)
        if (out[(x * Y + y) * Z + z] != (int)(x * 1000003u + y * 131u + z)) bad++;
  std::printf(bad ? "vulkan_slab FAIL %zu\n" : "vulkan_slab ok\n", bad);
  return bad != 0;
}
