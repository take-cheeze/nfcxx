// atomic_ref (integer and float, signed and unsigned, compare-and-swap), atomic-mode accessors, and sycl::vec.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

int main() {
  const int N = 512;
  std::vector<int> cnt(4, 0), mx(1, -1000000), mn(1, 1000000), casv(1, 0);
  std::vector<unsigned> umx(1, 0);
  std::vector<float> fsum(1, 0.0f), fmax_(1, -1.0e9f);
  std::vector<int> viota(N, 0);
  std::vector<float> vlen(N, 0.0f);
  {
    sycl::queue q;
    sycl::buffer<int> C(cnt), MX(mx), MN(mn), CAS(casv), VI(viota);
    sycl::buffer<unsigned> UM(umx);
    sycl::buffer<float> FS(fsum), FM(fmax_), VL(vlen);
    q.submit([&](sycl::handler &h) {
      sycl::accessor c(C, h, sycl::read_write);
      sycl::accessor<int, 1, sycl::access_mode::atomic> at(C, h);   // a second, atomic-mode accessor on the same buffer
      sycl::accessor mxa(MX, h);
      sycl::accessor mna(MN, h);
      sycl::accessor cas(CAS, h);
      sycl::accessor um(UM, h);
      sycl::accessor fs(FS, h);
      sycl::accessor fm(FM, h);
      sycl::accessor vi(VI, h, sycl::write_only, sycl::no_init);
      sycl::accessor vl(VL, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        int k = (int)i[0];
        sycl::atomic_ref<int> a0(c[0]), a1(c[1]), a2(c[2]);
        a0.fetch_add(1);
        a1 += k % 3;
        a2.fetch_sub(2);
        at[3].fetch_add(5);
        sycl::atomic_ref<int>(mxa[0]).fetch_max((k * 37) % 1001 - 500);
        sycl::atomic_ref<int>(mna[0]).fetch_min((k * 37) % 1001 - 500);
        sycl::atomic_ref<unsigned>(um[0]).fetch_max((unsigned)(k * 7919 % 10007));
        sycl::atomic_ref<float>(fs[0]).fetch_add(0.25f);
        sycl::atomic_ref<float>(fm[0]).fetch_max((float)(k % 100) - 3.5f);
        // a lock-free increment with compare-and-swap
        sycl::atomic_ref<int> cc(cas[0]);
        int old = cc.load();
        while (!cc.compare_exchange_strong(old, old + 2)) {}
        sycl::int4 v(k, k + 1, k + 2, k + 3);
        v = v * 2 + sycl::int4(1);
        vi[i] = v[0] + v.y() + v.z() + v.w();
        sycl::float3 f(1.0f, 2.0f, 2.0f);
        vl[i] = sycl::dot(f, f) + (float)k;
      });
    });
  }
  int bad = 0;
  int s1 = 0, want_mx = -1000000, want_mn = 1000000;
  unsigned want_um = 0;
  float want_fm = -1.0e9f;
  for (int k = 0; k < N; k++) {
    s1 += k % 3;
    int v = (k * 37) % 1001 - 500;
    if (v > want_mx) want_mx = v;
    if (v < want_mn) want_mn = v;
    unsigned u = (unsigned)(k * 7919 % 10007);
    if (u > want_um) want_um = u;
    float fv = (float)(k % 100) - 3.5f;
    if (fv > want_fm) want_fm = fv;
    if (viota[k] != (2 * k + 1) + (2 * (k + 1) + 1) + (2 * (k + 2) + 1) + (2 * (k + 3) + 1)) bad++;
    if (vlen[k] != 9.0f + (float)k) bad++;
  }
  if (cnt[0] != N || cnt[1] != s1 || cnt[2] != -2 * N || cnt[3] != 5 * N) bad++;
  if (mx[0] != want_mx || mn[0] != want_mn || umx[0] != want_um) bad++;
  if (fsum[0] != 0.25f * (float)N || fmax_[0] != want_fm) bad++;
  if (casv[0] != 2 * N) bad++;
  std::printf(bad ? "atomics FAIL %d\n" : "atomics ok\n", bad);
  return bad != 0;
}
