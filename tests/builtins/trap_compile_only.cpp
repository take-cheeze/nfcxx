// EXPECT: 0
// XFAIL-qbe: cproc has no __builtin_trap (EDG passes the name through to C)
// __builtin_trap: compiled, but only reached behind a condition that is never true,
// so the program does not trap. (Executing it would abort the process.)
[[noreturn]] static void panic() { __builtin_trap(); }
int main() {
  int x = 1;
  if (x == 2) panic();
  return 0;
}
