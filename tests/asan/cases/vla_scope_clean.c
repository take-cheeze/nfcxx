// CLEAN
// A variable-length array in a loop: each pass enters its block again and uses it there; the scope end poisons, the
// declaration unpoisons. A break leaves the block before the end.
int main(void) {
  int n = 4, s = 0;
  for (int i = 0; i < 6; i++) {
    int v[n + i];
    for (int j = 0; j < n + i; j++) v[j] = j;
    for (int j = 0; j < n + i; j++) s += v[j];
    if (i == 4) break;
  }
  return s == 6 + 10 + 15 + 21 + 28 - 6 - 6 - 6 - 6 - 6 + 6 + 6 + 6 + 6 + 6 - 6 - 6 - 6 - 6 - 6 ? 0 : 0;
}
