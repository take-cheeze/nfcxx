// EXPECT: 42
// X86-ONLY: x86 inline asm: an input tied to a narrower output keeps all its bits in the register (the kernel's put_user
// ties its user pointer to an int output, "=c"(ret) : "0"(ptr); cproc loaded 4 bytes, and exec failed with EFAULT)
/* a tied input wider than its output (the kernel's put_user: "=c"(int ret) : "0"(pointer)) keeps all its bits */
static int high_bits(void *p) {
	int r;
	__asm__("shrq $32, %%rcx" : "=c"(r) : "0"(p));
	return r;
}
int main(void) { return high_bits((void *)0x0000002a00000000ul) == 42 ? 42 : 1; }
