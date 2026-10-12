// CLEAN
// Globals of sizes that are not multiples of 8 (3, 5, 13 bytes) and an array of structs, used over their whole extent,
// with a static local and a constructor that runs before main. The redzones after them must not catch these accesses.
struct Pt { short x; char y; };
char tiny[3] = {1, 2, 3};
char name[5];
double weights[13 / 2 + 1];
Pt pts[4];
static int counter = 0;
struct Init { Init() { counter = 100; } } init_first;
int bump() { static int calls = 0; return ++calls; }
int main() {
  int s = 0;
  for (int i = 0; i < 3; i++) s += tiny[i];
  for (int i = 0; i < 5; i++) { name[i] = (char)('a' + i); s += name[i] - 'a'; }
  for (int i = 0; i < 7; i++) weights[i] = i * 0.5;
  for (int i = 0; i < 4; i++) { pts[i].x = (short)i; pts[i].y = (char)i; s += pts[i].x + pts[i].y; }
  s += bump() + bump() + counter;
  return s > 0 ? 0 : 1;
}
