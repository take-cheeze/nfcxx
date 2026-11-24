// EXPECT: 194
// IR-OPT: --hoist-pure
// A pure call whose loop writes the memory it reads runs every time: the store in the first loop and the impure call bump
// in the second change the result from one iteration to the next. Hoisting it would change the exit status.
static long cells[8];
__attribute__((noinline)) long read_cell(int k) { return cells[k & 7] * 3 + 1; }
__attribute__((noinline)) void bump() { cells[3] += 2; }
int main() {
  long acc = 0;
  for (int i = 0; i < 20; i++) {
    cells[3] = i;
    acc += read_cell(3);
  }
  for (int i = 0; i < 20; i++) {
    bump();
    acc += read_cell(3);
  }
  return (int)(acc & 255);
}
