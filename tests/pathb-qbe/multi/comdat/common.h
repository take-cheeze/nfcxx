// Everything here is COMDAT: each translation unit that uses it defines it, and the link must merge the copies.
inline int inl_add(int a, int b) { return a + b; }
template <class T> T tmpl_twice(T x) { return x + x; }
inline int counter_next() { static int n = 0; return ++n; }   // one counter shared by both units
inline int shared_var = 5;                                     // inline variable: one object
struct Shape {
  virtual int area() { return 3; }                             // inline virtual: vtable and member are COMDAT
  virtual ~Shape() {}
};
