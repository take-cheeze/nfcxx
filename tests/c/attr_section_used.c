// EXPECT: 42
// ELF-ONLY: an ELF section name (Mach-O wants segment,section)
// GNU section and used: two static entries nothing references are kept (used) in a named section, which the linker
// delimits with __start_/__stop_ symbols -- the shape of the kernel's initcall tables (docs/notes/cproc-nfcxx.md)
struct entry { int v; };
static const struct entry a __attribute__((used, section("nfcxx_tab"))) = { 40 };
static const struct entry b __attribute__((__used__)) __attribute__((__section__("nfcxx" "_tab"))) = { 2 };
extern const struct entry __start_nfcxx_tab[], __stop_nfcxx_tab[];
static int __attribute__((section(".text.nfcxx_init"))) sum(void) {
	int s = 0;
	for (const struct entry *e = __start_nfcxx_tab; e < __stop_nfcxx_tab; ++e)
		s += e->v;
	return s;
}
int main(void) { return sum(); }
