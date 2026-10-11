// EXPECT: 101
// A comparison returned or added as an integer (a bool-to-int conversion) and a double comparison. These lowered to
// (unsupported cast) in older builds of be/nfcxx_ir.c.
int neg(int x) { return x < 0; }
int main() {
  int r = neg(-5) + neg(3) * 10;
  r += (-2.5 < 0.0) ? 100 : 0;
  return r;
}
