// EXPECT: 32
// X86-ONLY: x86 inline assembly (fixed registers eax/edx; docs/notes/inline-asm.md)
static unsigned divmod(unsigned a, unsigned b) {
	unsigned q, r;
	/* edx:eax / b: seed edx=0 as an input so no register is written before it is read */
	__asm__("divl %4" : "=a"(q), "=d"(r) : "a"(a), "d"(0u), "r"(b) : "cc");
	return q * 10 + r;
}
int main(void) { return (int)divmod(17, 5); }   /* 17/5 = 3 rem 2 -> 32 */
