/* The definitions for tests/ffi/cb.h. No includes: the header comes first (Ffi::load). */
int apply_twice(int (*f)(int), int x) { return f(f(x)); }
void each_pair(void (*cb)(int, double), int n) { for (int i = 0; i < n; i++) cb(i, i * 0.5); }
int sum_with(int (*f)(int, double), int n) { int t = 0; for (int i = 0; i < n; i++) t += f(i, 0.25); return t; }
Pt step_pt(Pt (*f)(Pt), Pt p) { return f(f(p)); }
int count_pts(int (*f)(Pt), int n) { int t = 0; for (int i = 0; i < n; i++) { Pt q = {(double)i, 2.0 * i}; t += f(q); } return t; }
