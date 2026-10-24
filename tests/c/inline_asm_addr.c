// EXPECT: 42
// X86-ONLY: x86 inline assembly (the "p" address constraint and the %a modifier in thunks; docs/notes/inline-asm.md)
// The kernel's this_cpu_read_stable: "p"(&var.member) with %a (rip-relative) and %P (bare), and "p" on a pointer that is not constant
struct hot { long pad; long cur; };
static struct hot pcpu_hot = { 1, 30 };
static long arr[4] = { 1, 2, 5, 4 };
static long read_stable(void) { long v; __asm__("movq %a1, %0" : "=r"(v) : "p"(&pcpu_hot.cur)); return v; }
static long addr_bare(void) { long *p; __asm__("leaq %P1(%%rip), %0" : "=r"(p) : "p"(&arr[2])); return *p; }
static long via_reg(long *q) { long v; __asm__("movq %a1, %0" : "=r"(v) : "p"(q + 1)); return v; }
static long imm_off(void) { long v; __asm__("movq %c1(%%rip), %0" : "=r"(v) : "i"(&arr[3])); return v; }
int main(void) {
	if (read_stable() != 30) return 1;
	if (addr_bare() != 5) return 2;
	if (via_reg(arr) != 2) return 3;
	if (imm_off() != 4) return 4;
	return 42;
}
