// EXPECT: 42
// The bit-counting built-ins (cproc's own, not qbe-prep's helpers: the kernel's headers fold them in constant
// expressions), at run time and folded, for the int, long and long long forms. clz and ctz of zero are left out (GNU C
// leaves them undefined).
static const unsigned long long vals[] = {
	1, 2, 3, 0x80, 0xff, 0x100, 0x12345678, 0x7fffffff, 0x80000000, 0xffffffff, 0x100000000ull, 0xdeadbeefcafebabeull,
	0x8000000000000000ull, 0xffffffffffffffffull, 0x0000ffff0000ffffull, 0x5555555555555555ull,
};
static int bit(unsigned long long x, int k) { return x >> k & 1; }
static int ref_clz(unsigned long long x, int w) { int r = 0; for (int k = w - 1; k >= 0 && !bit(x, k); --k) ++r; return r; }
static int ref_ctz(unsigned long long x, int w) { int r = 0; for (int k = 0; k < w && !bit(x, k); ++k) ++r; return r; }
static int ref_pop(unsigned long long x, int w) { int r = 0; for (int k = 0; k < w; ++k) r += bit(x, k); return r; }
static int ref_ffs(unsigned long long x, int w) { return (w == 32 ? (unsigned)x : x) ? ref_ctz(x, w) + 1 : 0; }
_Static_assert(__builtin_clz(1) == 31 && __builtin_clzl(1) == 63 && __builtin_clzll(0x100) == 55, "clz folds");
_Static_assert(__builtin_ctz(0x80) == 7 && __builtin_ctzl(1ul << 40) == 40, "ctz folds");
_Static_assert(__builtin_popcount(0xff) == 8 && __builtin_popcountll(~0ull) == 64 && __builtin_parity(7) == 1, "popcount folds");
_Static_assert(__builtin_ffs(0) == 0 && __builtin_ffs(-2) == 2 && __builtin_ffsl(1l << 63) == 64, "ffs folds");
int main(void) {
	int n = sizeof vals / sizeof vals[0];
	for (int i = 0; i < n; ++i) {
		volatile unsigned long long v = vals[i];
		unsigned u = v; unsigned long l = v;
		if (u && __builtin_clz(u) != ref_clz(u, 32)) return 1;
		if (u && __builtin_ctz(u) != ref_ctz(u, 32)) return 2;
		if (__builtin_popcount(u) != ref_pop(u, 32)) return 3;
		if (__builtin_parity(u) != (ref_pop(u, 32) & 1)) return 4;
		if (__builtin_ffs((int)u) != ref_ffs(u, 32)) return 5;
		if (__builtin_clzl(l) != ref_clz(l, 64) || __builtin_clzll(l) != ref_clz(l, 64)) return 6;
		if (__builtin_ctzl(l) != ref_ctz(l, 64) || __builtin_ctzll(l) != ref_ctz(l, 64)) return 7;
		if (__builtin_popcountl(l) != ref_pop(l, 64) || __builtin_popcountll(l) != ref_pop(l, 64)) return 8;
		if (__builtin_parityl(l) != (ref_pop(l, 64) & 1)) return 9;
		if (__builtin_ffsl((long)l) != ref_ffs(l, 64) || __builtin_ffsll((long long)l) != ref_ffs(l, 64)) return 10;
	}
	volatile int z = 0;
	if (__builtin_ffs(z) != 0 || __builtin_ffsl(z) != 0 || __builtin_popcount(z) != 0) return 11;
	return 42;
}
