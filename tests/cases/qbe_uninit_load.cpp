// EXPECT: 5
// C copies a never-initialized 1-byte struct (an empty class such as a lambda) into a temporary: the copy
// loads the local's stack slot directly, and nothing stored it. QBE's promote() rejected the slot ("read but never stored to").
// The copy is legal (gcc copies the garbage byte); the fork commit 'mem: keep a slot that is loaded but never stored' keeps the slot.
struct E { char c; };
int take(E, int v) { return v; }
int main() {
  E a;
  E b = a;
  return take(b, 5);
}
