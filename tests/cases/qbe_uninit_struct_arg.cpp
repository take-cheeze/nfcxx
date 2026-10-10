// EXPECT: 7
// Passing a never-initialized struct by value is legal C. QBE used to kill the stack slot (empty store mask)
// and pass a null address, so the call segfaulted at "movq 0, %rsi" (scripts/qbe-uninit-slot.patch, found with
// nlohmann::json: libstdc++ passes a _Iter_pred<lambda> temporary that holds only a dummy char).
struct P { char d; };
struct Q { int a; int b; };
struct Big { long v[5]; };

int take_p(int a, P) { return a; }
int take_q(int a, Q) { return a; }
int take_big(int a, Big) { return a; }

int main() {
  P p;
  Q q;
  Big b;
  return take_p(3, p) + take_q(2, q) + take_big(2, b) == 7 ? 7 : 1;
}
