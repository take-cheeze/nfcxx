// EXPECT: 42
// GNU: a string initializer of a flexible array member (and elements of a wider one): the object is the struct plus them.
#include <string.h>
struct msg { int len; char text[]; };
struct msg a = { 5, "hello" };
struct msg b = { 0, "" };
struct msg c = { 11, "hello world" };
static struct wmsg { char tag; int w[]; } d = { 'x', { 1, 2, 3, 4, 5, 6, 7, 8, 9 } };
extern struct msg a, b, c;
int main(void) {
	if (strcmp(a.text, "hello") || a.len != 5) return 1;
	if (b.text[0] != 0) return 2;
	if (strcmp(c.text, "hello world") || strlen(c.text) != 11) return 3;
	int s = 0;
	for (int i = 0; i < 9; i++) s += d.w[i];
	if (s != 45 || d.tag != 'x') return 4;
	if (sizeof(struct msg) != 4) return 5;
	return 42;
}
