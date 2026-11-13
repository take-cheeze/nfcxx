/* The rest of the integer semantics of the 32-bit target: long is 32 bits (constants, wrapping, shifts, conversions), a switch on a
   long long and a dense switch (no jump tables on QBE's i386), the builtins that Path B expands inline, a variable-length array,
   goto, a local static, and a table of structures with pointers in a static initializer. */
extern void pb_putu(unsigned long v);
extern void pb_putll(unsigned long long v);
extern void pb_puts(const char *s);

struct entry {
	const char *name;
	int (*fn)(int);
	long long weight;
	unsigned short flags;
};

static int twice(int x) { return x * 2; }
static int neg(int x) { return -x; }

static const struct entry table[] = {
	{ "twice", twice, 5000000000LL, 3 },
	{ "neg", neg, -7, 0xffff },
	{ "null", 0, 0, 0 },
};

static int dense(unsigned x)
{
	switch (x) {
	case 0: return 5;
	case 1: return 8;
	case 2: return 13;
	case 3: return 21;
	case 4: return 34;
	case 5: return 55;
	case 6: return 89;
	case 7: return 144;
	case 8: return 233;
	case 10: return 377;
	default: return 0;
	}
}

static int sparse(long long x)
{
	switch (x) {
	case 1LL: return 1;
	case 100000000000LL: return 2;
	case -5LL: return 3;
	case 0x7fffffffffffffffLL: return 4;
	default: return 0;
	}
}

static unsigned long ulong_ops(unsigned long a, unsigned long b)
{
	unsigned long r = a * b + (a << 31) - (b >> 3);
	r ^= 0xfffffff0UL;
	r += 0x80000000UL;
	return r;
}

static long long_ops(long a, long b)
{
	long q = a / (b | 1), m = a % (b | 1);
	return q * 7 + m + (long)(a < b) + (long)((unsigned long)a > (unsigned long)b) + (a >> 4) + (a << 3);
}

static unsigned alloca_sum(int n)
{
	unsigned *buf = __builtin_alloca((unsigned)n * sizeof(unsigned));
	unsigned s = 0;
	for (int i = 0; i < n; i++)
		buf[i] = (unsigned)(i * i + 3);
	for (int i = 0; i < n; i++)
		s += buf[i] * (unsigned)(i + 1);
	return s;
}

static int counter(void)
{
	static int calls;
	return ++calls;
}

static int with_goto(int n)
{
	int s = 0, i = 0;
again:
	if (i >= n)
		goto done;
	s += i * 3;
	i++;
	goto again;
done:
	return s;
}

int pb_main(void)
{
	pb_putu(ulong_ops(0x12345678UL, 0x9abcdef0UL));
	pb_putu((unsigned long)long_ops(-123456789L, 12345L));
	pb_putu((unsigned long)long_ops(2000000000L, -77L));
	pb_putu((unsigned long)(0x7fffffffL + 1L < 0));
	pb_putu((unsigned long)(0xffffffffUL == (unsigned long)-1L));
	pb_putu((unsigned long)sizeof(long) + sizeof(long long) * 10 + sizeof(char *) * 100 + sizeof(long double) * 1000);
	for (unsigned i = 0; i < 12; i++)
		pb_putu((unsigned long)dense(i));
	pb_putu((unsigned long)(sparse(1) + sparse(100000000000LL) * 10 + sparse(-5) * 100 + sparse(0x7fffffffffffffffLL) * 1000 + sparse(9)));
	for (unsigned i = 0; i < 3; i++) {
		const struct entry *e = &table[i];
		pb_puts(e->name);
		pb_putll((unsigned long long)e->weight);
		pb_putu(e->flags);
		if (e->fn)
			pb_putu((unsigned long)e->fn(21));
	}
	pb_putu(__builtin_clz(0x00f0u) + __builtin_ctz(0x0f00u) * 100u + (unsigned)__builtin_popcount(0xf0f0f0f0u) * 10000u);
	pb_putu(__builtin_bswap32(0x11223344u));
	pb_putll(__builtin_bswap64(0x1122334455667788ULL));
	pb_putu(alloca_sum(9));
	{
		int c1 = counter(), c2 = counter(), c3 = counter();
		pb_putu((unsigned long)(c1 + c2 * 10 + c3 * 100));
	}
	pb_putu((unsigned long)with_goto(10));
	return with_goto(5) & 0x7f;
}
