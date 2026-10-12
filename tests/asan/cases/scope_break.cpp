// CLEAN
// break and continue out of blocks that declare objects. The jump poisons the objects of the blocks it leaves, and the
// code after the loop or the next iteration uses only objects of the enclosing scope or redeclares its own.
int main() {
  int sum = 0;
  int outer[3] = {1, 2, 3};
  for (int i = 0; i < 10; i++) {
    int skip[2] = {i, i + 1};
    if (i % 3 == 0) continue;
    {
      int inner = skip[1];
      if (inner > 7) break;
      sum += inner;
    }
    sum += outer[i % 3];
  }
  int n = 0;
  do {
    int step = n + 1;
    n += step > 0 ? 1 : 2;
    if (n < 5) continue;
  } while (n < 5);
  switch (sum & 3) {
  case 0: {
    int t = sum;
    sum = t + 1;
    break;
  }
  default: {
    int u[2] = {4, 5};
    sum += u[1];
    break;
  }
  }
  for (int k = 0; k < 4; k++) {
    int w[2] = {k, sum};
    if (w[0] == 2) break;
    sum += w[1] & 1;
  }
  return sum >= 0 && n == 5 ? 0 : 1;
}
