// EXPECT: 0
// Weak symbols across translation units. This unit defines hook() and weak_val weakly and declares provided() and
// provided_val weak; b.cpp overrides hook() and weak_val with strong definitions, and defines provided() and
// provided_val. optional_fn() and optional_val are defined nowhere: they stay null. The exit code is the number of
// wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

extern "C" {
int hook(int) __attribute__((weak));
int hook(int x) { return x + 1; }                 // overridden by b.cpp
int only_here(int) __attribute__((weak));
int only_here(int x) { return x * 3; }            // not overridden
int weak_val __attribute__((weak)) = 1;           // overridden by b.cpp
int only_val __attribute__((weak)) = 5;

int provided(int) __attribute__((weak));
extern int provided_val __attribute__((weak));
int optional_fn(void) __attribute__((weak));
extern int optional_val __attribute__((weak));
}

int call_hook_in_b();                             // calls hook() from b.cpp

int main() {
  CHECK(hook(1) == 100);                          // b.cpp's definition wins
  CHECK(call_hook_in_b() == 100);
  CHECK(only_here(2) == 6);
  CHECK(weak_val == 7);
  CHECK(only_val == 5);
  CHECK(provided != 0 && provided(4) == 8);
  CHECK(&provided_val != 0 && provided_val == 33);
  CHECK(optional_fn == 0);
  CHECK(&optional_val == 0);
  return bad;
}
