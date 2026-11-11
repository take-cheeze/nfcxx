// EXPECT: 42
// a GNU attribute between the pointer and the declarator name (the kernel's __must_check on ERR_PTR)
static inline void * __attribute__((__warn_unused_result__)) ident(void *p) { return p; }
int main(void) {
	long v = 42;
	int * __attribute__((aligned(8))) q = (int *)&v;   /* attribute after '*' on an object declarator */
	return *(long *)ident(q);
}
