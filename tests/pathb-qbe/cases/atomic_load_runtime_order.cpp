// EXPECT: 0
// std::atomic<unsigned long>::load with a memory order that is a run-time variable: the 8-byte load lowers to a plain
// load (no __atomic_load_8 call), whatever the order, since a load needs no fence on x86. Each order returns the stored
// value, checked against the expected one; compared with the gcc backend.
#include <atomic>

__attribute__((noinline)) unsigned long load_with(std::atomic<unsigned long> *a, std::memory_order o) {
  return a->load(o);
}

__attribute__((noinline)) int load_checked(std::atomic<unsigned long> *a, std::memory_order o, unsigned long want) {
  return load_with(a, o) == want ? 0 : 1;
}

int main() {
  std::atomic<unsigned long> v{0x1122334455667788UL};
  std::memory_order orders[] = {std::memory_order_relaxed, std::memory_order_consume, std::memory_order_acquire,
                                std::memory_order_seq_cst};
  int bad = 0;
  for (std::memory_order o : orders) bad += load_checked(&v, o, 0x1122334455667788UL);
  v.store(7, std::memory_order_seq_cst);
  bad += load_checked(&v, std::memory_order_acquire, 7);
  return bad;
}
