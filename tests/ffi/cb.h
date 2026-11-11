/* The callback test (tests/ffi/host.cpp): the C side calls host callables through trampolines. */
int apply_twice(int (*f)(int), int x);
void each_pair(void (*cb)(int, double), int n);
int sum_with(int (*f)(int, double), int n);
typedef struct { double x, y; } Pt;
Pt step_pt(Pt (*f)(Pt), Pt p);
int count_pts(int (*f)(Pt), int n);
