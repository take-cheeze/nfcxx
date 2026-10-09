// EXPECT: 0
// __builtin_launder and __builtin_addressof.
struct Overloaded {
  int v;
  Overloaded* operator&() { return nullptr; }  // hijacked unary &
};
struct Plain { int v; };

// placement new without <new>: declared here so the probe needs no hosted headers
void* operator new(decltype(sizeof(0)), void* p) noexcept { return p; }

int main() {
  int fails = 0;
  Overloaded o{7};
  fails += __builtin_addressof(o) == nullptr;     // must bypass operator&
  fails += __builtin_addressof(o)->v != 7;
  Plain p{11};
  int* ip = __builtin_addressof(p.v);
  fails += *ip != 11;
  // launder: a pointer to an object re-created in the same storage by placement new.
  // (Storage is a union rather than alignas(): cproc rejects __attribute__((aligned)) on locals.)
  union { Plain p; unsigned char bytes[sizeof(Plain)]; } storage;
  Plain* pp = new (&storage) Plain{5};
  fails += __builtin_launder(pp)->v != 5;
  return fails;
}
