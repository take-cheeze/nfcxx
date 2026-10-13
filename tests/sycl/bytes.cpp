// 8- and 16-bit element types, bool, signed narrow arithmetic, switch, a loop with break/continue.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

int main() {
  const int N = 300;
  std::vector<unsigned char> px(N);
  std::vector<signed char> sc(N);
  std::vector<short> sh(N);
  std::vector<unsigned char> out(N, 0);
  std::vector<int> cls(N, 0);
  for (int i = 0; i < N; i++) { px[i] = (unsigned char)(i * 5); sc[i] = (signed char)(i - 150); sh[i] = (short)(i * 211 - 20000); }
  {
    sycl::queue q;
    sycl::buffer<unsigned char> P(px), O(out);
    sycl::buffer<signed char> S(sc);
    sycl::buffer<short> H(sh);
    sycl::buffer<int> C(cls);
    q.submit([&](sycl::handler &h) {
      sycl::accessor p(P, h, sycl::read_only);
      sycl::accessor o(O, h, sycl::write_only, sycl::no_init);
      sycl::accessor s(S, h, sycl::read_only);
      sycl::accessor hh(H, h, sycl::read_only);
      sycl::accessor c(C, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        int v = (int)p[i] + 40;                      // brighten, saturate
        o[i] = (unsigned char)(v > 255 ? 255 : v);
        int k = 0;
        for (int j = 0; j < 20; j++) {
          if (j == 3) continue;
          if (j > 12) break;
          k += (int)s[i] * j + (int)hh[i];
        }
        switch (((int)p[i]) % 4) {
          case 0: k += 1; break;
          case 1: k += 10; break;
          case 2:
          case 3: k += 100; break;
        }
        c[i] = k;
      });
    });
  }
  int bad = 0;
  for (int i = 0; i < N; i++) {
    int v = (int)px[i] + 40;
    if (out[i] != (unsigned char)(v > 255 ? 255 : v)) bad++;
    int k = 0;
    for (int j = 0; j < 20; j++) { if (j == 3) continue; if (j > 12) break; k += (int)sc[i] * j + (int)sh[i]; }
    switch (((int)px[i]) % 4) { case 0: k += 1; break; case 1: k += 10; break; default: k += 100; break; }
    if (cls[i] != k) bad++;
  }
  std::printf(bad ? "bytes FAIL %d\n" : "bytes ok\n", bad);
  return bad != 0;
}
