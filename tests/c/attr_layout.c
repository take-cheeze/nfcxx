// EXPECT: 42
// Struct, union and enum layouts under GNU packed and aligned in every position cproc takes them, against gcc's
// x86-64 values (docs/notes/cproc-nfcxx.md). A wrong layout would miscompile silently, so each case is checked.
// X86-ONLY: the expected sizes are x86-64 SysV
struct p1 { char c; int a; } __attribute__((packed));
typedef struct { char c; long l; short s; } __attribute__((packed)) p2;
union  p3 { char c; int a; long l; } __attribute__((__packed__));
struct m1 { char c; int a __attribute__((packed)); char d; };
struct m2 { char c; int a __attribute__((packed, aligned(2))); char d; };
struct a1 { char c; unsigned long a[2] __attribute__((aligned(16))); };
struct a2 { char c; int x; } __attribute__((aligned(32)));
struct pa { char c; int a __attribute__((aligned(8))); } __attribute__((packed));
struct pp { char c; struct p1 in; short s; } __attribute__((packed));
struct np { char c; struct p1 in; int i; };
enum __attribute__((packed)) e1 { E1A, E1B = 200 };
enum e2 { E2A = -1, E2B = 100 } __attribute__((packed));
enum __attribute__((packed)) e3 { E3A = 70000 };
typedef int __attribute__((aligned(16))) ai;
struct sai { char c; ai x; };
static int __attribute__((aligned(64))) gv;
#include <stddef.h>
#include <stdlib.h>
static int n;
static void eq(size_t got, size_t want) { ++n; if (got != want) exit(n); }
int main(void) {
	eq(sizeof(struct p1), 5); eq(offsetof(struct p1, a), 1);
	eq(sizeof(p2), 11); eq(offsetof(p2, l), 1); eq(offsetof(p2, s), 9);
	eq(sizeof(union p3), 8); eq(_Alignof(union p3), 1);
	eq(sizeof(struct m1), 6); eq(offsetof(struct m1, a), 1); eq(offsetof(struct m1, d), 5); eq(_Alignof(struct m1), 1);
	eq(sizeof(struct m2), 8); eq(offsetof(struct m2, a), 2); eq(offsetof(struct m2, d), 6); eq(_Alignof(struct m2), 2);
	eq(sizeof(struct a1), 32); eq(offsetof(struct a1, a), 16); eq(_Alignof(struct a1), 16);
	eq(sizeof(struct a2), 32); eq(_Alignof(struct a2), 32);
	eq(sizeof(struct pa), 16); eq(offsetof(struct pa, a), 8); eq(_Alignof(struct pa), 8);
	eq(sizeof(struct pp), 8); eq(offsetof(struct pp, s), 6); eq(_Alignof(struct pp), 1);
	eq(sizeof(struct np), 12); eq(offsetof(struct np, i), 8); eq(_Alignof(struct np), 4);
	eq(sizeof(enum e1), 1); eq(sizeof(enum e2), 1); eq(sizeof(enum e3), 4); eq((enum e2)-1 < 0, 1);
	eq(sizeof(struct sai), 32); eq(offsetof(struct sai, x), 16); eq(_Alignof(ai), 16);
	eq((unsigned long)&gv % 64, 0);
	return 42;
}
