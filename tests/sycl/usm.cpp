// Unified shared memory: malloc_shared / malloc_device / malloc_host, memcpy, memset, fill, free; raw pointers captured by
// kernels; a kernel chain with no buffers; a reduction into a USM variable.
#include <sycl/sycl.hpp>
#include <cstdio>

int main() {
  sycl::queue q;
  const int N = 1000;
  int bad = 0;

  // shared USM: the host writes, the kernel updates in place, the host reads after wait()
  float *s = sycl::malloc_shared<float>(N, q);
  for (int i = 0; i < N; i++) s[i] = (float)i;
  q.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) { s[i] = s[i] * 2.0f + 1.0f; }).wait();
  for (int i = 0; i < N; i++) if (s[i] != 2.0f * (float)i + 1.0f) bad++;
  q.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) { s[i] += 10.0f; }).wait();   // a second round: the host data went to the device again
  for (int i = 0; i < N; i++) if (s[i] != 2.0f * (float)i + 11.0f) bad++;

  // device USM + explicit copies
  int *d = sycl::malloc_device<int>(N, q);
  int host_in[N], host_out[N];
  for (int i = 0; i < N; i++) { host_in[i] = i * 3; host_out[i] = -1; }
  q.memcpy(d, host_in, N * sizeof(int)).wait();
  q.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) { d[i] = d[i] + (int)i; });
  q.memcpy(host_out, d, N * sizeof(int)).wait();
  for (int i = 0; i < N; i++) if (host_out[i] != i * 4) bad++;

  // memset and fill
  q.memset(d, 0, N * sizeof(int)).wait();
  q.fill(d, 7, N).wait();
  q.memcpy(host_out, d, N * sizeof(int)).wait();
  for (int i = 0; i < N; i++) if (host_out[i] != 7) bad++;

  // reduction into a shared variable (+ and max)
  int *sum = sycl::malloc_shared<int>(1, q);
  int *mx = sycl::malloc_shared<int>(1, q);
  *sum = 0; *mx = -1000000;
  for (int i = 0; i < N; i++) host_in[i] = (i * 37) % 101 - 50;
  q.memcpy(d, host_in, N * sizeof(int)).wait();
  q.submit([&](sycl::handler &h) {
    h.parallel_for(sycl::range<1>(N), sycl::reduction(sum, sycl::plus<int>()), [=](sycl::id<1> i, auto &r) { r += d[i]; });
  }).wait();
  q.submit([&](sycl::handler &h) {
    h.parallel_for(sycl::range<1>(N), sycl::reduction(mx, sycl::maximum<int>()), [=](sycl::id<1> i, auto &r) { r.combine(d[i]); });
  }).wait();
  int want = 0, wmax = -1000000;
  for (int i = 0; i < N; i++) { want += host_in[i]; if (host_in[i] > wmax) wmax = host_in[i]; }
  if (*sum != want || *mx != wmax) bad++;

  // a float sum through a buffer
  float acc = 100.0f;
  {
    sycl::buffer<float> B(&acc, sycl::range<1>(1));
    q.submit([&](sycl::handler &h) {
      h.parallel_for(sycl::range<1>(64), sycl::reduction(B, h, sycl::plus<float>(), sycl::property::reduction::initialize_to_identity()),
                     [=](sycl::id<1> i, auto &r) { r += 0.5f * (float)i[0]; });
    });
  }
  if (acc != 0.5f * 2016.0f) bad++;

  sycl::free(s, q); sycl::free(d, q); sycl::free(sum, q); sycl::free(mx, q);
  std::printf(bad ? "usm FAIL %d\n" : "usm ok\n", bad);
  return bad != 0;
}
