/* EXPECT: 0 */
/* A block with more than 63 predecessors and a phi: QBE reads at most 63 phi arguments, so the Path B emitter merges them in
   groups (pathb-ssa-qbe.rb, split_wide_phis). 70 switch arms each set two variables and goto the one join. */
#include <stdio.h>

static int join(int n, int k)
{
  int x = k, y = 1000;
  switch (n) {
  case 0: x += 1 * k; y -= 0; goto done;
  case 1: x += 2 * k; y -= 1; goto done;
  case 2: x += 3 * k; y -= 2; goto done;
  case 3: x += 4 * k; y -= 3; goto done;
  case 4: x += 5 * k; y -= 4; goto done;
  case 5: x += 6 * k; y -= 5; goto done;
  case 6: x += 7 * k; y -= 6; goto done;
  case 7: x += 8 * k; y -= 7; goto done;
  case 8: x += 9 * k; y -= 8; goto done;
  case 9: x += 10 * k; y -= 9; goto done;
  case 10: x += 11 * k; y -= 10; goto done;
  case 11: x += 12 * k; y -= 11; goto done;
  case 12: x += 13 * k; y -= 12; goto done;
  case 13: x += 14 * k; y -= 13; goto done;
  case 14: x += 15 * k; y -= 14; goto done;
  case 15: x += 16 * k; y -= 15; goto done;
  case 16: x += 17 * k; y -= 16; goto done;
  case 17: x += 18 * k; y -= 17; goto done;
  case 18: x += 19 * k; y -= 18; goto done;
  case 19: x += 20 * k; y -= 19; goto done;
  case 20: x += 21 * k; y -= 20; goto done;
  case 21: x += 22 * k; y -= 21; goto done;
  case 22: x += 23 * k; y -= 22; goto done;
  case 23: x += 24 * k; y -= 23; goto done;
  case 24: x += 25 * k; y -= 24; goto done;
  case 25: x += 26 * k; y -= 25; goto done;
  case 26: x += 27 * k; y -= 26; goto done;
  case 27: x += 28 * k; y -= 27; goto done;
  case 28: x += 29 * k; y -= 28; goto done;
  case 29: x += 30 * k; y -= 29; goto done;
  case 30: x += 31 * k; y -= 30; goto done;
  case 31: x += 32 * k; y -= 31; goto done;
  case 32: x += 33 * k; y -= 32; goto done;
  case 33: x += 34 * k; y -= 33; goto done;
  case 34: x += 35 * k; y -= 34; goto done;
  case 35: x += 36 * k; y -= 35; goto done;
  case 36: x += 37 * k; y -= 36; goto done;
  case 37: x += 38 * k; y -= 37; goto done;
  case 38: x += 39 * k; y -= 38; goto done;
  case 39: x += 40 * k; y -= 39; goto done;
  case 40: x += 41 * k; y -= 40; goto done;
  case 41: x += 42 * k; y -= 41; goto done;
  case 42: x += 43 * k; y -= 42; goto done;
  case 43: x += 44 * k; y -= 43; goto done;
  case 44: x += 45 * k; y -= 44; goto done;
  case 45: x += 46 * k; y -= 45; goto done;
  case 46: x += 47 * k; y -= 46; goto done;
  case 47: x += 48 * k; y -= 47; goto done;
  case 48: x += 49 * k; y -= 48; goto done;
  case 49: x += 50 * k; y -= 49; goto done;
  case 50: x += 51 * k; y -= 50; goto done;
  case 51: x += 52 * k; y -= 51; goto done;
  case 52: x += 53 * k; y -= 52; goto done;
  case 53: x += 54 * k; y -= 53; goto done;
  case 54: x += 55 * k; y -= 54; goto done;
  case 55: x += 56 * k; y -= 55; goto done;
  case 56: x += 57 * k; y -= 56; goto done;
  case 57: x += 58 * k; y -= 57; goto done;
  case 58: x += 59 * k; y -= 58; goto done;
  case 59: x += 60 * k; y -= 59; goto done;
  case 60: x += 61 * k; y -= 60; goto done;
  case 61: x += 62 * k; y -= 61; goto done;
  case 62: x += 63 * k; y -= 62; goto done;
  case 63: x += 64 * k; y -= 63; goto done;
  case 64: x += 65 * k; y -= 64; goto done;
  case 65: x += 66 * k; y -= 65; goto done;
  case 66: x += 67 * k; y -= 66; goto done;
  case 67: x += 68 * k; y -= 67; goto done;
  case 68: x += 69 * k; y -= 68; goto done;
  case 69: x += 70 * k; y -= 69; goto done;
  default: x = -1; y = -1;
  }
done:
  return x * 3 + y;
}

int main(void)
{
  int bad = 0, n;
  for (n = -1; n <= 70; n++) {
    int k = n + 5;
    int want = n < 0 || n >= 70 ? -1 * 3 + -1 : (k + (n + 1) * k) * 3 + (1000 - n);
    if (join(n, k) != want) { printf("join(%d)=%d want %d\n", n, join(n, k), want); bad = 1; }
  }
  return bad;
}
