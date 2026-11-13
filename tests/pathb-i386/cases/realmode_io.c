// NO-RUN
/* The helpers of the kernel's real-mode boot code (arch/x86/boot/boot.h, io.h): port I/O, segment registers, %fs-relative loads
   and stores, a BIOS-style call through a structure. They are privileged or real-mode instructions: this case is only built
   (as 32-bit code, and as .code16gcc code for real mode), not run. */
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned int addr_t;

struct biosregs {
	u32 edi, esi, ebp, _esp, ebx, edx, ecx, eax, _fsgs, _dses, eflags;
};

static inline void outb(u8 v, u16 port)
{
	asm volatile("outb %0,%1" : : "a"(v), "dN"(port));
}

static inline u8 inb(u16 port)
{
	u8 v;
	asm volatile("inb %1,%0" : "=a"(v) : "dN"(port));
	return v;
}

static inline void io_delay(void)
{
	const u16 DELAY_PORT = 0x80;
	asm volatile("outb %%al,%0" : : "dN"(DELAY_PORT));
}

static inline u16 ds(void)
{
	u16 seg;
	asm("movw %%ds,%0" : "=rm"(seg));
	return seg;
}

static inline void set_fs(u16 seg)
{
	asm volatile("movw %0,%%fs" : : "rm"(seg));
}

static inline u8 rdfs8(addr_t addr)
{
	u8 v;
	asm volatile("movb %%fs:%1,%0" : "=q"(v) : "m"(*(u8 *)addr));
	return v;
}

static inline u16 rdfs16(addr_t addr)
{
	u16 v;
	asm volatile("movw %%fs:%1,%0" : "=r"(v) : "m"(*(u16 *)addr));
	return v;
}

static inline void wrfs32(u32 v, addr_t addr)
{
	asm volatile("movl %1,%%fs:%0" : "+m"(*(u32 *)addr) : "ri"(v));
}

static inline int memcmp_fs(const void *s1, addr_t s2, unsigned len)
{
	u8 diff;
	asm volatile("fs; repe; cmpsb; setnz %0" : "=qm"(diff), "+D"(s1), "+S"(s2), "+c"(len));
	return diff;
}

static inline void cpuid(u32 *a, u32 *b, u32 *c, u32 *d)
{
	asm volatile("cpuid" : "=a"(*a), "=b"(*b), "=c"(*c), "=d"(*d) : "0"(*a), "2"(*c));
}

static inline int a20_ok(void)
{
	u16 a, b;
	set_fs(0x0000);
	a = rdfs16(0x0200);
	b = rdfs16(0x0210);
	return a != b;
}

static void bios_call(u8 int_no, const struct biosregs *in, struct biosregs *out)
{
	(void)int_no;
	asm volatile("pushfl; pushw %%ds; pushw %%es\n\t"
		     "int $0x10\n\t"
		     "popw %%es; popw %%ds; popfl"
		     : "=a"(out->eax), "=b"(out->ebx), "=c"(out->ecx), "=d"(out->edx)
		     : "0"(in->eax), "1"(in->ebx), "2"(in->ecx), "3"(in->edx)
		     : "esi", "edi", "memory");
}

static u32 probe(void)
{
	struct biosregs ireg = { 0 }, oreg;
	u32 a = 1, b = 0, c = 0, d = 0;

	outb(0x11, 0x20);
	io_delay();
	cpuid(&a, &b, &c, &d);
	ireg.eax = 0x0e00 | inb(0x60);
	bios_call(0x10, &ireg, &oreg);
	wrfs32(oreg.eax, 0x0500);
	return d + (u32)a20_ok() + rdfs8(0x0413) + ds() + (u32)memcmp_fs(&ireg, 0x0600, 8);
}

int pb_main(void)
{
	return (int)probe();
}
