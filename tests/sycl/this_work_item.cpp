// sycl::ext::oneapi::this_work_item: get_nd_item<3>() and get_sub_group() inside an nd_range<3> kernel are the running
// work-item's item (on the host, the fiber that runs it; on the device, the kernel's item), checked against the lambda's
// item before and after a barrier (a fiber switch). Also dpct::dim3 * sycl::range<3> in a host expression. The dpct::dim3
// class is the one of the ggml dpct helper (ggml/src/ggml-sycl/dpct/helper.hpp), copied so that the test needs no ggml source.
// Expected output: "this_work_item ok".
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

namespace dpct {
class dim3 {
 public:
  unsigned x, y, z;
  constexpr dim3(unsigned x = 1, unsigned y = 1, unsigned z = 1) : x(x), y(y), z(z) {}
  dim3(const sycl::id<3> &r) : dim3(r[2], r[1], r[0]) {}
  operator sycl::range<3>() const { return sycl::range<3>(z, y, x); }
};
}  // namespace dpct

int main() {
  int bad = 0;

  // dim3 * range<3>: x is the last index of the range, so (2,3,4) is range (4,3,2); times (1,1,5) is (4,3,10)
  dpct::dim3 blocks(2, 3, 4);
  sycl::range<3> blk(1, 1, 5);
  sycl::range<3> prod = blocks * blk;
  if (prod[0] != 4 || prod[1] != 3 || prod[2] != 10) bad++;
  sycl::range<3> prod2 = blk * blocks;
  if (prod2 != prod) bad++;

  const sycl::range<3> G(4, 6, 8), L(2, 2, 4);
  const size_t N = G.size();
  std::vector<int> res(N, 0);
  {
    sycl::queue q;
    sycl::buffer<int> R(res);
    q.submit([&](sycl::handler &h) {
      sycl::accessor r(R, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::nd_range<3>(G, L), [=](sycl::nd_item<3> it) {
        using sycl::ext::oneapi::this_work_item::get_nd_item;
        using sycl::ext::oneapi::this_work_item::get_sub_group;
        auto same_item = [&](const sycl::nd_item<3> &w) {
          bool ok = true;
          for (int d = 0; d < 3; d++) {
            ok = ok && w.get_global_id(d) == it.get_global_id(d);
            ok = ok && w.get_local_id(d) == it.get_local_id(d);
            ok = ok && w.get_group(d) == it.get_group(d);
            ok = ok && w.get_global_range(d) == it.get_global_range(d);
            ok = ok && w.get_local_range(d) == it.get_local_range(d);
          }
          ok = ok && w.get_global_linear_id() == it.get_global_linear_id();
          ok = ok && w.get_local_linear_id() == it.get_local_linear_id();
          ok = ok && w.get_group_linear_id() == it.get_group_linear_id();
          return ok;
        };
        auto same_sub_group = [&]() {
          auto sg = get_sub_group();
          auto isg = it.get_sub_group();
          return sg.get_local_linear_id() == isg.get_local_linear_id() && sg.get_group_linear_id() == isg.get_group_linear_id() &&
                 sg.get_local_linear_range() == isg.get_local_linear_range() && sg.get_group_linear_range() == isg.get_group_linear_range();
        };
        bool ok = same_item(get_nd_item<3>()) && same_sub_group();
        it.barrier(sycl::access::fence_space::local_space);   // a fiber switch on the host: the item must still be this one
        ok = ok && same_item(get_nd_item<3>()) && same_sub_group();
        r[it.get_global_linear_id()] = ok ? 1 : 0;
      });
    });
  }
  for (size_t i = 0; i < N; i++)
    if (res[i] != 1) bad++;

  std::printf(bad ? "this_work_item FAIL %d\n" : "this_work_item ok\n", bad);
  return bad != 0;
}
