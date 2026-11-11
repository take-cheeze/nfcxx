// EXPECT: 42
// X86-ONLY: x86 flag outputs (=@ccCOND, __GCC_ASM_FLAG_OUTPUTS__): the kernel's test_bit and dec_and_test shapes (docs/notes/inline-asm.md)
static int test_bit(long nr, const unsigned long *addr) {
	_Bool oldbit;
	__asm__ volatile("btq %2, %1" : "=@ccc"(oldbit) : "m"(*addr), "Ir"(nr) : "memory");
	return oldbit;
}
static int dec_and_test(int *v) {
	_Bool zero;
	__asm__ volatile("lock decl %0" : "+m"(*v), "=@cce"(zero) : : "memory");
	return zero;
}
static int below(unsigned a, unsigned b) { int r; __asm__("cmpl %2, %1" : "=@ccb"(r) : "r"(a), "r"(b)); return r; }
int main(void) {
	unsigned long w = 1UL << 9 | 1UL << 40;
	if (test_bit(9, &w) != 1 || test_bit(10, &w) != 0 || test_bit(40, &w) != 1) return 1;
	int c = 2; if (dec_and_test(&c) != 0 || dec_and_test(&c) != 1) return 2;
	if (below(3, 5) != 1 || below(5, 3) != 0) return 3;
	return 42;
}
