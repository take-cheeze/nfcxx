// EXPECT: 42
// GCC: transparent_union_abi_gcc.c
// X86-ONLY: the classes checked are System V x86-64's
// a transparent_union parameter is passed as its first member (a pointer here, INTEGER class; gcc rejects a
// double member), between this backend's code and gcc's, directly and through a function pointer
typedef union { long *lp; int *ip; unsigned long u; } tp __attribute__((__transparent_union__));
int g_tp(tp a, int k);
int p_tp(tp a, int k) { return *a.lp + k; }
int main(void) {
	long v = 40;
	if (g_tp(&v, 1) != 41) return 1;
	if (p_tp(&v, 2) != 42) return 2;
	int (*f)(tp, int) = p_tp; if (f(&v, 5) != 45) return 3;
	int (*g)(tp, int) = g_tp; if (g(&v, 5) != 45) return 4;
	return 42;
}
