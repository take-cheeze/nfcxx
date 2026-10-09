// Path B: constructor calls for locals, members, base classes, temporaries, arrays, function arguments and results.
// Bases are constructed before members (in declaration order, a virtual base once and first), the destructors run in
// the reverse order, a temporary dies at the end of its full expression, a temporary bound to a const reference lives
// as long as the reference, and an array of objects is constructed in index order and destroyed in reverse.
// EXPECT: 42
// STDOUT: same
extern "C" int printf(const char *, ...);

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

struct T {
  char id;
  T() : id('?') { put('t'); }
  T(char i) : id(i) { put(i); }
  T(const T &o) : id(o.id + 1) { put('c'); }   // a copy shows as c and has id + 1
  ~T() { put(id + ('a' - 'A')); }
};

struct VB { VB() { put('V'); } ~VB() { put('v'); } };
struct B1 : virtual VB { B1() { put('1'); } ~B1() { put('!'); } };
struct B2 : virtual VB { B2() { put('2'); } ~B2() { put('@'); } };
struct D : B1, B2 {
  T m1;
  T m2;
  int n;
  D(int k) : m1('X'), m2('Y'), n(k) { put('D'); }
  ~D() { put('d'); }
};

struct Pair {
  T first;
  T second;
  Pair() : first('P'), second('Q') {}   // members only
};

T make(char c) { return T(c); }
int take(T t) { return t.id; }
int take_ref(const T &t) { return t.id; }

int main()
{
  bool ok = true;

  { D d(3); ok = ok && d.n == 3; }
  // virtual base first, then B1, B2, the members, D's body; destruction is the reverse
  ok = ok && is("V12XYDdyx@!v");
  clear();

  { Pair p; ok = ok && p.first.id == 'P' && p.second.id == 'Q'; }
  ok = ok && is("PQqp");
  clear();

  { T a('A'), b('B'); (void)a; (void)b; }
  ok = ok && is("ABba");
  clear();

  { T arr[3]; ok = ok && arr[2].id == '?'; }   // default constructor, index order, reverse destruction
  ok = ok && is("ttt___");
  clear();

  { T arr[2] = {T('K'), T('L')}; (void)arr; }
  ok = ok && is("KLlk");
  clear();

  take_ref(T('R'));                            // the temporary dies at the end of the statement
  ok = ok && is("Rr");
  clear();

  { const T &r = T('S'); put('.'); ok = ok && r.id == 'S'; }   // lifetime extended
  ok = ok && is("S.s");
  clear();

  { T t = make('U'); ok = ok && (t.id == 'U' || t.id == 'V'); }   // built in place, or copied (c, id + 1)
  ok = ok && (is("Uu") || is("Ucuv"));
  clear();

  int v = take(T('W'));                        // copy into the argument (id + 1 when copied)
  ok = ok && (v == 'W' || v == 'X');
  clear();

  { T t('A'); T u = t; ok = ok && u.id == 'B'; }   // copy constructor
  ok = ok && is("Acba");
  clear();

  printf("%s\n", ok ? "ok" : "bad");
  return ok ? 42 : 1;
}
