// Constant tables of more than 4 KB in one translation unit (ggml-sycl's iq quant grids, about 25 KB of statics). The
// manifest holds the whole static region on one hex line, and the image loader read lines into a 4096-byte buffer: the
// line was cut after about 2 KB of statics, and every table past that read as zeros on the device.
#include <sycl/sycl.hpp>
#include <cstdint>
#include <cstdio>

#define R4(b) (b), (b) + 1, (b) + 2, (b) + 3
#define R16(b) R4(b), R4((b) + 4), R4((b) + 8), R4((b) + 12)
#define R64(b) R16(b), R16((b) + 16), R16((b) + 32), R16((b) + 48)
#define R256(b) R64(b), R64((b) + 64), R64((b) + 128), R64((b) + 192)
#define R1024(b) R256(b), R256((b) + 256), R256((b) + 512), R256((b) + 768)

static const uint64_t grid[2048] = {R1024(0x100000000ull), R1024(0x100000000ull + 1024)};   // 16 KB
static const int8_t tail[16] = {-127, -104, -83, -65, -49, -35, -22, -10, 1, 13, 25, 38, 53, 69, 89, 113};

int main() {
  sycl::queue q;
  const int n = 2048;
  uint64_t *g = sycl::malloc_shared<uint64_t>(n, q);
  int *t = sycl::malloc_shared<int>(16, q);
  q.parallel_for(sycl::range<1>(n), [=](sycl::id<1> i) {
    g[i] = grid[i];
    if (i < 16) t[i] = tail[i];
  }).wait();
  int bad = 0;
  for (int i = 0; i < n; i++) if (g[i] != 0x100000000ull + i) bad++;
  for (int i = 0; i < 16; i++) if (t[i] != tail[i]) bad++;
  sycl::free(g, q);
  sycl::free(t, q);
  if (bad) { std::printf("big_tables: %d wrong\n", bad); return 1; }
  std::printf("big_tables ok\n");
  return 0;
}
