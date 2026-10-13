// ASAN: heap-buffer-overflow
// A byte read past a 5-byte heap block: the block's last granule is partly addressable (5 bytes), and the read
// is in the granule after it, the redzone.
extern "C" void* malloc(unsigned long n);
int main() {
  char* p = (char*)malloc(5);
  p[0] = 1;
  return p[5];
}
