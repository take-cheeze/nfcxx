// EXPECT: 55
// A switch inside a loop: break leaves the switch only, continue leaves the switch and goes to the loop step.
int main() {
  int s = 0;
  for (int i = 0; i < 10; i++) {
    switch (i % 4) {
      case 0: s += 1; break;
      case 1: continue;
      case 2: s += 10; break;
      default: s += 100; break;
    }
    s += 1000;
  }
  return s & 255;
}
