// EXPECT: 42
// the 'aligned' attribute on a typedef, and on a struct/object (docs/notes/cproc-nfcxx.md)
typedef int aligned_int __attribute__((aligned(16)));
struct S { int a; } __attribute__((aligned(32)));
int main(void) {
	if (__alignof__(aligned_int) != 16) return 1;
	if (__alignof__(struct S) != 32) return 2;
	return 42;
}
