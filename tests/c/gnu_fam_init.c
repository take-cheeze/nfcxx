// EXPECT: 42
// GNU: a static initializer of a flexible array member (the kernel's init_mm.cpu_bitmap, init_struct_pid.numbers):
// the array takes its initializers, and the object is sizeof the struct plus them, as gcc lays it out
#include <string.h>
struct s { long a; char c; int n[]; };
struct s x = { 1, 2, { 3 } };
struct s y = { 1, 2, { 3, 4, 5, 6 } };
struct s z = { 1, 2 };
static struct s d = { .n = { [2] = 9 }, .a = 5 };
struct t { long a; char c; char n[]; };
struct t w = { 1, 2, { 3 } };
struct t str = { 1, 2, "hello" };
struct inner { int nr; void *ns; };
struct pid { int count; struct inner numbers[]; } init_pid = { .count = 1, .numbers = { { .nr = 0, .ns = &x }, } };
struct after { struct s s; int tail; };
struct after af = { { 1, 2 }, 3 };   /* no initializer for the inner flexible member */
extern char sx[], sy[], sw[], sstr[], spid[], sd[];
int main(void) {
	if (sizeof x != 16 || x.n[0] != 3 || y.n[3] != 6 || z.c != 2 || w.n[0] != 3) return 1;
	if (d.a != 5 || d.n[2] != 9 || d.n[0] != 0) return 2;
	if (strcmp(str.n, "hello") || init_pid.numbers[0].ns != &x || init_pid.count != 1) return 3;
	if (af.tail != 3) return 4;
	/* the objects follow one another without overlapping: y's elements are not z's */
	if (z.a != 1 || y.n[0] != 3) return 5;
	return 42;
}
