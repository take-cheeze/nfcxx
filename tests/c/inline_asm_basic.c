// EXPECT: 42
// X86-ONLY: x86 inline assembly (lowered to thunks on the qbe backend; docs/notes/inline-asm.md)
static long add(long a, long b) { long r; __asm__("addq %2, %0" : "=r"(r) : "0"(a), "r"(b)); return r; }
static int inc(int x) { __asm__ volatile("incl %0" : "+r"(x)); return x; }
static long imm(long a) { long r; __asm__("leaq %c1(%2), %0" : "=r"(r) : "i"(40), "r"(a)); return r; }
static int named(int a, int b) { int r; __asm__("addl %[y], %[x]" : [x]"=r"(r) : "0"(a), [y]"r"(b)); return r; }
int main(void) {
	if (add(3, 4) != 7) return 1;
	if (inc(41) != 42) return 2;
	if (imm(2) != 42) return 3;
	if (named(40, 2) != 42) return 4;
	return 42;
}
