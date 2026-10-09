// Path B: __attribute__((constructor)) and __attribute__((destructor)) functions. They are `static`, nothing refers
// to them, so reachability pruning must keep them on the marker alone. Priorities order them: 101 before 102 before
// the functions without one; a C++ global with a dynamic initializer is constructed in the same start-up phase.
// The destructors run at exit, the higher priority number first.
// EXPECT: 42
// STDOUT: same
extern "C" int printf(const char *, ...);
extern "C" void _exit(int);
extern "C" int fflush(void *);

static char logbuf[128];
static int logn;
static void put(char c) { logbuf[logn++] = c; logbuf[logn] = 0; }
static bool is(const char *want)
{
  int i = 0;
  while (want[i] != 0 && logbuf[i] == want[i]) i++;
  return want[i] == 0 && logbuf[i] == 0;
}

// The default priority runs last among the constructors and first among the destructors, so this destructor, the one
// of the lowest priority number (101), runs last of all: it checks the log and ends the process.
__attribute__((destructor(101))) static void finish()
{
  put('f');
  printf("log %s\n", logbuf);
  fflush(0);
  _exit(is("abDECmzxyf") ? 42 : 43);
}

__attribute__((constructor(102))) static void ctor_102() { put('b'); }
__attribute__((constructor(101))) static void ctor_101() { put('a'); }
__attribute__((destructor(103))) static void dtor_103() { put('x'); }
__attribute__((destructor(102))) static void dtor_102() { put('y'); }
__attribute__((destructor)) static void dtor_default() { put('z'); }

struct G {
  G() { put('C'); }
};
G g;   // the __sti__ routine of this translation unit: default priority

// extern "C" so that the function is not mangled; not static, not called: only the marker keeps it.
extern "C" __attribute__((constructor)) void ctor_default_2() { put('D'); }
__attribute__((constructor)) static void ctor_default_3() { put('E'); }

int main()
{
  put('m');
  return 0;
}
