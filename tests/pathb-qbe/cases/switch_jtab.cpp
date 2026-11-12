// EXPECT: 0
// STDOUT: same
// Dense switches, lowered as a jump table (QBE's jtab): negative and unsigned operands, holes that take the default,
// a target shared by several values, fallthrough into a target with a phi, and a switch in a loop.
#include <cstdio>

static int dense8(int x) {
  switch (x) {
    case 0: return 100;
    case 1: return 101;
    case 2: return 102;
    case 3: return 103;
    case 4: return 104;
    case 5: return 105;
    case 6: return 106;
    case 7: return 107;
    default: return -1;
  }
}

static int negative(int x) {
  switch (x) {
    case -5: return 1;
    case -4: return 2;
    case -3: return 3;
    case -2: return 4;
    case -1: return 5;
    case 0: return 6;
    case 1: return 7;
    case 2: return 8;
    case 3: return 9;
    case 4: return 10;
    default: return 0;
  }
}

static int holes(int x) {
  switch (x) {
    case 0: return 1;
    case 1: return 2;
    case 2: return 3;
    case 4: return 5;
    case 5: return 6;
    case 6: return 7;
    default: return 0;
  }
}

static int shared(int x) {
  switch (x) {
    case 10: case 11: case 12: return 1;
    case 13: case 14: case 15: return 2;
    case 16: return 3;
    case 17: return 1;
    case 18: return 4;
    default: return 0;
  }
}

static unsigned uns(unsigned x) {
  switch (x) {
    case 1000u: return 1u;
    case 1001u: return 2u;
    case 1002u: return 3u;
    case 1003u: return 4u;
    case 1004u: return 5u;
    case 1005u: return 6u;
    default: return 0u;
  }
}

static int letters(char c) {
  switch (c) {
    case 'a': return 1;
    case 'b': return 2;
    case 'c': return 3;
    case 'd': return 4;
    case 'e': return 5;
    case 'f': return 6;
    default: return 0;
  }
}

// Fallthrough into a target that has a phi (r is set on several paths).
static int falls(int x) {
  int r = 0;
  switch (x) {
    case 0: r += 1;
    case 1: r += 10; break;
    case 2: r += 100;
    case 3: r += 1000; break;
    case 4: r += 10000; break;
    case 5: r += 100000;
    case 6: r += 1000000;
    default: r += 7;
  }
  return r;
}

static int inloop(int n) {
  int acc = 0;
  for (int i = 0; i < n; i++) {
    switch (i % 6) {
      case 0: acc += 1; break;
      case 1: acc += 2; break;
      case 2: acc += 4; continue;
      case 3: acc += 8; break;
      case 4: acc += 16; break;
      case 5: acc += 32; break;
    }
    acc ^= i;
  }
  return acc;
}

int main() {
  for (int x = -1; x <= 9; x++) std::printf("dense8 %d %d\n", x, dense8(x));
  for (int x = -7; x <= 6; x++) std::printf("negative %d %d\n", x, negative(x));
  for (int x = -1; x <= 8; x++) std::printf("holes %d %d\n", x, holes(x));
  for (int x = 9; x <= 19; x++) std::printf("shared %d %d\n", x, shared(x));
  for (unsigned x = 998; x <= 1007; x++) std::printf("uns %u %u\n", x, uns(x));
  for (char c = 'Z'; c <= 'h'; c++) std::printf("letters %c %d\n", c, letters(c));
  for (int x = -1; x <= 8; x++) std::printf("falls %d %d\n", x, falls(x));
  std::printf("inloop %d\n", inloop(40));
  return 0;
}
