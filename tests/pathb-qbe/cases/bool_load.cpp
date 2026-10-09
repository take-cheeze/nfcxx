// EXPECT: 0
// GCC: undefined
// A bool object holding a byte other than 0 or 1 (written through unsigned char) is read as true, and a load
// yields 0 or 1. C++ leaves such an object undefined, so the gcc backend is not compared (it keeps the raw byte).
// The program counts wrong answers.
static int wrong = 0;

static void check(bool ok) { if (!ok) wrong++; }
static int as_int(bool b) { return b; }

union U { bool b; unsigned char c; };

static bool g;
static bool pass_through(bool b) { return b; }

int main() {
  bool b = false;
  *(unsigned char *)&b = 2;
  if (!b) wrong++;             // !2 is false
  if (b) { } else wrong++;
  check(b ? true : false);
  check(!(!b));
  int x = b;                   // true converts to 1
  if (x != 1) wrong++;
  if (as_int(b) != 1) wrong++;
  if (b != true) wrong++;
  if (b + 1 != 2) wrong++;

  union U u;
  u.c = 0x80;
  if (!u.b) wrong++;
  bool seen = false;
  if (u.b && b) seen = true;
  check(seen);
  check(!(!u.b || !b));
  if (u.b != b) wrong++;       // two different non-zero bytes are both true, hence equal

  *(unsigned char *)&b = 0;
  if (b) wrong++;
  check(!b);
  if (as_int(b) != 0) wrong++;

  *(unsigned char *)&g = 255;
  if (!g) wrong++;
  check(pass_through(g));
  if (as_int(g) != 1) wrong++;
  return wrong;
}
