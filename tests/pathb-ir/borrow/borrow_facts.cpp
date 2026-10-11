// Tier 0 borrow facts (docs/notes/borrowck-plan.md section 1.3). The golden borrow/borrow_facts.ir is printed with
// NFCXX_PATHB_BORROW=1 by tests/pathb-ir/run.sh. With the flag unset the output is the same without the fact lines.
struct Own {
  int *p;
  Own(int v);
  Own(Own &&o);
  ~Own();
};
void consume(Own o);

int borrow_facts(int &r, int *q, bool early) {
  int x = 1;
  int &rx = x;   // a reference local
  int *px = &x;  // a pointer local (no reference flag)
  {
    Own b(2);    // a local with a destructor, closed at the end of its block
    consume(static_cast<Own &&>(b));  // an rvalue-reference argument: the move constructor
  }
  if (early) return 0;  // a return: closes px, rx, x, early, q and r; tail is not declared yet, so it is not closed
  int tail = 3;
  return rx + *px + r + *q + tail;
}
