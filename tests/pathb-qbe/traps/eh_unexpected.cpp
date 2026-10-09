// TRAP-STDERR: terminate() called
// STD: c++14
// A dynamic exception specification is violated: std::unexpected, then std::terminate.
static void thrower() { throw 'c'; }
static void f() throw(int) { thrower(); }
int main() {
  try { f(); } catch (int) { return 1; } catch (...) { return 2; }   // not reached: unexpected() terminates
  return 0;
}
