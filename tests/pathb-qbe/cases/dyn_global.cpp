// Path B: dynamic initialization of namespace-scope objects. Constructors run before main in declaration order, a
// dynamic initializer calls a function, static data members and arrays of objects are initialized, and the
// destructors run in reverse order at exit through __cxa_atexit. The order is recorded in a log; Final (the first
// object, so the last one destroyed) checks the whole log and ends the process with _exit.
// EXPECT: 42
// STDOUT: same
extern "C" int printf(const char *, ...);
extern "C" void _exit(int);
extern "C" int fflush(void *);

static char logbuf[256];
static int logn;
static void put(char c) { logbuf[logn++] = c; logbuf[logn] = 0; }
static bool is(const char *want)
{
  int i = 0;
  while (want[i] != 0 && logbuf[i] == want[i]) i++;
  return want[i] == 0 && logbuf[i] == 0;
}

struct Tracer {
  char id;
  Tracer(char i) : id(i) { put(id); printf("ctor %c\n", id); }
  ~Tracer() { put(id + ('a' - 'A')); printf("dtor %c\n", id); }
};

// Constructed first, destroyed last: verifies the order and ends the process.
struct Final {
  Final() { put('F'); }
  ~Final()
  {
    printf("log %s\n", logbuf);
    fflush(0);
    _exit(is("FABxCyDEmzedcba") ? 42 : 43);
  }
};
Final fin;

Tracer a('A');
namespace ns {
Tracer b('B');
int computed = (put('x'), 7);   // a dynamic initializer that is not a constructor
}
struct Holder {
  static Tracer member;
  static int counter;
};
Tracer Holder::member('C');
int Holder::counter = (put('y'), 5);
Tracer arr[2] = {Tracer('D'), Tracer('E')};

int main()
{
  put('m');
  int ok = is("FABxCyDEm");
  put('z');
  (void)ns::computed;
  return ok ? 40 : 41;
}
