// EXPECT: 14
// tfun(3) is 3 * 2 + 1 = 7 in each unit: 7 + 7 = 14.
#include "common.h"
int main() { return tfun(3) + b_work(); }
