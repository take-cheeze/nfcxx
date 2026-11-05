// EXPECT: 40
// An arm that does not end in a jump falls into the next arm (C's fallthrough): run(1) = 5 + 6, run(2) = 6,
// run(3) = 7 + 8 (case 3 falls into the default, which is the last arm), run(4) = 8. The g++ result is 40.
static int run(int x) {
  int y = 0;
  switch (x) {
    case 1: y += 5;
    case 2: y += 6; break;
    case 3: y += 7;
    default: y += 8;
  }
  return y;
}
int main() { return run(1) + run(2) + run(3) + run(4); }
