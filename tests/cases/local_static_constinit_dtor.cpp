// EXPECT: 0
// A function-local static with a constant initializer (a constexpr constructor) and a non-trivial destructor: EDG makes its
// initialization static and leaves no guard, and Path B registered the destructor with __cxa_atexit at every call of the
// function, so the object was destroyed once per call at exit (tests/poly ops.cpp: double free in std::vector's destructor).
// No library headers: the IR of a header-including version is several hundred KB, more than the script worlds take.
extern "C" void _exit(int);

static int destroyed;

struct Counted {
  constexpr Counted() {}
  ~Counted() {
    if (++destroyed > 1) _exit(3);  // a second destruction of the one object
  }
  int n = 0;
};

static Counted& counted() {
  static Counted c;
  return c;
}

// the std::vector pattern: an owning buffer, constexpr-constructed, freed in the destructor
struct Buf {
  constexpr Buf() {}
  ~Buf() { delete[] p; }  // a second call is a double free
  void push(int x) {
    if (n == cap) {
      int* q = new int[cap ? cap * 2 : 4];
      for (int i = 0; i < n; ++i) q[i] = p[i];
      delete[] p;
      p = q;
      cap = cap ? cap * 2 : 4;
    }
    p[n++] = x;
  }
  int* p = nullptr;
  int n = 0;
  int cap = 0;
};

static Buf& values() {
  static Buf v;
  return v;
}

int main() {
  for (int i = 0; i < 5; ++i) counted().n += 1;
  for (int i = 0; i < 5; ++i) values().push(i);  // freed once at exit, not once per call
  return counted().n == 5 && values().n == 5 ? 0 : 1;
}
