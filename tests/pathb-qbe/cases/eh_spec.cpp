// EXPECT: 0
// STD: c++14
// C++ exceptions, part 5 (Path B): dynamic exception specifications (C++14 mode; removed in C++17), `throw()` and
// noexcept. A function with a specification that lets the exception through is a normal function; a violation calls
// std::unexpected -> std::terminate (see tests/pathb-qbe/traps/eh_*). The exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) bad++; } while (0)

static long trace;
static void ev(int d) { trace = trace * 10 + d; }
struct G { int id; G(int i) : id(i) { ev(i); } ~G() { ev(id + 5); } };

struct Base { virtual ~Base() {} };
struct Derived : Base {};

static void allows_int(int k) throw(int) { G g(1); if (k) throw k; }
static void allows_two(int k) throw(int, char) { if (k == 1) throw 1; if (k == 2) throw 'c'; }
static void allows_base(int k) throw(Base) { if (k) throw Derived(); }
static void allows_any(int k) { if (k) throw k; }
static void nothrow_fn(int k) throw() { G g(2); (void)k; }
static void noexcept_fn(int k) noexcept { G g(3); (void)k; }
static void noexcept_false(int k) noexcept(false) { if (k) throw k; }
template <class T> static void spec_tmpl(T v) throw(T) { throw v; }

static long t_allows() {
  trace = 0;
  int got = 0;
  try { allows_int(7); } catch (int e) { got = e; }
  return trace * 100 + got;                 // events 1 6, result 7
}
int main() {
  CHECK(t_allows() == 1607);
  { int got = 0; try { allows_two(1); } catch (int e) { got = e; } CHECK(got == 1); }
  { int got = 0; try { allows_two(2); } catch (char c) { got = c; } CHECK(got == 'c'); }
  { int got = 0; try { allows_two(0); got = 5; } catch (...) { got = 6; } CHECK(got == 5); }
  { int got = 0; try { allows_base(1); } catch (Base &) { got = 1; } CHECK(got == 1); }
  { int got = 0; try { allows_any(3); } catch (int e) { got = e; } CHECK(got == 3); }
  trace = 0; nothrow_fn(0); noexcept_fn(0); CHECK(trace == 2738);
  { int got = 0; try { noexcept_false(4); } catch (int e) { got = e; } CHECK(got == 4); }
  { int got = 0; try { spec_tmpl<char>('z'); } catch (char c) { got = c; } CHECK(got == 'z'); }
  return bad;
}
