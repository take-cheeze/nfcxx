// ASAN-EXPECT: 51127
// Clean under the mode: blocks are freed and allocated within the heap. A block of 512 bytes is written and freed, then 200
// blocks of 1024 bytes are written, read and freed: 200 * 1088 bytes of chunks fit the 256 KB heap, since no address is
// handed out twice. Every access is in bounds. The sum is 127 + 200 * (255 - 0) = 51127.
extern "C" void* malloc(unsigned long n);
extern "C" void free(void* p);
int main() {
  long sum = 0;
  int* first = (int*)malloc(512);
  for (int j = 0; j < 128; j++) first[j] = j;
  sum += first[127];
  free(first);
  for (int i = 0; i < 200; i++) {
    int* b = (int*)malloc(1024);
    for (int j = 0; j < 256; j++) b[j] = i + j;
    sum += b[255] - b[0];
    free(b);
  }
  return (int)sum;
}
