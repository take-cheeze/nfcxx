// EXPECT: 5
// X86-ONLY: x86 asm goto with "i" operands that depend on the parameter of an __always_inline function (the kernel's _static_cpu_has)
// XFAIL-qbe: cproc does not inline, and an "i" operand of a parameter is not a constant in the function itself
// Path B (NFCXX_BACKEND=pathb) inlines the function and folds the operands: the bit number to an immediate, the address of
// `((const char *)boot.w)[bit >> 3]` (an offset into a global, then an index by a folded value) to a symbol and an offset.
struct caps { int pad; unsigned int w[4]; };
struct caps boot = { 0, { 0, 0x20, 0, 0x100 } };

static inline __attribute__((always_inline)) int has(unsigned short bit)
{
	__asm__ goto("testb %[bitnum], %P[cap_byte](%%rip)\n\t"
		     "jnz %l[yes]"
		     : : [bitnum] "i" (1 << (bit & 7)),
			 [cap_byte] "i" (&((const char *)boot.w)[bit >> 3])
		     : "cc" : yes);
	return 0;
yes:
	return 1;
}

int main(void)
{
	/* bit 37 is word 1 bit 5, bit 104 is word 3 bit 8, bit 38 is clear */
	return has(37) | has(38) << 1 | has(104) << 2;
}
