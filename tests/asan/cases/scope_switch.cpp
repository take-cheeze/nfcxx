// CLEAN
// A declaration directly in a switch body, before its case labels. The first pass leaves the switch by break, which
// poisons x; the dispatch of the second pass enters case 1 past x's declaration (C++ allows it: no initializer), so x has
// to be addressable again at that case label.
int main(int argc, char **) {
  int sum = 0, n = 0;
  while (n < 3) {
    switch (n) {
      int x;
    case 0:
      x = 1 + argc - 1;
      sum += x;
      n = 1;
      break;
    case 1:
      x = 2;
      sum += x;
      n = 2;
      break;
    default:
      n = 3;
    }
  }
  return sum == 3 ? 0 : 1;
}
