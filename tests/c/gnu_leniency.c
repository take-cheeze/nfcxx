// EXPECT: 42
// GNU C the Linux kernel's headers rely on: a keyword as an attribute name (__attribute__((const))), an empty member
// declaration, a ';' after a function body at file scope, a void function returning a void expression, and
// __builtin_memset/__builtin_memcpy as calls of the library functions
typedef struct { int *lock; ; } guard_t;
static __attribute__((const)) int twice(int x) { return 2 * x; }
static int hits;
static void bump(int n) { hits += n; }
static void bump_twice(int n) { return bump(twice(n)); };
int main(void) {
	char buf[8];
	guard_t g = { &hits };
	bump_twice(20);
	__builtin_memset(buf, 1, sizeof buf);
	__builtin_memcpy(buf, "\2", 1);
	return *g.lock + buf[0] + buf[7] - 1;
}
