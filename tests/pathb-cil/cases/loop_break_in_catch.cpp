// EXPECT: 150
// A throw inside a loop: the handler adds 100 * e and breaks. Sum 0..3 = 6, plus 400 = 406, and 406 & 255 = 150.
static int h(void) {
  int s = 0;
  for (int i = 0; i < 10; i++) {
    try { if (i == 4) throw i; s += i; }
    catch (int e) { s += 100 * e; break; }
  }
  return s;
}
int main(void) { return h() & 255; }
