// EXPECT: 0
// STDOUT: same
// An exception object built in place from subobjects (throw E{S(...), g()}): EDG's region of a built member has no
// variable, only its offset in the exception object. When g() throws, the pad destroys the members built so far
// through the address the throw keeps in a slot (be/nfcxx_ir_eh.h ir_eh_thr_slot); once the object is complete,
// __cxa_throw is called outside those regions, so the unwind from it does not destroy them. Before, the function had
// no pads at all (an unsupported cleanup) and an exception through it ended in std::terminate.
#include <string>
struct S { std::string n; S(const char *p) : n(p) { std::printf("S(%s)\n", p); } S(const S &o) : n(o.n) {} ~S() { std::printf("~S(%s)\n", n.c_str()); } };
struct E { S a; S b; };
static S g(int x) { if (x) throw 42; return S("g"); }
void f(int x) { throw E{S("first"), g(x)}; }
int main() {
  try { f(1); } catch (int v) { std::printf("caught %d\n", v); } catch (E &e) { std::printf("caught E %s %s\n", e.a.n.c_str(), e.b.n.c_str()); }
  try { f(0); } catch (int v) { std::printf("caught %d\n", v); } catch (E &e) { std::printf("caught E %s %s\n", e.a.n.c_str(), e.b.n.c_str()); }
}
