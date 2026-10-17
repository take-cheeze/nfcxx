// EXPECT: 7
// Path B CIL spike: a void callee and a callee that is itself passed a pointer, each called through a pointer taken from
// a named function. counter is 3 + 4 = 7; then sub(10, 3) = 7 through a pointer passed as an argument: 7 + 7 - 7 = 7.
static int counter;
static void bump(int by) { counter += by; }
static int sub(int a, int b) { return a - b; }
static void run(void (*f)(int), int by) { f(by); }
static int apply2(int (*g)(int, int), int a, int b) { return g(a, b); }
int main(void) {
  void (*f)(int) = bump;
  run(f, 3);
  run(bump, 4);
  return counter + apply2(sub, 10, 3) - 7;
}
