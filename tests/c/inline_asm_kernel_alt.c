// EXPECT: 42
// X86-ONLY: x86-64 inline asm (asm goto, verw, wrmsr, rdfsbase) and the alternatives sections
// XFAIL-qbe: cproc does not inline, so the "i" operands that depend on the parameter `bit` are not constants there (the kernel mode clones always_inline functions for constant arguments; the plain driver does not). Path B inlines and folds them: tests/nfcc/run.sh builds this file with NFCXX_BACKEND=pathb and compares its exit code with gcc's
// The kernel's alternatives macros (arch/x86/include/asm/alternative.h, cpufeature.h, nospec-branch.h, fsgsbase.h):
// static_cpu_has' asm goto whose "i" operands are constants only after the always_inline function is inlined (1
// << (bit & 7), &caps[bit >> 3]), a "m" operand of a static const object, an empty/alternative template with "c"
// "a" "d" inputs and a memory clobber, a "=r" output with a memory clobber. The alternatives' patching is not
// done (the section entries are only data), so the unpatched code runs: jmp 6f to the test.
#include <stdint.h>
#include <sys/auxv.h>

typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef uint64_t u64;
#define ALWAYS_INLINE inline __attribute__((always_inline))
#define __stringify_1(x) #x
#define __stringify(x) __stringify_1(x)

#define b_replacement(num)	"664" #num
#define e_replacement(num)	"665" #num
#define alt_end_marker		"663"
#define alt_slen		"662b-661b"
#define alt_total_slen		alt_end_marker "b-661b"
#define alt_rlen(num)		e_replacement(num) "f-" b_replacement(num) "f"
#define OLDINSTR(oldinstr, num) \
	"# ALT: oldnstr\n" \
	"661:\n\t" oldinstr "\n662:\n" \
	"# ALT: padding\n" \
	".skip -(((" alt_rlen(num) ")-(" alt_slen ")) > 0) * " \
		"((" alt_rlen(num) ")-(" alt_slen ")),0x90\n" \
	alt_end_marker ":\n"
#define alt_max_short(a, b)	"((" a ") ^ (((" a ") ^ (" b ")) & -(-((" a ") < (" b ")))))"
#define OLDINSTR_2(oldinstr, num1, num2) \
	"# ALT: oldinstr2\n" \
	"661:\n\t" oldinstr "\n662:\n" \
	"# ALT: padding2\n" \
	".skip -((" alt_max_short(alt_rlen(num1), alt_rlen(num2)) " - (" alt_slen ")) > 0) * " \
		"(" alt_max_short(alt_rlen(num1), alt_rlen(num2)) " - (" alt_slen ")), 0x90\n" \
	alt_end_marker ":\n"
#define ALTINSTR_ENTRY(ft_flags, num) \
	" .long 661b - .\n" \
	" .long " b_replacement(num) "f - .\n" \
	" .4byte " __stringify(ft_flags) "\n" \
	" .byte " alt_total_slen "\n" \
	" .byte " alt_rlen(num) "\n"
#define ALTINSTR_REPLACEMENT(newinstr, num) \
	"# ALT: replacement " #num "\n" \
	b_replacement(num) ":\n\t" newinstr "\n" e_replacement(num) ":\n"
#define ALTERNATIVE(oldinstr, newinstr, ft_flags) \
	OLDINSTR(oldinstr, 1) \
	".pushsection .altinstructions,\"a\"\n" \
	ALTINSTR_ENTRY(ft_flags, 1) \
	".popsection\n" \
	".pushsection .altinstr_replacement, \"ax\"\n" \
	ALTINSTR_REPLACEMENT(newinstr, 1) \
	".popsection\n"
