// ASAN: global-buffer-overflow
// ASAN-PATHB: use-after-poison
// A read of the first byte after a global char array of 8 bytes (exactly one shadow granule), through a computed address.
char g[8] = {1, 2, 3, 4, 5, 6, 7, 8};
int get(const char *p, int i) { return p[i]; }
int main(int argc, char **) { return get(g, 7 + argc); }
