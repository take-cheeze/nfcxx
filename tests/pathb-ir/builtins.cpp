// GCC built-ins lowered to IR without a library call (golden: tests/pathb-ir/builtins.ir): alloca, the overflow family
// (same-type textbook tests, the general 64-bit pair scheme for signed multiply and mixed types, the _p predicates, the
// sized forms), bswap / popcount / clz / ctz / ffs / parity / clrsb, hints, atomics, the float classification built-ins.
typedef unsigned long size_t;

void *alloc_loop(int n) {
  char *keep = 0;
  for (int i = 0; i < n; i++) keep = (char *)__builtin_alloca(i + 1);
  return keep;
}
void *alloc_aligned(size_t n) { return __builtin_alloca_with_align(n, 512); }

bool add_u(unsigned a, unsigned b, unsigned *r) { return __builtin_add_overflow(a, b, r); }
bool add_s(int a, int b, int *r) { return __builtin_add_overflow(a, b, r); }
bool mul_u(unsigned long a, unsigned long b, unsigned long *r) { return __builtin_mul_overflow(a, b, r); }
bool mul_s(int a, int b, int *r) { return __builtin_mul_overflow(a, b, r); }
bool mul_s64(long a, long b, long *r) { return __builtin_mul_overflow(a, b, r); }
bool mixed(int a, unsigned b, short *r) { return __builtin_sub_overflow(a, b, r); }
bool mixed_u8(long a, signed char b, unsigned char *r) { return __builtin_add_overflow(a, b, r); }
bool pred(long a, long b) { return __builtin_mul_overflow_p(a, b, (int)0); }
bool sized(long a, long b, long *r) { return __builtin_saddl_overflow(a, b, r) | __builtin_usubl_overflow(a, b, (unsigned long *)r); }

unsigned short bs16(unsigned short x) { return __builtin_bswap16(x); }
unsigned bs32(unsigned x) { return __builtin_bswap32(x); }
unsigned long bs64(unsigned long x) { return __builtin_bswap64(x); }
int pc(unsigned x) { return __builtin_popcount(x); }
int pcl(unsigned long x) { return __builtin_popcountl(x); }
int lz(unsigned x) { return __builtin_clz(x); }
int tz(unsigned long x) { return __builtin_ctzl(x); }
int ff(int x) { return __builtin_ffs(x); }
int par(unsigned long long x) { return __builtin_parityll(x); }
int crsb(int x) { return __builtin_clrsb(x); }

int hints(int *p, int x) {
  __builtin_prefetch(p);
  p = (int *)__builtin_assume_aligned(p, 16);
  if (__builtin_expect(x > 0, 1)) return __builtin_constant_p(x) + (int)__builtin_object_size(p, 0);
  if (x == -1) __builtin_unreachable();
  return 0;
}

int atomics(int *p, char *c, long *l) {
  int a = __sync_fetch_and_add(p, 1);
  int b = __sync_bool_compare_and_swap(p, 3, 4);
  long d = __sync_val_compare_and_swap(l, 1L, 2L);
  __sync_synchronize();
  __sync_lock_release(c);
  bool t = __atomic_test_and_set(c, __ATOMIC_SEQ_CST);
  __atomic_thread_fence(__ATOMIC_ACQUIRE);
  __atomic_signal_fence(__ATOMIC_SEQ_CST);
  __atomic_clear(c, __ATOMIC_RELEASE);
  return a + b + (int)d + t + __atomic_fetch_add(p, 5, __ATOMIC_SEQ_CST);
}

int floats(double d, float f) {
  return __builtin_isnan(d) + __builtin_isinf(d) + __builtin_isfinite(f) + __builtin_isnormal(d) + __builtin_isgreater(d, 1.0) +
         __builtin_islessgreater(f, 2.0f) + __builtin_isunordered(d, d) + __builtin_isinf_sign(d) + __builtin_signbit(d) +
         __builtin_fpclassify(0, 1, 4, 3, 2, d);
}

double nonfinite(void) { return __builtin_inf() - __builtin_nan(""); }
