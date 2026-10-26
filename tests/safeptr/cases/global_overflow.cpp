// SAFE: out-of-bounds access
int table[8];
int other[8];
int get(int *p, int i) { return p[i]; }
int main(int argc, char **) {
  return get(table, 8 + argc - 1);
}
