// A helper taking a struct by value: the emitter refuses it (exit 3), aggregates are not lowered.
extern "C" unsigned __nfcxx_tid_x(void);
struct Pair { int a; int b; };
extern "C" int sum_pair(Pair p) { return p.a + p.b; }
extern "C" void k(int *out) { out[0] = sum_pair(Pair{1, 2}) + (int)__nfcxx_tid_x(); }
