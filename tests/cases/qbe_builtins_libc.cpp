// EXPECT: 0
// QBE path (scripts/qbe-prep.rb): builtins that cproc lacks and doctest uses (docs/notes/realworld.md,
// blocker 2): __builtin_memcpy/memmove/memset/memcmp/strlen map to the libc functions, __builtin_isnan and
// __builtin_clzl map to small helpers, and __builtin_mul_overflow(x, C, &x) with an unsigned long constant C
// maps to a checked multiply. Each check counts a failure; main returns the count.
int main() {
    int fails = 0;

    char src[16], dst[16], buf[16];
    for (int i = 0; i < 16; ++i) src[i] = (char)('a' + i);
    __builtin_memcpy(dst, src, 16);
    fails += dst[0] != 'a' || dst[15] != 'p';
    for (int i = 0; i < 16; ++i) buf[i] = (char)i;
    __builtin_memmove(buf + 2, buf, 8);  // overlapping copy
    fails += buf[2] != 0 || buf[9] != 7 || buf[10] != 10;
    __builtin_memset(dst, 0x5a, 16);
    fails += dst[0] != 0x5a || dst[15] != 0x5a;
    fails += __builtin_memcmp("abc", "abc", 3) != 0;
    fails += !(__builtin_memcmp("abc", "abd", 3) < 0);
    fails += __builtin_strlen("hello") != 5;

    double zero = 0.0;
    double nan = zero / zero;
    fails += __builtin_isnan(nan) != 1;
    fails += __builtin_isnan(1.5) != 0;

    // Width-independent: unsigned long is 64-bit on the host and 32-bit on the Hexagon check.
    const int bits = (int)(8 * sizeof(unsigned long));
    const int s = bits / 2 + 8;
    fails += __builtin_clzl(1UL) != bits - 1;
    fails += __builtin_clzl(1UL << s) != bits - 1 - s;
    fails += __builtin_clzl(~0UL) != 0;

    unsigned long n = 3;
    fails += __builtin_mul_overflow(n, 8UL, &n) != 0 || n != 24;
    unsigned long big = 1UL << (bits - 1);
    fails += __builtin_mul_overflow(big, 2UL, (&big)) != 1 || big != 0;  // wraps, and reports it
    unsigned long zz = 0;
    fails += __builtin_mul_overflow(zz, 72UL, &zz) != 0 || zz != 0;
    return fails;
}
