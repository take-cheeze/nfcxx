// EXPECT: 55
#include <stdio.h>
typedef int (*binop)(int, int);
static int add(int a, int b) { return a + b; }
static int mul(int a, int b) { return a * b; }
static binop table[2] = { add, mul };
static int run(binop f, int a, int b) { return f(a, b); }
int main(void) {
    int acc = 0;
    for (int i = 0; i < 2; i++) acc += run(table[i], 6, 7);
    binop p = (acc & 1) ? add : mul;
    printf("acc=%d p=%d\n", acc, p(3, 4));
    return acc & 0xff;
}
