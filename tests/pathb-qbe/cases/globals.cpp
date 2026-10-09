// EXPECT: 21
// Static objects with initializers: arrays with a zero tail, string tables, a char array from a string, a
// struct with a base class, pointers to globals and to functions, and a function pointer table.
struct Base { int b; long pad; };
struct Node : Base { const char *name; int vals[3]; };
int counter = 5;
static int table[6] = {1, 2, 3};
const char *names[] = {"zero", "one", "two"};
char word[8] = "abc";
static double ratio = 0.25;
Node nodes[2] = {{{10, 20}, "first", {1, 2, 3}}, {{30, 40}, "second", {4}}};
int add1(int x) { return x + 1; }
int add2(int x) { return x + 2; }
int (*ops[2])(int) = {add1, add2};
int *cptr = &counter;
int main() {
  int r = 0;
  r += table[0] + table[1] + table[2];
  r += table[5];
  r += names[2][0] == 't';
  r += word[2] == 'c' && word[3] == 0;
  r += (int)(ratio * 8);
  r += nodes[0].name[1] == 'i';
  r += nodes[0].vals[2] + nodes[1].vals[0] + nodes[1].vals[2];
  r += nodes[1].b == 30;
  r += ops[1](ops[0](0)) == 3;
  r += *cptr == 5;
  return r;
}
