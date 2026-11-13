/* Inline asm on the 32-bit target: each template becomes a helper (scripts/pathb-ssa-qbe.rb, asm_block32) that the code calls with a
   block of its operands. Fixed registers, tied operands, memory operands, byte operands, an immediate, a flag output, a
   clobber, and a string instruction with registers in and out. */
extern void pb_putu(unsigned long v);

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;

static inline u32 bswap(u32 x)
{
	asm("bswap %0" : "+r"(x));
	return x;
}

static inline u32 add3(u32 a, u32 b)
{
	u32 r;
	asm("leal (%1,%2,2), %0" : "=r"(r) : "r"(a), "r"(b));
	return r;
}

static inline void mul64(u32 a, u32 b, u32 *lo, u32 *hi)
{
	u32 l, h;
	asm("mull %3" : "=a"(l), "=d"(h) : "0"(a), "rm"(b));
	*lo = l;
	*hi = h;
}

static inline u8 rd8(const u8 *p)
{
	u8 v;
	asm volatile("movb %1, %0" : "=q"(v) : "m"(*p));
	return v;
}

static inline void wr16(u16 *p, u16 v)
{
	asm volatile("movw %1, %0" : "=m"(*p) : "ri"(v));
}

static inline u32 shl3(u32 x)
{
	asm("shll %1, %0" : "+r"(x) : "I"(3));
	return x;
}

static inline int less(int a, int b)
{
	int r;
	asm("cmpl %2, %1" : "=@ccl"(r) : "r"(a), "r"(b));
	return r;
}

static inline void fill8(void *p, u8 v, u32 n)
{
	asm volatile("rep; stosb" : "+D"(p), "+c"(n) : "a"(v) : "memory");
}

static inline u32 swap_regs(u32 a, u32 b)
{
	asm("xchgl %%ebx, %%ecx" : "+b"(a), "+c"(b));
	return a * 100 + b;
}

static inline u32 clobbering(u32 x)
{
	u32 r;
	asm("movl %1, %%edx\n\taddl %%edx, %%edx\n\tmovl %%edx, %0" : "=r"(r) : "r"(x) : "edx", "cc");
	return r;
}

static inline void barrier(void)
{
	asm volatile("" ::: "memory");
}

int pb_main(void)
{
	u8 buf[16] = { 1, 2, 3, 4 };
	u16 h = 0;
	u32 lo, hi;

	pb_putu(bswap(0x11223344));
	pb_putu(add3(5, 7));
	mul64(0xfffffff1u, 12345, &lo, &hi);
	pb_putu(lo);
	pb_putu(hi);
	pb_putu(rd8(buf + 2));
	wr16(&h, 0xbeef);
	pb_putu(h);
	pb_putu(shl3(21));
	pb_putu((unsigned long)(less(1, 2) * 10 + less(2, 1)));
	fill8(buf + 4, 0x5a, 8);
	barrier();
	pb_putu(buf[3] * 10000u + buf[4] * 100u + buf[11]);
	pb_putu(buf[12]);
	pb_putu(swap_regs(7, 9));
	pb_putu(clobbering(21));
	return (int)(lo & 0x7f);
}
