// EXPECT: 0
// __is_trivially_copyable, __is_trivially_constructible, __is_trivially_destructible, __is_constructible.
struct Triv { int a; };
struct CopyCtor { CopyCtor(const CopyCtor&) {} int a; };
struct DtorX { ~DtorX() {} };
struct Ctor2 { Ctor2(int, int) {} };
struct Nope { Nope() = delete; };
struct NoCopy { NoCopy(const NoCopy&) = delete; };

int main() {
  int fails = 0;
  fails += !__is_trivially_copyable(Triv);
  fails += !__is_trivially_copyable(int);
  fails += !!__is_trivially_copyable(CopyCtor);
  fails += !__is_trivially_constructible(Triv);
  fails += !__is_trivially_constructible(int, int);
  fails += !!__is_trivially_constructible(CopyCtor, int);
  fails += !__is_trivially_destructible(Triv);
  fails += !!__is_trivially_destructible(DtorX);
  fails += !__is_constructible(Ctor2, int, int);
  fails += !!__is_constructible(Ctor2, int);
  fails += !__is_constructible(int, long);
  fails += !!__is_constructible(Nope);
  fails += !!__is_constructible(NoCopy, NoCopy);
  fails += __is_constructible(NoCopy);   // a user-declared copy ctor suppresses the implicit default ctor
  return fails;
}
