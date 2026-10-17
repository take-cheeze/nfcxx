// EXPECT: 134
// Path B CIL spike: a checked shift whose count is not less than the width of int aborts (the QBE emitter calls
// abort: SIGABRT, status 134). Nothing after the shift runs.
static int n_shift(int n) { return 1 << n; }
int main(void) { return n_shift(40); }
