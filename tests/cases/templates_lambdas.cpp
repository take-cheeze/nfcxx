// EXPECT: 12
template<class T> T add(T a, T b){ return a+b; }
struct P { int x,y; int sum() const { return x+y; } };
int main(){ P p{add(1,2), 4}; auto f=[&](int k){ return p.sum()+k; }; return f(5); }
