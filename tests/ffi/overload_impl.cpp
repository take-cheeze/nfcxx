/* The definitions for tests/ffi/overload.hpp. No includes: the header comes first (Ffi::load). */
#include <string.h>
int pick(int a) { return a * 10; }
int pick(double a) { return (int)(a * 100); }
int pick(const char* s) { return (int)strlen(s); }
