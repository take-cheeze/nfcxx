// EXPECT: 42
// true/false/bool/nullptr are ordinary identifiers before C23 (the kernel's stddef.h/types.h idioms)
enum { false = 0, true = 1 };
typedef _Bool bool;
static bool positive(int x) { return x > 0; }
int main(void) {
	bool t = true, f = false;
	int nullptr = 7;                 /* 'nullptr' as a plain identifier */
	if (!positive(5) || positive(-1)) return 1;
	if (t != 1 || f != 0) return 2;
	return nullptr * 6;              /* 42 */
}
