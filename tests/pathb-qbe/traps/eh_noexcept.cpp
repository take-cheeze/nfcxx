// TRAP-STDERR: terminate() called
// An exception leaves a noexcept function: terminate (EDG puts a throw-specification entry on the EH stack; the runtime finds it and calls terminate).
static void thrower() { throw 1; }
static void f() noexcept { thrower(); }
int main() {
  try { f(); } catch (int) { return 1; }   // not reached: the exception never gets past f
  return 0;
}
