// EXPECT: 23
struct V { virtual int k() const { return 1; } virtual ~V(){} };
struct W : V { int k() const override { return 2; } };
struct X : W { int k() const override { return 3; } };
int h(const V& v){ return v.k(); }
int main(){ W w; X x; return h(w)*10 + h(x); }
// X86-ONLY: the EDG front end on aarch64 rejects a long double literal (x86-64 long double layout), so this case is skipped there
