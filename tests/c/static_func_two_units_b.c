// helper source of static_func_two_units.c
static int helper(int x) { return x + 10; }
int b_call(int x) { return helper(x); }
