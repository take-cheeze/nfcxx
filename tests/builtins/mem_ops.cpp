// EXPECT: 0
// __builtin_memcpy / memmove / memset / memcmp, with values checked at runtime.
extern "C" int printf(const char*, ...);
int main() {
  char src[16], dst[16], buf[16];
  for (int i = 0; i < 16; ++i) src[i] = (char)('a' + i);
  int fails = 0;
  __builtin_memcpy(dst, src, 16);
  fails += dst[0] != 'a' || dst[15] != 'p';
  // memmove with overlap: shift right by 2 inside one buffer.
  for (int i = 0; i < 16; ++i) buf[i] = (char)i;
  __builtin_memmove(buf + 2, buf, 8);
  fails += buf[2] != 0 || buf[9] != 7 || buf[10] != 10;
  // memset
  __builtin_memset(dst, 0x5a, 16);
  fails += dst[0] != 0x5a || dst[15] != 0x5a;
  // memcmp: sign and zero
  fails += __builtin_memcmp("abc", "abc", 3) != 0;
  fails += !(__builtin_memcmp("abc", "abd", 3) < 0);
  fails += !(__builtin_memcmp("abd", "abc", 3) > 0);
  // struct copy through memcpy
  struct S { int a; double d; };
  S s1 = {42, 2.5}, s2 = {0, 0.0};
  __builtin_memcpy(&s2, &s1, sizeof s1);
  fails += s2.a != 42 || s2.d != 2.5;
  return fails;
}
