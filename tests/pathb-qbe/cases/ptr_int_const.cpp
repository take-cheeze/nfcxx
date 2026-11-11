// An integer constant of pointer type that is not zero is an address, not a null pointer: (void *) 0x1000 reads back as
// 0x1000 from a global and from a function. A zero constant is still null.
// EXPECT: 3
static void * const base = (void *)(unsigned long)0x1000;
static void * other = (void *)(unsigned long)0x2000;
void * pick(int k) { return k ? (void *)(unsigned long)0x3000 : (void *)0; }
int main() {
  int r = 0;
  if (base == (void *)(unsigned long)0x1000) r += 1;
  if (other == (void *)(unsigned long)0x2000) r += 1;
  if (pick(0) == nullptr && pick(1) == (void *)(unsigned long)0x3000) r += 1;
  return r;
}
