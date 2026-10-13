// Work-group algorithms (reduce, broadcast, scans, any/all/none, joint_reduce) and sub-group basics, on 1-D and 2-D groups.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

int main() {
  const int WG = 32, NG = 5, N = WG * NG;
  std::vector<int> in(N), red(N), bc(N), inc(N), exc(N), flags(N), joint(NG);
  std::vector<float> fred(NG);
  for (int i = 0; i < N; i++) in[i] = (i * 13) % 17 - 6;
  {
    sycl::queue q;
    sycl::buffer<int> I(in), R(red), B(bc), IN(inc), EX(exc), F(flags), J(joint);
    sycl::buffer<float> FR(fred);
    q.submit([&](sycl::handler &h) {
      sycl::accessor a(I, h, sycl::read_only);
      sycl::accessor r(R, h, sycl::write_only, sycl::no_init);
      sycl::accessor b(B, h, sycl::write_only, sycl::no_init);
      sycl::accessor ic(IN, h, sycl::write_only, sycl::no_init);
      sycl::accessor ex(EX, h, sycl::write_only, sycl::no_init);
      sycl::accessor f(F, h, sycl::write_only, sycl::no_init);
      sycl::accessor j(J, h, sycl::write_only, sycl::no_init);
      sycl::accessor fr(FR, h, sycl::write_only, sycl::no_init);
      sycl::local_accessor<int, 1> tile(sycl::range<1>(WG), h);
      h.parallel_for(sycl::nd_range<1>(sycl::range<1>(N), sycl::range<1>(WG)), [=](sycl::nd_item<1> it) {
        auto g = it.get_group();
        size_t gi = it.get_global_id(0), li = it.get_local_id(0);
        int x = a[gi];
        r[gi] = sycl::reduce_over_group(g, x, sycl::plus<int>());
        b[gi] = sycl::group_broadcast(g, x, sycl::id<1>(3));
        ic[gi] = sycl::inclusive_scan_over_group(g, x, sycl::plus<int>());
        ex[gi] = sycl::exclusive_scan_over_group(g, x, sycl::plus<int>());
        int bits = (sycl::any_of_group(g, x > 9) ? 1 : 0) | (sycl::all_of_group(g, x > -7) ? 2 : 0) | (sycl::none_of_group(g, x > 100) ? 4 : 0);
        f[gi] = bits;
        tile[li] = x;
        sycl::group_barrier(g);
        int jm = sycl::joint_reduce(g, tile.get_pointer(), tile.get_pointer() + WG, sycl::maximum<int>());
        float fs = sycl::reduce_over_group(g, (float)x * 0.5f, sycl::plus<float>());
        if (li == 0) {
          j[it.get_group(0)] = jm;
          fr[it.get_group(0)] = fs;
        }
      });
    });
  }
  int bad = 0;
  for (int g = 0; g < NG; g++) {
    int sum = 0, mx = -1000;
    bool any = false, all = true;
    for (int i = 0; i < WG; i++) { int x = in[g * WG + i]; sum += x; if (x > mx) mx = x; if (x > 9) any = true; if (!(x > -7)) all = false; }
    if (joint[g] != mx) bad++;
    if (fred[g] != 0.5f * (float)sum) bad++;
    int run = 0;
    for (int i = 0; i < WG; i++) {
      int k = g * WG + i, x = in[k];
      if (red[k] != sum) bad++;
      if (bc[k] != in[g * WG + 3]) bad++;
      if (exc[k] != run) bad++;
      run += x;
      if (inc[k] != run) bad++;
      if (flags[k] != ((any ? 1 : 0) | (all ? 2 : 0) | 4)) bad++;
    }
  }
  std::printf(bad ? "groups FAIL %d\n" : "groups ok\n", bad);
  return bad != 0;
}
