// REFUSE: fallthrough
int main() {
  int x = 2;
  int y = 0;
  switch (x) {
    case 1: y = 5;
    case 2: y = 6; break;
    default: y = 7;
  }
  return y;
}
