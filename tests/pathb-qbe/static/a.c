__attribute__((noinline)) static int helper(int x) { return x + 1; }
int a_val(int x) { return helper(x); }
