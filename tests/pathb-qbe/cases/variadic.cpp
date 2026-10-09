// EXPECT: 0
// Variadic calls: float and double arguments go in vector registers, so the call must be marked variadic
// (QBE then sets %al for the callee's register-save prologue). snprintf/sprintf into a buffer, then compare.
// The exit code is the number of wrong results.
extern "C" int snprintf(char *, unsigned long, const char *, ...);
extern "C" int sprintf(char *, const char *, ...);
extern "C" int strcmp(const char *, const char *);
__attribute__((noinline)) int mixed(char *buf, unsigned long n, int a, double x, long b, float y, const char *s, double z) {
  return snprintf(buf, n, "%d %.2f %ld %.1f %s %.3f", a, x, b, y, s, z);
}
int main() {
  char buf[128];
  int bad = 0;
  snprintf(buf, sizeof buf, "%f", 1.5);
  if (strcmp(buf, "1.500000") != 0) bad++;
  snprintf(buf, sizeof buf, "%d", 42);
  if (strcmp(buf, "42") != 0) bad++;
  mixed(buf, sizeof buf, 7, 2.25, 100000000000L, 0.5f, "str", -3.125);
  if (strcmp(buf, "7 2.25 100000000000 0.5 str -3.125") != 0) bad++;
  // More than eight double arguments: the rest go on the stack.
  sprintf(buf, "%.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f", 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0);
  if (strcmp(buf, "1 2 3 4 5 6 7 8 9 10") != 0) bad++;
  // No float arguments: still must work.
  sprintf(buf, "%d-%d-%d-%d-%d-%d-%d", 1, 2, 3, 4, 5, 6, 7);
  if (strcmp(buf, "1-2-3-4-5-6-7") != 0) bad++;
  return bad;
}
