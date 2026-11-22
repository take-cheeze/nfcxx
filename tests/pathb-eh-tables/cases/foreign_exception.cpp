// EXPECT: 0
// STDOUT: same
// A foreign exception (an _Unwind_Exception whose class is not a C++ one, raised with _Unwind_RaiseException) through
// Path B's frames: the pads run the destructors, a catch of a C++ type does not match it, catch (...) catches it, and
// `throw;` passes it on to the next catch (...). Its cleanup function runs when the last handler ends.
#include <cstdio>
#include <cstring>
#include <unwind.h>
struct D {
  const char *n;
  ~D() { std::printf("%s\n", n); }
};
static int cleaned;
static void cleanup(_Unwind_Reason_Code, _Unwind_Exception *) { cleaned++; }
static _Unwind_Exception foreign;
__attribute__((noinline)) static void raise_it() {
  D d{"~raise_it"};
  std::memset(&foreign, 0, sizeof foreign);
  foreign.exception_class = 0x4e46435846525247ULL;   // "NFCXFRRG": not "GNUCC++\0"
  foreign.exception_cleanup = cleanup;
  _Unwind_RaiseException(&foreign);
  std::printf("raise returned (wrong)\n");
}
__attribute__((noinline)) static void middle() {
  D d{"~middle"};
  try {
    raise_it();
  } catch (int) {
    std::printf("caught int (wrong)\n");
  } catch (...) {
    std::printf("middle: catch (...), rethrow\n");
    throw;
  }
}
int main() {
  try {
    D d{"~main"};
    middle();
  } catch (const char *) {
    std::printf("caught const char * (wrong)\n");
  } catch (...) {
    std::printf("main: catch (...)\n");
  }
  std::printf("cleanup ran %d time(s)\n", cleaned);
  return cleaned == 1 ? 0 : 1;
}
