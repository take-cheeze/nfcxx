// EXPECT: 1
// A class-returning routine whose body only throws (no return statement) is inlined by the front end, and the expansion
// of its missing return value used to be an lvalue comma that the caller's initialization rejected (an internal error in
// make_assignment_expr). This is the shape of sycl::sub_group::id() in <sycl/khr/group_interface.hpp> over
// sycl::sub_group::get_group_id() in <sycl/sub_group.hpp>.
struct I {
  int v;
};

struct X {
  I get() const { throw 1; }
};

I f(X x) { return x.get(); }

int main() {
  try {
    X x;
    (void)f(x);
  } catch (int e) {
    return e;
  }
  return 0;
}
