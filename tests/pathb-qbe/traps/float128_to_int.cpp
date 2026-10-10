// _Float128 to an integer: a value whose truncation does not fit the target type must abort, as for float and double
// (the cf2i rule); the helper __nfcxx_f128_to_s of be/nfcxx_ldrt.c checks the bounds. The first conversion fits and
// the second does not (2^31 is the first value above the int range).
__attribute__((noinline)) __float128 id(__float128 x) { return x; }
__attribute__((noinline)) int conv(__float128 x) { return (int)x; }
int main() {
  int ok = conv(id((__float128)-2147483648.9));   // truncates to INT_MIN: fits
  if (ok != -2147483647 - 1) return 1;
  return conv(id((__float128)2147483648.0));
}
