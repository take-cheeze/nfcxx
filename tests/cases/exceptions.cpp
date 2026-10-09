// EXPECT: 15
// C++ exceptions (EDG lowers them to C plus its EH runtime in libC.a).
struct E { int v; };
int thrower(int x){ if (x > 2) throw E{x}; return x; }
int main(){ try { return thrower(1) + thrower(5); } catch (E& e) { return e.v + 10; } }
