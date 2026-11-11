// CLEAN
// Globals whose sizes are not multiples of 8, a struct, an array of structs and a string: each one is read and written in
// bounds up to its last byte. A redzone after an object must start after the last byte of the object, not inside it.
struct P { char a; int b; char c; };
char g1[1] = {1};
char g3[3] = {1, 2, 3};
char g5[5] = {1, 2, 3, 4, 5};
char g9[9] = {1, 2, 3, 4, 5, 6, 7, 8, 9};
P gp[3] = {{1, 2, 3}, {4, 5, 6}, {7, 8, 9}};
const char *gs = "hello, world";
static const char lit[] = "abcdefg";   // 8 bytes with the NUL: exactly one granule
int sum(const char *p, int n) { int s = 0; for (int i = 0; i < n; i++) s += p[i]; return s; }
int main(int argc, char **) {
  int s = sum(g1, 1) + sum(g3, 3) + sum(g5, 5) + sum(g9, 9) + sum(lit, 8) + sum(gs, 13);
  for (int i = 0; i < 3; i++) s += gp[i].a + gp[i].b + gp[i].c;
  g9[8 + (argc - 1)] = 0;   // the last byte, through a computed address
  gp[2 + (argc - 1)].c = 1;
  return s > 0 ? 0 : 1;
}
