// EXPECT: 0
// A conditional whose branches are a derived-class pointer and null, converted to a pointer to a base class: EDG lowers the
// conversion to `&(adjusted p->base)`, which reads no memory, so a null p is not a null dereference. Path B put a null check
// on the pointer under the lvalue adjustment and trapped (tests/ast engine.cpp: `return r ? make<ArithUninit>(...) : nullptr`).
struct Node {
  int line = 0;
  virtual ~Node() {}
};
struct Base : Node {
  int op;
  explicit Base(int o) : op(o) {}
};
struct Derived : Base {
  using Base::Base;
};

static Derived* make(int o) { return new Derived(o); }

static Node* pick(Node* r) { return r ? make(1) : nullptr; }

// A second base class sits at a non-zero offset: the conversion of a null pointer still gives null (EDG tests for it itself).
struct B1 { int a = 1; };
struct B2 { int b = 2; };
struct D2 : B1, B2 {};
static D2* none() { return nullptr; }
static D2* some(D2* d) { return d; }

int main() {
  D2 d2;
  B2* q = none();
  B2* r = some(&d2);
  if (q != nullptr || r == nullptr || r->b != 2) return 2;
  Node* a = pick(nullptr);
  Node one;
  Node* b = pick(&one);
  int bad = (a != nullptr) + (b == nullptr);
  delete b;
  return bad;
}
