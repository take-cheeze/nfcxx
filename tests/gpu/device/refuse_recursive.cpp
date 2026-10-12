// A recursive helper: the emitter refuses the call cycle (exit 3).
extern "C" int fact(int x) { return x <= 1 ? 1 : x * fact(x - 1); }
extern "C" void k(int *out) { out[0] = fact(5); }
