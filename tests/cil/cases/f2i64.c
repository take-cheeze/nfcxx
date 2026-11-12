// EXPECT: 56
// PATHB-ONLY: scripts/qbe2cil.rb converts a double to a 64-bit integer through 32 bits ((long long)-2.9e9 is -2147483648 there)
#include <stdio.h>
int main(void) {
    double d = 2.9, big = 1.8e19;
    unsigned long long u = (unsigned long long)(d * 1e9), v = (unsigned long long)big;
    long long l = (long long)(-d * 1e9), m = (long long)(-9.2e18 + d);
    printf("%llu %lld %llu %lld\n", u, l, v, m);
    return (int)(u >> 30) + (int)(l >> 31) + (int)(v >> 60) * 2 + (int)(m >> 62) + 28;
}
