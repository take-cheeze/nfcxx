__attribute__((noinline)) static int helper(int x) { return x * 2; }
int b_val(int x) { return helper(x); }

