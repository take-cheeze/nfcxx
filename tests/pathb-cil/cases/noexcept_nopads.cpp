// EXPECT: 134
void f() noexcept { throw 1; }
int main() {
  try { f(); } catch (...) { return 7; }
  return 3;
}
