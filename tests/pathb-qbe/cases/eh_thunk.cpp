// EXPECT: 0
// IR golden for two lowering gaps that C++ exceptions ran into (tests/pathb-ir/eh_thunk.ir):
//  - the this-adjusting thunk of a virtual destructor of a second base class (EDG node
//    enk_result_of_overriding_function: "call the underlying function with my parameters"), reached when an object of
//    such a class is thrown and later destroyed through its second base;
//  - `throw &f`: the address of a function in an expression that is not a constant (a function designator as lvalue).
// The exit code is the number of wrong results.
static int bad;
static int dtors;
struct P { virtual ~P() { dtors += 1; } };
struct Q { virtual ~Q() { dtors += 10; } };
struct PQ : P, Q {};
static void fn() { dtors += 100; }
static int run() {
  try { throw PQ(); } catch (Q &) { dtors += 1000; }          // thrown by value, destroyed after the handler
  Q *q = new PQ; delete q;                                     // deleting destructor through the second base: the thunk
  try { throw &fn; } catch (void (*p)()) { p(); }
  return dtors;
}
int main() {
  if (run() != 1122) bad++;   // exception object 11 + handler 1000 + delete 11 + fn 100
  return bad;
}
