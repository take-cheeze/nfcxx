// EXPECT: 9
// Passing an empty class by value on to another function copies it. cproc used to emit one byte of copy for a
// zero-size struct, into a zero-byte stack slot that QBE places at the frame pointer: the saved %rbp was
// overwritten and the caller ran with a corrupted frame pointer (scripts/cproc-empty-copy.patch, found with
// nlohmann::json's std::all_of(first, last, lambda)).
struct Pred {
  bool operator()(int v) const { return v > 0; }
};
struct Wrap {
  Pred p;
  char dummy;
};

__attribute__((noinline)) int apply(Pred p, int v) { return p(v) ? v : 0; }
__attribute__((noinline)) int forward(int a, int b, Pred p) { return apply(p, a) + apply(p, b); }
__attribute__((noinline)) int outer(int a, int b, Pred p) {
  int x = forward(a, b, p);  // p is copied into the call; the frame pointer must survive
  int y = forward(b, a, p);
  return x + y - a - b;
}

int main() {
  Pred p;
  int r = outer(4, 5, p);
  return r;
}
