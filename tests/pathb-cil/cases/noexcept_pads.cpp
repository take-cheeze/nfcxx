// EXPECT: 134
struct S { ~S() {} };
void f() noexcept { S s; throw 1; }
int main() {
  try { f(); } catch (...) { return 7; }
  return 3;
}
