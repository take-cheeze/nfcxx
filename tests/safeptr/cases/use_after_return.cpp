// SAFE: use of a stack object after its function returned
static int *leak() {
  int x = 42;
  int *volatile p = &x;
  return p;
}
static int deeper(int n) { volatile int pad[64]; pad[0] = n; return pad[0]; }
int main() {
  int *p = leak();
  deeper(1);
  return *p;
}
