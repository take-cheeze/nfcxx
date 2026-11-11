// A constructor that throws after building members with destructors. The members are destroyed on the way out: a
// vector, a deque, two strings, and a stack over a deque (which destroys its own members). With --nfcxx_eh_unwind the
// members are destroyed by the system unwinder, and a noexcept destructor (a noexcept frame below the function frame)
// must not be destroyed a second time. The exit code is the number of wrong results.
// BACKENDS: gcc qbe
// EXPECT: 0
#include <cstdio>
#include <deque>
#include <stack>
#include <string>
#include <vector>

static int bad;
#define CHECK(c) do { if (!(c)) { bad++; std::printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

struct Vec { std::vector<int> v; Vec(int n) { v.push_back(n); if (n) throw n; } };
struct Dq { std::deque<int> d; Dq(int n) { d.push_back(n); if (n) throw n; } };
struct Two { std::string a, b; Two(int n) { a = std::string(40, (char)65); b = std::string(40, (char)66); if (n) throw n; } };
struct Stk { std::stack<int, std::deque<int>> st; Stk() { st.push(1); throw 3; } };

struct Guard { int *p; ~Guard() noexcept { ++*p; } };
struct NoexceptMember { Guard g; NoexceptMember(int *c) : g{c} { throw 5; } };

int main()
{
  try { Vec v(7); CHECK(false); } catch (int e) { CHECK(e == 7); }
  try { Dq d(7); CHECK(false); } catch (int e) { CHECK(e == 7); }
  try { Two t(7); CHECK(false); } catch (int e) { CHECK(e == 7); }
  try { Stk s; CHECK(false); } catch (int e) { CHECK(e == 3); }
  int dtors = 0;
  try { NoexceptMember m(&dtors); CHECK(false); } catch (int e) { CHECK(e == 5); }
  CHECK(dtors == 1);
  return bad;
}
