// ASAN: allocator-out-of-memory
// 5000 blocks of 64 bytes, none freed: 128 bytes each with the redzones, 640000 bytes in all, more than the 256 KB heap.
// The request that does not fit is reported (its size is the report's address) and traps, as libasan does by default.
extern "C" void* malloc(unsigned long n);
int main() {
  long sum = 0;
  for (int i = 0; i < 5000; i++) {
    int* p = (int*)malloc(64);
    p[0] = i;
    sum += p[0];
  }
  return (int)(sum & 0xff);
}
