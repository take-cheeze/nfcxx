// thread_local definitions used from tls_use.cpp (tests/multi-tu/run.sh). counter and pod need no dynamic
// initialization, so this unit defines no _ZTH init function for them: the users' wrappers reference it weakly
// (null here), as g++ does. name has a dynamic initializer and a destructor, so its _ZTH function exists.
#include <string>
struct Pod { int a, b; };
thread_local int counter = 100;
thread_local Pod pod = {1, 2};
// A call the compiler cannot evaluate at compile time: an initializer that C++20 constant evaluation can fold makes
// EDG emit a static image whose pointer refers to the thread-local itself, which C rejects (docs/notes/realworld.md).
std::string make_name() { return std::string("tl-") + "name"; }
thread_local std::string name = make_name();
int bump_counter() { return ++counter; }
