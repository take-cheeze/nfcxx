struct P { int x; long y; };

static P table[4] = {{1, 10}, {2, 20}, {3, 30}, {4, 40}};

long dot(const P* p, int n) {
  long s = 0;
  for (int i = 0; i < n; ++i)
    s += p[i].x * p[i].y;
  return s;
}

int main() {
  return (int)dot(table, 4);
}
