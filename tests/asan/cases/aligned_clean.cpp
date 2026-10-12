// CLEAN
// An over-aligned object is at its alignment and its whole extent is accessible.
int main() {
  alignas(128) int a[10];
  for (int i = 0; i < 10; i++) a[i] = i;
  int s = 0;
  for (int i = 0; i < 10; i++) s += a[i];
  return ((unsigned long)a % 128 == 0 && s == 45) ? 0 : 1;
}
