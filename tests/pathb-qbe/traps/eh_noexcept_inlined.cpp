// TRAP-STDERR: terminate() called
// An exception leaves a noexcept function that is inlined into a caller with a try block and a local with a destructor: terminate,
// whatever the frame passes did to the callee's guard. The inner function makes only calls that cannot throw but for the
// one that does, so its frame has to stay.
#include <stdexcept>
struct D { ~D() {} };
[[gnu::noinline]] static void thrower(int x) { if (x) throw std::runtime_error("x"); }
static inline int inner(int x) noexcept { thrower(x); return x; }
static int outer(int x) {
  D d;
  try { return inner(x); } catch (const std::exception&) { return 1; }
}
int main() { return outer(1); }
