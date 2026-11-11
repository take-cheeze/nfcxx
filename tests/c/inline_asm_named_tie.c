// EXPECT: 42
// X86-ONLY: x86 inline asm: an input tied to an output by name ("[sum]"), and basic asm (no operands), whose text is
// not substituted (the kernel's io_delay: asm volatile("outb %al, $0x80"))
static long add3(long a, long b) { long sum; __asm__("leaq (%[a],%[b]), %[sum]\n\taddq $3, %[sum]" : [sum] "=r"(sum) : "[sum]"(0L), [a] "r"(a), [b] "r"(b)); return sum; }
static long tied(long rest, long x) { long sum; __asm__("addq %[x], %[sum]" : [sum] "=r"(sum) : "[sum]"(rest), [x] "r"(x)); return sum; }
int main(void) {
	__asm__ volatile("nop # 100% literal: %al stays");
	__asm__ volatile("" ::: "memory");
	return add3(10, 20) == 33 && tied(30, 12) == 42 ? 42 : 1;
}
