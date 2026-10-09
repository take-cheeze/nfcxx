// Falling off the end of a non-void function is undefined; the IR says unreachable, which must abort.
__attribute__((noinline)) int id(int x) { return x; }
__attribute__((noinline)) int pick(int x) { if (x > 0) return 1; }
int main() { return pick(id(-1)); }
