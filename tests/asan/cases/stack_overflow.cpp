// ASAN: stack-buffer-overflow
int sink(int *p, int i) { return p[i]; }
int main(int argc, char **) {
  int a[4] = {1, 2, 3, 4};
  return sink(a, 4 + argc);
}
