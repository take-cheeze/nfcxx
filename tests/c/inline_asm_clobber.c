// EXPECT: 99
// X86-ONLY: x86 inline assembly (callee-saved clobbers preserved by the thunk; docs/notes/inline-asm.md)
static long f(long a) {
	long r;
	__asm__ volatile("movq %1, %0" : "=r"(r) : "r"(a) : "r12", "r13", "rcx", "memory");
	return r;
}
int main(void) { return (int)f(99); }
