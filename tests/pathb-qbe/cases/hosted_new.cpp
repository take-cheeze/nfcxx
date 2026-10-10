// Path B, hosted: <new>. std::nothrow, std::bad_alloc thrown by operator new and caught as bad_alloc and as
// std::exception, placement new, new[] with initializer list, get_new_handler.
// EXPECT: 8
// (The gcc backend must agree: the driver links libC.a ahead of libstdc++, so `new` of a huge size reaches EDG's operator
// new and throws an exception EDG's handlers catch; before, it was libstdc++'s, with a gcc-ABI std::bad_alloc, and aborted.)
#include <new>
#include <exception>
#include <cstdio>

struct T { int v; T(int x = 0) : v(x) {} };

static volatile unsigned long huge_n = (unsigned long)-1 / 4;
int main()
{
  int n = 0;
  int *p = new (std::nothrow) int(5);
  n += p && *p == 5;
  delete p;
  char big[sizeof(T)];
  T *t = new (big) T(7);
  n += t->v == 7 && (void *)t == (void *)big;
  t->~T();
  try { char *q = new char[huge_n]; delete[] q; }
  catch (const std::bad_alloc &e) { n += 1; std::printf("caught bad_alloc: %s\n", e.what()); }
  try { char *q = new char[huge_n]; delete[] q; }
  catch (const std::exception &e) { n += 1; }
  char *q = new (std::nothrow) char[huge_n];
  n += q == nullptr;
  try { throw std::bad_alloc(); }
  catch (std::bad_alloc &) { n += 1; }
  T *arr = new T[3]{1, 2, 3};
  n += arr[2].v == 3;
  delete[] arr;
  n += std::get_new_handler() == nullptr;
  std::printf("n=%d\n", n);
  return n;
}
