/* The gcc half of float16_exhaustive.c: gcc's own _Float16 conversions and arithmetic, on binary16 patterns, bit patterns
   and plain integers, so the other half can be built by any backend. */
typedef union { unsigned short u; _Float16 h; } f16u;
typedef union { float f; unsigned u; } fu;
typedef union { double d; unsigned long long u; } dbu;

static _Float16 hf(unsigned b) { f16u x; x.u = (unsigned short)b; return x.h; }
static unsigned hb(_Float16 h) { f16u x; x.h = h; return x.u; }

unsigned g_to_f32(unsigned h) { fu x; x.f = (float)hf(h); return x.u; }
unsigned long long g_to_f64(unsigned h) { dbu x; x.d = (double)hf(h); return x.u; }
unsigned g_from_f32(unsigned f) { fu x; x.u = f; return hb((_Float16)x.f); }
unsigned g_from_f64(unsigned long long d) { dbu x; x.u = d; return hb((_Float16)x.d); }
unsigned g_from_s64(long long v) { return hb((_Float16)v); }
unsigned g_from_u64(unsigned long long v) { return hb((_Float16)v); }
unsigned g_from_ld(long double v) { return hb((_Float16)v); }
long long g_to_s64(unsigned h) { return (long long)hf(h); }
unsigned g_op(int op, unsigned a, unsigned b)
{
	_Float16 x = hf(a), y = hf(b);
	switch (op) {
	case 0: return hb(x + y);
	case 1: return hb(x - y);
	case 2: return hb(x * y);
	default: return hb(x / y);
	}
}
/* bit 0 ==, 1 !=, 2 <, 3 <=, 4 >, 5 >= */
unsigned g_cmp(unsigned a, unsigned b)
{
	_Float16 x = hf(a), y = hf(b);
	return (x == y) | (x != y) << 1 | (x < y) << 2 | (x <= y) << 3 | (x > y) << 4 | (x >= y) << 5;
}
unsigned g_neg(unsigned a) { return hb(-hf(a)); }
unsigned g_inc(unsigned a) { _Float16 x = hf(a); x++; return hb(x); }
unsigned g_dec(unsigned a) { _Float16 x = hf(a); --x; return hb(x); }
unsigned g_bool(unsigned a) { return hf(a) ? 1 : 0; }
