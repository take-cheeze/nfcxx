// USM allocations start at a multiple of 128 bytes (the device's mem_base_addr_align, 1024 bits), whatever the element
// type, as DPC++'s do: ggml-sycl takes the base of a malloc_device buffer to be aligned to its buffer type's 128 bytes, and
// gives up on a buffer whose aligned base leaves too little room. aligned_alloc_* gets the larger alignment it asks for.
// Odd sizes in a row (so a 16-byte granular heap would hand out unaligned blocks), a free and a reuse, and a kernel that
// writes through every pointer.
#include <sycl/sycl.hpp>
#include <cstdint>
#include <cstdio>

int main() {
  sycl::queue q;
  int bad = 0;
  const size_t sizes[] = {1, 3, 17, 100, 129, 4000};
  const int n = sizeof(sizes) / sizeof(sizes[0]);
  char *p[3 * n];
  for (int i = 0; i < n; i++) {
    p[3 * i] = sycl::malloc_device<char>(sizes[i], q);
    p[3 * i + 1] = sycl::malloc_shared<char>(sizes[i], q);
    p[3 * i + 2] = sycl::malloc_host<char>(sizes[i], q);
  }
  for (int i = 0; i < 3 * n; i++)
    if ((uintptr_t)p[i] % 128 != 0) { std::printf("allocation %d (%zu bytes) at %p: not 128-byte aligned\n", i, sizes[i / 3], (void *)p[i]); bad++; }

  // a larger alignment than the floor
  float *big = sycl::aligned_alloc_device<float>(4096, 10, q);
  if ((uintptr_t)big % 4096 != 0) { std::printf("aligned_alloc_device(4096) at %p\n", (void *)big); bad++; }

  // a freed block is reused (or not) without breaking the alignment
  sycl::free(p[1], q);
  p[1] = sycl::malloc_shared<char>(5, q);
  if ((uintptr_t)p[1] % 128 != 0) { std::printf("reused allocation at %p\n", (void *)p[1]); bad++; }

  // every block is usable: a kernel writes each one's first byte, the host reads them back
  char *flags = sycl::malloc_shared<char>(3 * n, q);
  char **ptrs = sycl::malloc_shared<char *>(3 * n, q);
  for (int i = 0; i < 3 * n; i++) ptrs[i] = p[i];
  q.parallel_for(sycl::range<1>(3 * n), [=](sycl::id<1> i) { ptrs[i][0] = (char)(i + 1); }).wait();
  q.parallel_for(sycl::range<1>(3 * n), [=](sycl::id<1> i) { flags[i] = ptrs[i][0]; }).wait();
  for (int i = 0; i < 3 * n; i++) if (flags[i] != (char)(i + 1)) bad++;

  for (int i = 0; i < 3 * n; i++) sycl::free(p[i], q);
  sycl::free(big, q);
  sycl::free(flags, q);
  sycl::free(ptrs, q);
  if (bad) { std::printf("usm_align: %d bad\n", bad); return 1; }
  std::printf("usm_align ok\n");
  return 0;
}
