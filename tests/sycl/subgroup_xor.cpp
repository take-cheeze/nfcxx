// Sub-groups are real: a sub-group has 16 lanes, and its shuffles move values between them. A work-group of 32 items holds
// two sub-groups (lanes 0..15 and 16..31). Each lane sums its local id with its partners over the xor masks 1, 2, 4, 8
// (a butterfly), so every lane ends with the sum over its sub-group: 256*j + 120 for sub-group j. reduce_over_group and
// select_from_group must agree.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

int main() {
  const int WG = 32, N = 64;
  std::vector<int> xsum(N), red(N), sel(N), lane(N), sgid(N);
  {
    sycl::queue q;
    sycl::buffer<int> X(xsum), R(red), S(sel), L(lane), G(sgid);
    q.submit([&](sycl::handler &h) {
      sycl::accessor x(X, h, sycl::write_only, sycl::no_init);
      sycl::accessor r(R, h, sycl::write_only, sycl::no_init);
      sycl::accessor s(S, h, sycl::write_only, sycl::no_init);
      sycl::accessor l(L, h, sycl::write_only, sycl::no_init);
      sycl::accessor g(G, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::nd_range<1>(sycl::range<1>(N), sycl::range<1>(WG)), [=](sycl::nd_item<1> it) {
        sycl::sub_group sg = it.get_sub_group();
        size_t gi = it.get_global_id(0);
        int lid = (int)it.get_local_id(0);
        int v = lid;
        v += sycl::permute_group_by_xor(sg, v, 1);
        v += sycl::permute_group_by_xor(sg, v, 2);
        v += sycl::permute_group_by_xor(sg, v, 4);
        v += sycl::permute_group_by_xor(sg, v, 8);
        x[gi] = v;
        r[gi] = sycl::reduce_over_group(sg, lid, sycl::plus<int>());
        s[gi] = sycl::select_from_group(sg, lid, sycl::id<1>(5));
        l[gi] = (int)sg.get_local_linear_id();
        g[gi] = (int)sg.get_group_linear_id();
      });
    });
  }
  int bad = 0;
  for (int i = 0; i < N; i++) {
    int lid = i % WG, j = lid / 16, k = lid % 16;
    int want = 256 * j + 120;
    if (xsum[i] != want) bad++;
    if (red[i] != want) bad++;
    if (sel[i] != 16 * j + 5) bad++;
    if (lane[i] != k) bad++;
    if (sgid[i] != j) bad++;
  }
  std::printf(bad ? "subgroup_xor FAIL %d\n" : "subgroup_xor ok\n", bad);
  return bad != 0;
}
