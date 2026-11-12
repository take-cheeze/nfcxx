// EXPECT: 0
// STDOUT: same
// switch lowered as a balanced tree of range tests (GCC's clusters): merged runs of adjacent values with one target,
// negative and unsigned and narrow operands, targets reached from several ranges, fallthrough, and a switch in a loop.
#include <cstdio>
#include <initializer_list>

enum Color { Red = -2, Green = 7, Blue = 9, Cyan = 10, Mag = 11, Yellow = 40, Black = 1000 };

static int dense(int x) {
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

static int sparse(int x) {
  switch (x) {
    case -7: return 1;
    case -50: return 2;
    case 1: return 3;
    case 5: return 4;
    case 9: return 5;
    case 100: return 6;
    case 1000: return 7;
    case 1001: return 8;
    case 1002: return 9;
    case 70000: return 10;
    default: return 0;
  }
}

static int runs(int x) {
  switch (x) {
    case 10: case 11: case 12: case 13:
      return 1;
    case 20: case 21: case 22:
      return 2;
    case 23:
      return 3;
    case 30: case 32: case 34: case 36:
      return 4;
    case 40: case 41:
      return 5;
    case 50: case 51: case 52: case 53: case 54:
      return 1;
    default:
      return 0;
  }
}

static int unsigned_ops(unsigned x) {
  switch (x) {
    case 0u: return 1;
    case 1u: return 2;
    case 2u: return 3;
    case 3000000000u: return 4;
    case 3000000001u: return 5;
    case 4294967295u: return 6;
    case 2147483648u: return 7;
    default: return 0;
  }
}

static int narrow(signed char c) {
  switch (c) {
    case -128: return 1;
    case -127: return 2;
    case -1: return 3;
    case 0: return 4;
    case 1: return 5;
    case 127: return 6;
    default: return 0;
  }
}

static int wide(long v) {
  switch (v) {
    case 1L << 40: return 1;
    case (1L << 40) + 1: return 2;
    case (1L << 40) + 2: return 3;
    case -(1L << 40): return 4;
    case 5000000000L: return 5;
    default: return 0;
  }
}

static const char *named(Color c) {
  switch (c) {
    case Red: return "red";
    case Green: return "green";
    case Blue: return "blue";
    case Cyan: return "cyan";
    case Mag: return "mag";
    case Yellow: return "yellow";
    case Black: return "black";
    default: return "?";
  }
}

// Fallthrough and break inside a tree.
static int falls(int x) {
  int r = 0;
  switch (x) {
    case 0: r += 1;
    case 1: r += 10;
    case 2: r += 100; break;
    case 3: r += 1000;
    case 4: r += 10000; break;
    case 8: r += 100000;
    case 9: r += 1000000;
    case 10: r += 2;
    default: r += 3;
  }
  return r;
}

// A switch in a loop: continue and nested switches.
static int loop(int n) {
  int acc = 0;
  for (int i = -3; i < n; i++) {
    switch (i) {
      case -3: case -2: continue;
      case 0: acc += 1; break;
      case 1: acc += 2;
      case 2: acc += 3; break;
      case 3: case 4: case 5: case 6:
        switch (i & 1) {
          case 0: acc += 100; break;
          default: acc += 200;
        }
        break;
      default:
        acc += 1000;
    }
  }
  return acc;
}

int main() {
  int total = 0;
  for (int x = -2; x <= 12; x++) { total += dense(x); std::printf("dense %d %d\n", x, dense(x)); }
  const int sp[] = {-60, -50, -7, -6, 0, 1, 5, 6, 9, 100, 999, 1000, 1001, 1002, 1003, 70000, 70001};
  for (int x : sp) std::printf("sparse %d %d\n", x, sparse(x));
  for (int x = 8; x <= 56; x++) std::printf("runs %d %d\n", x, runs(x));
  const unsigned up[] = {0u, 1u, 2u, 3u, 2147483647u, 2147483648u, 2999999999u, 3000000000u, 3000000001u, 4294967294u, 4294967295u};
  for (unsigned x : up) std::printf("unsigned %u %d\n", x, unsigned_ops(x));
  for (int x = -130; x <= 130; x += 1) {
    if (x == -128 || x == -127 || (x >= -2 && x <= 2) || x == 127 || x == -130 || x == 126) {
      std::printf("narrow %d %d\n", x, narrow((signed char)x));
    }
  }
  const long wv[] = {1L << 40, (1L << 40) + 1, (1L << 40) + 2, (1L << 40) + 3, -(1L << 40), 5000000000L, 0L};
  for (long v : wv) std::printf("wide %ld %d\n", v, wide(v));
  for (int c : {-2, 7, 9, 10, 11, 40, 1000, 8, 0}) std::printf("named %d %s\n", c, named((Color)c));
  for (int x = -1; x <= 11; x++) std::printf("falls %d %d\n", x, falls(x));
  std::printf("loop %d\n", loop(12));
  total += unsigned_ops(3000000001u) + narrow(-128) + wide(5000000000L);
  std::printf("total %d\n", total);
  return 0;
}
