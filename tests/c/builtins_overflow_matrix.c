// EXPECT: 42
// __builtin_{add,sub,mul}_overflow for every mix of signed and unsigned char, short, int and long operands and results
// (1536 combinations, 441 value pairs each): the results and flags hash to what gcc computes. Ordinary nfcc C goes
// through qbe-prep.rb's lowering; tests/c/cc-mode.sh compiles this file in NFCXX_QBE_KERNEL mode too, where cproc
// lowers the builtins itself (qbe.c funcoverflow).
static unsigned long long h = 1469598103934665603ull;
static void mix(unsigned long long x) { h = (h ^ x) * 1099511628211ull; }
static const long long va[] = { 0, 1, -1, 2, -2, 127, -128, 255, 32767, -32768, 65535, 2147483647, (-2147483647 - 1),
	4294967295u, 9223372036854775807L, (-9223372036854775807L - 1), 18446744073709551615ul, 3037000499L, 4294967296L,
	100, -77 };
#define N (int)(sizeof va / sizeof va[0])
#define CASE(op, ta, tb, tr) \
	for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) { \
		ta a = (ta)va[i]; tb b = (tb)va[j]; tr r; int o = __builtin_##op##_overflow(a, b, &r); \
		mix((unsigned long long)(long long)r); mix(o); }
#define TR(op, ta, tb) CASE(op, ta, tb, signed char) CASE(op, ta, tb, unsigned char) CASE(op, ta, tb, short) \
	CASE(op, ta, tb, unsigned short) CASE(op, ta, tb, int) CASE(op, ta, tb, unsigned) CASE(op, ta, tb, long) \
	CASE(op, ta, tb, unsigned long)
#define TB(op, ta) TR(op, ta, signed char) TR(op, ta, unsigned char) TR(op, ta, short) TR(op, ta, unsigned short) \
	TR(op, ta, int) TR(op, ta, unsigned) TR(op, ta, long) TR(op, ta, unsigned long)
#define TA(op) static void run_##op(void) { TB(op, signed char) TB(op, unsigned char) TB(op, short) \
	TB(op, unsigned short) TB(op, int) TB(op, unsigned) TB(op, long) TB(op, unsigned long) }
TA(add)
TA(sub)
TA(mul)
int main(void) {
	run_add(); run_sub(); run_mul();
	return h == 0x35b96ad31741888bull ? 42 : 1;
}
