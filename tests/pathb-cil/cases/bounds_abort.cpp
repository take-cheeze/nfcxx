// EXPECT: 134
// An index past the end of the array must not succeed: the bounds check aborts (SIGABRT, status 134), as QBE does.
static int a[4];
static int get(int i) { return a[i]; }
int main(void) { return get(4); }
