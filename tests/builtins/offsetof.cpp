// EXPECT: 0
// __builtin_offsetof, against the layout the compiler actually produces.
struct Inner { char c; int i; };
struct Outer { char a; double d; Inner in; int tail[3]; };
int main() {
  int fails = 0;
  fails += __builtin_offsetof(Outer, a) != 0;
  fails += __builtin_offsetof(Outer, d) != 8;
  fails += __builtin_offsetof(Outer, in.i) != __builtin_offsetof(Outer, in) + 4;
  fails += __builtin_offsetof(Outer, tail[2]) != __builtin_offsetof(Outer, tail) + 8;
  Outer* p = nullptr;
  (void)p;
  fails += (char*)&((Outer*)0)->d - (char*)0 != 8;  // pointer-based form, same answer
  fails += __builtin_offsetof(Outer, d) + 0 != (unsigned long)&((Outer*)0)->d;
  return fails;
}
