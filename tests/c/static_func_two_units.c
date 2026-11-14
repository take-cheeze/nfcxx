// EXPECT: 0
// SOURCES: static_func_two_units.c static_func_two_units_b.c
// A `static` function has internal linkage: two units may define one under the same name (mruby's libmruby has `static inline
// mrb_type` in every unit; Path B exported them and the link failed with "multiple definition").
static int helper(int x) { return x + 1; }
int (*a_helper(void))(int) { return helper; }
int b_call(int);
int main(void) { return helper(1) == 2 && b_call(1) == 11 && a_helper()(5) == 6 ? 0 : 1; }
