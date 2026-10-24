// EXPECT: 42
// GNU weak (a definition, and a declaration whose symbol may be absent), alias (the kernel's SYSCALL_DEFINE stubs: a
// global alias of a static function; and of an object), and visibility("hidden"); tests/c/cc-mode.sh compares the
// symbol table with gcc's
__attribute__((weak)) int maybe_defined(void) { return 1; }
extern int never_defined(void) __attribute__((weak));
extern int unused_weak(void) __attribute__((weak));
static long do_sys(long x) { return x + 1; }
long sys_entry(long x) __attribute__((alias("do_sys")));
__attribute__((visibility("hidden"))) int hidden_one(void) { return 3; }
int tab[2] = { 5, 6 };
extern int tab_alias[2] __attribute__((alias("tab")));
int main(void) {
	if (never_defined) return 1;
	return maybe_defined() + sys_entry(37) + hidden_one() == 42 && tab_alias[1] == 6 ? 42 : 2;
}
