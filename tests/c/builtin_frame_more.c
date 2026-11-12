// EXPECT: 42
// X86-ONLY-qbe: cproc lowers __builtin_return_address and __builtin_frame_address with x86-64 helpers and refuses them elsewhere
// X86-ONLY-pathb: the Path B helpers read %rbp, an x86-64 register
// __builtin_return_address(0) and __builtin_frame_address(0) when the call is the last thing a function does (no tail call),
// when it is called from two different functions, and __builtin_extract_return_addr
#include <stddef.h>
__attribute__((noinline)) static void *ra(void) { return __builtin_return_address(0); }
__attribute__((noinline)) static void *fa(void) { return __builtin_frame_address(0); }
__attribute__((noinline)) static void *both(void **frame) { *frame = __builtin_frame_address(0); return __builtin_extract_return_addr(__builtin_return_address(0)); }
__attribute__((noinline)) static void c1(void **r) { *r = ra(); __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) static void c2(void **r) { __asm__ volatile("" ::: "memory"); *r = ra(); __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) static void deeper(void **fp_in, void **fp_out) { *fp_in = __builtin_frame_address(0); *fp_out = fa(); __asm__ volatile("" ::: "memory"); }
int main(void) {
	void *r1, *r2, *f, *x;
	c1(&r1); c2(&r2);
	if (!r1 || !r2 || r1 == r2 || ((char *)r1 > (char *)c1 + 64 || (char *)r1 <= (char *)c1)) return 1;   /* each is inside its own caller */
	x = both(&f);
	if (!x || !f || x == f) return 2;
	void *a, *b;
	deeper(&a, &b);
	if (!a || !b || (char *)b >= (char *)a || (char *)a - (char *)b > 4096) return 3;   /* the callee's frame is below the caller's */
	return 42;
}
