// ASAN: heap-buffer-overflow
// C++ variable-length arrays: a and b are small VLAs declared one after the other. EDG's allocator carved both from one
// shared block, so the write past a's end went into b unreported. Each VLA is a malloc block of its own now (see
// lib/asan/nfcxx_vla_asan.c), so the write is one past the end of a's block, in its redzone.
static int fill(int n) {
  int a[n];
  int b[n];
  b[0] = 9;
  for (int i = 0; i <= n; ++i) a[i] = i;   // a[n] is past the end
  return a[0] + b[0];
}
int main(int argc, char **) {
  return fill(argc + 3);
}
