// EXPECT: 0
// `int + pointer` with the integer first, on a cast address of a static const struct (Onigmo's gperf table: `o + uniname2ctype_pool`).
// EDG's padd keeps the operands in source order; Path B's IR put the integer as the base of the index ("invalid type for first operand").
struct P { char a[4]; char b[4]; };
static const struct P pool = { "abc", "def" };
#define poolp ((const char *) &pool)
const char *f(int o) { return o + poolp; }
const char *g(int o) { return poolp + o; }
const char *h(long o, const int *base) { return (const char *)(o + base); }
int main(void) {
  int v[4] = { 1, 2, 3, 4 };
  return *f(4) == 'd' && *g(1) == 'b' && *f(0) == 'a' && *(const int *)h(2, v) == 3 ? 0 : 1;
}
