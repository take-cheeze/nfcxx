// Path B: function-local statics. The initializer runs once, on the first call that reaches the declaration (the
// guard variable is __cxa_guard_acquire / __cxa_guard_release, not thread-safe in the way that matters here: one
// thread), later calls skip it, a static in an unreached branch is never constructed, statics in an inline function
// and in a template are shared, and the destructors run at exit in reverse order of construction.
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

struct T {
  char id;
  T(char i) : id(i) { put(id); printf("ctor %c\n", id); }
  ~T() { put(id + ('a' - 'A')); printf("dtor %c\n", id); }
};

// Verifies the whole log at exit (this static is constructed first, so it is destroyed last).
struct Final {
  ~Final()
  {
    printf("log %s\n", logbuf);
    fflush(0);
    _exit(is("AmBCDExFedcba") ? 42 : 43);
  }
};
static Final fin;

int counter_calls;
int once(int v)
{
  static int n = (put('x'), v * 10);   // scalar with a dynamic initializer: the first value stays
  counter_calls++;
  return n;
}

T &first() { static T t('A'); return t; }

inline int in_inline(int v)
{
  static T t('D');
  return t.id + v;
}

template <class X> X &holder(char id)
{
  static X x(id);
  return x;
}

int branchy(int k)
{
  if (k > 0) {
    static T never_when_zero('B');
    return never_when_zero.id;
  }
  return 0;
}

int loopy()
{
  int s = 0;
  for (int i = 0; i < 3; i++) {
    static T once_in_loop('C');
    s += once_in_loop.id;
  }
  return s;
}

int main()
{
  first();
  put('m');
  bool ok = true;
  ok = ok && branchy(0) == 0;           // the static is not reached
  ok = ok && branchy(1) == 'B';         // constructed now (B)
  ok = ok && branchy(2) == 'B';         // not again
  ok = ok && loopy() == 3 * 'C';        // C once
  ok = ok && in_inline(1) == 'D' + 1;   // D
  ok = ok && in_inline(5) == 'D' + 5;
  ok = ok && holder<T>('E').id == 'E';  // E
  ok = ok && holder<T>('Z').id == 'E';  // the same object, no Z
  ok = ok && once(1) == 10 && once(2) == 10 && counter_calls == 2;
  ok = ok && first().id == 'A';
  put('F');
  return ok ? 0 : 1;
}
