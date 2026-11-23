// EXPECT: 0
// STDOUT: same
// The landing pads are cold code (QBE's ehcoldmark: .text.unlikely, with an FDE and an LSDA of their own). The hot
// code calls the pads through the LSDA's LPStart (the cold code's start): the pads of hot calls (cleanups, catches),
// a catch clause's own call with a pad (a call site of the cold code), and a rethrow from a catch. Its output is g++'s.
#include <cstdio>
struct D {
  const char *n;
  ~D() { std::printf("~%s\n", n); }
};
__attribute__((noinline)) static void deep(int x) {
  if (x == 3) throw x;
}
__attribute__((noinline)) static void inner(int x) {
  D d{"inner"};
  if (x == 4) throw x * 10;
}
__attribute__((noinline)) static int mid(int x) {
  D d{"mid"};
  deep(x);
  inner(x);
  return x + 1;
}
__attribute__((noinline)) static void thrower2(int x) {
  if (x == 3) throw x + 47;
}
// the catch clause is cold code: its call throws into a try of its own, whose pad is cold code too
__attribute__((noinline)) static int catcher(int x) {
  try {
    deep(x);
  } catch (int e) {
    try {
      thrower2(e);
    } catch (int f) {
      std::printf("nested %d\n", f);
      return f;
    }
  }
  return x;
}
__attribute__((noinline)) static int rethrow(int x) {
  try {
    mid(x);
  } catch (int e) {
    std::printf("rethrow %d\n", e);
    throw e + 100;
  }
  return 0;
}
__attribute__((noinline)) static int shared(int x) {
  D d{"shared"};
  if (x == 6) deep(x);
  return x;
}
int main() {
  int total = 0;
  for (int x = 0; x < 8; x++) {
    try {
      total += shared(x);
      total += mid(x);
    } catch (int e) {
      std::printf("caught %d\n", e);
      total += e;
    }
    try {
      total += catcher(x);
    } catch (int e) {
      std::printf("catcher threw %d\n", e);
    }
    try {
      rethrow(x);
    } catch (int e) {
      std::printf("outer caught %d\n", e);
      total += e;
    }
  }
  return total == 0 ? 1 : 0;
}
