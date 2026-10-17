// EXPECT: 2
#include <stdio.h>
int main(void) {
    int a = -17, b = 5;
    unsigned int ua = 0xfffffff0u, ub = 7;
    short sh = -300; unsigned char uc = 250; signed char sc = -100;
    long long big = 1234567890123LL;
    printf("%d %d %d %d\n", a / b, a % b, a >> 2, (int)((unsigned)a >> 28));
    printf("%u %u %u\n", ua / ub, ua % ub, ua >> 3);
    printf("%d %d %d\n", (int)sh, (int)uc, (int)sc);
    printf("%lld %lld\n", big / 1000, big % 1000);
    printf("%d %d %d\n", a < b, (unsigned)a < ub, (uc + sc) < 0);
    double d = 2.75; float f = 1.5f;
    printf("%d %u %.2f %.2f %d\n", (int)d, (unsigned)(d * 4), d * f, (double)(f / 4), (int)(-d));
    return (a + b + sh + uc) & 0x3f;
}
