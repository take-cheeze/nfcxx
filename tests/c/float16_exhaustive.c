// EXPECT: 0
// GCC: float16_exh_peer.c
// X86-ONLY: long double is the x87 type of be/nfcxx_ldrt.c (the conversion from it is checked)
/* _Float16 against gcc for every one of the 65536 binary16 patterns, the code under test being built by the backend and
   gcc's answers by float16_exh_peer.c (built by gcc):
   - to float and to double (exact);
   - from float and from double, on every half value and on its neighbours: the value itself, one unit in the last place of
     the source type either side, and the exact midpoint with the next half value (the tie, and either side of it);
   - from every integer in [-70000, 70000], from sampled 64-bit integers, and from long double;
   - to integers, for every finite value of the range of long long;
   - + - * / on every pattern against 24 others and 2 million pairs, the six comparisons, unary minus, ++, --, truth.
   A result must be gcc's bits, or a NaN where gcc's is a NaN. The exit status is the number of failed checks, at most 100. */

typedef unsigned short u16;
typedef union { u16 u; _Float16 h; } f16u;
typedef union { float f; unsigned u; } fu;
typedef union { double d; unsigned long long u; } dbu;

unsigned g_to_f32(unsigned h);
unsigned long long g_to_f64(unsigned h);
unsigned g_from_f32(unsigned f);
unsigned g_from_f64(unsigned long long d);
unsigned g_from_s64(long long v);
unsigned g_from_u64(unsigned long long v);
unsigned g_from_ld(long double v);
long long g_to_s64(unsigned h);
unsigned g_op(int op, unsigned a, unsigned b);
unsigned g_cmp(unsigned a, unsigned b);
unsigned g_neg(unsigned a);
unsigned g_inc(unsigned a);
unsigned g_dec(unsigned a);
unsigned g_bool(unsigned a);

static unsigned fails;
#define CHECK(c) do { if (!(c)) ++fails; } while (0)

static _Float16 hf(unsigned b) { f16u x; x.u = (u16)b; return x.h; }
static unsigned hb(_Float16 h) { f16u x; x.h = h; return x.u; }
static int isnan16(unsigned b) { return (b & 0x7c00) == 0x7c00 && (b & 0x3ff); }
static int same16(unsigned got, unsigned want)
{
	if (isnan16(want)) return isnan16(got);
	return got == want;
}
static int same32(unsigned got, unsigned want)
{
	if ((want & 0x7f800000) == 0x7f800000 && (want & 0x7fffff)) return (got & 0x7f800000) == 0x7f800000 && (got & 0x7fffff);
	return got == want;
}
static int same64(unsigned long long got, unsigned long long want)
{
	if ((want & 0x7ff0000000000000ull) == 0x7ff0000000000000ull && (want & 0xfffffffffffffull))
		return (got & 0x7ff0000000000000ull) == 0x7ff0000000000000ull && (got & 0xfffffffffffffull);
	return got == want;
}

static unsigned long long rng = 0x9e3779b97f4a7c15ull;
static unsigned long long next(void)
{
	rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
	return rng;
}

/* the volatile calls keep a backend from folding the run-time conversions under test */
static _Float16 (*volatile f16_id)(_Float16) ;
static _Float16 ident(_Float16 x) { return x; }

