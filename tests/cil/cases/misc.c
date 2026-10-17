// EXPECT: 77
#include <stdio.h>
#include <alloca.h>
#include <string.h>
struct big { int a[20]; char name[12]; };
union pun { float f; unsigned int u; unsigned char b[4]; };
struct bits { unsigned lo : 3; unsigned mid : 5; signed hi : 4; };
static struct big make_big(int seed) { struct big b; for (int i = 0; i < 20; i++) b.a[i] = seed * i; strcpy(b.name, "big"); return b; }
static int fill(int n) { int *p = alloca(n * sizeof(int)); for (int i = 0; i < n; i++) p[i] = i * 3; int s = 0; for (int i = 0; i < n; i++) s += p[i]; return s; }
static int next_id(void) { static int table[4] = { 10, 20, 30, 40 }; static int k; return table[k++ & 3]; }
int main(void) {
    struct big x = make_big(2), y;
    y = x;
    y.a[19] += 1;
    union pun u; u.f = 1.0f;
    struct bits bt = { 5, 17, -3 };
    printf("%d %d %s %x %x %d %d %d\n", x.a[19], y.a[19], y.name, u.u, u.b[3], bt.lo, bt.mid, bt.hi);
    printf("%d %d %d\n", fill(5), next_id(), next_id() + next_id());
    unsigned long big = 18446744073709551000ul;
    printf("%lu %lu\n", big / 7, big % 7);
    return (x.a[19] + y.a[19]) & 0xff;
}