#define ALTERNATIVE_2(oldinstr, newinstr1, ft_flags1, newinstr2, ft_flags2) \
	OLDINSTR_2(oldinstr, 1, 2) \
	".pushsection .altinstructions,\"a\"\n" \
	ALTINSTR_ENTRY(ft_flags1, 1) \
	ALTINSTR_ENTRY(ft_flags2, 2) \
	".popsection\n" \
	".pushsection .altinstr_replacement, \"ax\"\n" \
	ALTINSTR_REPLACEMENT(newinstr1, 1) \
	ALTINSTR_REPLACEMENT(newinstr2, 2) \
	".popsection\n"
#define ALTERNATIVE_TERNARY(oldinstr, ft_flags, newinstr_yes, newinstr_no) \
	ALTERNATIVE_2(oldinstr, newinstr_no, X86_FEATURE_ALWAYS, newinstr_yes, ft_flags)
#define X86_FEATURE_ALWAYS (3 * 32 + 21)
#define _ASM_RIP(x) __stringify(x(%%rip))

struct cpuinfo_x86 { u32 x86_capability[20]; };
struct cpuinfo_x86 boot_cpu_data;

/* arch/x86/include/asm/cpufeature.h */
static ALWAYS_INLINE _Bool _static_cpu_has(u16 bit)
{
	__asm__ goto(
		ALTERNATIVE_TERNARY("jmp 6f", %P[feature], "", "jmp %l[t_no]")
		".pushsection .altinstr_aux,\"ax\"\n"
		"6:\n"
		" testb %[bitnum]," _ASM_RIP(%P[cap_byte]) "\n"
		" jnz %l[t_yes]\n"
		" jmp %l[t_no]\n"
		".popsection\n"
		 : : [feature]  "i" (bit),
		     [bitnum]   "i" (1 << (bit & 7)),
		     [cap_byte] "i" (&((const char *)boot_cpu_data.x86_capability)[bit >> 3])
		 : : t_yes, t_no);
t_yes:
	return 1;
t_no:
	return 0;
}
#define static_cpu_has(bit) _static_cpu_has(bit)

/* arch/x86/include/asm/nospec-branch.h */
static ALWAYS_INLINE void mds_clear_cpu_buffers(void)
{
	static const u16 ds = 0x18;
	__asm__ volatile("verw %[ds]" : : [ds] "m" (ds) : "cc");
}
static ALWAYS_INLINE void alternative_msr_write(unsigned int msr, u64 val, unsigned int feature)
{
	__asm__ volatile(ALTERNATIVE("", "wrmsr", %c[feature])
		: : "c" (msr),
		    "a" ((u32)val),
		    "d" ((u32)(val >> 32)),
		    [feature] "i" (feature)
		: "memory");
}
static void indirect_branch_prediction_barrier(void)
{
	/* the write is only in the replacement section: the unpatched code runs nops */
	alternative_msr_write(0x49, 1, 7 * 32 + 25);
}

/* arch/x86/include/asm/fsgsbase.h */
static ALWAYS_INLINE unsigned long rdfsbase(void)
{
	unsigned long fsbase;
	__asm__ volatile("rdfsbase %0" : "=r" (fsbase) :: "memory");
	return fsbase;
}

int main(void)
{
	long tcb;
	boot_cpu_data.x86_capability[0] = 1u << 5;       /* bit 5 */
	boot_cpu_data.x86_capability[1] = 1u << 3;       /* bit 32 + 3 = 35 */
	boot_cpu_data.x86_capability[2] = 0x80000000u;   /* bit 95 */
	if (!static_cpu_has(5) || static_cpu_has(4) || static_cpu_has(6)) return 1;
	if (!static_cpu_has(35) || static_cpu_has(34) || static_cpu_has(36)) return 2;
	if (!static_cpu_has(95) || static_cpu_has(94) || static_cpu_has(0)) return 3;
	mds_clear_cpu_buffers();
	indirect_branch_prediction_barrier();
	if (getauxval(AT_HWCAP2) & 2) {                  /* HWCAP2_FSGSBASE: rdfsbase is enabled */
		__asm__ volatile("movq %%fs:0, %0" : "=r" (tcb));
		if (rdfsbase() != (unsigned long)tcb) return 4;
	}
	return 42;
}
