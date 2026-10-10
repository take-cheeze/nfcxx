// EXPECT: 0
// __attribute__((weak)) declarations: the IR carries (declare "f" (weak)) for an undefined weak function and
// (global ... (weak) (extern)) for an undefined weak object; the emitter references them through the GOT and marks
// them .weak, so an absent definition reads as a null address (a PIE links, too). A weak definition is an interface
// symbol (pruning keeps it) and is marked .weak. The exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

extern "C" {
int absent_fn(int) __attribute__((weak));
extern int absent_data __attribute__((weak));
extern int absent_array[4] __attribute__((weak));
void absent_void(void) __attribute__((weak));
int weak_def_fn(int x) __attribute__((weak));
int weak_def_fn(int x) { return x + 1; }
int weak_def_data __attribute__((weak)) = 41;
// defined by the C library or the runtime; a weak declaration of an existing symbol is an ordinary reference
extern void abort(void) __attribute__((weak));
}

typedef int (*fn_t)(int);
static fn_t table[] = {absent_fn, weak_def_fn};

int main() {
  CHECK(absent_fn == 0);
  CHECK(&absent_data == 0);
  CHECK(&absent_array[0] == 0);
  CHECK(absent_void == 0);
  CHECK(!absent_fn);
  CHECK(weak_def_fn != 0);
  CHECK(weak_def_fn(1) == 2);
  CHECK(weak_def_data == 41);
  CHECK(abort != 0);
  CHECK(table[0] == 0 && table[1] != 0 && table[1](5) == 6);
  int r = 0;
  if (absent_fn) r = absent_fn(3);          // not taken: the symbol is absent
  CHECK(r == 0);
  if (&absent_data) r = absent_data;        // likewise
  CHECK(r == 0);
  fn_t f = absent_fn;
  CHECK(f == 0);
  f = weak_def_fn;
  CHECK(f != 0 && f(9) == 10);
  return bad;
}
