// CLEAN
// A return inside a loop, after variable-length arrays were allocated on earlier passes. That return is generated before
// the declaration, so only the function's return blocks can unpoison those allocations (asandynret). After find returns,
// the redzones of its last allocation must be addressable again, which libasan's interface reports directly.
int __asan_address_is_poisoned(const volatile void *);
static char *last;
static int find(int n) {
  for (int i = 0; i < 3; i++) {
    if (i == 2) return n;
    int a[n];
    last = (char *)a;
    a[0] = i;
    for (int j = 1; j < n; j++) a[j] = a[j - 1] + 1;
    if (a[n - 1] < 0) return -1;
  }
  return 0;
}
static int reuse(int n) {
  int big[48];
  for (int i = 0; i < 48; i++) big[i] = 0;
  big[47] = n;
  return big[47];
}
int main(void) {
  int s = 0;
  for (int i = 1; i < 60; i++) s += find(i % 13 + 1) + reuse(i);
  /* the last allocation has n = 8 ints: its 32-byte redzones are the 32 bytes before and after the array */
  s += find(8);
  int poisoned = __asan_address_is_poisoned(last - 1) || __asan_address_is_poisoned(last + 32);
  return (s != 0 && !poisoned) ? 0 : 1;
}
