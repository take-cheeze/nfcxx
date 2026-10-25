/* The callback test (tests/ffi/host.cpp): the C side calls host callables through trampolines. */
int apply_twice(int (*f)(int), int x);
void each_pair(void (*cb)(int, double), int n);
int sum_with(int (*f)(int, double), int n);
