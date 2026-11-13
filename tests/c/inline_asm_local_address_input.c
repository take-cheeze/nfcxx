// EXPECT: 17
// X86-ONLY: x86 inline asm whose template no class knows (the general asm block) with the address of a local as an input
// The kernel's int3_selftest: `asm volatile("int3_selftest_ip: ..." : ASM_CALL_CONSTRAINT : "D" (&val) : "memory")`. The
// address of a local is a slot name in the IR, not a typed value: Path B refused the function ("operand $val has no
// declared type").
struct pair { unsigned int a, b; };

__attribute__((noinline)) static unsigned int run(void)
{
	unsigned int val = 0;
	struct pair p = { 0, 0 };

	__asm__ volatile("movl $1, (%%rdi)\n\t"
			 "nop; nop"
			 : : "D" (&val) : "memory");
	__asm__ volatile("movl $7, (%0)\n\t"
			 "movl $9, 4(%0)\n\t"
			 "nop"
			 : : "r" (&p) : "memory");
	return val + p.a + p.b;
}

int main(void)
{
	return (int)run();
}
