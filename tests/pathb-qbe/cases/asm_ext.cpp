// Path B: extended-asm idioms that QBE can express (docs/notes/pathb-hosted.md, "Inline asm"):
//   mfence/lfence/sfence and `lock; addl $0,(%rsp)` are a full fence, a call of the helper __pathb_fence, which the
//   assembler step writes with the real mfence; pause / rep nop / nop are compiler barriers or nothing;
//   rdtsc (alone or after lfence) reads the counter through the helper __pathb_rdtsc;
//   an empty template with operands is a value passthrough (the benchmark idiom DoNotOptimize): "+r" and "=r" outputs
//   keep their value, "m" inputs and outputs only mark the memory, an output tied to an input receives it.
// Other templates, operands on a fence, register clobbers and asm goto stay refused (tests/pathb-ir/gaps.cpp).
// The exit code is the number of wrong results.
// EXPECT: 0
// ASM-COUNT: fences __pathb_fence 5
// ASM-COUNT: spin __pathb_barrier 1
// ASM-COUNT: nofence __pathb_fence 0
// ASM-COUNT: nofence __pathb_barrier 1
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

int shared;

extern "C" void fences(int *p) {
  *p = 1;
  asm volatile("mfence" ::: "memory");
  asm volatile("lfence");
  __asm__ __volatile__("sfence" : : : "memory");
  asm volatile("lock; addl $0,0(%%rsp)" ::: "memory", "cc");
  asm("MFENCE\n\t");
}

// pause is a hint: with a memory clobber it is the barrier a spin loop needs, without one it emits nothing.
extern "C" int spin(volatile int *flag, int n) {
  int spins = 0;
  while (*flag == 0 && spins < n) {
    asm volatile("pause" ::: "memory");
    ++spins;
  }
  return spins;
}

extern "C" int nofence(int x) {
  asm volatile("pause");  // basic asm: gcc takes it for a memory clobber, so one barrier; no fence
  asm volatile("rep; nop" : : : "cc");
  asm volatile("nop" : :);
  return x + 1;
}

template <class T> inline void keep(T const &v) { asm volatile("" : : "r,m"(v) : "memory"); }
template <class T> inline void keep_mut(T &v) { asm volatile("" : "+r,m"(v) : : "memory"); }
inline void clobber() { asm volatile("" : : : "memory"); }

struct Big { long a, b, c; };

static unsigned long ticks() {
  unsigned lo, hi;
  asm volatile("rdtsc" : "=a"(lo), "=d"(hi));
  return ((unsigned long)hi << 32) | lo;
}

static unsigned long ticks_fenced() {
  unsigned long lo, hi;
  asm volatile("lfence\n\trdtsc" : "=a"(lo), "=d"(hi) : : "memory");
  return (hi << 32) | lo;
}

int main() {
  int x = 5;
  fences(&x);
  CHECK(x == 1);

  int flag = 1;
  CHECK(spin(&flag, 10) == 0);
  flag = 0;
  CHECK(spin(&flag, 7) == 7);
  CHECK(nofence(1) == 2);

  // value passthrough
  int a = 41;
  keep_mut(a);
  CHECK(a == 41);
  long l = -7;
  keep(l);
  asm volatile("" : "+r"(l));
  CHECK(l == -7);
  double d = 2.5;
  asm volatile("" : "+x"(d));
  CHECK(d == 2.5);
  int *p = &x;
  asm volatile("" : "+r"(p));
  CHECK(p == &x && *p == 1);
  Big big = {1, 2, 3};
  keep(big);
  asm volatile("" : : "m"(big) : "memory");
  CHECK(big.a + big.b + big.c == 6);

  // an input is evaluated exactly once, and its side effects happen
  int cnt = 0;
  asm volatile("" : : "r"(++cnt));
  CHECK(cnt == 1);
  int arr[3] = {1, 2, 3};
  int i = 0;
  asm volatile("" : "+r"(arr[i++]));
  CHECK(i == 1 && arr[0] == 1);

  // an output tied to an input receives the input
  int src = 99, dst = 0;
  asm("" : "=r"(dst) : "0"(src));
  CHECK(dst == 99);
  unsigned long u1 = 3, u2 = 4;
  asm volatile("" : "=r"(u1), "=r"(u2) : "1"(u1), "0"(u2));  // swapped through the ties
  CHECK(u1 == 4 && u2 == 3);

  // an untied output is unspecified; the lowering leaves it alone
  int junk = 12;
  asm volatile("" : "=r"(junk));
  (void)junk;

  // memory operands as outputs
  int mem = 3;
  asm volatile("" : "+m"(mem) : : "memory");
  CHECK(mem == 3);
  clobber();
  shared = 4;
  clobber();
  CHECK(shared == 4);

  // the time stamp counter moves forward (it is not a fixed value)
  unsigned long t0 = ticks();
  unsigned long acc = 0;
  for (int k = 0; k < 2000000; ++k) { acc += (unsigned long)k; asm volatile("" : "+r"(acc)); }
  unsigned long t1 = ticks_fenced();
  CHECK(acc == 1999999000000UL);
  CHECK(t1 > t0);
  asm volatile("rdtsc");
  return bad;
}
