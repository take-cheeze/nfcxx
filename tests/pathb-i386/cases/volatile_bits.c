/* Volatile accesses (a call of a helper each), bit-fields, unions, narrow integers, long long arithmetic and the string/memory
   operations the kernel's boot code uses (a boot_params-like structure copied and cleared). */
extern void pb_putu(unsigned long v);
extern void pb_putll(unsigned long long v);
extern void pb_puts(const char *s);

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long long u64;

struct regs {
	volatile u8 status;
	volatile u16 count;
	volatile u32 data;
	volatile u64 wide;
	u8 pad[3];
};

struct flags {
	unsigned a : 3;
	unsigned b : 5;
	unsigned c : 12;
	int d : 7;
	unsigned long long e : 40;
};

union cvt {
	u32 w;
	u16 h[2];
	u8 b[4];
};

struct params {
	u8 raw[64];
	u32 magic;
	u16 version;
	char name[10];
};

static struct regs dev;
static volatile int counter;

static u32 poll(volatile struct regs *r, int n)
{
	u32 sum = 0;
	while (n--) {
		r->status = (u8)(n | 0x80);
		r->count = (u16)(r->count + 3);
		r->data = r->data * 5 + 1;
		sum += r->status + r->count + r->data;
	}
	return sum;
}

static u64 swap64(u64 v)
{
	return ((v & 0xffULL) << 56) | ((v & 0xff00ULL) << 40) | ((v & 0xff0000ULL) << 24) | ((v & 0xff000000ULL) << 8) |
	       ((v >> 8) & 0xff000000ULL) | ((v >> 24) & 0xff0000ULL) | ((v >> 40) & 0xff00ULL) | (v >> 56);
}

static int narrow(signed char a, unsigned char b, short c, unsigned short d)
{
	return a * b + c / (d | 1) - (a >> 1) + (b << 3) + (short)(c << 2) + (u16)(d + 70000);
}

static long long lmath(long long a, long long b)
{
	long long q = a / (b | 1), r = a % (b | 1);
	unsigned long long ua = (unsigned long long)a;
	return q * 1000003LL + r + (long long)(ua >> 13) - (a << 5) + (a < b) + (ua > (unsigned long long)b) * 7;
}

static void fill(struct params *p)
{
	for (int i = 0; i < 64; i++)
		p->raw[i] = (u8)(i * 7);
	p->magic = 0x53726448;
	p->version = 0x020d;
	p->name[0] = 'b';
	p->name[1] = 'o';
	p->name[2] = 'o';
	p->name[3] = 't';
	p->name[4] = 0;
}

int pb_main(void)
{
	struct flags f = { 5, 17, 3000, -33, 0x123456789aULL };
	union cvt c;
	struct params p, q;

	dev.count = 40;
	dev.data = 7;
	dev.wide = 0x1122334455667788ULL;
	pb_putu(poll(&dev, 5));
	pb_putu(dev.status);
	pb_putu(dev.count);
	pb_putu(dev.data);
	pb_putll(dev.wide);
	dev.wide += 1;
	pb_putll(dev.wide);
	counter = 3;
	counter += 4;
	pb_putu((unsigned long)(counter++ + ++counter));

	f.b += 20;
	f.d -= 40;
	f.e <<= 4;
	pb_putu(f.a);
	pb_putu(f.b);
	pb_putu(f.c);
	pb_putu((unsigned long)f.d);
	pb_putll(f.e);
	pb_putu(sizeof f);

	c.w = 0x01020304;
	pb_putu(c.b[0] * 1000 + c.b[3]);
	pb_putu(c.h[1]);
	c.h[0] = 0xffff;
	pb_putu(c.w);

	pb_putll(swap64(0x0102030405060708ULL));
	pb_putu((unsigned long)narrow(-100, 200, -3000, 65000));
	pb_putll((unsigned long long)lmath(-123456789012345LL, 987654321LL));
	pb_putll((unsigned long long)lmath(98765432101234LL, -4321LL));

	fill(&p);
	q = p;
	q.version++;
	__builtin_memset(p.raw, 0, 8);
	pb_putu(q.magic + q.version + q.raw[10] + p.raw[3] + p.raw[9]);
	pb_puts(q.name);
	return (int)(q.raw[63] & 0x7f);
}
