// ASAN: attempting-double-free
// A block freed and then, after the eviction described in asan_heap_reuse_read.cpp, a new 16-byte block r allocated.
// The second free of the first block is a double free: its block was freed, and no address is handed out twice, so r
// is not that block and the free must be reported.
extern "C" void* malloc(unsigned long n);
extern "C" void free(void* p);
int main() {
  void* p = malloc(16);
  free(p);
  void* big = malloc(4000);
  free(big);
  int* r = (int*)malloc(16);
  r[0] = 1;
  free(p);
  return 0;
}
