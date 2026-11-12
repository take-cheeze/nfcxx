// EXPECT: 42
// X86-ONLY: x86-64 inline asm
// Register operands of an asm that clobbers every caller-saved register (the kernel's call_on_stack(), which calls a
// function from the asm): the operands go to callee-saved registers, which the thunk preserves -- the caller's values
// in them survive, and so do the operands across the call the template makes
__attribute__((noinline)) long twice(long v) { return 2 * v; }
static long sum(long a, long b, long c) {
	long r;
	__asm__ volatile("movq %[a], %%rdi\n\tcall twice\n\tmovq %%rax, %[r]\n\taddq %[b], %[r]\n\taddq %[c], %[r]"
		: [r] "=&r"(r) : [a] "r"(a), [b] "r"(b), [c] "r"(c)
		: "rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "memory", "cc");
	return r;
}
int main(void) {
	volatile long s1 = 3, s2 = 5, s3 = 7, s4 = 11, s5 = 13;
	long k1 = s1, k2 = s2, k3 = s3, k4 = s4, k5 = s5;   /* live across the asm: in callee-saved registers */
	long r = sum(k1, k2, k3);   /* 2*3 + 5 + 7 = 18 */
	r += sum(k4, k5, 1);        /* 2*11 + 13 + 1 = 36 */
	if (r != 54) return 1;
	if (k1 + k2 + k3 + k4 + k5 != 39) return 2;
	return 42;
}
