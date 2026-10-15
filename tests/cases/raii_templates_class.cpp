// EXPECT: 7
static int live = 0;
template<class T> struct Box { T v; Box(T x):v(x){ ++live; } ~Box(){ --live; } };
int f(){ Box<int> a(3); { Box<long> b(4); if (live != 2) return -1; } return live==1 ? 7 : -2; }
int main(){ int r = f(); return live==0 ? r : -3; }
