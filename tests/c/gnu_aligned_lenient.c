// EXPECT: 42
// GNU aligned on an object is its alignment, even below its type's (the kernel's DEFINE_PER_CPU_PAGE_ALIGNED, 4096, of
// the 16 KiB-aligned struct irq_stack), as gcc lays it out; on a function up to 16 (__function_aligned) it holds; and
// its argument may name a block-scope constant (blake2s-selftest's enum { TEST_ALIGNMENT = 16 })
struct stack { char bytes[64]; } __attribute__((aligned(16384)));
struct stack __attribute__((aligned(4096))) backing;
static struct stack __attribute__((aligned(64))) other;
struct stack big;
#ifdef __x86_64__   /* cproc takes aligned on a function only where QBE aligns every function to 16 (x86-64) */
__attribute__((aligned(16))) int fn(void) { return 40; }
#else
int fn(void) { return 40; }
#endif
static int local(void) {
	enum { TEST_ALIGNMENT = 32 };
	unsigned char blocks[100] __attribute__((aligned(TEST_ALIGNMENT)));
	blocks[0] = 1;
	return (unsigned long)blocks % TEST_ALIGNMENT == 0 && _Alignof(blocks) == TEST_ALIGNMENT;
}
int main(void) {
	if (!local()) return 3;
	_Static_assert(_Alignof(struct stack) == 16384, "type alignment");
	_Static_assert(_Alignof(backing) == 4096 && _Alignof(other) == 64 && _Alignof(big) == 16384, "object alignment");
	if ((unsigned long)&backing % 4096 || (unsigned long)&other % 64 || (unsigned long)&big % 16384) return 1;
#ifdef __x86_64__
	if ((unsigned long)fn % 16) return 2;
#endif
	other.bytes[0] = 2;
	return fn() + other.bytes[0];
}
