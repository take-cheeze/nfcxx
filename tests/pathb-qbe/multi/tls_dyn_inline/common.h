extern "C" int printf(const char *, ...);

struct T {
  int id;
  int val;
  T(int i, int v) : id(i), val(v) { printf("ctor %d val=%d\n", id, val); }
  ~T() { printf("dtor %d val=%d\n", id, val); }
};

// Defined in every unit that includes the header; the linker keeps one definition (weak), and every thread must
// construct its copy once, whichever unit touches it first.
inline thread_local T hv(7, 70);

template <class U> struct Tmpl {
  static thread_local U v;
};
template <class U> thread_local U Tmpl<U>::v(8, 80);

inline int &hfn() {
  thread_local int x = 9;
  return x;
}

int use_in_b();
