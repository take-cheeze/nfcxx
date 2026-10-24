// EXPECT: 46
// A body of labels and gotos with no loop (the emitter's dispatch lowering): a backward goto makes the loop.
int collatz_steps(int n) {
  int steps = 0;
again:
  if (n == 1) goto done;
  if (n % 2 == 0) goto even;
  n = 3 * n + 1;
  goto count;
even:
  n = n / 2;
count:
  steps++;
  goto again;
done:
  return steps;
}

int main() { return collatz_steps(27) - 65; }
