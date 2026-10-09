// TRAP-STDERR: terminate() called
// An exception that no handler catches: EDG's runtime (__throw) finds no matching try and calls std::terminate, which aborts.
struct E { int v; };
static void f(int x) { if (x > 0) throw E{x}; }
int main() {
  try { f(1); } catch (char) { return 1; }   // no match: char is not E
  return 0;
}
