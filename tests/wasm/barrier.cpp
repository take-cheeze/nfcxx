// A compiler barrier: the module is one thread with no shared memory, so it has no code, and the statements around it
// keep their order.
// EXPECT: 7
static int g;

int main() {
  int x = 3;
  g = x;
  __asm__ __volatile__("" ::: "memory");
  g = g + 4;
  __asm__ __volatile__("" ::: "memory");
  return g;
}
