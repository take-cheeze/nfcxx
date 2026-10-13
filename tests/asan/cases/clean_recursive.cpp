// CLEAN
// Recursion: each call has its own frame, so a call's local whose address goes to the next call is still valid for as long
// as that call runs, and each frame is given back when its call returns (the next call of the same function reuses it).
static int depth(int n, int *acc) {
  int here = n;
  int *p = &here;
  if (n == 0) return *acc;
  *acc += *p;
  int r = depth(n - 1, acc);
  return r + *p - here;
}
static int tree(int n) {
  int cell[4] = {n, n + 1, n + 2, n + 3};
  if (n <= 0) return cell[0];
  return tree(n - 1) + tree(n - 2) * 0 + cell[3] - cell[3];
}
int main(int argc, char **) {
  int total = 0;
  for (int i = 0; i < 50; i++) total += depth(20 + argc, &total) & 1;
  return (tree(12) == 0 && total >= 0) ? 0 : 1;
}
