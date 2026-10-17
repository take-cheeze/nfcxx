// EXPECT: 5
// A try that does not throw returns its normal value.
static int g(int x) { try { return x + 1; } catch (int e) { return -e; } }
int main(void) { return g(4); }
