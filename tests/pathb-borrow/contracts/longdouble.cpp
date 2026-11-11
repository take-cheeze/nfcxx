// long double and __int128 operations are calls of the runtime helpers, described
// by scripts/pathb-runtime.effects (--effects).
int main() {
  long double a = 2.0L, b = 3.0L;
  long double c = a * b + a;
  __int128 x = 5;
  __int128 y = -x;
  return (c == 8.0L) + (y < 0) - 2;
}
