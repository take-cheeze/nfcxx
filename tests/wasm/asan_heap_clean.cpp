// ASAN-EXPECT: 63
// Clean under the mode: blocks of a partial granule (5 bytes), a whole one, and a struct, accessed in bounds (their last
// bytes included), then 1000 malloc/free pairs of 16 bytes. Without reuse the pairs would need 1000 blocks of 80 bytes
// (the heap is 64 KB): the loop only completes when a freed block is reused once the quarantine has evicted it.
extern "C" void* malloc(unsigned long n);
extern "C" void free(void* p);
struct S {
  int a;
  char b;
  long c;
};
int main() {
  char* c5 = (char*)malloc(5);
  c5[4] = 9;
  int* i4 = (int*)malloc(16);
  i4[3] = 4;
  S* s = (S*)malloc(sizeof(S));
  s->a = 1;
  s->b = 2;
  s->c = 3;
  long sum = 0;
  for (int i = 0; i < 1000; i++) {
    int* q = (int*)malloc(16);
    if (q == 0) return 1;
    q[0] = i;
    sum += q[0];
    free(q);
  }
  int r = c5[4] + i4[3] + s->a + s->b + (int)s->c + (int)(sum & 0xff);
  free(c5);
  free(i4);
  free(s);
  return r;
}
