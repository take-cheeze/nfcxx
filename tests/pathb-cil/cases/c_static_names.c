// EXPECT: 7
#include <stdio.h>
static int n = 3;
static int helper(int x) { return x + n; }
int main(void) { printf("%d\n", helper(4)); return helper(4); }
