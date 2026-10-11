/* EXPECT: 0
   long double (x87 extended, 16 bytes in memory) through cproc's runtime helpers (docs/notes/float128-qbe.md): arithmetic,
   comparisons, conversions, ++ and --, conditions, initializers, arrays, compound assignment and by-value parameters and
   results. The exit status is the number of failed checks, so the same file must give 0 under gcc too. */
#define CHECK(c) do { if (!(c)) ++fails; } while (0)

static int fails;
static long double gl = 2.5L;
static long double garr[3] = {1.0L, -0.5L, 1000.0L};
static long double gneg = -3.25L;

struct rec { int k; long double v; };

static long double add3(long double a, long double b, long double c) { return a + b + c; }
static long double half(long double x) { return x / 2; }
static struct rec mkrec(int k, long double v) { struct rec r = {k, v}; return r; }

int main(void) {
	long double a = 1.5L, b = 2.25L, c, p;
	int i;
	long j;
	unsigned long u;
	float f;
	double d;
	struct rec r;

	c = a * b + 1.0L;
	CHECK(c == 4.375L);
	CHECK(a + b == 3.75L);
	CHECK(b - a == 0.75L);
	CHECK(a * b == 3.375L);
	CHECK(b / a == 1.5L);
	CHECK(-a == -1.5L);
	CHECK(+a == 1.5L);
	CHECK(a < b && b > a && a <= b && b >= a && a != b && !(a == b));
	CHECK(!(b < a) && !(a > b) && !(b <= a) && !(a >= b));
	CHECK(a < b || 0);

	i = (int)(c * 1000.0L);
	CHECK(i == 4375);
	j = (long)-b;
	CHECK(j == -2);
	u = (unsigned long)(b * 4);
	CHECK(u == 9);
	CHECK((long double)7 == 7.0L);
	CHECK((long double)-7 == -7.0L);
	CHECK((long double)(unsigned long)4000000000u == 4000000000.0L);
	CHECK((long double)18446744073709551615ul > 1.8e19L);
	f = (float)a;
	CHECK(f == 1.5f);
	d = (double)b;
	CHECK(d == 2.25);
	c = 0.5f;
	CHECK(c == 0.5L);
	c = 0.25;
	CHECK(c == 0.25L);
	CHECK((double)(long double)0.1 == 0.1);
	CHECK((int)(-7.9L) == -7);
	CHECK((unsigned)(7.9L) == 7u);

	c = 1.0L;
	c++;
	CHECK(c == 2.0L);
	++c;
	CHECK(c == 3.0L);
	c--;
	CHECK(c == 2.0L);
	p = c++;
	CHECK(p == 2.0L && c == 3.0L);
	p = ++c;
	CHECK(p == 4.0L && c == 4.0L);
	p = c--;
	CHECK(p == 4.0L && c == 3.0L);

	c = 0.0L;
	CHECK(!c);
	if (c) ++fails;
	c = -0.0L;
	CHECK(!c);
	c = 1e-4000L;
	CHECK(c != 0 && c > 0);
	c = 1e300L * 1e300L;
	CHECK(c > 1e599L);
	c = 0.5L;
	if (!c) ++fails;
	while (c < 4.0L) c *= 2;
	CHECK(c == 4.0L);

	CHECK(gl == 2.5L);
	CHECK(garr[1] == -0.5L && garr[2] == 1000.0L && garr[0] == 1.0L);
	CHECK(gneg == -3.25L);
	{
		long double arr[4] = {1, 2.5L};
		CHECK(arr[1] == 2.5L && arr[2] == 0 && arr[3] == 0);
		arr[3] = arr[1] * 2;
		CHECK(arr[3] == 5.0L);
	}

	CHECK(add3(1.0L, 2.0L, 3.5L) == 6.5L);
	CHECK(half(c) == 2.0L);
	r = mkrec(4, 0.75L);
	CHECK(r.v * r.k == 3.0L);
	r.v = r.v + 1;
	CHECK(r.v == 1.75L);

	c = 10;
	c += 5;
	c -= 1;
	c *= 2;
	c /= 4;
	CHECK(c == 7.0L);
	c = 3;
	c = c + 2;
	CHECK(c == 5);
	c = a > b ? a : b;
	CHECK(c == 2.25L);
	c = a > b ? 1 : 0;
	CHECK(c == 0);

	return fails;
}
