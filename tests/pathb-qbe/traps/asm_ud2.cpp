// asm volatile("ud2") is lowered to the same illegal instruction as __builtin_trap: SIGILL (exit 132).
// TRAP-EXIT: 132
static int reached(int x) {
  if (x == 4) __asm__ __volatile__("ud2");
  return x;
}
int main() {
  int s = 0;
  for (int i = 0; i < 10; ++i) s += reached(i);
  return s;
}
