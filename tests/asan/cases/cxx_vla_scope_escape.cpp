// ASAN: heap-use-after-free
// A pointer to a C++ variable-length array kept past the block that declared it. The block ends, the VLA's storage is
// freed (each VLA is a malloc block of its own), and the read is a use after free.
static int *keep;
static void make(int n) {
  int v[n];
  v[0] = 7;
  keep = v;
}
int main(int argc, char **) {
  make(argc + 3);
  return *keep;
}
