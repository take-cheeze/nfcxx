// CLEAN
// A throw in the same frame that the inner try does not catch: its landing is the inner try's setjmp, which poisons the
// objects of the inner try body (out of scope there), and the outer handler runs without touching them. The pointer kept
// from the body is not read.
#include <cstdio>

int *gp;

int main() {
	int acc = 0;
	try {
		try {
			int x = 7;
			gp = &x;
			acc += x;
			throw 1.5;
		} catch (int) {
			acc += 100;
		}
	} catch (double d) {
		acc += (int)d;
	}
	return acc == 8 ? 0 : 1;
}
