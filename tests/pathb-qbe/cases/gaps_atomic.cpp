// EXPECT: 0
// STDOUT: same
// std::atomic, atomic_flag, atomic_thread_fence / signal_fence, and the GCC __atomic_* / legacy __sync_* built-ins (sized, EDG calls
// them __atomic_fetch_add_4 ...): libatomic functions, with the ones nothing exports (__atomic_test_and_set, __atomic_clear,
// the fences, every __sync_*) lowered to them. Output compared with the gcc backend.
#include <atomic>
#include <cstdio>
struct S { int a, b; };
static int part1() {
  std::atomic_flag af = ATOMIC_FLAG_INIT;
  int f1 = af.test_and_set();
  int f2 = af.test_and_set();
  af.clear();
  int f3 = af.test_and_set();
  std::atomic_thread_fence(std::memory_order_seq_cst);
  std::atomic_thread_fence(std::memory_order_acquire);
  std::atomic_signal_fence(std::memory_order_release);
  std::atomic<long> a{1};
  a += 5;
  a -= 2;
  a++;
  long old = a.fetch_add(3);
  a &= 0xff;
  a |= 0x100;
  a ^= 3;
  long ex = a.exchange(7);
  long exp = 7;
  bool ok = a.compare_exchange_weak(exp, 9);
  std::atomic<bool> b{false};
  b.store(true);
  std::atomic<int *> p{nullptr};
  int x;
  p.store(&x);
  int *q = p.fetch_add(0);
  std::atomic<short> sh{1};
  sh.fetch_sub(2);
  std::atomic<unsigned char> uc{200};
  uc.fetch_add(100);
  std::atomic<double> d{1.5};
  d.store(2.5);
  double dd = d.load();
  std::atomic<S> as{S{1, 2}};
  S s = as.load();
  std::printf("%d %d %d %ld %ld %ld %d %d %d %d %d %d %g %d\n", f1, f2, f3, old, ex, a.load(), (int)ok, (int)b.load(), q == &x, (int)sh.load(), (int)uc.load(), (int)a.is_lock_free(), dd, s.b);
  return 0;
}

static int part2() {
  int x = 5;
  long y = 10;
  char c = 1;
  int a = __sync_fetch_and_add(&x, 3);
  int b = __sync_add_and_fetch(&x, 1);
  long cc = __sync_fetch_and_sub(&y, 2);
  int ok = __sync_bool_compare_and_swap(&x, 9, 20);
  int v = __sync_val_compare_and_swap(&x, 20, 30);
  int t = __sync_lock_test_and_set(&x, 1);
  __sync_lock_release(&x);
  __sync_synchronize();
  char o = __sync_fetch_and_or(&c, 6);
  int n = __sync_fetch_and_nand(&x, 3);
  int ld = __atomic_load_n(&x, __ATOMIC_SEQ_CST);
  __atomic_store_n(&x, 77, __ATOMIC_RELEASE);
  int tmp;
  __atomic_load(&x, &tmp, __ATOMIC_ACQUIRE);
  int ex = __atomic_exchange_n(&x, 5, __ATOMIC_SEQ_CST);
  int expected = 5;
  bool cx = __atomic_compare_exchange_n(&x, &expected, 6, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
  int af = __atomic_add_fetch(&x, 4, __ATOMIC_SEQ_CST);
  int nf = __atomic_nand_fetch(&x, 4, __ATOMIC_SEQ_CST);
  bool lf = __atomic_always_lock_free(4, 0);
  bool lf2 = __atomic_is_lock_free(8, &y);
  std::printf("%d %d %ld %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n", a, b, cc, ok, v, t, (int)o, n, ld, tmp, ex, (int)cx, af, nf, (int)lf, (int)lf2, x, (int)y);
  return 0;
}
int main() { return part1() + part2(); }
