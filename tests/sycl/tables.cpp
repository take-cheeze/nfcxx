// Static data in kernels: constant tables of several element types, a table of structs, a pointer to another table (the string), a
// string literal read byte by byte.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

static const float weights[5] = {0.25f, 0.5f, 1.0f, 0.5f, 0.25f};
static const int primes[8] = {2, 3, 5, 7, 11, 13, 17, 19};
static const short deltas[4] = {-3, 1, 4, -1};
static const unsigned char bits[6] = {1, 2, 4, 8, 16, 255};
struct Pair { int a; float b; };
static const Pair pairs[3] = {{10, 0.5f}, {20, 1.5f}, {30, 2.5f}};
static const char *const words = "kernel";

int main() {
  const int N = 64;
  std::vector<float> out(N, 0.0f);
  std::vector<int> cnt(1, 0), len(N, 0);
  {
    sycl::queue q;
    sycl::buffer<float> O(out);
    sycl::buffer<int> L(len);
    q.submit([&](sycl::handler &h) {
      sycl::accessor o(O, h, sycl::write_only, sycl::no_init);
      sycl::accessor l(L, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        int k = (int)i[0];
        float v = weights[k % 5] * (float)primes[k % 8] + (float)deltas[k % 4] + (float)bits[k % 6] + pairs[k % 3].b + (float)pairs[k % 3].a;
        int n = 0;
        while (words[n]) n++;
        l[i] = n * 100 + (int)words[k % 6];
        o[i] = v;
      });
    });
  }
  int bad = 0;
  for (int k = 0; k < N; k++) {
    float v = weights[k % 5] * (float)primes[k % 8] + (float)deltas[k % 4] + (float)bits[k % 6] + pairs[k % 3].b + (float)pairs[k % 3].a;
    if (out[k] != v) bad++;
    if (len[k] != 600 + (int)words[k % 6]) bad++;
  }
  std::printf(bad ? "tables FAIL %d\n" : "tables ok\n", bad);
  return bad != 0;
}
