// EXPECT: 0
// STDOUT: same
// switch lowered with bit tests (GCC's bit_test_cluster): case values in a window under 32 that go to at most three targets,
// several case labels per target, with gaps; and a bit-test group inside a larger tree.
#include <cstdio>
#include <initializer_list>

static int vowel(char c) {
  switch (c) {
    case 'a': case 'e': case 'i': case 'o': case 'u':
      return 1;
    case 'y':
      return 2;
    default:
      return 0;
  }
}

static int two_targets(int x) {
  switch (x) {
    case 3: case 5: case 6: case 9: case 10:
      return 10;
    case 4: case 7: case 8:
      return 20;
    case 40:
      return 30;
    default:
      return 0;
  }
}

static int three_targets(unsigned x) {
  switch (x) {
    case 0: case 2: case 4: case 6: case 8:
      return 1;
    case 1: case 3: case 5: case 7:
      return 2;
    case 11: case 13: case 15: case 17: case 19: case 21:
      return 3;
    case 100:
      return 4;
    default:
      return 0;
  }
}

static int in_tree(int x) {
  switch (x) {
    case -50: return 1;
    case 0: case 1: case 3: return 2;
    case 20: return 3;
    case 21: case 23: case 24: return 4;
    case 30: return 5;
    case 90: return 6;
    case 91: return 7;
    default: return 0;
  }
}

static int fall_bits(int x) {
  int r = 0;
  switch (x) {
    case 0: r += 1;
    case 2: r += 10; break;
    case 1: case 3: case 5: r += 100; break;
    case 4: r += 1000;
    default: r += 5;
  }
  return r;
}

int main() {
  for (char c = 'A'; c <= 'z'; c++) if (vowel(c)) std::printf("vowel %c %d\n", c, vowel(c));
  for (int x = -1; x <= 42; x++) std::printf("two %d %d\n", x, two_targets(x));
  for (unsigned x = 0; x <= 22; x++) std::printf("three %u %d\n", x, three_targets(x));
  for (int x = -51; x <= 92; x++) if (in_tree(x)) std::printf("tree %d %d\n", x, in_tree(x));
  for (int x = -1; x <= 6; x++) std::printf("fall %d %d\n", x, fall_bits(x));
  return 0;
}
