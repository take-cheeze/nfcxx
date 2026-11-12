typedef union { long *lp; int *ip; unsigned long u; } tp __attribute__((__transparent_union__));
__attribute__((noinline)) int g_tp(tp a, int k) { return *a.lp + k; }
