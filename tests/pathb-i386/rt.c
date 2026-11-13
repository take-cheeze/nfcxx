/* The runtime of tests/pathb-i386: built by gcc -m32 (with -mregparm=3 for the regparm run), linked with a case that Path B built.
   A static 32-bit program with no libc: _start calls pb_main and exits with its value, int $0x80 is the system call
   interface (the 32-bit one runs on an x86-64 Linux kernel with IA32 emulation). The output helpers are called from the case. */
typedef unsigned long long u64;
typedef unsigned int u32;

__asm__(".globl _start\n"
        "_start:\n"
        "\tcall pb_main\n"
        "\tmovl %eax, %ebx\n"
        "\tmovl $1, %eax\n"
        "\tint $0x80\n");

static long sys3(long n, long a, long b, long c)
{
	long r;
	__asm__ volatile("int $0x80" : "=a"(r) : "0"(n), "b"(a), "c"(b), "d"(c) : "memory");
	return r;
}

void pb_puts(const char *s)
{
	unsigned n = 0;
	while (s[n]) n++;
	sys3(4, 1, (long)s, n);
}

void pb_putu(unsigned long v)
{
	char b[16];
	int i = 15;
	b[i] = '\n';
	do { b[--i] = '0' + v % 10; v /= 10; } while (v);
	sys3(4, 1, (long)(b + i), 16 - i);
}

void pb_putll(unsigned long long v)
{
	pb_putu((unsigned long)(v >> 32));
	pb_putu((unsigned long)v);
}

/* 64-bit division, the libgcc entry points both gcc and QBE call: written with shifts and subtractions, so that this file calls none of them. */
static u64 udivmod(u64 n, u64 d, u64 *rem)
{
	u64 q = 0, r = 0;
	int i;
	for (i = 63; i >= 0; i--) {
		r = (r << 1) | ((n >> i) & 1);
		if (r >= d) { r -= d; q |= (u64)1 << i; }
	}
	if (rem) *rem = r;
	return q;
}

u64 __udivdi3(u64 n, u64 d) { return udivmod(n, d, 0); }
u64 __umoddi3(u64 n, u64 d) { u64 r; udivmod(n, d, &r); return r; }
long long __divdi3(long long n, long long d)
{
	int neg = (n < 0) != (d < 0);
	u64 q = udivmod(n < 0 ? -(u64)n : (u64)n, d < 0 ? -(u64)d : (u64)d, 0);
	return neg ? -(long long)q : (long long)q;
}
long long __moddi3(long long n, long long d)
{
	u64 r;
	udivmod(n < 0 ? -(u64)n : (u64)n, d < 0 ? -(u64)d : (u64)d, &r);
	return n < 0 ? -(long long)r : (long long)r;
}

/* The C library's block functions, which the compilers call for copies and clears. */
void *memcpy(void *d, const void *s, unsigned n)
{
	unsigned char *a = d;
	const unsigned char *b = s;
	while (n--) *a++ = *b++;
	return d;
}

void *memmove(void *d, const void *s, unsigned n)
{
	unsigned char *a = d;
	const unsigned char *b = s;
	if (a < b) while (n--) *a++ = *b++;
	else { a += n; b += n; while (n--) *--a = *--b; }
	return d;
}

void *memset(void *d, int c, unsigned n)
{
	unsigned char *a = d;
	while (n--) *a++ = (unsigned char)c;
	return d;
}
