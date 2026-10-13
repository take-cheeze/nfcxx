// ASAN: attempting-free-on-address-which-was-not-malloc
// A free of the address of a local, which the allocator did not return.
extern "C" void free(void* p);
int main() {
  int x = 3;
  free(&x);
  return x;
}
