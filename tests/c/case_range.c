// EXPECT: 42
// GNU case ranges: next to single values, across zero in a signed switch, at the top of an unsigned one, on char and
// long values; overlapping labels are an error (docs/notes/cproc-nfcxx.md)
static int s(int x) {
	switch (x) {
	case -100 ... -10: return 1;
	case -9 ... 9:     return 2;     /* crosses zero */
	case 10:           return 3;
	case 11 ... 1000:  return 4;
	default:           return 5;
	}
}
static int u(unsigned x) {
	switch (x) {
	case 0 ... 9:            return 1;
	case 0xfffffff0u ... 0xffffffffu: return 2;
	default:                 return 3;
	}
}
static int c(char ch) {
	switch (ch) {
	case 'a' ... 'z': return 1;
	case 'A' ... 'Z': return 2;
	case '0' ... '9': return 3;
	}
	return 0;
}
static int l(long x) { switch (x) { case -5000000000L ... 5000000000L: return 1; default: return 0; } }
int main(void) {
	int t[] = { s(-100), s(-50), s(-10), s(-9), s(0), s(9), s(10), s(11), s(500), s(1000), s(1001), s(-101) };
	int w[] = { 1, 1, 1, 2, 2, 2, 3, 4, 4, 4, 5, 5 };
	for (int i = 0; i < 12; i++) if (t[i] != w[i]) return 1 + i;
	if (u(0) != 1 || u(9) != 1 || u(10) != 3 || u(0xfffffff0u) != 2 || u(0xffffffffu) != 2 || u(0xffffffefu) != 3) return 20;
	if (c('m') != 1 || c('Q') != 2 || c('5') != 3 || c('!') != 0) return 21;
	if (l(-5000000000L) != 1 || l(4999999999L) != 1 || l(5000000001L) != 0 || l(0) != 1) return 22;
	return 42;
}