int main(void)
{
	unsigned h, i, j;
	static const unsigned others[] = { 0x0000, 0x8000, 0x0001, 0x8001, 0x03ff, 0x0400, 0x3800, 0x3c00, 0x3c01, 0xbc00, 0x4000, 0x4900,
		0x5640, 0x7bff, 0xfbff, 0x7c00, 0xfc00, 0x7e00, 0xfe01, 0x2e66, 0x0200, 0x5bff, 0x1234, 0xabcd };
	f16_id = ident;

	for (h = 0; h < 65536; ++h) {
		fu f; dbu d;
		_Float16 x = f16_id(hf(h));
		/* to float, to double */
		f.f = (float)x;
		CHECK(same32(f.u, g_to_f32(h)));
		d.d = (double)x;
		CHECK(same64(d.u, g_to_f64(h)));
		/* from the float and double that are exactly this half value, and their neighbours */
		if (!isnan16(h)) {
			fu a = f, lo, hi, mid_lo, mid_hi, mid;
			dbu da = d, dlo, dhi;
			unsigned nxt = h + 1;
			lo.u = a.u - 1; hi.u = a.u + 1;
			CHECK(same16(hb((_Float16)a.f), g_from_f32(a.u)));
			CHECK(same16(hb((_Float16)lo.f), g_from_f32(lo.u)));
			CHECK(same16(hb((_Float16)hi.f), g_from_f32(hi.u)));
			dlo.u = da.u - 1; dhi.u = da.u + 1;
			CHECK(same16(hb((_Float16)da.d), g_from_f64(da.u)));
			CHECK(same16(hb((_Float16)dlo.d), g_from_f64(dlo.u)));
			CHECK(same16(hb((_Float16)dhi.d), g_from_f64(dhi.u)));
			/* the midpoint with the next pattern of the same sign (not past the infinity): exact in float */
			if ((h & 0x7fff) < 0x7c00) {
				fu n; dbu dm;
				n.f = (float)hf(nxt & 0xffff);
				if ((h & 0x7fff) == 0x7bff) n.f = (h & 0x8000) ? -65536.0f : 65536.0f; /* the "next" value of the largest: 2^16 */
				mid.f = (a.f + n.f) / 2;
				mid_lo.u = mid.u - 1; mid_hi.u = mid.u + 1;
				CHECK(same16(hb((_Float16)mid.f), g_from_f32(mid.u)));
				CHECK(same16(hb((_Float16)mid_lo.f), g_from_f32(mid_lo.u)));
				CHECK(same16(hb((_Float16)mid_hi.f), g_from_f32(mid_hi.u)));
				dm.d = ((double)a.f + (double)n.f) / 2;
				{ dbu dml, dmh; dml.u = dm.u - 1; dmh.u = dm.u + 1;
				CHECK(same16(hb((_Float16)dm.d), g_from_f64(dm.u)));
				CHECK(same16(hb((_Float16)dml.d), g_from_f64(dml.u)));
				CHECK(same16(hb((_Float16)dmh.d), g_from_f64(dmh.u))); }
			}
		}
		/* a NaN through float and double stays a NaN */
		if (isnan16(h)) {
			CHECK(isnan16(hb((_Float16)(float)x)));
			CHECK(isnan16(hb((_Float16)(double)x)));
		}
		/* unary minus, ++, --, truth */
		CHECK(same16(hb(-x), g_neg(h)));
		{ _Float16 y = x; y++; CHECK(same16(hb(y), g_inc(h))); y = x; --y; CHECK(same16(hb(y), g_dec(h))); }
		CHECK((x ? 1u : 0u) == g_bool(h));
		/* to integers: every finite value whose truncation fits */
		if ((h & 0x7c00) != 0x7c00)
			CHECK((long long)x == g_to_s64(h));
		/* against 24 other patterns */
		for (j = 0; j < sizeof others / sizeof others[0]; ++j) {
			_Float16 y = f16_id(hf(others[j]));
			unsigned b = others[j];
			CHECK(same16(hb(x + y), g_op(0, h, b)));
			CHECK(same16(hb(x - y), g_op(1, h, b)));
			CHECK(same16(hb(x * y), g_op(2, h, b)));
			CHECK(same16(hb(x / y), g_op(3, h, b)));
			CHECK(((x == y) | (x != y) << 1 | (x < y) << 2 | (x <= y) << 3 | (x > y) << 4 | (x >= y) << 5) == g_cmp(h, b));
		}
	}

	/* two million random pairs of patterns */
	for (i = 0; i < 2000000; ++i) {
		unsigned long long r = next();
		unsigned a = r & 0xffff, b = r >> 16 & 0xffff;
		_Float16 x = f16_id(hf(a)), y = f16_id(hf(b));
		CHECK(same16(hb(x + y), g_op(0, a, b)));
		CHECK(same16(hb(x - y), g_op(1, a, b)));
		CHECK(same16(hb(x * y), g_op(2, a, b)));
		CHECK(same16(hb(x / y), g_op(3, a, b)));
		if ((i & 15) == 0)
			CHECK(((x == y) | (x != y) << 1 | (x < y) << 2 | (x <= y) << 3 | (x > y) << 4 | (x >= y) << 5) == g_cmp(a, b));
	}

	/* from integers */
	for (i = 0; i <= 140000; ++i) {
		long long v = (long long)i - 70000;
		CHECK(same16(hb((_Float16)v), g_from_s64(v)));
		CHECK(same16(hb((_Float16)(int)v), g_from_s64(v)));
		CHECK(same16(hb((_Float16)(unsigned)i), g_from_u64(i)));
		CHECK(same16(hb((_Float16)(short)v), g_from_s64((short)v)));
		CHECK(same16(hb((_Float16)(unsigned short)i), g_from_u64((unsigned short)i)));
		CHECK(same16(hb((_Float16)(signed char)v), g_from_s64((signed char)v)));
		CHECK(same16(hb((_Float16)(unsigned char)i), g_from_u64((unsigned char)i)));
	}
	for (i = 0; i < 400000; ++i) {
		unsigned long long r = next();
		int sh = (int)(next() & 63);
		long long s = (long long)(r >> sh) * ((i & 1) ? -1 : 1);
		unsigned long long u = r >> sh;
		CHECK(same16(hb((_Float16)s), g_from_s64(s)));
		CHECK(same16(hb((_Float16)u), g_from_u64(u)));
	}
	CHECK(same16(hb((_Float16)0x7fffffffffffffffll), g_from_s64(0x7fffffffffffffffll)));
	CHECK(same16(hb((_Float16)(-0x7fffffffffffffffll - 1)), g_from_s64(-0x7fffffffffffffffll - 1)));
	CHECK(same16(hb((_Float16)0xffffffffffffffffull), g_from_u64(0xffffffffffffffffull)));
	/* the ties of integers: 2049 -> 2048 (even), 2051 -> 2052, 65519 -> 65504, 65520 -> inf */
	for (i = 2040; i < 2070; ++i) CHECK(same16(hb((_Float16)(int)i), g_from_s64(i)));
	for (i = 65500; i < 65540; ++i) CHECK(same16(hb((_Float16)(int)i), g_from_s64(i)));

	/* from every half value, the exact value and its neighbours as long double */
	for (h = 0; h < 65536; ++h) {
		long double a;
		if (isnan16(h)) continue;
		a = (long double)hf(h);
		CHECK(same16(hb((_Float16)a), g_from_ld(a)));
		CHECK(same16(hb((_Float16)(a + a * 0x1p-40L + 0x1p-60L)), g_from_ld(a + a * 0x1p-40L + 0x1p-60L)));
		CHECK(same16(hb((_Float16)(a - a * 0x1p-40L - 0x1p-60L)), g_from_ld(a - a * 0x1p-40L - 0x1p-60L)));
	}
	return fails > 100 ? 100 : fails;
}
