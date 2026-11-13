// EXPECT: 11
// X86-ONLY: x86 asm goto with "i" operands that depend on the parameter of a large __always_inline function
// XFAIL-qbe: cproc does not inline, and an "i" operand of a parameter is not a constant in the function itself
// The callee is far over Path B's inlining cap (--max-callee) and the module grows past its budget (--max-growth): a function
// whose asm has an "i" operand of its parameter cannot be emitted alone, so it is inlined whatever its size.
unsigned int word = 0x20;
int counter;
__attribute__((noinline)) void touch(int n) { counter += n; }

static inline __attribute__((always_inline)) int has_big(unsigned short bit)
{
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	touch(1);
	__asm__ goto("testb %[bitnum], %P[cap_byte](%%rip)\n\t"
		     "jnz %l[yes]"
		     : : [bitnum] "i" (1 << (bit & 7)),
			 [cap_byte] "i" (&((const char *)&word)[bit >> 3])
		     : "cc" : yes);
	return 0;
yes:
	return 1;
}

int main(void)
{
	/* bit 5 is set, bit 6 is clear; 45 touches per call */
	int r = has_big(5) | has_big(6) << 1;
	return r + (counter == 90 ? 10 : 0);
}
