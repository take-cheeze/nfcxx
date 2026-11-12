// EXPECT: 42
// GNU case ranges of more than 1024 values: a compare pair before the switch, not one label per value. Next to single
// labels and a small range, on int, unsigned, char, long, with a default, with fall-through between the labels, nested.
static int s(int x) {
	switch (x) {
	case 1: return 1;
	case 2 ... 5: return 2;
	case 100 ... 100000: return 3;
	case -100000 ... -100: return 4;
	default: return 5;
	}
}
static int u(unsigned x) {
	switch (x) {
	case 0 ... 5000: return 1;
	case 0x80000000u ... 0xffffffffu: return 2;
	default: return 3;
	}
}
static int l(unsigned long x) {
	switch (x) {
	case 0 ... 0xffffffffffffffffUL: return 1;   /* every value */
	}
	return 0;
}
static int h(unsigned long x) {
	switch (x) {
	case 0x8000000000000000UL ... 0xfffffffffffffff0UL: return 1;
	case 7: return 2;
	}
	return 0;
}
static int c(signed char ch) {
	switch (ch) {
	case -128 ... -2: return 1;
	case -1: return 2;
	case 0 ... 127: return 3;
	}
	return 0;
}
static int ft(int x) {   /* the big range's label is entered by falling through, and by the compare */
	int r = 0;
	switch (x) {
	case 1: r += 1;
	case 2000 ... 4000: r += 10;
	case 5: r += 100; break;
	default: r = -1;
	}
	return r;
}
static int nest(int x, int y) {
	switch (x) {
	case 0 ... 5000:
		switch (y) {
		case 0 ... 3000: return 1;
		default: return 2;
		}
	default: return 3;
	}
}
int main(void) {
	if (s(1) != 1 || s(3) != 2 || s(99) != 5 || s(100) != 3 || s(100000) != 3 || s(100001) != 5) return 1;
	if (s(-100) != 4 || s(-100000) != 4 || s(-100001) != 5 || s(-99) != 5 || s(0) != 5) return 2;
	if (u(0) != 1 || u(5000) != 1 || u(5001) != 3 || u(0x7fffffffu) != 3 || u(0x80000000u) != 2 || u(0xffffffffu) != 2) return 3;
	if (l(0) != 1 || l(~0UL) != 1 || l(12345) != 1) return 4;
	if (h(0x7fffffffffffffffUL) != 0 || h(0x8000000000000000UL) != 1 || h(0xfffffffffffffff0UL) != 1 || h(0xfffffffffffffff1UL) != 0 || h(7) != 2) return 5;
	if (c(-128) != 1 || c(-2) != 1 || c(-1) != 2 || c(0) != 3 || c(127) != 3) return 6;
	if (ft(1) != 111 || ft(2000) != 110 || ft(3000) != 110 || ft(4000) != 110 || ft(4001) != -1 || ft(5) != 100 || ft(1999) != -1) return 7;
	if (nest(10, 10) != 1 || nest(10, 4000) != 2 || nest(6000, 1) != 3) return 8;
	return 42;
}
