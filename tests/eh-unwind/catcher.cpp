#include <cstdio>
extern "C" int mid(int x);
int main() {
	try {
		mid(41);
	} catch (int v) {
		std::printf("caught %d\n", v);
		return v == 42 ? 7 : 1;
	}
	return 2;
}
