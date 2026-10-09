// EXPECT: 0
// Type predicates: __is_same, __is_class, __is_enum, __is_union, __is_empty, __is_final, __is_pod.
// Each failed check adds 1 to `fails`; the exit code is the number of wrong answers.
struct Empty {};
struct NonEmpty { int x; };
struct Final final {};
struct Base {};
union U { int i; float f; };
enum E { A, B };
enum class EC : short { X };
struct Pod { int a; double b; };
struct NonPod { NonPod() {} int a; };

int main() {
  int fails = 0;
  fails += !__is_same(int, int);
  fails += !!__is_same(int, unsigned);
  fails += !__is_same(const int, const int);
  fails += !!__is_same(int, const int);
  fails += !!__is_same(Empty, Base);
  fails += !__is_class(Empty);
  fails += !__is_class(NonEmpty);
  fails += !!__is_class(int);
  fails += !!__is_class(E);
  fails += !!__is_class(U);
  fails += !__is_enum(E);
  fails += !__is_enum(EC);
  fails += !!__is_enum(Empty);
  fails += !__is_union(U);
  fails += !!__is_union(NonEmpty);
  fails += !__is_empty(Empty);
  fails += !!__is_empty(NonEmpty);
  fails += !__is_final(Final);
  fails += !!__is_final(Base);
  fails += !__is_pod(Pod);
  fails += !__is_pod(int);
  fails += !!__is_pod(NonPod);
  return fails;
}
