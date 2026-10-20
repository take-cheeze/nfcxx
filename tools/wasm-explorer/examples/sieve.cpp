// The primes below 100: a static array, nested loops and a branch.
static bool composite[100];

int main() {
  int count = 0;
  for (int i = 2; i < 100; ++i) {
    if (composite[i])
      continue;
    ++count;
    for (int j = i * i; j < 100; j += i)
      composite[j] = true;
  }
  return count;
}
