// EXPECT: 7
int g() noexcept { try { throw 3; } catch (int x) { return x + 4; } }
int main() { return g(); }
