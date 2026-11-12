// EXPECT-REFUSED: top-level form alias is not supported
static long do_sys(long x) { return x + 1; }
long sys_entry(long x) __attribute__((alias("do_sys")));
int main(void) { return (int)sys_entry(1); }
