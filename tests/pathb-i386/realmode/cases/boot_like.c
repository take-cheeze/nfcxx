/* A case for tests/pathb-i386/realmode.sh: code in the style of the kernel's boot code (arch/x86/boot), run in real mode under qemu.
   Segment registers and %fs-relative accesses, port I/O, a BIOS interrupt through an asm template, the BIOS data area, structures,
   strings, long long arithmetic (the 64-bit division is a call of the libgcc function, written in rt16.c), a table of function
   pointers and a switch. It writes its results to the debug console; the run is compared with the same code built by gcc -m16. */
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef unsigned int addr_t;

extern void pb_putc(char c);
extern void *memcpy(void *d, const void *s, unsigned n);
extern void *memset(void *d, int c, unsigned n);

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

/* the BIOS: int $0x12 returns the size of the conventional memory in KB in %ax */
static u16 bios_mem_kb(void)
{
	u16 kb;
	asm volatile("int $0x12" : "=a"(kb) : : "cc", "memory");
	return kb;
}

static void putu(u32 v)
{
	char b[12];
	int i = 0;
	do {
		b[i++] = (char)('0' + v % 10);
		v /= 10;
	} while (v);
	while (i)
		pb_putc(b[--i]);
	pb_putc('\n');
}

static void puts_(const char *s)
{
	while (*s)
		pb_putc(*s++);
	pb_putc('\n');
}

struct node {
	u16 tag;
	u32 value;
	struct node *next;
};

static struct node pool[4];

static u32 sum_list(const struct node *n)
{
	u32 s = 0;
	for (; n; n = n->next)
		s += n->value * n->tag;
	return s;
}

static int op_add(int a, int b) { return a + b; }
static int op_sub(int a, int b) { return a - b; }
static int op_mul(int a, int b) { return a * b; }

static int (*const ops[3])(int, int) = { op_add, op_sub, op_mul };

static int kind(u16 c)
{
	switch (c) {
	case 0x0e: return 1;
	case 0x1c: return 2;
	case 0x39: return 3;
	case 0x48: return 4;
	case 0x50: return 5;
	case 0x4b: return 6;
	default: return 0;
	}
}

static u64 collatz(u64 n)
{
	u64 steps = 0;
	while (n != 1) {
		n = (n & 1) ? 3 * n + 1 : n / 2;
		steps++;
	}
	return steps;
}

int pb_main(void)
{
	char buf[16];
	u32 i;

	set_fs(0x40);                      /* the BIOS data area: 0040:0013 is the memory size in KB */
	putu(rdfs16(0x13));
	putu(bios_mem_kb());
	putu(*(volatile u16 *)0x413);       /* the same, through ds = 0 and a volatile access */
	putu(ds());
	putu(rdfs8(0x13) + 256u * rdfs8(0x14));
	wrfs32(0xcafe1234, 0x300);          /* 0040:0300 is free memory */
	putu(rdfs16(0x302));
	putu(inb(0x64) & 0x20);              /* the keyboard controller's status: no mouse data */
	outb(0x00, 0x80);                    /* the POST code port: a harmless write */

	memset(pool, 0, sizeof pool);
	for (i = 0; i < 4; i++) {
		pool[i].tag = (u16)(i + 1);
		pool[i].value = 1000u * (i + 1);
		pool[i].next = i < 3 ? &pool[i + 1] : 0;
	}
	putu(sum_list(pool));

	memcpy(buf, "real mode", 10);
	puts_(buf);
	buf[0] = 'R';
	puts_(buf);

	for (i = 0; i < 3; i++)
		putu((u32)ops[i]((int)i + 7, 3));
	for (i = 0; i < 6; i++)
		putu((u32)kind((u16)(i == 0 ? 0x0e : i == 1 ? 0x1c : i == 2 ? 0x39 : i == 3 ? 0x48 : i == 4 ? 0x50 : 0x4b)));
	putu((u32)collatz(27));
	putu((u32)(0x123456789abcdefULL / 1000003ULL));
	putu((u32)(0x123456789abcdefULL % 1000003ULL));
	return (int)(sum_list(pool) & 0x3f);
}
