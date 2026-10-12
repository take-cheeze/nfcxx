// CLEAN
#include <cstdlib>
int main() {
  int *p = (int *)malloc(8 * sizeof(int));
  for (int i = 0; i < 8; i++) p[i] = i;
  int s = 0;
  for (int i = 0; i < 8; i++) s += p[i];
  free(p);
  return s == 28 ? 0 : 1;
}
