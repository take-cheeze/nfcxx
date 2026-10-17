// EXPECT: 111
#include <stdio.h>
static int counter(void) { static int n = 0; return ++n; }
static int helper(int x) { return x + 1; }
int shared = 5;
int bump(void);
int main(void) {
    int a = counter(); int b = counter();
    printf("%d %d %d %d\n", a, b, helper(shared), bump());
    return bump() + helper(0);
}
