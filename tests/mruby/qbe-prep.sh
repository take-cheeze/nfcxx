#!/usr/bin/env bash
# qbe-prep port check (docs/notes/mruby-scripting.md, stage 3): scripts/qbe-prep.rb must give the same
# output C, the same assembly tail, the same stderr and the same exit status as the Python original
# (tests/mruby/oracle/qbe-prep.py, the NFCXX_C_INPUT environment variable of which is the --c-input
# argument of the port) on
#   1. every input scripts/qbe-cc really feeds it: the compiles of tests/cases, tests/c, tests/builtins and
#      tests/lib (and tinyxml2, doctest, lua when build/realworld has them) run with the interpreter wrapped
#      by tests/mruby/qbe-prep-tap.sh, which saves each preprocessed C file and the C-input flag;
#   2. hand-written edge cases for each rewrite (aligned attributes, __bf16/_Float*, constructors,
#      thread_local aliases, overflow builtins, volatile locals, alloca, atomics, float literals, tokenizer).
# The comparison fails when it is vacuous: every corpus must have produced inputs, and every kind of rewrite must
# occur in the Python output somewhere. Skipped without EDG/QBE (part 1) or python3 and an interpreter.
#   MRB (an existing mruby executable)   QBE_PREP_CORPUS=<dir> (also compare the captures in <dir>, as written by
#   the tap, e.g. from a tests/realworld/run_mruby.sh run with MRB=tests/mruby/qbe-prep-tap.sh)
cd "$(dirname "$0")/../.."
root=$PWD; oracle=$root/tests/mruby/oracle/qbe-prep.py
real=${MRB:-$root/build/mruby-tool/bin/mruby}
prep=$root/scripts/qbe-prep.rb
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; pass=0; total=0; changed=0; errors=0
mkdir -p "$tmp/cmp" "$tmp/edge" "$tmp/tap" "$tmp/bin"; : >"$tmp/all.out"; : >"$tmp/all.tail"

command -v python3 >/dev/null || { echo "SKIP qbe-prep: python3 not installed"; exit 0; }
if [ ! -x "$real" ]; then
  command -v ruby >/dev/null || { echo "SKIP qbe-prep: ruby (needed to build mruby) not installed"; exit 0; }
  "$root/scripts/setup-mruby.sh" || { echo "FAIL qbe-prep: setup-mruby.sh failed"; exit 1; }
fi
mrb() { MRB=$real "$root/scripts/mrb" "$@"; }

