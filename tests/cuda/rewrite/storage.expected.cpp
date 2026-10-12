#line 1 "rewrite/storage.cu"
struct A { static constexpr  int f() { return 3; } };
static constexpr  int g() { return 4; }
static void k(int *p) { p[0] = g() + A::f(); }
// A device function whose declaration already has a storage class, and one with none (static is added).
static constexpr  int kept() { return 1; }
static int added() { return 2; }
