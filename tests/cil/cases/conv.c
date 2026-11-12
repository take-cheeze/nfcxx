// EXPECT: 41
#include <stdio.h>
#include <alloca.h>
#include <string.h>
// Conversions, float compares, a switch in a loop (continue and break), alloca, volatile stores, bit-fields, and a struct
// passed and returned by value: the forms the Path B route (scripts/pathb-cil-emit.rb) translates beyond the first cases.
struct bits { int a : 5; unsigned b : 11; long long c : 40; };
struct pair { int x; double y; };
static struct pair mk(int x, double y) { struct pair p = { x, y }; return p; }
static double sum(struct pair p, struct pair q) { return p.x + q.x + p.y + q.y; }
static int classify(int n) {
    int hits = 0;
    for (int i = 0; i < n; i++) {
        switch (i % 4) {
        case 0: continue;
        case 1: hits += 1; break;
        case 2: hits += 10;
        case 3: hits += 100; break;
        default: hits += 1000;
        }
        hits += 2;
    }
    return hits;
}
int main(void) {
    unsigned int u = 0xfffffff0u; long long wide = u;                 // zero extension of an unsigned 32-bit value
    int neg = -5; long long sx = neg;                                  // sign extension
    int big = 0x1234abcd; unsigned char uc = (unsigned char)big; signed char sc = (signed char)0x80; short sh = (short)0x18000;
    double d = 2.9;
    int c1 = d < 3.0, c2 = d <= 2.9, c3 = d > 3.0, c4 = d >= 2.95, c5 = d != d, c6 = !(d >= 3.0);
    unsigned long long ull = 3000000000u; double fu = (double)ull, fi = (double)(long long)-7;
    float f = (float)1.25; int trunc = (int)(-d), ut = (unsigned)3.99;
    unsigned short us = (unsigned short)(d * 20000.0);
    struct bits b = { -3, 2000, -5 }; b.a += 1; b.c = b.c * 3;
    volatile int vi = 0; vi = 7; vi++;
    char *buf = alloca(40); memset(buf, 'z', 39); buf[39] = 0;
    struct pair s = mk(2, 0.5);
    printf("%lld %lld %d %d %d %d%d%d%d%d%d\n", wide, sx, uc, sc, sh, c1, c2, c3, c4, c5, c6);
    printf("%.1f %.1f %.2f %d %d %d %d %lld %d\n", fu, fi, f, trunc, ut, b.a, b.b, b.c, vi);
    printf("%u\n", us);
    printf("%d %zu %.1f\n", classify(10), strlen(buf), sum(s, mk(1, 1.5)));
    return (int)(wide >> 28) + (c1 + c2) + sc / -128 + vi + (int)sum(s, s) + b.a + 12 + (classify(10) == 0);
}
