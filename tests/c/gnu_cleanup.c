// EXPECT: 42
// GNU C cleanup attribute (cproc -G for hand-written C and the kernel): the cleanup runs when the object leaves its
// scope -- block end, return, break, continue, goto -- innermost first, in the order gcc runs them
static int log[64], n;
static void rec(int *p) { log[n++] = *p; }
#define guard(v) int v __attribute__((cleanup(rec)))
static int early(int x) { guard(a) = 1; { guard(b) = 2; if (x) return 10; } guard(c) = 3; return 20; }
static void loops(void) {
	for (int i = 0; i < 3; i++) { guard(l) = 100 + i; if (i == 1) continue; if (i == 2) break; }
	for (int s __attribute__((cleanup(rec))) = 7, done = 0; !done; done = 1) { guard(t) = 8; }
	switch (n) { default: { guard(w) = 9; break; } }
}
static int jumps(int x) {
	guard(k) = 32;
	{ guard(g) = 30; if (x) goto out; guard(h) = 31; }
out:
	return 0;
}
int main(void) {
	int want[] = { 2, 1, 2, 3, 1, 100, 101, 102, 8, 7, 9, 31, 30, 32, 30, 32 };
	if (early(1) != 10) return 1;
	if (early(0) != 20) return 2;
	loops();
	jumps(0); jumps(1);
	if (n != (int)(sizeof want / sizeof want[0])) return 3;
	for (int i = 0; i < n; i++) if (log[i] != want[i]) return 10 + i;
	return 42;
}
