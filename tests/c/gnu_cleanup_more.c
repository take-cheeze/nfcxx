// EXPECT: 42
// GNU cleanup attribute, more shapes (gnu_cleanup.c has the basics): several in one scope run in reverse declaration order,
// a cleanup reads the variable's value at scope exit, a return value computed before the cleanups run, while and do-while loops
// with break and continue, a backward goto out of a scope, nested loops and a goto out of both, a cleanup of a function
// argument-sized object (a struct), and a switch.
static int log[128], n;
static void rec(int *p) { log[n++] = *p; }
static void bump(int *p) { *p += 1; log[n++] = 1000 + *p; }
struct pair { int a, b; };
static void recp(struct pair *p) { log[n++] = p->a * 10 + p->b; }
#define G(v) int v __attribute__((cleanup(rec)))

static int order(void) { G(a) = 1; G(b) = 2; G(c) = 3; return 7; }
static int late(void) { G(a) = 1; a = 5; return a + 1; }   /* the cleanup sees 5, the result is 6 */
static int value_first(void) { int x __attribute__((cleanup(bump))) = 10; return x; }   /* returns 10 though bump makes it 11 */
static void whiles(void) {
	int i = 0;
	while (i < 4) { G(w) = 20 + i; i++; if (i == 2) continue; if (i == 3) break; }
	i = 0;
	do { G(d) = 30 + i; i++; if (i == 1) continue; } while (i < 2);
}
static void back(void) {
	int k = 0;
again:
	{ G(g) = 40 + k; if (++k < 3) goto again; }
}
static void nested(void) {
	for (int i = 0; i < 3; i++) {
		G(o) = 50 + i;
		for (int j = 0; j < 3; j++) {
			G(p) = 60 + j;
			if (i == 1 && j == 1) goto out;
		}
	}
out:;
}
static void structs(void) { struct pair q __attribute__((cleanup(recp))) = { 7, 3 }; (void)q; }
static void sw(int x) {
	switch (x) {
	case 1: { G(s1) = 80; break; }
	case 2: { G(s2) = 81; }   /* falls out of the block, then the switch */
	default: break;
	}
}
int main(void) {
	int r;
	r = order(); if (r != 7) return 1;
	r = late(); if (r != 6) return 2;
	r = value_first(); if (r != 10) return 3;
	whiles(); back(); nested(); structs(); sw(1); sw(2); sw(3);
	int expect[] = { 3, 2, 1, 5, 1011, 20, 21, 22, 30, 31, 40, 41, 42, 60, 61, 62, 50, 60, 61, 51, 73, 80, 81 };
	if (n != (int)(sizeof expect / sizeof expect[0])) return 10 + n;
	for (int i = 0; i < n; i++) if (log[i] != expect[i]) return 50 + i;
	return 42;
}
