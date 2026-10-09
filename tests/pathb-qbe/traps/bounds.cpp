// Array bounds: an index past the end of a local array must abort (bounds).
__attribute__((noinline)) int id(int x) { return x; }
__attribute__((noinline)) int get(int i) { int a[4] = {1, 2, 3, 4}; return a[i]; }
int main() { return get(id(4)); }
