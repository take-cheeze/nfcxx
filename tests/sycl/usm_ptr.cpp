// USM pointers stored in USM memory: the host writes pointers that a kernel follows, and a kernel writes a pointer that the
// host reads back and follows. On a Vulkan device whose device addresses differ from the host addresses, each is translated
// when it is loaded or stored (see PUSH_MEMBERS in scripts/pathb-spirv-emit.rb). Prints "usm_ptr ok".
#include <sycl/sycl.hpp>
#include <cstdio>

int main() {
  sycl::queue q;
  const int N = 256;
  int bad = 0;

  int *data = sycl::malloc_shared<int>(N, q);
  int **table = sycl::malloc_shared<int *>(2, q);
  int *out = sycl::malloc_shared<int>(N, q);
  int **found = sycl::malloc_shared<int *>(1, q);
  for (int i = 0; i < N; i++) data[i] = i * 5;
  table[0] = data;
  table[1] = data + N / 2;
  *found = nullptr;

  // the kernel follows the pointers the host wrote into table
  q.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) { out[i] = table[i[0] / (N / 2)][i[0] % (N / 2)] + 1; }).wait();
  for (int i = 0; i < N; i++) if (out[i] != data[i] + 1) bad++;

  // the kernel stores a pointer into USM memory; the host reads it and follows it
  q.single_task([=]() { *found = &out[7]; }).wait();
  if (*found != &out[7]) bad++;
  if (**found != out[7]) bad++;

  // a second kernel follows the pointer the first one stored
  q.single_task([=]() { (*found)[1] = 99; }).wait();
  if (out[8] != 99) bad++;

  sycl::free(data, q); sycl::free(table, q); sycl::free(out, q); sycl::free(found, q);
  std::printf(bad ? "usm_ptr FAIL %d\n" : "usm_ptr ok\n", bad);
  return bad != 0;
}
