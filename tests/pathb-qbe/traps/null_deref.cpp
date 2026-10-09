// Null pointer: a dereference of a null pointer must abort (nonnull).
__attribute__((noinline)) int get(int *p) { return *p; }
int main() { return get(nullptr); }
