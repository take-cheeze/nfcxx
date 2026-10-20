// EXPECT: 89
// Branches, loops with break and continue, switch with fallthrough and default, and the conditional operator.
static int classify(int v) {
  switch (v) {
    case 0: return 1;
    case 1:
    case 2: return 2;
    case 7: return 7;
    default: return 0;
  }
}
int main(void) {
  int total = 0;
  for (int i = 0; i < 20; i++) {
    if (i % 3 == 0) continue;
    if (i > 14) break;
    total += i;                          /* 1+2+4+5+7+8+10+11+13+14 = 75 */
  }
  int n = 0;
  while (n < 5) n++;
  do { n += 2; } while (n < 9);          /* n = 9 */
  total += classify(0) + classify(2) + classify(7) + classify(9);   /* 1 + 2 + 7 + 0 */
  return (total % 256) + (n > 10 ? 3 : 4);   /* 85 + 4 */
}
