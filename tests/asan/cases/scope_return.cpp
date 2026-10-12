// CLEAN
// return out of nested blocks. Nothing of the frame runs after the return (funcret unpoisons the frame), and the local of
// the block it leaves is not used after it; the returned value is computed before the jump.
static int find(const int *v, int n, int want) {
  for (int i = 0; i < n; i++) {
    int cell = v[i];
    {
      int twice = cell * 2;
      if (cell == want) return twice;
    }
  }
  return -1;
}
int main() {
  int v[5] = {1, 2, 3, 4, 5};
  return find(v, 5, 4) == 8 ? 0 : 1;
}
