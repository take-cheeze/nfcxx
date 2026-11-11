// EXPECT: 134
// Path B CIL spike: __builtin_trap is the trap statement. It takes the abort path (SIGABRT, status 134), so the return
// is never reached.
int main(void) { __builtin_trap(); return 0; }
