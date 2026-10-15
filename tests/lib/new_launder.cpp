// EXPECT: 0
// <new>: placement new and destructor calls, std::launder.
#include <new>
#include <cstddef>

struct Tracked {
  static int live;
  int v;
  Tracked(int x) : v(x) { ++live; }
  ~Tracked() { --live; }
};
int Tracked::live = 0;

int main() {
  int fails = 0;
  // Storage as a union, not alignas: cproc rejects __attribute__((aligned)) on locals.
  union Raw { unsigned char bytes[sizeof(Tracked)]; long l; double d; void* p; } raw;
  Tracked* t = new (&raw) Tracked(41);
  fails += Tracked::live != 1;
  fails += t->v != 41;
  t->~Tracked();
  fails += Tracked::live != 0;

  // Reuse the same storage; launder gives a usable pointer to the new object.
  Tracked* t2 = new (&raw) Tracked(7);
  Tracked* l = std::launder(t2);
  fails += l->v != 7;
  l->~Tracked();

  int slot = 0;
  int* ip = new (&slot) int(99);
  fails += slot != 99 || *ip != 99;
  fails += Tracked::live != 0;
  return fails;
}
