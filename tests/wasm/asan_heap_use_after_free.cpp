// ASAN: heap-use-after-free
// A read of a block after it was freed: the block is in the quarantine, so its granules are poisoned.
extern "C" void* malloc(unsigned long n);
extern "C" void free(void* p);
int main() {
  int* p = (int*)malloc(16);
  p[1] = 5;
  free(p);
  return p[1];
}
