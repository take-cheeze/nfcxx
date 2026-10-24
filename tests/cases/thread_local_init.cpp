// EXPECT: 0
// thread_local initializers the front end could fold, and GNU __thread statics (docs/notes/multi-tu.md,
// "thread_local initialization"). The address of a thread_local object is not a constant, so a std::string or a class
// holding a pointer to itself is initialized dynamically, per thread, as with g++: EDG used to fold it to a static
// image with &self, which C rejects. A static __thread variable with an initializer used to get a tentative
// declaration first, a redefinition in C23. Each case on the main thread and on a second one.
#include <string>
#include <thread>
struct Self {
  Self *self; int v;
  constexpr Self(int x) : self(this), v(x) {}
  constexpr Self() : self(this), v(5) {}
};
static __thread long gnu_static = 9;
__thread long gnu_extern = 10;
thread_local std::string str = "hi";
thread_local Self self_arg(3);
thread_local Self self_default;
static thread_local Self self_static(4);
struct Holder { static thread_local std::string member; };
thread_local std::string Holder::member = "member";
static int local() {
  static thread_local Self l(7);
  thread_local std::string ls = "local";
  return (l.self == &l && l.v == 7 ? 0 : 1) | (ls == "local" ? 0 : 2);
}
static int check() {
  int r = local() << 8;
  if (gnu_static != 9 || gnu_extern != 10) r |= 1;
  if (str != "hi" || Holder::member != "member") r |= 2;
  if (self_arg.self != &self_arg || self_arg.v != 3) r |= 4;
  if (self_default.self != &self_default || self_default.v != 5) r |= 8;
  if (self_static.self != &self_static || self_static.v != 4) r |= 16;
  gnu_static++; str += "!"; self_arg.v++;   // per thread: the other thread still sees the initial values
  return r;
}
int main() {
  int r1 = check(), r2 = 0;
  std::thread t([&] { r2 = check(); });
  t.join();
  return r1 | r2;
}
