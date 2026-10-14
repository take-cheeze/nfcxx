// ASAN: attempting-double-free
// A block freed twice: the second free finds it quarantined.
extern "C" void* malloc(unsigned long n);
extern "C" void free(void* p);
int main() {
  void* p = malloc(16);
  free(p);
  free(p);
  return 0;
}
