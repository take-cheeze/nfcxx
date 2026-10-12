#include <stdio.h>
long double o_twice(long double);
long double o_mix(int, long double, int, long double);
int main(void) { volatile long double a = 1.5L, b = -4.0L; printf("%Lf\n%Lf\n", o_twice(a), o_mix(2, a, 7, b)); return 0; }
