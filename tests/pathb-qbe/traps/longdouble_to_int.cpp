// Long double to int: a value outside the int range must abort, as for float and double (cf2i); the helper of
// be/nfcxx_ldrt.c checks the truncated value against the width of the target type.
__attribute__((noinline)) long double id(long double x) { return x; }
__attribute__((noinline)) int conv(long double x) { return (int)x; }
int main() {
  int ok = conv(id(-2147483648.9L));   // truncates to INT_MIN: fits
  if (ok != -2147483647 - 1) return 1;
  return conv(id(2147483648.0L));
}
