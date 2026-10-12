// CLEAN
/* longjmp in the same function with nothing wrong: the block of inner is left, the block of outer (open at the setjmp)
   stays in scope and is used after the landing, the block of inner is entered again on the next pass, and the pointer
   into the left block is kept but not read. */
#include <setjmp.h>

static jmp_buf jb;
static int *gp;

int main(void) {
	int outer = 1;
	int *po = &outer;
	for (int i = 0; i < 2; i++) {
		if (setjmp(jb) == 0) {
			int inner = 7;
			{
				int deep = 5;
				gp = &deep;
				(void)inner;
				longjmp(jb, 1);
			}
		} else {
			*po += 1;
		}
	}
	return *po == 3 ? 0 : 1;
}
