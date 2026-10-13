// ASAN: heap-use-after-free
// A stale read of a block after its address was handed out again. The 16-byte block is freed, then a 4000-byte block is
// allocated and freed: the 4 KB quarantine of an allocator that reuses freed blocks evicts the 16-byte block to its free
// list, and the next 16-byte allocation takes it. The stale read of the first block must still be reported: no address
// is handed out twice, so the block is still freed.
extern "C" void* malloc(unsigned long n);
extern "C" void free(void* p);
int main() {
  int* p = (int*)malloc(16);
  p[1] = 5;
  free(p);
  int* big = (int*)malloc(4000);
  free(big);
  int* r = (int*)malloc(16);
  r[1] = 77;
  return p[1];
}
