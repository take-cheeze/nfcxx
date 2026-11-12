// EXPECT: 0
// STDOUT: same
// std::atomic stores and loads of 1, 2, 4 and 8 bytes in each memory order: lowered inline (a plain store or load, and for a
// sequentially consistent store a locked add of 0 as the barrier) next to their neighbours in the same word, which they must
// not change. Output compared with the gcc backend.
#include <atomic>
#include <cstdio>

struct Packed {
  std::atomic<unsigned char> a{1};
  std::atomic<unsigned char> b{2};
  std::atomic<unsigned short> c{3};
  std::atomic<unsigned int> d{4};
  std::atomic<unsigned long> e{5};
};

int main() {
  Packed p;
  int fails = 0;
  p.a.store(250);
  p.b.store(251, std::memory_order_relaxed);
  p.c.store(65000, std::memory_order_release);
  p.d.store(4000000000u);
  p.e.store(1ul << 40, std::memory_order_seq_cst);
  fails += p.a.load() != 250 || p.b.load(std::memory_order_acquire) != 251 || p.c.load(std::memory_order_relaxed) != 65000;
  fails += p.d.load() != 4000000000u || p.e.load() != (1ul << 40);
  p.b.store(7);
  fails += p.a.load() != 250 || p.b.load() != 7 || p.c.load() != 65000;
  p.c.store(1, std::memory_order_relaxed);
  fails += p.b.load() != 7 || p.c.load() != 1;
  std::atomic<bool> flag{false};
  flag.store(true);
  fails += !flag.load();
  flag.store(false, std::memory_order_release);
  fails += flag.load(std::memory_order_acquire);
  std::printf("%d %d %d %u %lu %d\n", (int)p.a.load(), (int)p.b.load(), (int)p.c.load(), p.d.load(), p.e.load(), fails);
  return fails;
}
