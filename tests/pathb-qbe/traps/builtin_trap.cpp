// __builtin_trap is an illegal instruction (QBE's hlt, ud2 on x86-64), as in gcc: the process dies of SIGILL (exit 132),
// not of the SIGABRT (134) that the checked operations raise. Nothing after it runs.
// TRAP-EXIT: 132
#include <stdio.h>
static int reached(int x) {
  if (x > 2) __builtin_trap();
  return x;
}
int main() {
  int s = 0;
  for (int i = 0; i < 10; ++i) s += reached(i);
  puts("not reached");
  return s;
}
