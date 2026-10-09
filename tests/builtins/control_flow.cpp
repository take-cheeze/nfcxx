// EXPECT: 0
// __builtin_unreachable and __builtin_expect (the unreachable branch is never executed).
static int pick(int x) {
  switch (x & 3) {
    case 0: return 10;
    case 1: return 20;
    case 2: return 30;
    case 3: return 40;
  }
  __builtin_unreachable();
}

static int checked(int x) {
  if (__builtin_expect(x > 100, 0)) return -1;
  return x * 2;
}

int main() {
  int fails = 0;
  fails += pick(0) != 10;
  fails += pick(1) != 20;
  fails += pick(6) != 30;
  fails += pick(7) != 40;
  fails += checked(5) != 10;
  fails += checked(500) != -1;
  fails += __builtin_expect(3, 3) != 3;
  return fails;
}
