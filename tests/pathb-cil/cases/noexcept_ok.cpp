// EXPECT: 5
int h() noexcept { return 5; }
int main() { try { return h(); } catch (...) { return 1; } }
