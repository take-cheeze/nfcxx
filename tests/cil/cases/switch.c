// EXPECT: 39
#include <stdio.h>
static const char *name(int k) {
    switch (k) {
    case 0: return "zero";
    case 1: case 2: return "small";
    case 7: return "seven";
    default: return "other";
    }
}
int main(void) {
    int total = 0;
    for (int i = 0; i < 9; i++) { printf("%s ", name(i)); total += i; }
    puts("");
    int j = 0;
    loop: if (j < 3) { j++; goto loop; }
    return total + j;
}
