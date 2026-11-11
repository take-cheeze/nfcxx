// EXPECT: 42
// X86-ONLY: x86 asm goto (thunk label stubs; docs/notes/inline-asm.md): a patchable nop with a jump-table entry, patched at
// run time into a jmp to its label as the kernel's jump_label code does, conditional jumps to labels, %lN, outputs
struct static_key { int enabled; };
struct static_key key_on = { 1 }, key_off = { 0 };
struct jump_entry { int code, target; long key; };
extern struct jump_entry __start_jt[], __stop_jt[];
/* a macro, not the kernel's always_inline function: cproc does not inline, and "i" needs the key's address */
#define arch_static_branch(key, branch) ({ \
	int r_ = 0; \
	__asm__ goto("1: .byte 0x0f,0x1f,0x44,0x00,0x00\n\t" \
		 ".pushsection jt, \"aw\"\n\t" \
		 ".balign 8\n\t" \
		 ".long 1b - ., %l[l_yes] - .\n\t" \
		 ".quad %c0 + %c1 - .\n\t" \
		 ".popsection\n\t" \
		 : : "i"(key), "i"(branch) : : l_yes); \
	if (0) { l_yes: r_ = 1; } \
	r_; })
static int on_branch(void) { return arch_static_branch(&key_on, 0); }
static int off_branch(void) { return arch_static_branch(&key_off, 0); }
static int below(long a, long b)
{
	__asm__ goto("cmpq %1, %0\n\tjl %l[yes]" : : "r"(a), "r"(b) : "cc" : yes);
	return 0;
yes:
	return 1;
}
static int pick(int x)
{
	__asm__ goto("testl %0, %0\n\tjz %l2\n\tcmpl $5, %0\n\tje %l[five]" : : "r"(x), "i"(0) : "cc" : zero, five);
	return 1;
zero:
	return 0;
five:
	return 5;
}
static int outgoto(int x)
{
	int r;
	__asm__ goto("movl %1, %0\n\taddl $1, %0\n\tcmpl $10, %0\n\tjge %l[big]" : "=r"(r) : "r"(x) : "cc" : big);
	return r;
big:
	return -r;
}
/* the kernel's jump_label patching, by hand: turn the nop at each entry into a jmp to its target */
#include <sys/mman.h>
#include <unistd.h>
static void patch_all(void)
{
	for (struct jump_entry *e = __start_jt; e < __stop_jt; ++e) {
		unsigned char *code = (unsigned char *)&e->code + e->code, *target = (unsigned char *)&e->target + e->target;
		struct static_key *k = (struct static_key *)(((long)&e->key + e->key) & ~1L);
		if (!k->enabled)
			continue;
		long pg = sysconf(_SC_PAGESIZE);
		mprotect((void *)((long)code & -pg), 2 * pg, PROT_READ | PROT_WRITE | PROT_EXEC);
		int rel = target - (code + 5);
		code[0] = 0xe9; __builtin_memcpy(code + 1, &rel, 4);
	}
}
int main(void)
{
	if (on_branch() || off_branch()) return 1;   /* unpatched: nops */
	patch_all();
	if (!on_branch() || off_branch()) return 2;   /* patched: key_on jumps */
	if (!below(1, 2) || below(3, 2)) return 3;
	if (pick(0) != 0 || pick(5) != 5 || pick(7) != 1) return 4;
	if (outgoto(3) != 4 || outgoto(20) != -21) return 5;
	return 42;
}
