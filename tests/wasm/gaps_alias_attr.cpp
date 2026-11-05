// Path B: GNU alias and weakref attributes. QBE has no aliases, so (alias NAME TARGET function|object [weak]) becomes
// a `.set` (with .globl or .weak and the symbol type) that the assembly step appends, the way COMDAT linkage becomes
// .weak. A weakref names a weak reference to another symbol: every use goes to the target, declared weak, so an undefined
// target reads as a null address.
// EXPECT: 0
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

extern "C" {
int target(int x) { return x + 1; }
int alias_fn(int) __attribute__((alias("target")));


int gv = 5;
extern int gv_alias __attribute__((alias("gv")));
extern int gv_alias2 __attribute__((alias("gv")));

int weak_alias(int) __attribute__((weak, alias("target")));

extern int ext_missing(int) __attribute__((weak));
static int wr(int) __attribute__((weakref("ext_missing")));

extern int pathb_present(int) __attribute__((weak));
int pathb_present(int x) { return x - 100; }
static int wr_present(int) __attribute__((weakref("pathb_present")));

extern int missing_data __attribute__((weak));
static int wd __attribute__((weakref("missing_data")));
}

int main() {
  CHECK(alias_fn(1) == 2);
  CHECK(target(9) == 10);
  CHECK(gv_alias == 5);
  gv = 8;
  CHECK(gv_alias == 8 && gv_alias2 == 8);
  gv_alias = 11;
  CHECK(gv == 11);
  CHECK(weak_alias(3) == 4);
  CHECK(wr == nullptr);        // the target is not defined anywhere
  CHECK(wr_present != nullptr && wr_present(101) == 1);
  CHECK(&wd == nullptr);
  int (*f)(int) = alias_fn;
  CHECK(f(4) == 5);
  return bad;
}
