// ASAN: stack-use-after-scope
// ASAN-ONLY: pathb   (gcc reports nothing here: EDG lowers the throw to a longjmp to the try's setjmp, and gcc's scope poison does not run on that path; Path B does not poison at the setjmp return yet: tests/asan/pathb-pending.txt)
// A C++ exception thrown in the same frame leaves the block of x for the handler (EDG lowers the throw to a longjmp to the
// try's setjmp). The pointer kept from x's block is read in the handler: x's scope has ended.
#include <cstdio>

int *gp;

int main() {
	try {
		{
			int x = 42;
			gp = &x;
			if (x == 42)
				throw 1;
		}
	} catch (int) {
		return *gp;
	}
	return 0;
}
