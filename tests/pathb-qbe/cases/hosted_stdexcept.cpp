// Path B, hosted: <stdexcept>. runtime_error, logic_error, out_of_range, invalid_argument thrown and caught by exact
// type, base class and std::exception; what() text; rethrow; a destructor-guarded scope.
// EXPECT: 10
// STDOUT: same
#include <stdexcept>
#include <cstdio>
#include <cstring>

struct G { int *c; ~G() { ++*c; } };

static void thrower(int k)
{
  switch (k) {
  case 0: throw std::runtime_error("rt");
  case 1: throw std::logic_error("lg");
  case 2: throw std::out_of_range("oor");
  case 3: throw std::invalid_argument("inv");
  default: throw std::overflow_error("ovf");
  }
}

int main()
{
  int n = 0, guards = 0;
  for (int k = 0; k < 5; k++) {
    try { G g{&guards}; thrower(k); }
    catch (const std::out_of_range &e) { n += k == 2 && !std::strcmp(e.what(), "oor"); }
    catch (const std::invalid_argument &e) { n += k == 3; }
    catch (const std::logic_error &e) { n += k == 1 && !std::strcmp(e.what(), "lg"); }
    catch (const std::runtime_error &e) { n += (k == 0 || k == 4); std::printf("rt: %s\n", e.what()); }
  }
  try { try { thrower(0); } catch (...) { throw; } }
  catch (const std::exception &e) { n += !std::strcmp(e.what(), "rt"); }
  n += guards == 5;
  std::printf("n=%d guards=%d\n", n, guards);
  return n + 2 + (guards == 5);
}
