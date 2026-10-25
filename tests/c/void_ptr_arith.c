// EXPECT: 42
// GNU pointer arithmetic on void and function pointers (element size 1), sizeof(void), sizeof of a function
// (docs/notes/cproc-nfcxx.md); an increment used to add 0 to a void pointer
static void f(void) {}
int main(void) {
	char buf[16]; void *p = buf, *q = buf + 10;
	p = p + 3; p += 2; p++; ++p; p--;            /* 3 + 2 + 1 + 1 - 1 = 6 */
	if ((char *)p != buf + 6) return 1;
	if (q - p != 4) return 2;
	if (sizeof(void) != 1 || __alignof__(void) != 1 || sizeof(f) != 1) return 3;
	void (*fp)(void) = f; fp = fp + 0; if (fp != f) return 4;
	return 42;
}
