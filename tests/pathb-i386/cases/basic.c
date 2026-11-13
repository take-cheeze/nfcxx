/* Integers, pointers, structs, arrays and calls on the 32-bit target: long and pointers are 4 bytes, long long is 8 and aligned on 4. */
extern void pb_putu(unsigned long v);
extern void pb_putll(unsigned long long v);
extern void pb_puts(const char *s);

struct hdr {
	unsigned char a;
	unsigned short b;
	unsigned long c;
	unsigned long long d;
	const char *name;
};

struct node { struct node *next; long v; };

static struct hdr g = { 7, 0x1234, 0xdeadbeefUL, 0x0123456789abcdefULL, "gname" };
static struct node nodes[4] = { { &nodes[1], 10 }, { &nodes[2], 20 }, { &nodes[3], 30 }, { 0, 40 } };
static int table[8] = { 1, 2, 3, 5, 8, 13, 21, 34 };
static const char *const names[3] = { "zero", "one", "two" };

static int sum(const int *p, int n)
{
	int s = 0;
	for (int i = 0; i < n; i++)
		s += p[i];
	return s;
}

static long list_sum(struct node *n)
{
	long s = 0;
	for (; n; n = n->next)
		s += n->v;
	return s;
}

static unsigned long hash(const char *s)
{
	unsigned long h = 5381;
	while (*s)
		h = h * 33 + (unsigned char)*s++;
	return h;
}

static int classify(unsigned c)
{
	switch (c) {
	case 0: return 10;
	case 1: return 11;
	case 2: return 12;
	case 3: return 13;
	case 4: return 14;
	case 5: return 15;
	case 9: return 19;
	case 100: return 200;
	default: return -1;
	}
}

static unsigned long long mix(unsigned long long x, long long y, unsigned long z)
{
	return (x << 7) ^ (x >> 3) ^ (unsigned long long)(y * 3) ^ z;
}

static int cmp(const void *a, const void *b)
{
	return *(const int *)a - *(const int *)b;
}

static void isort(int *v, int n, int (*c)(const void *, const void *))
{
	for (int i = 1; i < n; i++) {
		int t = v[i], j = i - 1;
		while (j >= 0 && c(&v[j], &t) > 0) {
			v[j + 1] = v[j];
			j--;
		}
		v[j + 1] = t;
	}
}

int pb_main(void)
{
	struct hdr h = g;
	int r = 0;
	int v[6] = { 5, 2, 9, 1, 7, 3 };

	h.c += sum(table, 8);
	h.d = mix(h.d, -5, h.c);
	pb_putu(h.c);
	pb_putll(h.d);
	pb_putu(sizeof h);
	pb_putu(sizeof(long));
	pb_putu(sizeof(void *));
	pb_putu((unsigned long)((char *)&h.d - (char *)&h));
	pb_putu((unsigned long)(&table[7] - &table[2]));
	pb_putu(list_sum(nodes));
	pb_putu(hash(g.name));
	pb_puts(names[2]);
	for (unsigned i = 0; i < 12; i++)
		r += classify(i) * (int)(i + 1);
	pb_putu((unsigned long)r);
	isort(v, 6, cmp);
	for (int i = 0; i < 6; i++)
		pb_putu((unsigned long)v[i]);
	pb_putll(0xfffffffffULL / 7 + 0x123456789aULL % 1000);
	pb_putu((unsigned long)(h.a + h.b));
	return (int)(h.c & 0x7f);
}
