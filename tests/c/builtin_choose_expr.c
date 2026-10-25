// EXPECT: 42
// GNU __builtin_choose_expr: the chosen operand keeps its type and lvalue-ness; the other is not evaluated (the program
// links although never_defined has no definition)
static int a = 1; static long b = 2; extern int never_defined(void);
#define pick(c) __builtin_choose_expr(c, a, b)
int main(void){ pick(1) = 40; return (int)sizeof(pick(0)) == 8 && pick(1) == 40 && __builtin_choose_expr(0, never_defined(), 2) == 2 ? 42 : 1; }
