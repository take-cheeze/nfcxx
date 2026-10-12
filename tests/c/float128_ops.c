/* EXPECT: 0
   __float128 (IEEE binary128) through cproc's runtime helpers: typedef, Q literals, arithmetic, comparisons, conversions to and
   from integers, float, double and long double, ++ and --, conditions, initializers and compound assignment. Only exactly
   representable values are compared, so the result does not depend on how a literal is rounded. Exit status = failed checks. */
#define CHECK(c) do { if (!(c)) ++fails; } while (0)

static int fails;
static __float128 gq = 2.5Q;
static __float128 garr[3] = {1.0Q, -0.5Q, 1000.0Q};
static __float128 gneg = -3.25Q;

struct rec { int k; __float128 v; };

int main(void) {
	__float128 a = 1.5Q, b = 2.25Q, c, p;
	int i;
	long j;
	unsigned long u;
	float f;
	double d;
	long double l;
	struct rec r;

	c = a * b + 1.0Q;
	CHECK(c == 4.375Q);
	CHECK(a + b == 3.75Q);
	CHECK(b - a == 0.75Q);
	CHECK(a * b == 3.375Q);
	CHECK(b / a == 1.5Q);
	CHECK(-a == -1.5Q);
	CHECK(+a == 1.5Q);
	CHECK(a < b && b > a && a <= b && b >= a && a != b && !(a == b));
	CHECK(!(b < a) && !(a > b) && !(b <= a) && !(a >= b));
	CHECK(a < b || 0);

	i = (int)(c * 1000.0Q);
	CHECK(i == 4375);
	j = (long)-b;
	CHECK(j == -2);
	u = (unsigned long)(b * 4);
	CHECK(u == 9);
	CHECK((__float128)7 == 7.0Q);
	CHECK((__float128)-7 == -7.0Q);
	CHECK((__float128)(unsigned long)4000000000u == 4000000000.0Q);
	CHECK((__float128)18446744073709551615ul > 1.8e19Q);
	f = (float)a;
	CHECK(f == 1.5f);
	d = (double)b;
	CHECK(d == 2.25);
	c = 0.5f;
	CHECK(c == 0.5Q);
	c = 0.25;
	CHECK(c == 0.25Q);
	CHECK((double)(__float128)0.1 == 0.1);
	CHECK((int)(-7.9Q) == -7);
	CHECK((unsigned)(7.9Q) == 7u);
	l = (long double)b;
	CHECK(l == 2.25L);
	c = (__float128)l;
	CHECK(c == 2.25Q);
	c = 1.0Q / 1024;
	CHECK(c * 1024 == 1.0Q);

	c = 1.0Q;
	c++;
	CHECK(c == 2.0Q);
	++c;
	CHECK(c == 3.0Q);
	c--;
	CHECK(c == 2.0Q);
	p = c++;
	CHECK(p == 2.0Q && c == 3.0Q);
	p = ++c;
	CHECK(p == 4.0Q && c == 4.0Q);
	p = c--;
	CHECK(p == 4.0Q && c == 3.0Q);

	c = 0.0Q;
	CHECK(!c);
	if (c) ++fails;
	c = -0.0Q;
	CHECK(!c);
	c = 1e300Q * 1e300Q;
	CHECK(c > 1e599Q);
	c = 0.5Q;
	while (c < 4.0Q) c *= 2;
	CHECK(c == 4.0Q);

	CHECK(gq == 2.5Q);
	CHECK(garr[1] == -0.5Q && garr[2] == 1000.0Q && garr[0] == 1.0Q);
	CHECK(gneg == -3.25Q);
	{
		__float128 arr[4] = {1, 2.5Q};
		CHECK(arr[1] == 2.5Q && arr[2] == 0 && arr[3] == 0);
		arr[3] = arr[1] * 2;
		CHECK(arr[3] == 5.0Q);
	}

	r.k = 4;
	r.v = 0.75Q;
	CHECK(r.v * r.k == 3.0Q);
	r.v = r.v + 1;
	CHECK(r.v == 1.75Q);

	c = 10;
	c += 5;
	c -= 1;
	c *= 2;
	c /= 4;
	CHECK(c == 7.0Q);
	c = a > b ? a : b;
	CHECK(c == 2.25Q);
	c = a > b ? 1 : 0;
	CHECK(c == 0);
	return fails;
}
