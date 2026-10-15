// X86-ONLY: __float128 is not a GCC type on aarch64; qbe aborts in spill.c on aarch64 Linux, and its helpers in be/nfcxx_ldrt.c are x86-64 only
/* EXPECT: 0
   __float128 and long double passed and returned by value: between functions of this program (the calls are made by
   cproc's own code, so the convention is the one cproc uses: the aggregate of two integer eightbytes), through a function
   pointer, recursively, mixed with scalars, and in a struct returned in memory. Exit status = failed checks. */
#define CHECK(c) do { if (!(c)) ++fails; } while (0)

static int fails;

struct pair { __float128 x; int tag; };
struct big { __float128 x, y; };

static __float128 f128_add(__float128 a, __float128 b) { return a + b; }
static __float128 f128_mix(int n, __float128 a, double d, __float128 b, long double l) { return n * a + d + b + l; }
static __float128 f128_fact(int n) { return n <= 1 ? 1.0Q : n * f128_fact(n - 1); }
static __float128 f128_id(__float128 v) { return v; }
static long double ld_pass(long double a, __float128 q, long double b) { return a * b + q; }
static struct pair mkpair(__float128 v, int t) { struct pair p = {v, t}; return p; }
static struct big mkbig(__float128 x, __float128 y) { struct big bg = {x, y}; return bg; }

int main(void) {
	__float128 (*fp)(__float128, __float128) = f128_add;
	__float128 q;
	struct pair pr;
	struct big bg;
	long double l;

	CHECK(f128_add(1.0Q, 2.0Q) == 3.0Q);
	CHECK(fp(1.5Q, 2.25Q) == 3.75Q);
	CHECK(f128_mix(2, 1.5Q, 0.5, 0.25Q, 4.0L) == 7.75Q);
	CHECK(f128_fact(10) == 3628800.0Q);
	CHECK(f128_id(f128_id(-6.5Q)) == -6.5Q);
	l = ld_pass(2.0L, 0.5Q, 3.0L);
	CHECK(l == 6.5L);
	pr = mkpair(9.0Q, 3);
	CHECK(pr.x == 9.0Q && pr.tag == 3);
	bg = mkbig(1.0Q, -2.0Q);
	CHECK(bg.x + bg.y == -1.0Q);
	q = f128_add(mkpair(0.5Q, 1).x, bg.x);
	CHECK(q == 1.5Q);
	return fails;
}
