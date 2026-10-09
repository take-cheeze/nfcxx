// EXPECT: 0
// GNU statement expressions whose value is a class with a user-defined copy constructor (and a destructor): the
// result is copied out of the expression, locals of the expression are destroyed, the copy count matches gcc.
// The exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

static int copies, dtors, ctors;
struct C {
  int v;
  C(int x) : v(x) { ++ctors; }
  C(const C &o) : v(o.v + 100) { ++copies; }
  ~C() { ++dtors; }
};

static int use(C c) { return c.v; }

int main() {
  {
    C a = ({ C t(5); t; });
    CHECK(a.v >= 105);
    CHECK(copies >= 1);
  }
  CHECK(dtors == ctors + copies);
  int c0 = copies;
  int r = use(({ C t(7); t; }));
  CHECK(r >= 107);
  CHECK(copies > c0);
  C b(1);
  C d = ({ int k = 3; b; });
  CHECK(d.v == 101);
  int s = ({ C u(2); u.v + 1; });
  CHECK(s == 3);
  const C &ref = ({ C t(9); t; });
  CHECK(ref.v >= 109);
  return bad;
}
