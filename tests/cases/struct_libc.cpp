// EXPECT: 9
// Structs by value, arrays, and a call into libc.
extern "C" unsigned long strlen(const char*);
struct V { int a, b, c; };
V make(int x){ return V{x, x + 1, x + 2}; }
int sum(V v){ return v.a + v.b + v.c; }
int main(){
  int arr[4] = {1, 2, 3, 4};
  int t = 0; for (int x : arr) t += x;
  return sum(make(2)) == 9 && t == 10 && strlen("hello") == 5 ? 9 : 1;
}
