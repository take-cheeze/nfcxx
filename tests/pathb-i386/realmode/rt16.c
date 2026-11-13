/* The C library and libgcc functions the code of tests/pathb-i386/realmode.sh calls: built by gcc -m16 (-mregparm=3), as the
   kernel's boot code gets them from arch/x86/boot/copy.S and the compiler. */
typedef unsigned long long u64;

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
