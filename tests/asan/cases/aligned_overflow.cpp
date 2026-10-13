// ASAN: stack-buffer-overflow
// ASAN-QBE: use-after-poison   (qbe poisons redzones with __asan_poison_memory_region, see stack_overflow.cpp)
// An object aligned over 16 bytes has redzones around its aligned address, not only at 16-byte alignment.
int sink(int *p, int i) { return p[i]; }
int main(int argc, char **) {
  alignas(64) int a[4] = {1, 2, 3, 4};
  return sink(a, 4 + argc);
}
