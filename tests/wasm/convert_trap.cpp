// A float that does not fit the integer type traps (the IR's checked conversion, cf2i).
// TRAP
int main() {
  volatile double d = 1.0e30;
  return (int)d;
}
