static int helper(int x) { return x * 10; }
extern int shared;
int bump(void) { shared += 3; return helper(shared); }
