// A shift count at or above the width traps (the IR's checked shift).
// TRAP
int main() {
  volatile int n = 40;
  return 1 << n;
}
