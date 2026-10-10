// EXPECT: 0
// __builtin_isfinite / __builtin_signbit on runtime values (cproc has no such builtin: scripts/qbe-prep.rb supplies a helper).
__attribute__((noinline)) static double id(double x) { return x; }
int main() {
  int bad = 0;
  double inf = id(1.0) / id(0.0), nan = id(0.0) / id(0.0);
  if (__builtin_isfinite(id(inf))) bad++;
  if (__builtin_isfinite(id(-inf))) bad++;
  if (__builtin_isfinite(id(nan))) bad++;
  if (!__builtin_isfinite(id(1.5))) bad++;
  if (!__builtin_isfinite(id(-0.0))) bad++;
  if (!__builtin_signbit(id(-0.0))) bad++;
  if (__builtin_signbit(id(2.0))) bad++;
  return bad;
}
