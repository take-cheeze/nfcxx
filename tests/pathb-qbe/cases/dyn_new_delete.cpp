// Path B: new and delete of objects with constructors and destructors. new T(args) allocates and constructs, delete
// destroys and frees, new T[n] / delete[] construct in index order and destroy in reverse (with the element count kept
// in front of the array), a virtual destructor runs through a base pointer, placement new constructs in given
// storage, and a constructor that throws gives the memory back and runs the destructors of the completed members.
// EXPECT: 42
// STDOUT: same
extern "C" int printf(const char *, ...);
extern "C" void *malloc(unsigned long);
extern "C" void free(void *);

static char logbuf[256];
static int logn;
static void put(char c) { logbuf[logn++] = c; logbuf[logn] = 0; }
static bool is(const char *want)
{
  int i = 0;
  while (want[i] != 0 && logbuf[i] == want[i]) i++;
  bool same = want[i] == 0 && logbuf[i] == 0;
  if (!same) printf("log %s, expected %s\n", logbuf, want);
  return same;
}
static void clear() { logn = 0; logbuf[0] = 0; }

static int live;   // objects constructed minus destroyed
static int news, deletes;

void *operator new(unsigned long n) { news++; return malloc(n); }
void *operator new[](unsigned long n) { news++; return malloc(n); }
void operator delete(void *p) noexcept { deletes++; free(p); }
void operator delete[](void *p) noexcept { deletes++; free(p); }
inline void *operator new(unsigned long, void *p) noexcept { return p; }
// The sized forms are what the lowered delete calls (C++14); defined here so that no address of a libstdc++ function
// is taken (a PIE link rejects the PC-relative reference QBE emits for it).
void operator delete(void *p, unsigned long) noexcept { deletes++; free(p); }
void operator delete[](void *p, unsigned long) noexcept { deletes++; free(p); }

struct T {
  char id;
  T() : id('?') { put('t'); live++; }
  T(char i) : id(i) { put(i); live++; }
  ~T() { put(id + ('a' - 'A')); live--; }
};

struct Base {
  virtual ~Base() { put('b'); }
};
struct Derived : Base {
  T member;
  Derived() : member('M') { put('d'); }
  ~Derived() { put('~'); }
};

struct Thrower {
  T before;
  Thrower(bool go) : before('Q') { if (go) throw 7; put('T'); }
  ~Thrower() { put('!'); }
};

int main()
{
  bool ok = true;

  T *p = new T('A');
  ok = ok && p->id == 'A' && news == 1;
  delete p;
  ok = ok && is("Aa") && deletes == 1;
  clear();

  T *arr = new T[3];
  ok = ok && arr[0].id == '?' && arr[2].id == '?';
  delete[] arr;
  ok = ok && is("ttt___") && live == 0;
  clear();

  Base *b = new Derived;
  delete b;                       // virtual: Derived's destructor, its member, then Base's
  ok = ok && is("Md~mb");
  clear();

  {
    alignas(T) char storage[sizeof(T)];
    T *q = new (storage) T('P');   // placement: no allocation
    ok = ok && q->id == 'P' && news == 3;
    q->~T();
    ok = ok && is("Pp");
    clear();
  }

  int before_news = news, before_deletes = deletes;
  try {
    Thrower *t = new Thrower(true);
    (void)t;
    ok = false;
  } catch (int v) {
    ok = ok && v == 7;
  }
  // The completed member `before` is destroyed, the Thrower destructor does not run, the memory is freed.
  ok = ok && is("Qq") && news == before_news + 1 && deletes == before_deletes + 1 && live == 0;
  clear();

  Thrower *t2 = new Thrower(false);
  delete t2;
  ok = ok && is("QT!q") && live == 0;
  clear();

  printf("%s\n", ok ? "ok" : "bad");
  return ok ? 42 : 1;
}
