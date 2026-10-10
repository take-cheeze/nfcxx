// The IR of long double (docs/notes/pathb-longdouble.md): a 16-byte object (array 16 unsigned_char), helper calls for
// every operation, byval arguments with the module-level (abi-type "__nfcxx_ld"), a result pointer for a function
// returning one, call thunks (x87-thunk call) for libc and libm, an entry thunk for the function defined here, a static
// initializer in two 64-bit items. No headers: the golden tests/pathb-ir/longdouble_ir.ir stays small.
// EXPECT: 7
extern "C" {
long double strtold(const char*, char**);
long double sqrtl(long double);
int printf(const char*, ...);
}

long double g = 1.5L;
long double arr[2] = {0.25L, -2.0L};
struct S { int n; long double x; };
S gs = {3, 2.5L};

long double scale(long double x, int k) {
  long double r = x * k + 1.0L;
  if (r > 100.0L) r -= x;
  return r++;
}

int main() {
  long double a = strtold("2.25", 0);
  long double b = sqrtl(a) + scale(g, 3) - arr[1];
  bool lt = a < b, nz = (bool)a;
  int i = (int)b;
  double d = (double)b;
  long double c = i;
  c = lt ? c : -c;
  printf("%Lf %d\n", c + gs.x, nz);
  return i + (int)(d - d) + (c > 0.0L) + (int)gs.n - 3 * 2 - 1 + (int)(arr[0] * 4);
}
