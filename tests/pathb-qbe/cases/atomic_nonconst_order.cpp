// EXPECT: 0
// STDOUT: same
// std::atomic<bool> and std::atomic<unsigned char> stores and loads whose memory order is a runtime parameter (the members
// are emitted out of line, with a non-constant order): Path B lowers them inline (a plain load; a store with the seq_cst
// barrier) and leaves no __atomic_load_1 or __atomic_store_1 call. Checked against the expected values and the gcc backend.
#include <atomic>
#include <cstdio>

extern "C" __attribute__((noinline)) bool store_flag(std::atomic<bool> &a, bool v, std::memory_order o) {
  a.store(v, o);
  return v;
}

extern "C" __attribute__((noinline)) bool load_flag(std::atomic<bool> &a, std::memory_order o) {
  return a.load(o);
}

int main() {
  std::atomic<bool> flag{false};
  int fails = 0;
  for (int i = 0; i < 4; i++) {
    bool v = (i & 1) != 0;
    std::memory_order o = i < 2 ? std::memory_order_seq_cst : std::memory_order_relaxed;
    fails += store_flag(flag, v, o) != v;
    fails += load_flag(flag, o) != v;
  }
  std::atomic<unsigned char> byte{0};
  byte.store(250, std::memory_order_seq_cst);
  fails += byte.load(std::memory_order_seq_cst) != 250;
  std::printf("%d %d\n", (int)flag.load(), fails);
  return fails;
}
