// EXPECT: 0
// Path B: __atomic_exchange_4 and _8 (std::atomic::exchange, used and discarded) are a loop of locked compare-exchanges, not a
// libatomic call (scripts/pathb-ssa-qbe.rb, atomic_xchg_lines). The probe checks the values and that no call of
// __atomic_exchange remains in the functions that exchange.
// ASM-COUNT: exchange_used __atomic_exchange 0
// ASM-COUNT: exchange_discarded __atomic_exchange 0
// ASM-COUNT: exchange_runtime_order __atomic_exchange 0
#include <atomic>

std::atomic<long> cell8{5};
std::atomic<int> cell4{7};

extern "C" {
__attribute__((noinline)) long exchange_used(long v) { return cell8.exchange(v); }

__attribute__((noinline)) void exchange_discarded(int v) {
  cell4.exchange(v);
  cell8.exchange(v + 1L);
}

__attribute__((noinline)) int exchange_runtime_order(int v, std::memory_order o) { return cell4.exchange(v, o); }
}

int main() {
  long a = exchange_used(9);       // returns 5, leaves 9
  exchange_discarded(4);           // cell4 = 4, cell8 = 5
  int b = exchange_runtime_order(11, std::memory_order_seq_cst); // returns 4, leaves 11
  if (a != 5 || cell8.load() != 5 || b != 4 || cell4.load() != 11) return 1;
  return 0;
}
