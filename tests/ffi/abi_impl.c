/* The definitions for abi.h, built by gcc (abi_gcc.c) and by nfcxx (abi_host.cpp). The header comes first. */
long double ld_twice(long double v) { return 2 * v; }
Rec rec_make(int n, double x) { Rec r = {n, 'q', {x, x + 1}}; return r; }
double rec_sum(Rec r) { return r.n + r.tag + r.p.x + r.p.y; }
Big big_make(long v) { Big r = {v, 2 * v, 3 * v}; return r; }
Mixed mixed_make(float f) { Mixed r = {f, -7, 200}; return r; }
Pt pt_step(Pt (*f)(Pt), Pt p) { return f(f(p)); }
int pt_count(int (*f)(Pt), int n) { int t = 0; for (int i = 0; i < n; i++) { Pt q = {(double)i, 2.0 * i}; t += f(q); } return t; }
int sum_squares(int (*f)(int), int n) { int t = 0; for (int i = 1; i <= n; i++) t += f(i); return t; }
