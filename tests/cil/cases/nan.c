// EXPECT: 32
// PATHB-ONLY: scripts/qbe2cil.rb compares a NaN wrongly (nan < 1.0 and nan <= 1.0 are true there); the Path B route follows C
#include <stdio.h>
int main(void) {
    volatile double zero = 0.0; double nan = zero / zero, one = 1.0;
    int r = (nan < one) + (nan <= one) * 2 + (nan > one) * 4 + (nan >= one) * 8 + (nan == nan) * 16 + (nan != nan) * 32;
    printf("%d\n", r);
    return r + (!(nan < one) && !(nan >= one) ? 0 : 1);
}
