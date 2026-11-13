// MACOS-XFAIL-pathb: Path B's EH runtime on macOS (EDG's libC.a and the libstdc++ shim) does not catch the C++ exceptions of libc++, which macOS links, so a throw terminates (134); see docs/notes/eh-shim.md
// EXPECT: 15
// C++ exceptions (EDG lowers them to C plus its EH runtime in libC.a).
struct E { int v; };
int thrower(int x){ if (x > 2) throw E{x}; return x; }
int main(){ try { return thrower(1) + thrower(5); } catch (E& e) { return e.v + 10; } }
