// EXPECT: 49
// Struct copies and pointer members through pointers, with the statics and the stack: under --memory64 each memory
// access takes its i64 address as it is, and the copies' lengths are i64 (memory.copy).
struct Pair { long a; int *p; char c[5]; };
int g[3] = {4, 5, 6};
Pair gp = {10, &g[1], {1, 2, 3, 4, 5}};
int touch(Pair *q) { return (int)q->a + *q->p + q->c[4]; }
int main() {
  Pair local = gp;
  Pair *pp = &local;
  pp->a += 2;
  Pair *arr[2] = {&local, &gp};
  int t = 0;
  for (int i = 0; i < 2; i++) t += touch(arr[i]);
  return t + pp->c[0] + g[2];   // (12 + 5 + 5) + (10 + 5 + 5) + 1 + 6 = 49
}
