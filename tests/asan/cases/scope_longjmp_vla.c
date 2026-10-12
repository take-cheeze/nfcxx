// CLEAN
/* setjmp in a loop around a VLA declared before it, and a switch whose case longjmps out of its block: the landing poisons
   the case's block, which the longjmp left; the VLA encloses the setjmp, so it stays in scope and is read after the landing. */
#include <setjmp.h>

static jmp_buf jb;

int main(void) {
	/* volatile: total changes between the setjmp and the longjmp (C11 7.13.2.1), so its value after it needs this */
	volatile int total = 0;
	int n = 4;
	int k = 0;
	for (;;) {
		int vla[n];
		vla[0] = k;
		if (setjmp(jb) == 0) {
			int inner = k;
			switch (inner % 2) {
			case 0: {
				int a = 3;
				total += a;
				longjmp(jb, 1);
			}
			default:
				total += 100;
				break;
			}
			total += vla[0];
		} else {
			total += 1000;
		}
		k++;
		if (k == 2)
			break;
	}
	return total == 1104 ? 0 : 1;
}
