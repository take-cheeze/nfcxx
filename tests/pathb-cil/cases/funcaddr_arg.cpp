// EXPECT: 42
// Path B CIL spike: the address of a named function (&"f") passed to a callee, which calls it through the pointer (an
// indirect call, calli on the stored address). apply(twice, 21) = 2 * 21.
static int twice(int x) { return 2 * x; }
static int apply(int (*f)(int), int v) { return f(v); }
int main(void) { return apply(twice, 21); }
