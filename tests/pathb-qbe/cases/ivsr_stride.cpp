// EXPECT: 0
// Path B: an address base + i * size in a loop is a pointer induction (QBE's ivsr, 3rd/qbe licm.c): the pointer starts at
// base + i0 * size and advances by size * step per iteration. The probes below cover a constant start, a variable start,
// a step of 2 over an int array (a shift scale), two bases of different element sizes, a multiply that is also used as a
// value (no rewrite), and a negative step. The exit code is the number of wrong results; the references walk pointers,
// so they do not contain the index arithmetic under test.
#include <cstdint>

struct Rec { int32_t a, b, c; uint8_t flag; };   // 16 bytes
struct Rec12 { int32_t a, b, c; };               // 12 bytes

static Rec recs[32];
static Rec12 r12[32];
static int32_t ints[64];

__attribute__((noinline)) long sum_const(const Rec *r, int n) {
	long s = 0;
	for (int i = 3; i < n; i++) s += r[i].a * 2 + r[i].b;
	return s;
}

__attribute__((noinline)) long sum_var(const Rec *r, int i0, int n) {
	long s = 0;
	for (int i = i0; i < n; i++) s += r[i].a;
	return s;
}

__attribute__((noinline)) long step2(const int32_t *x, int n) {
	long s = 0;
	for (int i = 0; i < n; i += 2) s += x[i];
	return s;
}

__attribute__((noinline)) void two_bases(Rec *dst, const Rec12 *src, int n) {
	for (int i = 0; i < n; i++) {
		dst[i].c = src[i].c + i;
		dst[i].a = src[i].a;
	}
}

__attribute__((noinline)) long value_too(const Rec *r, int n, long *out) {
	long s = 0;
	for (int i = 0; i < n; i++) {
		out[i] = i * 16;
		s += r[i].b;
	}
	return s;
}

__attribute__((noinline)) long rev(const Rec *r, int n) {
	long s = 0;
	for (int i = n - 1; i >= 0; i--) s += r[i].b;
	return s;
}

// references by pointer walks (no index multiply)
static long ref_sum_const(const Rec *r, int n) {
	long s = 0;
	const Rec *p = r + 3;
	for (int i = 3; i < n; i++, p++) s += p->a * 2 + p->b;
	return s;
}

static long ref_sum_var(const Rec *r, int i0, int n) {
	long s = 0;
	const Rec *p = r + i0;
	for (int i = i0; i < n; i++, p++) s += p->a;
	return s;
}

static long ref_step2(const int32_t *x, int n) {
	long s = 0;
	const int32_t *p = x;
	for (int i = 0; i < n; i += 2, p += 2) s += *p;
	return s;
}

static long ref_rev(const Rec *r, int n) {
	long s = 0;
	// the walk starts one past the end and steps back before each read, so it never leaves the array (a p-- after the
	// last read would point before r, which -fsafe-pointers reports as arithmetic out of the object)
	const Rec *p = r + n;
	for (int i = n - 1; i >= 0; i--) { --p; s += p->b; }
	return s;
}

int main() {
	int bad = 0;
	for (int i = 0; i < 32; i++) {
		recs[i].a = i + 1;
		recs[i].b = 2 * i;
		recs[i].c = 0;
		recs[i].flag = (uint8_t)i;
		r12[i].a = 5 - i;
		r12[i].b = 0;
		r12[i].c = 100 + i;
	}
	for (int i = 0; i < 64; i++) ints[i] = (i * 37) % 101 - 50;

	bad += sum_const(recs, 32) != ref_sum_const(recs, 32);
	bad += sum_var(recs, 0, 32) != ref_sum_var(recs, 0, 32);
	bad += sum_var(recs, 7, 20) != ref_sum_var(recs, 7, 20);
	bad += sum_var(recs, 31, 32) != ref_sum_var(recs, 31, 32);
	bad += step2(ints, 64) != ref_step2(ints, 64);
	bad += step2(ints, 9) != ref_step2(ints, 9);

	two_bases(recs, r12, 32);
	for (int i = 0; i < 32; i++) {
		if (recs[i].c != 100 + i + i) bad++;
		if (recs[i].a != 5 - i) bad++;
	}

	long out[32];
	long vt = value_too(recs, 32, out);
	long vref = 0;
	for (int i = 0; i < 32; i++) vref += recs[i].b;
	bad += vt != vref;
	for (int i = 0; i < 32; i++) bad += out[i] != (long)i * 16;

	bad += rev(recs, 32) != ref_rev(recs, 32);
	bad += rev(recs, 0) != 0;
	return bad;
}
