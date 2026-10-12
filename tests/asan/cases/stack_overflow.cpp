// ASAN: stack-buffer-overflow
// ASAN-QBE: use-after-poison   (qbe poisons its redzones with __asan_poison_memory_region, which libasan reports as use-after-poison)
int sink(int *p, int i) { return p[i]; }
int main(int argc, char **) {
  int a[4] = {1, 2, 3, 4};
  return sink(a, 4 + argc);
}
