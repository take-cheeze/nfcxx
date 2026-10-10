// EXPECT: 0
// STDOUT: same
// Single-instruction asm templates without operands that do nothing observable: pause (rep nop) and nop, in the forms
// spin-wait loops are written with. They become an opaque call of an empty function (the same lowering as the empty
// "memory" barrier). Anything else (mfence, lock-prefixed instructions, cpuid) is refused, see tests/pathb-ir/asm_refuse.cpp.
#include <atomic>
#include <cstdio>
#include <thread>

static inline void relax1() { __asm__ __volatile__("pause" ::: "memory"); }
static inline void relax2() { asm volatile("rep; nop"); }
static inline void relax3() { __asm__("rep nop" ::: "cc"); }
static inline void relax4() { asm volatile("pause\n\t"); }
static inline void relax5() { __asm__ __volatile__("nop"); }
static inline void relax6() { __builtin_ia32_pause(); }

static std::atomic<int> flag{0};
static int plain = 0;

int main() {
  std::thread t([] {
    for (int i = 0; i < 1000; i++) { relax1(); relax2(); relax3(); }
    plain = 17;
    flag.store(1, std::memory_order_release);
  });
  long spins = 0;
  while (flag.load(std::memory_order_acquire) == 0) {
    relax1();
    relax4();
    relax5();
    relax6();
    spins++;
  }
  t.join();
  asm("pause");
  asm volatile("nop");
  printf("flag %d plain %d\n", flag.load(), plain);
  return plain == 17 ? 0 : 1;
}
