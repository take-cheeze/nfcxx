// EXPECT: 105
// Nested switches on a long selector, a default in the middle of the arms, an arm that ends in return with no break,
// a break inside a loop inside an arm (it leaves that loop only), and an empty switch.
long classify(long v, int k) {
  switch (v) {
    case 1:
      switch (k) {
        case 0: return 100;
        case 1: k = 9; return 1000 + k;
        default: return 1000 + k;
      }
      break;
    default:
      for (int i = 0; i < 10; i++) {
        if (i == k) break;
        v += 2;
      }
      break;
    case 2: v = v * 3; break;
    case -4: return 50;
  }
  return v;
}
int main() {
  int total = 0;
  switch (3) {
  }
  total += classify(1, 0) - 100;           // 0
  total += classify(1, 1) - 1009;          // 0
  total += classify(2, 0) - 6;             // 0
  total += classify(-4, 0) - 50;           // 0
  total += classify(5, 4);                 // 5 + 8 = 13
  total += classify(6, 0) - 6;             // 0 (the loop breaks at once)
  return total + 92;                       // 13 + 92 = 105
}
