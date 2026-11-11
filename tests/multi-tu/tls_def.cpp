// thread_local definitions used from tls_use.cpp (tests/multi-tu/run.sh). counter and pod need no dynamic
// initialization, so this unit defines no _ZTH init function for them: the users' wrappers reference it weakly
// (null here), as g++ does. name has a dynamic initializer and a destructor, so its _ZTH function exists.
#include <string>
struct Pod { int a, b; };
thread_local int counter = 100;
thread_local Pod pod = {1, 2};
// A call, and a literal that constant evaluation could fold: the address of a thread_local is not a constant, so both
// are dynamic initializations with a _ZTH function, as with g++ (docs/notes/multi-tu.md).
std::string make_name() { return std::string("tl-") + "name"; }
thread_local std::string name = make_name();
thread_local std::string folded = "folded";
int bump_counter() { return ++counter; }
