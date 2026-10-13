// ASAN: heap-buffer-overflow
// A store one int past the end of an 8-byte heap block, through a pointer: it lands in the block's right redzone.
extern "C" void* malloc(unsigned long n);
int main() {
  int* p = (int*)malloc(8);
  p[2] = 7;
  return 0;
}
