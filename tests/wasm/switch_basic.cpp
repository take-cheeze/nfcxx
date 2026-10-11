// EXPECT: 143
// A switch with several cases, a default, a case that falls into a label with no statements, and a break.
int f(int x) {
  switch (x) {
    case 1: return 10;
    case 2:
    case 3: x = x * 10; break;
    case 40: return 40;
    default: return 99;
  }
  return x + 100;
}
int main() {
  int r = f(1) + f(2) + f(3) + f(40) + f(7);   // 10 + 120 + 130 + 40 + 99 = 399, & 255 = 143
  return r & 255;
}
