/* The ABI integration test (run.sh): these functions are built by gcc (abi_gcc.c, with abi_impl.c) and by nfcxx through nfcffi
   (abi_host.cpp). The two print the same lines, so they agree on the layouts, the register and stack conventions, and the
   callbacks. */
typedef struct { double x, y; } Pt;
typedef struct { int n; char tag; Pt p; } Rec;
typedef struct { long a, b, c; } Big;
typedef struct { float f; short s; unsigned char u; } Mixed;

long double ld_twice(long double v);
Rec rec_make(int n, double x);
double rec_sum(Rec r);
Big big_make(long v);
Mixed mixed_make(float f);
Pt pt_step(Pt (*f)(Pt), Pt p);
int pt_count(int (*f)(Pt), int n);
int sum_squares(int (*f)(int), int n);
