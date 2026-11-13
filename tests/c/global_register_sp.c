// EXPECT: 42
// X86-ONLY: a global register variable bound to rsp (x86-64 only)
// XFAIL-qbe: cproc has no global register variables (it takes `current_stack_pointer` for an ordinary global that nothing defines)
// The kernel's `register unsigned long current_stack_pointer asm("rsp")` (arch/x86/include/asm/asm.h): the variable is the stack
// pointer register itself, not an object, so a read is rsp, no symbol is defined or referenced, and the "+r" operand of
// ASM_CALL_CONSTRAINT only orders the asm after the frame is set up.
register unsigned long current_stack_pointer asm("rsp");

static unsigned long sp_read(void) { return current_stack_pointer; }

static unsigned long with_constraint(unsigned long x)
{
	asm volatile("" : "+r"(current_stack_pointer) : : "memory");
	return x + 1;
}

int main(void)
{
	char here[64];
	unsigned long a = (unsigned long)here, sp = current_stack_pointer, sp2 = sp_read();
	/* the stack pointer of main is just below its locals; sp_read's is below main's */
	if (sp > a || a - sp > 4096) return 1;
	if (sp2 > sp || sp - sp2 > 4096) return 2;
	if (with_constraint(41) != 42) return 3;
	if ((sp & 7) != 0) return 4;   /* a stack pointer is aligned */
	return 42;
}
