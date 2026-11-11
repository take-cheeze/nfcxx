/* C: function pointers. A table of operations, a sort that takes its comparison as a pointer, and a callback;
   each call through a pointer is a call_indirect into the module's function table. puts and putchar print to the
   Console (declared by hand, so the freestanding emscripten mode builds this too). */
int puts(const char *s);
int putchar(int c);

typedef int (*binop)(int, int);
static int add(int a, int b) { return a + b; }
static int mul(int a, int b) { return a * b; }
static int max(int a, int b) { return a > b ? a : b; }

static const struct { const char *name; binop f; } ops[] = { { "add", add }, { "mul", mul }, { "max", max } };

static int fold(binop f, const int *v, int n) {
  int acc = v[0];
  for (int i = 1; i < n; i++) acc = f(acc, v[i]);
  return acc;
}

static int ascending(int a, int b) { return a - b; }
static int descending(int a, int b) { return b - a; }

static void sort(int *v, int n, int (*cmp)(int, int)) {
  for (int i = 1; i < n; i++)
    for (int j = i; j > 0 && cmp(v[j - 1], v[j]) > 0; j--) {
      int t = v[j]; v[j] = v[j - 1]; v[j - 1] = t;
    }
}

static void print_int(int x) {
  char buf[12];
  int n = 0;
  if (x == 0) buf[n++] = '0';
  while (x > 0) { buf[n++] = (char)('0' + x % 10); x /= 10; }
  while (n > 0) putchar(buf[--n]);
}

int main(void) {
  int v[] = { 4, 1, 3, 5, 2 };
  int total = 0;
  for (int i = 0; i < 3; i++) {
    int r = fold(ops[i].f, v, 5);
    for (const char *p = ops[i].name; *p; p++) putchar(*p);
    putchar(' ');
    print_int(r);
    putchar('\n');
    total += r;
  }
  sort(v, 5, descending);
  puts(v[0] == 5 ? "sorted descending" : "not sorted");
  sort(v, 5, ascending);
  return total + v[0] * 1000;   /* 15 + 120 + 5 + 1000 */
}
