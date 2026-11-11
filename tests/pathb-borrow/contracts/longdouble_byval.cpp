// A long double passed by value: the frontend's (borrow-layout (struct "__nfcxx_ld") ...) record names its 10
// significant bytes, the callee is inferred, and the runtime helpers (scripts/pathb-runtime.effects) describe the
// arithmetic. The program runs natively.
long double twice(long double x) { return x + x; }
int main() {
  long double z = 1.5L;
  return (int)twice(z) - 3;
}
