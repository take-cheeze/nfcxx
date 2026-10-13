// Two kernels in a row on the same buffers (the data stays on the device), a host_accessor in between, a functor kernel,
// a named kernel, single_task, and a histogram with atomic_ref.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

struct Scale {
  sycl::accessor<float, 1, sycl::access_mode::read_write> d;
  float k;
  void operator()(sycl::id<1> i) const { d[i] = d[i] * k; }
};

class AddOne;

int main() {
  const int N = 200;
  std::vector<float> v(N);
  for (int i = 0; i < N; i++) v[i] = (float)i;
  std::vector<int> hist(8, 0), data(1000);
  for (int i = 0; i < 1000; i++) data[i] = (i * 37 + 11) % 8;
  int one = 0;
  int bad = 0;
  {
    sycl::queue q;
    sycl::buffer<float> V(v);
    q.submit([&](sycl::handler &h) {
      sycl::accessor a(V, h);
      h.parallel_for(sycl::range<1>(N), Scale{a, 3.0f});
    });
    q.submit([&](sycl::handler &h) {
      sycl::accessor a(V, h);
      h.parallel_for<class AddOne>(sycl::range<1>(N), [=](sycl::id<1> i) { a[i] += 1.0f; });
    });
    {
      // a ranged accessor over the middle of the buffer, through the 1.2.1 spelling, and a tagged host access
      q.submit([&](sycl::handler &h) {
        auto r = V.get_access<sycl::access_mode::read_write>(h, sycl::range<1>(N - 20), sycl::id<1>(10));
        h.parallel_for(sycl::range<1>(N - 20), [=](sycl::id<1> i) { r[i] += 100.0f; });
      });
      auto ha = V.get_host_access(sycl::read_write);
      for (int i = 10; i < N - 10; i++) ha[i] -= 100.0f;   // undo it on the host, so the checks below still hold
    }
    {
      sycl::host_accessor ha(V, sycl::read_only);   // waits for both kernels
      for (int i = 0; i < N; i++)
        if (ha[i] != 3.0f * (float)i + 1.0f) bad++;
    }
    q.submit([&](sycl::handler &h) {
      sycl::accessor a(V, h);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) { a[i] = a[i] * 2.0f; });   // after the host read: data must still be right
    });
    sycl::buffer<int> H(hist), D(data), O(&one, sycl::range<1>(1));
    q.submit([&](sycl::handler &h) {
      sycl::accessor hh(H, h);
      sycl::accessor dd(D, h, sycl::read_only);
      h.parallel_for(sycl::range<1>(1000), [=](sycl::id<1> i) {
        sycl::atomic_ref<int> r(hh[dd[i]]);
        r.fetch_add(1);
      });
    });
    q.submit([&](sycl::handler &h) {
      sycl::accessor o(O, h, sycl::write_only, sycl::no_init);
      h.single_task([=]() { int s = 0; for (int i = 1; i <= 10; i++) s += i * i; o[0] = s; });
    });
  }
  for (int i = 0; i < N; i++)
    if (v[i] != 2.0f * (3.0f * (float)i + 1.0f)) bad++;
  int want[8] = {0};
  for (int i = 0; i < 1000; i++) want[data[i]]++;
  for (int b = 0; b < 8; b++)
    if (hist[b] != want[b]) bad++;
  if (one != 385) bad++;
  std::printf(bad ? "chain FAIL %d\n" : "chain ok\n", bad);
  return bad != 0;
}
