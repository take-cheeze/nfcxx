// Path B: an alias of a static function or object keeps its target even though nothing else refers to it (the alias is an
// exported symbol, the target is internal). The gcc back end cannot do this: the generated C names the static function by
// a mangled name that the alias attribute no longer matches, so only EXPECT is checked.
// EXPECT: 0
// GCC: undefined
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

extern "C" {
static int hidden(int x) { return x * 3; }
int alias_hidden(int) __attribute__((alias("hidden")));

static int hidden_data = 21;
extern int alias_data __attribute__((alias("hidden_data")));
}

int main() {
  CHECK(alias_hidden(2) == 6);
  CHECK(alias_data == 21);
  alias_data = 4;
  CHECK(hidden_data == 4);
  return bad;
}
