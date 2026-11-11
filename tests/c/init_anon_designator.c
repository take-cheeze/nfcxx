// EXPECT: 42
// A designator of a member of an anonymous struct or union: positional initializers go on after it, inside the
// anonymous member and then after it, as gcc does (and a compound literal with one, drivers/hid's
// (struct hid_device_id){ .kernel ... }, does not crash the parser)
struct s { int a; struct { int b; int c; }; int d; int e; };
struct s x = { .b = 1, 2, 3 };
struct s y = { .c = 5, 6, 7 };
struct u { int a; union { int b; long c; }; int d; };
struct u z = { .b = 1, 9 };
struct n { int a; struct { int b; struct { int c; int d; }; }; int e; };
struct n w = { .c = 1, 2, 3 };
struct f { int n; struct { int kernel; }; int tail[]; };
int get(void) { return ((struct f){ .kernel = 4 }).kernel; }
int main(void) {
	if (x.a || x.b != 1 || x.c != 2 || x.d != 3 || x.e) return 1;
	if (y.b || y.c != 5 || y.d != 6 || y.e != 7) return 2;
	if (z.b != 1 || z.d != 9) return 3;
	if (w.b || w.c != 1 || w.d != 2 || w.e != 3) return 4;
	return get() == 4 ? 42 : 5;
}
