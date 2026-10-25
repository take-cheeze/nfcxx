// EXPECT: 42
// X86-ONLY-qbe: cproc lowers __builtin_return_address and __builtin_frame_address with x86-64 helpers and refuses them elsewhere
// __builtin_return_address(0) and __builtin_frame_address(0) (the kernel's _RET_IP_), and __builtin_offsetof with an
// index that is not constant (its container_of(node, struct latch_tree_node, node[idx]))
struct node { int x; };
struct latch { int pad[3]; struct node node[2]; };
static void *seen;
__attribute__((noinline)) static void *whoami(void) { return __builtin_return_address(0); }
__attribute__((noinline)) static void *frame(void) { return __builtin_frame_address(0); }
__attribute__((noinline)) static void caller(void) { seen = whoami(); __asm__ volatile("" ::: "memory"); }
static struct latch *from(struct node *n, int idx) { return (struct latch *)((char *)n - __builtin_offsetof(struct latch, node[idx])); }
int main(void) {
	struct latch l;
	if (from(&l.node[1], 1) != &l || from(&l.node[0], 0) != &l) return 1;
	_Static_assert(__builtin_offsetof(struct latch, node[1].x) == 16, "constant offsetof");
	caller();
	char *ra = seen;   /* the return address is inside caller(), just after its call of whoami */
	if (ra <= (char *)caller || ra > (char *)caller + 64) return 2;
	char *fp = frame(), *sp = __builtin_frame_address(0);
	if (!fp || !sp || fp >= sp || sp - fp > 4096) return 3;   /* frame()'s frame is below main's */
	return 42;
}
