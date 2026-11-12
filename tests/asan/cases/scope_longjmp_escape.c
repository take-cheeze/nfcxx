// ASAN: stack-use-after-scope
// ASAN-ONLY: pathb   (gcc reports nothing here: its scope poison does not run on a longjmp; Path B does not poison at the setjmp return yet: tests/asan/pathb-pending.txt)
/* A longjmp in the same function leaves the block of x for the setjmp: the pointer kept from x's block is read after the
   landing, when x's scope has ended. */
#include <setjmp.h>

static jmp_buf jb;
static int *gp;

int main(void) {
	if (setjmp(jb) == 0) {
		{
			int x = 42;
			gp = &x;
			longjmp(jb, 1);
		}
	} else {
		return *gp;
	}
	return 0;
}
