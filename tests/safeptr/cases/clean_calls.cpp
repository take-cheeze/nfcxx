// Indirect calls that are correct: virtual functions (with this-adjusting thunks), function pointers, member function
// pointers, std::function, lambdas, callbacks from the C library (qsort), and pointers to library functions.
// EXPECT: 0
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>
struct A { virtual ~A() {} virtual int f(int x) { return x + 1; } int pad = 0; };
struct B { virtual ~B() {} virtual long g(long y) { return y * 2; } };
struct C : A, B { int f(int x) override { return x + 10; } long g(long y) override { return y * 3; } };
static int add(int a, int b) { return a + b; }
static double scale(double d, float f) { return d * f; }
static int cmp(const void *a, const void *b) { return *static_cast<const int *>(a) - *static_cast<const int *>(b); }
struct S { int k; int get(int x) const { return k + x; } };
int main() {
  std::vector<A *> as{new A, new C};
  int r = 0;
  for (A *a : as) r += a->f(1);
  if (r != 2 + 11) return 1;
  B *b = static_cast<C *>(as[1]);
  if (b->g(5) != 15) return 2;
  for (A *a : as) delete a;
  int (*fp)(int, int) = add;
  double (*sp)(double, float) = scale;
  if (fp(2, 3) != 5 || sp(2.0, 1.5f) != 3.0) return 3;
  int (S::*mp)(int) const = &S::get;
  S s{4};
  if ((s.*mp)(1) != 5) return 4;
  std::function<std::string(int)> fn = [](int n) { return std::string(n, 'x'); };
  if (fn(3) != "xxx") return 5;
  int v[] = {3, 1, 2};
  std::qsort(v, 3, sizeof(int), cmp);
  if (v[0] != 1 || v[2] != 3) return 6;
  size_t (*len)(const char *) = std::strlen;
  if (len("abcd") != 4) return 7;
  void *(*alloc)(size_t) = std::malloc;
  void *m = alloc(8);
  std::free(m);
  return 0;
}
