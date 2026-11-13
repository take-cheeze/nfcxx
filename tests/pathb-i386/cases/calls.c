/* The calling conventions: more arguments than registers, long long, structs by value (arguments and results), function pointers,
   variadic functions, recursion; the callers and callees in this file and in the runtime (gcc's code). */
extern void pb_putu(unsigned long v);
extern void pb_putll(unsigned long long v);
extern void pb_puts(const char *s);

typedef __builtin_va_list va_list;
#define va_start(a, b) __builtin_va_start(a, b)
#define va_arg(a, t) __builtin_va_arg(a, t)
#define va_end(a) __builtin_va_end(a)

struct small { unsigned char a; unsigned char b; };
struct mid { int x; long y; void *p; };
struct big { long long a; int b[5]; char c; };

__attribute__((noinline)) static int many(int a, int b, int c, int d, int e, int f, int g)
{
	return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g;
}

__attribute__((noinline)) static long long wide(int a, long long b, int c, unsigned long long d, short e)
{
	return a + b * c - (long long)d + e;
}

__attribute__((noinline)) static struct small mk_small(int x)
{
	struct small s = { (unsigned char)x, (unsigned char)(x * 2) };
	return s;
}

__attribute__((noinline)) static struct mid mk_mid(int x, struct mid m)
{
	m.x += x;
	m.y *= 3;
	return m;
}

__attribute__((noinline)) static struct big mk_big(struct big b, long long k)
{
	b.a += k;
	for (int i = 0; i < 5; i++)
		b.b[i] += i * (int)k;
	b.c++;
	return b;
}

__attribute__((noinline)) static int take_small(struct small s, struct mid m, int z)
{
	return s.a + s.b + m.x + (int)m.y + z;
}

static int vsum(int n, ...)
{
	va_list ap;
	int s = 0;
	va_start(ap, n);
	while (n--)
		s += va_arg(ap, int);
	va_end(ap);
	return s;
}

static long long vsum_ll(int n, ...)
{
	va_list ap;
	long long s = 0;
	va_start(ap, n);
	while (n--)
		s += va_arg(ap, long long);
	va_end(ap);
	return s;
}

static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

static int (*const ops[3])(int, int, int, int) = { 0, 0, 0 };

static int add4(int a, int b, int c, int d) { return a + b + c + d; }
static int mul4(int a, int b, int c, int d) { return a * b * c * d; }

int pb_main(void)
{
	struct small s = mk_small(21);
	struct mid m = { 1, 2, &s };
	struct big b = { 1LL << 40, { 1, 2, 3, 4, 5 }, 'a' };
	int (*fp[2])(int, int, int, int) = { add4, mul4 };
	(void)ops;

	pb_putu((unsigned long)many(1, 2, 3, 4, 5, 6, 7));
	pb_putll((unsigned long long)wide(-3, 5000000000LL, 7, 123456789012ULL, -9));
	pb_putu((unsigned long)(s.a + s.b));
	m = mk_mid(10, m);
	pb_putu((unsigned long)(m.x + m.y + (m.p == &s)));
	b = mk_big(b, 1000000007LL);
	pb_putll((unsigned long long)b.a);
	for (int i = 0; i < 5; i++)
		pb_putu((unsigned long)b.b[i]);
	pb_putu((unsigned long)b.c);
	pb_putu((unsigned long)take_small(s, m, 4));
	pb_putu((unsigned long)vsum(5, 1, 2, 3, 4, 5));
	pb_putll((unsigned long long)vsum_ll(3, 1LL << 33, 5LL, -7LL));
	pb_putu((unsigned long)fib(15));
	pb_putu((unsigned long)(fp[0](1, 2, 3, 4) + fp[1](1, 2, 3, 4)));
	return fib(10) & 0x7f;
}
