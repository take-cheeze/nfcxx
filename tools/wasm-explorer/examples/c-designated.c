/* C (EDG in C mode): designated initializers, a compound literal, struct pointers and an insertion sort.
   main() returns 95 (the sorted values weighted by position) + 10 (a dot product) + 6 = 111. */
struct point { int x, y; };

static int dot(const struct point *a, const struct point *b) { return a->x * b->x + a->y * b->y; }

static void sort(int *v, int n) {
  for (int i = 1; i < n; i++) {
    int key = v[i], j = i - 1;
    while (j >= 0 && v[j] > key) { v[j + 1] = v[j]; j--; }
    v[j + 1] = key;
  }
}

int main(void) {
  struct point pts[] = { [0] = { .x = 1, .y = 2 }, [1] = { .y = 4, .x = 3 }, [2] = { 5, 6 } };
  int v[] = { 9, 3, 7, 1, 5 };
  sort(v, 5);
  int s = 0;
  for (int i = 0; i < 5; i++) s += (i + 1) * v[i];
  return s + dot(&pts[1], &(struct point){ .x = 2, .y = 1 }) + pts[2].y;
}
