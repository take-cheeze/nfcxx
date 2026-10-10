// Path B: a weakref without a target name (__attribute__((weakref, alias("t")))) and an ifunc symbol (__attribute__((ifunc
// ("resolver")))). A weakref names the target of its alias, declared weak: every use goes to the target, so an undefined
// target reads as a null address (alias_attr.cpp). An ifunc is a symbol of type STT_GNU_IFUNC whose value is what the
// resolver returns: a call goes to the function the resolver chose (the same for every call of the program).
// The gcc backend is compared too: its C output keeps both attributes.
// EXPECT: 0
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

extern "C" {
int target_fn(int x) { return x + 1; }
static int wr_noarg(int) __attribute__((weakref, alias("target_fn")));

int impl_fast(int x) { return x * 2; }
int impl_slow(int x) { return x * 3; }
static int (*resolve_it(void))(int) { return impl_fast; }
int ifn(int) __attribute__((ifunc("resolve_it")));
}

int main() {
  CHECK(wr_noarg(4) == 5);
  CHECK((void *)wr_noarg == (void *)target_fn);
  CHECK(ifn(7) == 14);
  return bad;
}
