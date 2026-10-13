// CLEAN
// C++ variable-length arrays with no memory error: each VLA is a malloc block freed when its scope ends (lib/asan/
// nfcxx_vla_asan.c). Loops left by break, continue and return, a VLA of a size that EDG's runtime would serve from a
// malloc of its own (4096 bytes and more), and exceptions thrown out of VLA blocks, caught in the same function and in a
// caller, run to completion under asan with no report. The exit code is the number of wrong results.
#include <stdexcept>

extern "C" long __vla_number_of_active_allocations(void);

static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

static int loops(int n) {
  int s = 0;
  for (int i = 0; i < n; ++i) {
    int a[i + 1];
    for (int j = 0; j <= i; ++j) a[j] = j;
    if (i == 1) continue;
    if (i == 4) break;
    s += a[i];
  }
  return s;   // i = 0, 2, 3 add 0, 2, 3
}

static int early(int n) {
  int b[n];
  for (int i = 0; i < n; ++i) b[i] = i + 1;
  for (int i = 0; i < n; ++i) {
    int c[i + 2];
    c[0] = b[i];
    if (c[0] == 3) return c[0] * 10;   // leaves two VLA blocks at once
  }
  return -1;
}

static long wide(int rounds) {
  long s = 0;
  for (int r = 0; r < rounds; ++r) {
    double d[1000 + r];   // 8000 bytes and more
    d[0] = r;
    if (r == 5) break;
    s += (long)d[0];
  }
  return s;   // 0 + 1 + 2 + 3 + 4
}

static void inner(int n) {
  int w[n];
  w[0] = n;
  if (n > 0 && w[0] == n) throw std::runtime_error("inner");   // leaves w through the EH cleanup of the frame
  w[0] = 0;
}

static int caught_here(int n) {
  int got = 0;
  try {
    int v[n];
    v[0] = 1;
    inner(n);
    got = 100;   // not reached
  } catch (const std::runtime_error &) {
    got = 7;     // v was released by the cleanup of the try block's frame
  }
  return got;
}

static int up(int n) {
  int a[n];
  a[0] = n;
  inner(n);
  return a[0];   // not reached
}

int main() {
  CHECK(loops(10) == 5);
  CHECK(early(5) == 30 && early(2) == -1);
  CHECK(wide(10) == 10);
  CHECK(caught_here(3) == 7);
  int caught = 0;
  try {
    up(4);
  } catch (const std::runtime_error &) {
    caught = 1;
  }
  CHECK(caught == 1);
  CHECK(__vla_number_of_active_allocations() == 0);
  return bad;
}
