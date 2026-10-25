// A work-group smaller than a sub-group, for a kernel that uses no sub-group operation, in a translation unit whose other
// kernel does (a sub-group reduction). The OpenCL and Level Zero runtimes require whole 16-lane sub-groups only of the
// kernels that reach a sub-group shuffle (the k line of the manifest gives the size); before, the whole module's kernels
// had to, and ggml-sycl's argsort (a 4-work-item work-group for 4 columns, in a TU with sub-group reductions) was refused.
#include <sycl/sycl.hpp>
#include <cstdio>

int main() {
  sycl::queue q;
  int bad = 0;

  // the sub-group kernel: each work-group of 32 sums its two sub-groups' values with reduce_over_group
  const int n = 64;
  int *v = sycl::malloc_shared<int>(n, q);
  int *sums = sycl::malloc_shared<int>(n, q);
  for (int i = 0; i < n; i++) v[i] = i;
  q.parallel_for(sycl::nd_range<1>(n, 32), [=](sycl::nd_item<1> it) {
    sycl::sub_group sg = it.get_sub_group();
    sums[it.get_global_id(0)] = sycl::reduce_over_group(sg, v[it.get_global_id(0)], sycl::plus<int>());
  }).wait();
  for (int i = 0; i < n; i++) {
    int first = i / 16 * 16, want = 0;
    for (int j = first; j < first + 16; j++) want += j;
    if (sums[i] != want) bad++;
  }

  // the plain kernel: work-groups of 4, each reversing its slice through local memory
  const int m = 12;
  int *a = sycl::malloc_shared<int>(m, q);
  for (int i = 0; i < m; i++) a[i] = 100 + i;
  q.submit([&](sycl::handler &h) {
    sycl::local_accessor<int, 1> t(sycl::range<1>(4), h);
    h.parallel_for(sycl::nd_range<1>(m, 4), [=](sycl::nd_item<1> it) {
      const size_t l = it.get_local_id(0);
      t[l] = a[it.get_global_id(0)];
      it.barrier(sycl::access::fence_space::local_space);
      a[it.get_global_id(0)] = t[3 - l];
    });
  }).wait();
  for (int i = 0; i < m; i++) if (a[i] != 100 + (i / 4 * 4 + 3 - i % 4)) bad++;

  sycl::free(v, q);
  sycl::free(sums, q);
  sycl::free(a, q);
  if (bad) { std::printf("partial_subgroup: %d bad\n", bad); return 1; }
  std::printf("partial_subgroup ok\n");
  return 0;
}
