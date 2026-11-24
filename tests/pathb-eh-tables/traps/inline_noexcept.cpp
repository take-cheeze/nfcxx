// A noexcept callee inlined into a caller that catches: an exception that leaves the copy still calls std::terminate.
static int boom = 1;
static void maybe(int k) { if (k == boom) throw k; }
struct G { ~G() {} };
static inline void nx(int k) noexcept { G g; maybe(k); }
int main() { try { nx(1); } catch (...) { return 0; } return 1; }
