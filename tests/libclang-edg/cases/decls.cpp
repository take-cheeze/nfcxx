namespace ns {
struct S { int a; static int s; S(); ~S(); int get(int k) const; };
enum Color { Red, Green };
typedef int Num;
}
int add(int x, int y) { return x + y; }
int proto(int q);
int gv = 3;
