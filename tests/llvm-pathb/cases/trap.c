// TRAP: 1
// The nsw add is checked in the IR: an overflow traps (SIGABRT) where C leaves it undefined.
volatile int v = 2147483647;
int main(void) { return v + 1; }
