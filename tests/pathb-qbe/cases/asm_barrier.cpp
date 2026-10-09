// Path B: the subset of inline assembly that QBE can express: an empty template with no operands whose clobbers are
// "memory" and/or "cc" is a compiler barrier, lowered to (barrier) and emitted as a call of an empty module-local
// function (an opaque call QBE keeps in order). Without a "memory" clobber the statement emits nothing. Templates,
// operands, register clobbers and asm goto are refused with a clear message (tests/pathb-ir/gaps.cpp,
// tests/mruby/pathb-edge/barrier*.ir). The exit code is the number of wrong results.
// EXPECT: 0
// ASM-COUNT: two_barriers __pathb_barrier 2
// ASM-COUNT: no_barrier __pathb_barrier 0
// ASM-COUNT: cc_only __pathb_barrier 0
// ASM-COUNT: basic_empty __pathb_barrier 1
// ASM-COUNT: in_loop __pathb_barrier 1
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)
#define BARRIER() __asm__ __volatile__("" ::: "memory")

int shared;

extern "C" int two_barriers(int *p) {
  *p = 1;
  BARRIER();
  int a = *p;
  asm volatile("" : : : "memory", "cc");
  return a + shared;
}

extern "C" int no_barrier(int x) {
  asm volatile("" : :);
  asm volatile("" ::: "cc");
  return x + 1;
}

extern "C" int cc_only(int x) {
  __asm__ __volatile__("   " : : : "cc");
  return x * 2;
}

extern "C" int basic_empty(int x) {
  asm("");
  return x - 1;
}

extern "C" int in_loop(int n) {
  int s = 0;
  for (int i = 0; i < n; ++i) {
    s += i;
    BARRIER();
  }
  return s;
}

template <class T> T tmpl(T v) { BARRIER(); return v + 1; }

struct S {
  int v;
  void touch() { BARRIER(); ++v; }
};

int main() {
  int x = 5;
  shared = 10;
  CHECK(two_barriers(&x) == 11);
  CHECK(no_barrier(1) == 2);
  CHECK(cc_only(4) == 8);
  CHECK(basic_empty(3) == 2);
  CHECK(in_loop(5) == 10);
  CHECK(tmpl<int>(1) == 2 && tmpl<long>(5) == 6);
  S s = {1};
  s.touch();
  s.touch();
  CHECK(s.v == 3);
  int y = 0;
  BARRIER();
  y = 1;
  BARRIER();
  CHECK(y == 1);
  return bad;
}
