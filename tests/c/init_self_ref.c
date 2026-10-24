// EXPECT: 42
// An automatic object whose initializer takes its address in a statement expression (the kernel's
// COMPLETION_INITIALIZER_ONSTACK), and an external symbol plus an offset beyond 32 bits (the kernel's __pa_symbol(_end):
// QBE loaded it from the GOT and added the offset as an immediate, which x86 cannot encode; for a local symbol it wrote
// sym+2^31(%rip), beyond the reach of a rip-relative displacement in the kernel's link)
struct node { struct node *next, *prev; };
struct work { struct node n; int done; };
static void init(int *d) { *d = 7; }
extern char _end[];
static unsigned long __attribute__((noinline)) pa(void) { return (unsigned long)_end + 0x80000000ul; }
static char tab[64];
static unsigned long __attribute__((noinline)) pb(void) { return (unsigned long)tab + 0x80000000ul; }   /* a local symbol too */
int main(void) {
	if (pa() - (unsigned long)_end != 0x80000000ul || pb() - (unsigned long)tab != 0x80000000ul)
		return 2;
	struct work w = { { &w.n, &w.n }, (*({ init(&w.done); &w.done; })) };
	return w.n.next == &w.n && w.done == 7 ? 42 : 1;
}
