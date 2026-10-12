// CLEAN
// The same kind of exit with nothing wrong: a throw in the same frame leaves blocks whose objects a destructor still
// uses while the runtime unwinds (before the handler runs, so they are in scope), an object of the block that encloses
// the try is used in the handler, and a block the throw left is entered again by the next pass.
#include <cstdio>

int *gp;

struct Guard {
	int *p;
	explicit Guard(int *q) : p(q) {}
	~Guard() { *p = -1; }
};

int run(int n) {
	int acc = 0;
	for (int i = 0; i < 2; i++) {
		try {
			int x = i + n;
			Guard g(&x);
			{
				int y = 3;
				gp = &y;
				if (x > 0)
					throw i;
			}
		} catch (int e) {
			acc += e + 1;
		}
	}
	return acc;
}

int main() {
	return run(1) == 3 ? 0 : 1;
}