# cmp_one NAME SRC FLAG [status-only]: run both versions on SRC (FLAG "c": hand-written C input) and compare.
# "status-only": the Python original dies with a traceback (an uncaught exception), so only the exit status
# (and the absence of output files) is compared.
cmp_one() {
  local name=$1 src=$2 flag=$3 mode=${4:-exact} d
  d=$tmp/cmp/$name; mkdir -p "$d"; rm -f "$d"/*
  if [ -n "$flag" ]; then
    NFCXX_C_INPUT=1 python3 -I "$oracle" "$src" "$d/py.out" "$d/py.tail" 2>"$d/py.err"; local prc=$?
    mrb "$prep" --c-input "$src" "$d/rb.out" "$d/rb.tail" 2>"$d/rb.err"; local rrc=$?
  else
    env -u NFCXX_C_INPUT python3 -I "$oracle" "$src" "$d/py.out" "$d/py.tail" 2>"$d/py.err"; local prc=$?
    mrb "$prep" "$src" "$d/rb.out" "$d/rb.tail" 2>"$d/rb.err"; local rrc=$?
  fi
  total=$((total + 1))
  local why=""
  [ $prc -eq $rrc ] || why="exit status py=$prc rb=$rrc"
  if [ -z "$why" ] && [ "$mode" != status-only ] && ! cmp -s "$d/py.err" "$d/rb.err"; then why="stderr differs"; fi
  if [ -z "$why" ]; then
    for f in out tail; do
      if [ -e "$d/py.$f" ] && [ ! -e "$d/rb.$f" ] || [ ! -e "$d/py.$f" ] && [ -e "$d/rb.$f" ]; then why="only one wrote $f"
      elif [ -e "$d/py.$f" ] && ! cmp -s "$d/py.$f" "$d/rb.$f"; then why="$f differs"; fi
    done
  fi
  if [ -n "$why" ]; then
    echo "FAIL qbe-prep $name: $why"; fail=1
    diff "$d/py.out" "$d/rb.out" 2>&1 | head -5; diff "$d/py.tail" "$d/rb.tail" 2>&1 | head -3
    diff "$d/py.err" "$d/rb.err" 2>&1 | head -3
    return
  fi
  pass=$((pass + 1))
  if [ $prc -ne 0 ]; then errors=$((errors + 1))
  else
    cmp -s "$src" "$d/py.out" || changed=$((changed + 1))
    cat "$d/py.out" >>"$tmp/all.out"; cat "$d/py.tail" >>"$tmp/all.tail"
  fi
}

# expect NAME out|tail TEXT: the Python output of case NAME contains TEXT (the rewrite really happened).
expect() {
  if ! grep -qF -e "$3" "$tmp/cmp/$1/py.$2"; then echo "FAIL qbe-prep $1: expected '$3' in the $2"; fail=1; fi
}
# refuse NAME STATUS-TEXT: the case ended with a nonzero status and the message contains TEXT.
refuse() {
  if ! grep -qF -e "$2" "$tmp/cmp/$1/py.err" || [ -e "$tmp/cmp/$1/py.out" ]; then
    echo "FAIL qbe-prep $1: expected a refusal containing '$2'"; fail=1; fi
}
# both NAME [status-only]: compare an edge file in the plain and the C-input mode
both() { cmp_one "$1" "$tmp/edge/$1.c" "" "${2:-exact}"; cmp_one "$1+c" "$tmp/edge/$1.c" c "${2:-exact}"; }

# ---- 2. edge cases -----------------------------------------------------------------------------------
cat >"$tmp/edge/aligned.c" <<'EOF'
typedef struct { char b[40]; } big;
static char buf[40] __attribute__((__aligned__(16)));
double m[2][3] __attribute__((aligned(32)));
struct S1 { char b[32]; } __attribute__((__aligned__(16)));
struct S2 { char b[30]; } __attribute__((__aligned__(16)));
struct S3 { int b[8]; } __attribute__((__aligned__(16)));
struct S4 { char b[0x20]; } __attribute__((__aligned__(0x10)));
struct S5 { char b[32]; } __attribute__((__aligned__(8))) s5v;
int plain[4];
char *ptrs[3] , other[2] __attribute__((__aligned__(4)));
int tricky(int a[4] __attribute__((__aligned__(8))));
EOF
both aligned
expect aligned out 'buf __attribute__((__aligned__(16)))[40]'
expect aligned out '_Alignas(16) char b[32];'
expect aligned out '_Alignas(16) char b[0x20];'
expect aligned out 'm __attribute__((__aligned__(32)))[2][3]'
cat >"$tmp/edge/floats.c" <<'EOF'
__bf16 b1; _Float16 h1; _Float32 f1; _Float64 d1; _Float128 q1; _Float32x f2; unsigned _Float64x u;
_Float16 h2 = (1.5f16), h3 = (.5f16), h4 = (65504.0f16), h5 = (6.103515625e-5f16), h6 = (2049f16), h7 = (0f16),
  h8 = (0.0f16), h9 = (1e-2f16), h10 = (65519.99f16), h11 = ( 3.14159265358979f16 ), h12 = (1.0009765625f16),
  h13 = (1.00048828125f16), h14 = (1.00146484375f16), h15 = (1.e1f16), h16 = (2.5E+3f16), h17 = (0.1f16);
_Float128 q2 = (3.14159265358979323846264338327950288f128), q3 = (1f128), q4 = (1e4000f128), q5 = (0.1f128),
  q6 = (1.18973149535723176508575932662800702e4932f128), q7 = (2.2250738585072014e-308f128), q8 = (1e-4900f128),
  q9 = (0f128), q10 = (1.00000000000000000000000000000000009629f128), q11 = (6.8e-4932f128);
float x1 = 1.5f32; double x2 = 2.5f64; float x3 = 1e10f32; double x4 = .25e-3f64; _Float32 y = 2f32;
float x5 = 1e+5f32, x6 = 3.f32; double x7 = 1.e5f64, x8 = .5f32; const _Float16 *hp; _Float16 f(_Float16 a, __bf16 b);
EOF
both floats
expect floats out '{ 0x3e00 }'
expect floats out 'struct __nfcxx_float128 q2 = { { 0x'
expect floats out 'float x1 = 1.5f;'
expect floats out 'double x2 = 2.5;'
expect floats out 'float x5 = 1e+5f,'
expect floats out 'x6 = 3.f;'
cat >"$tmp/edge/f16_nonparen.c" <<'EOF'
_Float16 x = 1.5f16;
EOF
both f16_nonparen; refuse f16_nonparen 'qbe-prep: float literal 1.5f16 is not in a supported form'
cat >"$tmp/edge/f128_nonparen.c" <<'EOF'
_Float128 x = (1.5f128 + 1);
_Float128 y = (2.5f128 ) + 1.5f128;
EOF
both f128_nonparen; refuse f128_nonparen 'is not in a supported form'
cat >"$tmp/edge/f16_subnormal.c" <<'EOF'
_Float16 x = (1e-6f16);
EOF
both f16_subnormal; refuse f16_subnormal 'is out of range for this format'
cat >"$tmp/edge/f16_overflow.c" <<'EOF'
_Float16 x = (65520f16);
EOF
both f16_overflow; refuse f16_overflow 'out of range'
cat >"$tmp/edge/f128_overflow.c" <<'EOF'
_Float128 x = (1e5000f128);
EOF
both f128_overflow; refuse f128_overflow 'out of range'
cat >"$tmp/edge/f128_subnormal.c" <<'EOF'
_Float128 x = (1e-5000f128);
EOF
both f128_subnormal; refuse f128_subnormal 'out of range'
cat >"$tmp/edge/f16_garbage.c" <<'EOF'
_Float16 x = (1.2.3f16);
EOF
both f16_garbage status-only
cat >"$tmp/edge/ctors.c" <<'EOF'
static void __sti_a(void) __attribute__((__constructor__));
void __sti_b ( int x , int (*f)(void) ) __attribute__((__constructor__));
static void __sti_a(void) __attribute__((__constructor__));
void ctor_prio(void) __attribute__((__constructor__(101)));
void ctor_conj(void) __attribute__((__weak__, __constructor__));
void __sti_a(void) { }
__attribute__((__constructor__)) void ctor_prefix(void);
__attribute__((__weak__)) int _ZTWx(void) { return 0; }
int _ZTWy(void);
__attribute__((__weak__, __visibility__("hidden"))) extern int _ZTWw(void);
__asm__(".globl _ZTHx");
__asm__("_ZTHx = __tls_init");
__asm__(" .global  _ZTHy ");
__asm__("_ZTHw\t=\t__tls_w\n");
__asm__("_ZTHz=foo");
__asm__(".glob" "l  split_name");
__asm__(".globl a.b$c");
__asm__("\056globl esc_name");
__asm__(".align 2");
__asm__("\t.align\t4\n");
__asm__(".align" " 8");
void f(void) { __asm__(".align 4"); __asm__("nop"); __asm__ ("movl %0, %0" : "=r"(x)); __asm("int $3" : :); }
void g(void) {
  __asm__ volatile("int $3\n" : :);
  if (1) __asm__ volatile ("int $3" : :);
  __asm__ __volatile__("int $3\n" : :);
  __asm__ volatile("int $3\n" : : : "memory");
  __asm__ volatile("int $3\n" : "=r"(x) :);
  { __asm__("int $3\n" : :); }
  int z = (__asm__ ("x"), 1);
}
EOF
both ctors
expect ctors out '__nfcxx_int3();'
expect ctors tail '.init_array'
expect ctors tail '.quad __sti_a'
expect ctors tail '.quad __sti_b'
expect ctors tail '.set _ZTHx, __tls_init'
expect ctors tail '.weak _ZTHx'
expect ctors tail '.weak _ZTHw'
expect ctors tail '.globl _ZTHy'
expect ctors tail '.globl split_name'
expect ctors tail '.globl a.b$c'
expect ctors tail '.globl esc_name'
expect ctors tail '.set _ZTHz, foo'
expect ctors tail '__nfcxx_int3,@function'
cat >"$tmp/edge/asm_unsupported.c" <<'EOF'
int x;
__asm__("movl $1, %eax");
EOF
both asm_unsupported; refuse asm_unsupported 'qbe-prep: unsupported top-level asm "movl $1, %eax"'
cat >"$tmp/edge/asm_unsupported2.c" <<'EOF'
__asm__(".globl ");
EOF
both asm_unsupported2; refuse asm_unsupported2 'unsupported top-level asm'
cat >"$tmp/edge/ctor_noname.c" <<'EOF'
(void) __attribute__((__constructor__));
EOF
both ctor_noname; refuse ctor_noname 'cannot find the name of a constructor declaration'
cat >"$tmp/edge/overflow.c" <<'EOF'
int t(int a, long b, unsigned long c, char d, short e, long long ll, float f) {
  int r1; long r2; unsigned long r3; unsigned long long r4; char r5; short r6; long long r7; unsigned r8; float fr;
  unsigned long x = 5, y;
  __builtin_mul_overflow(x, 10UL, &x);
  __builtin_mul_overflow(x, 10ul, (&x));
  __builtin_mul_overflow(x, 10lu, &x);
  __builtin_mul_overflow(x, 10UL, &y);
  __builtin_mul_overflow(x, 10, &x);
  __builtin_mul_overflow(x, 0x10UL, &x);
  __builtin_mul_overflow(x, 10ULL, &x);
  __builtin_mul_overflow(x, 10UL, (&y));
  __builtin_add_overflow(a, 1, &r1);
  __builtin_sub_overflow(b, c, &r2);
  __builtin_add_overflow(c, c, &r3);
  __builtin_mul_overflow(ll, ll, &r7);
  __builtin_mul_overflow(a, a, &r8);
  __builtin_add_overflow(d, e, &r5);
  __builtin_sub_overflow((a + 1), foo(a, b), &r6);
  __builtin_add_overflow(f, 1, &fr);
  __builtin_add_overflow(a, b, (int *)(&r1));
  __builtin_mul_overflow(b[1], (c, 2), &arr[a < b ? 1 : 2]);
  __builtin_mul_overflow(1, 2, &r4);
  void *p = __builtin_add_overflow; p = __builtin_mul_overflow;
  return __builtin_add_overflow(a, 2, &r1) ? __builtin_sub_overflow(a, 2, &r1) : 0;
}
EOF
both overflow
expect overflow out '__nfcxx_mulov_ul(x, 10UL, &x)'
expect overflow out '__nfcxx_mulov_ul(x, 10ul, (&x))'
expect overflow out '__nfcxx_mulov_ul(x, 10lu, &x)'
expect overflow out 'static int __nfcxx_ovx_unsigned_long('
expect overflow out 'static int __nfcxx_addov_i('
expect overflow out 'static int __nfcxx_mulov_ull('
expect overflow out 'int __nfcxx_overflow_unsupported_operand_types(long long, ...);'
cat >"$tmp/edge/overflow_args.c" <<'EOF'
int t(int a, int b) { int r; return __builtin_add_overflow(a, b); }
EOF
both overflow_args; refuse overflow_args '__builtin_add_overflow expects three arguments'
cat >"$tmp/edge/overflow_args2.c" <<'EOF'
int t(int a, int b) { int r; return __builtin_sub_overflow(a, b, &r, 1); }
EOF
both overflow_args2; refuse overflow_args2 'expects three arguments'
cat >"$tmp/edge/builtins.c" <<'EOF'
void f(char *a, char *b, unsigned long n, double x, unsigned long u, unsigned v, unsigned long long w) {
  __builtin_memcpy(a, b, n); __builtin_memmove(a, b, n); __builtin_memset(a, 0, n); __builtin_memcmp(a, b, n);
  __builtin_strlen(a); __builtin_isnan(x); __builtin_clzl(u); __builtin_clz(v); __builtin_clzll(w);
  __builtin_ctz(v); __builtin_ctzl(u); __builtin_ctzll(w); __builtin_popcount(v); __builtin_popcountl(u);
  __builtin_popcountll(w); __builtin_memcpy_chk(a, b, n); __builtin_clzl; __builtin_expect(n, 1);
}
EOF
both builtins
expect builtins out 'static int __nfcxx_popcountll('
expect builtins out 'static int __nfcxx_ctz('
expect builtins out 'void *memmove(void *, const void *, unsigned long);'
expect builtins out 'static int __nfcxx_clz('
cat >"$tmp/edge/atomics.c" <<'EOF'
void f(void *p, int *e) {
  __atomic_load_1(p, 5); __atomic_load_2(p, 5); __atomic_load_4(p, 5); __atomic_load_8(p, 5); __atomic_load_16(p, 5);
  __atomic_store_4(p, 1, 5); __atomic_exchange_8(p, 1, 5); __atomic_compare_exchange_4(p, e, 1, 0, 5, 5);
  __atomic_fetch_add_4(p, 1, 5); __atomic_fetch_sub_1(p, 1, 5); __atomic_fetch_and_2(p, 1, 5);
  __atomic_fetch_or_8(p, 1, 5); __atomic_fetch_xor_4(p, 1, 5); __atomic_fetch_nand_1(p, 1, 5);
  __atomic_add_fetch_4(p, 1, 5); __atomic_sub_fetch_8(p, 1, 5); __atomic_and_fetch_2(p, 1, 5);
  __atomic_or_fetch_1(p, 1, 5); __atomic_xor_fetch_4(p, 1, 5); __atomic_nand_fetch_8(p, 1, 5);
  __atomic_load(p, e, 5); __atomic_load_3(p, 5); __atomic_fetch_mul_4(p, 1, 5); __atomic_add_fetch(p, 1, 5);
  __atomic_exchange_n(p, 1, 5); __atomic_thread_fence(5); __atomic_fetch_add_41(p, 1, 5); __atomic_load_(p);
}
EOF
both atomics
expect atomics out 'unsigned char __atomic_load_1(const volatile void *, int);'
expect atomics out '_Bool __atomic_compare_exchange_4(volatile void *, void *, unsigned int, _Bool, int, int);'
expect atomics out 'unsigned long __atomic_nand_fetch_8(volatile void *, unsigned long, int);'
expect atomics out 'void __atomic_store_4(volatile void *, unsigned int, int);'
cat >"$tmp/edge/volatile.c" <<'EOF'
volatile int g1;
struct S { volatile int m; } s;
int f(volatile int *pp, volatile int arr[2]) {
  volatile int a = 1, b;
  int volatile c;
  volatile int *p1, q1;
  int * volatile p2, r2;
  volatile int * volatile p3;
  volatile int arr2[4];
  static volatile int st;
  extern volatile int ex;
  register volatile int rg;
  volatile int (*fp)(void);
  volatile int fn(void);
  typedef volatile int vt;
  for (volatile int i = 0; i < 3; i++) { volatile long inner = i; }
  if (a) { volatile char blk = 2; } else { volatile char blk2; }
  do { volatile short dd; } while (0);
  { volatile int nested; }
  while (a) volatile_helper();
  switch (a) { case 1: { volatile int in_case = 1; } }
  lbl: { volatile int after_label; }
  __asm__ volatile("nop");
  __asm__ __volatile__("" ::: "memory");
  volatile struct S ss;
  const volatile unsigned long long cv = 3, cw = 4;
  volatile int x = (volatile int)3, y = f2(1, 2);
  volatile int z = ({ volatile int inner2 = 1; inner2; });
  return a;
}
static int h(void) { volatile int one; return one; }
int k(void) { int v = 0; struct { volatile int q; } *w; volatile int late; return v; }
int broken(void) { volatile int open_no_semi
EOF
cmp_one volatile "$tmp/edge/volatile.c" ""
cmp_one volatile+c "$tmp/edge/volatile.c" c
expect volatile+c out '__nfcxx_keep(&a);'
expect volatile+c out '__nfcxx_keep(&c);'
expect volatile+c out '__nfcxx_keep(&p3);'
expect volatile+c out '__nfcxx_keep(&inner);'
expect volatile+c out '__nfcxx_keep(&blk2);'
expect volatile+c out '__nfcxx_keep(&nested);'
expect volatile+c out '__nfcxx_keep(&one);'
expect volatile+c out 'static void __nfcxx_keep(void *p) { }'
cat >"$tmp/edge/alloca.c" <<'EOF'
extern void *alloca (unsigned long);
void *alloca(unsigned long);
int f(unsigned long n) { char *p = alloca(n); char *q = (alloca (n + 1)); void *(*fp)(unsigned long) = alloca; return alloca(3) != 0; }
int g(void) { return *alloca(1) + malloca(2) + alloca_x(3); }
EOF
both alloca
expect alloca+c out 'char *p = __builtin_alloca(n);'
expect alloca+c out '(__builtin_alloca (n + 1))'
cat >"$tmp/edge/ldlits.c" <<'EOF'
double a = ((double)2.2250738585072014e-308L);
float b = ((float)1.5L);
long double c = ((long double)1.5L);
double d = 1.0L;
double e = (double)1L;
double f = (double)1e5L;
double g = (double).5L;
double h = (double)5.L;
double i = (double)0x1.8p1L;
double j = ( double ) 1.5l;
double k = (double)1.5e+10L;
double l = (float)1.5eL;
double m = (double)15L;
double n = (double)1.5LL;
double o = (double)1.5e-308l, p = (double)1.5L + 1.5L;
double q = (double)-1.5L;
double r = (double)1.7976931348623157e+308L;
EOF
both ldlits
expect ldlits+c out '((double)2.2250738585072014e-308)'
expect ldlits+c out 'double g = (double).5;'
expect ldlits+c out 'double h = (double)5.;'
expect ldlits+c out 'double e = (double)1L;'
cat >"$tmp/edge/floatn.c" <<'EOF'
typedef float _Float32;
typedef double _Float64;
typedef long double _Float64x;
typedef long double _Float128x;
typedef struct { int a; } _Float32;
typedef float _Float16;
typedef double (*fp)(void);
typedef __bf16 mybf;
typedef float _Float32, other_t;
typedef float
  _Float32
  ;
typedef float arr[3]; typedef unsigned _Float128 qq;
typedef long double _Float128;
EOF
both floatn
expect floatn out 'typedef struct { int a; } float;'
expect floatn out 'typedef float arr[3];'
cat >"$tmp/edge/tok_comment.c" <<'EOF'
int a = 1; /* unterminated __bf16 x;
_Float16 y;
EOF
both tok_comment
expect tok_comment out 'struct __nfcxx_half16 y;'
cat >"$tmp/edge/tok_strings.c" <<'EOF'
char *s = "esc \" quote __bf16"; char *t = u8"x_Float16"; wchar_t w = L'\''; char u = u'x'; int z = u8'q';
char *bad = "unterminated __bf16
char *c = 'unterminated __bf16
int uint8_t_ = 1; int u8 = 2; int L = 3; int U8 = 4; char *s2 = u"x"; char *s3 = U"y"; char *s4 = L"w\"";
char *cont = "line one\
 __bf16 inside"; char *t2 = "tail\\"; __bf16 after;
char *s5 = u8 "split"; char *s6 = "a" "b" __bf16; char c2 = '"'; char *s7 = "'"; _Float16 z2;
char *e = "end with backslash\
EOF
both tok_strings
expect tok_strings out 'struct __nfcxx_half16 after;'
expect tok_strings out 'esc \" quote __bf16'
cat >"$tmp/edge/tok_numbers.c" <<'EOF'
int n = 1e+5; double d = 0x1p-3; double e = .5; double f = ..5; int g = 1.2.3; double h = 1e+5f32;
double i = 0x1p-3f32; double j = 3.f32; double k = 1.e5f64; double l = .5f64; int m = 1_000; int o = 0b101;
double p = 1e+f32; double q = 1.5e-3f64 + 2.5E+3f32 + 0.5e5f64 + 00.5f32 + 5.f64;
double r = 1f32 - 1f64 + 12e3f32; double s = 0x1f32; double t = 1.5F; int u = 0xdeadbeefUL; double v = 1e5e5f32;
EOF
both tok_numbers
expect tok_numbers out 'double h = 1e+5f;'
expect tok_numbers out 'double l = .5;'
cat >"$tmp/edge/tok_dollar.c" <<'EOF'
int $ = 1; int $foo = 2; int a$b; __bf16$x; $ __bf16; __bf16 $; _Float16$$; x$_Float16;
EOF
both tok_dollar
cat >"$tmp/edge/tok_misc.c" <<'EOF'
int x = a/b; int y = a / *p; int z = a/**/b; int w = a/***/b; // c __bf16
int v = 1; //* not a block __bf16 q;
/* comment */ __bf16 u; /**/ __bf16 t; /*/ still comment */ __bf16 s;
int é = 1; char *str = "é __bf16"; /* ü __bf16 */ __bf16 eacute;
#define X(a) a ## b
int last = 2 /
EOF
both tok_misc
expect tok_misc out 'struct __nfcxx_half16 eacute;'
printf 'int a;\r\n__bf16 b;\r\nchar *s = "x\\\r\ny";\r\n// c\r\nint c;\rint d;\r' >"$tmp/edge/crlf.c"
both crlf
expect crlf out 'struct __nfcxx_half16 b;'
printf '' >"$tmp/edge/empty.c"; both empty
printf '  \n\t\n' >"$tmp/edge/blank.c"; both blank
printf 'int a; // no newline __bf16' >"$tmp/edge/eof_comment.c"; both eof_comment
printf 'int a = b /' >"$tmp/edge/eof_slash.c"; both eof_slash
printf '__bf16 x; "' >"$tmp/edge/eof_quote.c"; both eof_quote
printf '__bf16 x; u8' >"$tmp/edge/eof_prefix.c"; both eof_prefix
printf '__attribute__((__aligned__(16)))' >"$tmp/edge/eof_attr.c"; both eof_attr
printf 'int x[4] __attribute__((__aligned__(16' >"$tmp/edge/eof_attr2.c"; both eof_attr2
printf 'struct T { char b[16]; } __attribute__((__aligned__(8)))' >"$tmp/edge/eof_attr3.c"; both eof_attr3
printf '} __attribute__((__aligned__(8)));\nint x[2][' >"$tmp/edge/unbalanced.c"; both unbalanced
printf '__builtin_add_overflow(a, b, ' >"$tmp/edge/eof_call.c"; both eof_call; refuse eof_call 'expects three arguments'
printf 'int f(void) { __asm__("nop"' >"$tmp/edge/eof_asm.c"; both eof_asm
printf 'asm("int $3" : :);\n__asm__ volatile' >"$tmp/edge/eof_asm2.c"; both eof_asm2
printf 'struct T { char b[16]; } __attribute__((__aligned__(016)));\n' >"$tmp/edge/octal_align.c"; both octal_align status-only
printf 'struct T { char b[16]; } __attribute__((__aligned__(16U)));\n' >"$tmp/edge/suffix_align.c"; both suffix_align status-only
printf 'struct T { char b[16UL]; } __attribute__((__aligned__(16)));\nstruct U { char b[0x10]; } __attribute__((__aligned__(0b1000)));\nstruct V { char b[0]; } __attribute__((__aligned__(1_6)));\n' >"$tmp/edge/num_forms.c"; both num_forms status-only
printf 'struct T { char b[32]; } __attribute__((__aligned__(0x10)));\nstruct U { char b[0x20]; } __attribute__((__aligned__(0b1000)));\nstruct V { char b[0]; } __attribute__((__aligned__(0o20)));\nstruct W { char b[1_6]; } __attribute__((__aligned__(8)));\n' >"$tmp/edge/num_forms2.c"; both num_forms2

# ---- 1. inputs of real compiles ----------------------------------------------------------------------
corpus() { # corpus NAME COUNT-FILES  (compare every capture under $tmp/tap/NAME)
  local name=$1 want=$2 dir=$tmp/tap/$1 n=0 d before=$pass
  for d in "$dir"/in.*; do
    [ -e "$d/src.c" ] || continue
    cmp_one "$name.${d##*.}" "$d/src.c" "$(cat "$d/flag")"; n=$((n + 1))
  done
  if [ "$n" -lt "$want" ]; then echo "FAIL qbe-prep: corpus $name gave $n qbe-prep inputs, want at least $want"; fail=1
  elif [ $((pass - before)) -ne "$n" ]; then echo "FAIL qbe-prep: corpus $name: $((n - pass + before)) of $n inputs differ"
  else echo "ok   qbe-prep corpus $name: $n inputs identical (py vs rb)"; fi
}
tap_dir() { mkdir -p "$tmp/tap/$1"; export QBE_PREP_TAP=$tmp/tap/$1; }
jobs_max=$(nproc)
par() { while [ "$(jobs -r | wc -l)" -ge "$jobs_max" ]; do wait -n; done; "$@" & }
build() { "$@" >/dev/null 2>&1 || true; }   # the compile may fail (documented limits); qbe-prep ran first

if [ -x "$root/build/edg/bin/cpfe" ] && [ -x "$root/build/qbe/qbe" ] && [ -x "$root/build/cproc/cproc-qbe" ]; then
  export QBE_PREP_REAL_MRB=$real MRB=$root/tests/mruby/qbe-prep-tap.sh NFCXX_BACKEND=qbe
  tap_dir cases; n=0
  for f in "$root"/tests/cases/*.cpp; do par build "$root/nfcxx" "$f" -o "$tmp/bin/case$n"; n=$((n + 1)); done; wait
  corpus cases "$n"
  tap_dir builtins; n=0
  for f in "$root"/tests/builtins/*.cpp; do
    dialect=$(sed -n 's,^// DIALECT: *\(.*\),\1,p' "$f" | head -1)
    par build "$root/nfcxx" --gnu-version=130000 ${dialect:+--dialect=$dialect} "$f" -o "$tmp/bin/b$n"; n=$((n + 1))
  done; wait
  corpus builtins "$n"
  tap_dir lib; n=0
  for f in "$root"/tests/lib/*.cpp; do par build "$root/nfcxx" --freestanding "$f" -o "$tmp/bin/l$n"; n=$((n + 1)); done; wait
  corpus lib "$n"
  tap_dir c; n=0; nc=0
  for f in "$root"/tests/c/*.c "$root"/tests/c/*.cpp; do
    srcs=$(sed -n 's|^// SOURCES: *||p' "$f" | head -1); [ -n "$srcs" ] || srcs=$(basename "$f")
    files=(); for s in $srcs; do files+=("$root/tests/c/$s"); done
    par build "$root/nfcxx" -I"$root/tests/c" "${files[@]}" -o "$tmp/bin/c$n"; n=$((n + 1))
    case $f in *.c) nc=$((nc + 1)) ;; esac
  done; wait
  corpus c "$nc"
  rw=$root/build/realworld
  if [ -f "$rw/tinyxml2/tinyxml2.cpp" ]; then
    tap_dir tinyxml2
    build "$root/nfcxx" -I"$rw/tinyxml2" "$root/tests/realworld/tinyxml2_main.cpp" "$rw/tinyxml2/tinyxml2.cpp" -o "$tmp/bin/tx"
    corpus tinyxml2 2
  else echo "skip qbe-prep tinyxml2: build/realworld/tinyxml2 not cached (tests/realworld/run.sh)"; fi
  if [ -f "$rw/doctest/doctest/doctest.h" ]; then
    tap_dir doctest
    build "$root/nfcxx" -I"$rw/doctest" "$root/tests/realworld/doctest_main.cpp" -o "$tmp/bin/dt"
    corpus doctest 1
  else echo "skip qbe-prep doctest: build/realworld/doctest not cached (tests/realworld/run_doctest.sh)"; fi
  if [ -f "$rw/lua/lapi.c" ]; then
    tap_dir lua; srcs=()
    for f in "$rw"/lua/*.c; do
      case $(basename "$f") in luac.c|ltests.c|onelua.c) ;; *) srcs+=("$f") ;; esac
    done
    build "$root/nfcxx" "${srcs[@]}" -lm -o "$tmp/bin/lua"
    corpus lua "${#srcs[@]}"
  else echo "skip qbe-prep lua: build/realworld/lua not cached (tests/realworld/run_lua.sh)"; fi
  if [ -n "${QBE_PREP_CORPUS:-}" ] && [ -d "$QBE_PREP_CORPUS" ]; then
    mkdir -p "$tmp/tap"; ln -s "$(cd "$QBE_PREP_CORPUS" && pwd)" "$tmp/tap/extra"; corpus extra 1
  fi
  unset MRB QBE_PREP_REAL_MRB QBE_PREP_TAP NFCXX_BACKEND
else
  echo "skip qbe-prep corpus: needs EDG and QBE (scripts/setup-edg.sh, scripts/setup-qbe.sh); only the edge cases ran"
fi

# ---- non-vacuity ----------------------------------------------------------------------------------------
if [ $changed -eq 0 ] || [ $total -lt 60 ]; then
  echo "FAIL qbe-prep: vacuous comparison ($total inputs, $changed rewritten)"; fail=1
fi
if [ $errors -lt 8 ]; then echo "FAIL qbe-prep: only $errors refusal cases compared"; fail=1; fi
for m in 'struct __nfcxx_half16 {' 'struct __nfcxx_float128 {' '{ 0x' 'UL, 0x' '_Alignas(' '__attribute__((__aligned__(' \
         '__nfcxx_int3();' '__nfcxx_mulov_ul(' '__nfcxx_ovx_' '__nfcxx_addov_' '__nfcxx_popcount' '__builtin_alloca(' \
         '__nfcxx_keep(&' 'unsigned long __atomic_fetch_add_' 'memcpy(void *' '__nfcxx_isnan' '1.5f;'; do
  grep -qF -e "$m" "$tmp/all.out" || { echo "FAIL qbe-prep: no input produced '$m'"; fail=1; }
done
for m in '.init_array' '.set ' '.globl ' '.weak _ZTH' '__nfcxx_int3,@function' '.quad '; do
  grep -qF -e "$m" "$tmp/all.tail" || { echo "FAIL qbe-prep: no tail contained '$m'"; fail=1; }
done
echo "tests/mruby qbe-prep: $pass of $total inputs identical ($changed rewritten, $errors refusals compared)"
[ $fail -eq 0 ]
