// EXPECT: 0
// std::atomic compare-exchange of 4 and 8 bytes, strong and weak, in several orders: lowered inline (a locked compare-exchange,
// QBE's cmpxchg0/cmpxchg1 pair) and not a libatomic call. On success the object takes the desired value and the expected
// object is unchanged; on failure the expected object takes the value the object held and the object is unchanged. Output
// compared with the gcc backend.
#include <atomic>
#include <cstdio>

struct Node {
  std::atomic<int> count{1};
  std::atomic<long> tag{100};
  int pad = 0;
};

// The compare-exchange in a function of its own (what weak_ptr::lock does: retry until the count is not zero).
static bool try_inc(std::atomic<long> &c) {
  long v = c.load(std::memory_order_relaxed);
  do {
    if (v == 0) return false;
  } while (!c.compare_exchange_weak(v, v + 1, std::memory_order_acq_rel, std::memory_order_relaxed));
  return true;
}

int main() {
  int fails = 0;
  Node n;

  // success, strong, seq_cst
  int e = 1;
  bool ok = n.count.compare_exchange_strong(e, 5);
  fails += !ok || e != 1 || n.count.load() != 5;

  // failure, strong: the expected object takes the observed value, the object keeps it
  e = 9;
  ok = n.count.compare_exchange_strong(e, 6, std::memory_order_acq_rel, std::memory_order_acquire);
  fails += ok || e != 5 || n.count.load() != 5;

  // success, weak, in a loop (weak may fail spuriously, so retry until it succeeds)
  e = 5;
  while (!n.count.compare_exchange_weak(e, 7, std::memory_order_acq_rel, std::memory_order_relaxed)) {
    if (e != 5) { fails++; break; }
  }
  fails += n.count.load() != 7;

  // 8 bytes
  long l = 100;
  ok = n.tag.compare_exchange_strong(l, 200);
  fails += !ok || l != 100 || n.tag.load() != 200;
  l = 1;
  ok = n.tag.compare_exchange_strong(l, 300, std::memory_order_seq_cst);
  fails += ok || l != 200 || n.tag.load() != 200;

  // the increment-if-not-zero loop of weak_ptr::lock
  std::atomic<long> c{2};
  fails += !try_inc(c) || c.load() != 3;
  std::atomic<long> zero{0};
  fails += try_inc(zero) || zero.load() != 0;

  // the other fields are not touched by a 4-byte exchange next to them
  fails += n.pad != 0 || n.tag.load() != 200;

  std::printf("fails %d\n", fails);
  return fails != 0;
}
