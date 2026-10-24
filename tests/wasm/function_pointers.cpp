// EXPECT: 32
// Function pointers: calls through a pointer (call_indirect), a table of pointers in a static initializer, and a
// pointer passed as an argument and kept in a local.
static int add(int a, int b) { return a + b; }
static int mul(int a, int b) { return a * b; }
static int sub(int a, int b) { return a - b; }

typedef int (*op)(int, int);
static op ops[3] = {add, mul, sub};

static int fold(op f, const int* v, int n) {
  int acc = v[0];
  for (int i = 1; i < n; ++i) acc = f(acc, v[i]);
  return acc;
}

int main() {
  int v[4] = {1, 2, 3, 4};
  int r = fold(ops[0], v, 4) + fold(ops[1], v, 4) + fold(ops[2], v, 4);   // 10 + 24 - 8
  op p = mul;
  return r + p(2, 3);
}
