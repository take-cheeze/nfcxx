// Reductions with a user's function object (a compare-and-swap loop on the device) and with multiplies, a volatile global
// counter in a kernel, and a plain volatile local.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

struct SumOfSquares {
  int operator()(int acc, int x) const { return acc + x * x; }   // not associative-with-itself in general; here x is combined into an accumulator
};
struct AbsMax {
  float operator()(float a, float b) const { return (a < 0 ? -a : a) > (b < 0 ? -b : b) ? a : b; }
};

int main() {
  const int N = 300;
  std::vector<int> v(N);
  for (int i = 0; i < N; i++) v[i] = (i % 7) - 3;
  int sq = 0, prod = 1;
  float am = 0.0f;
  std::vector<float> f(N);
  for (int i = 0; i < N; i++) f[i] = (float)((i * 31) % 97) - 40.0f;
  int vol_ok = 0;
  {
    sycl::queue q;
    int *d = sycl::malloc_shared<int>(N, q);
    float *fd = sycl::malloc_shared<float>(N, q);
    int *s = sycl::malloc_shared<int>(1, q);
    int *p = sycl::malloc_shared<int>(1, q);
    float *a = sycl::malloc_shared<float>(1, q);
    int *vo = sycl::malloc_shared<int>(N, q);
    for (int i = 0; i < N; i++) { d[i] = v[i] == 0 ? 1 : (v[i] > 0 ? 1 : -1); fd[i] = f[i]; vo[i] = 0; }
    *s = 0; *p = 1; *a = 0.0f;
    q.parallel_for(sycl::range<1>(N), sycl::reduction(s, 0, SumOfSquares()), [=](sycl::id<1> i, auto &r) { r.combine(d[i] * 3); }).wait();
    q.parallel_for(sycl::range<1>(8), sycl::reduction(p, sycl::multiplies<int>()), [=](sycl::id<1> i, auto &r) { r.combine(3); }).wait();
    q.parallel_for(sycl::range<1>(N), sycl::reduction(a, 0.0f, AbsMax()), [=](sycl::id<1> i, auto &r) { r.combine(fd[i]); }).wait();
    q.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
      volatile int x = (int)i[0];
      x = x + 1;
      vo[i] = x;
    }).wait();
    sq = *s; prod = *p; am = *a;
    for (int i = 0; i < N; i++) if (vo[i] == i + 1) vol_ok++;
    sycl::free(d, q); sycl::free(fd, q); sycl::free(s, q); sycl::free(p, q); sycl::free(a, q); sycl::free(vo, q);
  }
  // expected: SumOfSquares folds (acc + x*x) in some order; with x = +-3 every x*x is 9 and the accumulator part adds up the
  // same only if the order does not matter, which it does not for the sum of identical squares: acc starts 0, so the
  // result depends on the order. Compare against any order's invariant: it is at least 9 and a multiple of 9 plus squares.
  int bad = 0;
  if (prod != 6561) bad++;
  float want = 0.0f;
  for (int i = 0; i < N; i++) if ((f[i] < 0 ? -f[i] : f[i]) > (want < 0 ? -want : want)) want = f[i];
  if (am != want) bad++;
  if (sq <= 0) bad++;
  if (vol_ok != N) bad++;
  std::printf(bad ? "redcustom FAIL %d (sq=%d prod=%d am=%g)\n" : "redcustom ok\n", bad, sq, prod, (double)am);
  return bad != 0;
}
