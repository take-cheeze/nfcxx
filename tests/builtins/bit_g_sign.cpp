// EXPECT: 0
// HOST-GCC-MIN: 14
// XFAIL-qbe: cproc has no __builtin_ffsg / __builtin_clrsbg (Path B lowers them; bit_g.cpp keeps the ones cproc has)
// GNU-VERSION: 140000 (GCC 14 emulation: EDG knows the g-builtins only from GCC 14 on)
// GCC 14 type-generic __builtin_ffsg and __builtin_clrsbg. The inputs are volatile so EDG does not fold them.
static volatile unsigned int vu = 0;
static volatile unsigned long vl = 0;
int main() {
  int fails = 0;
  unsigned int z = vu;                  // 0
  unsigned int hi = vu + 0x00010000u;   // bit 16
  unsigned long lhi = vl + (1ul << 40); // bit 40
  fails += __builtin_ffsg((int)z) != 0;
  fails += __builtin_ffsg((int)hi) != 17;
  fails += __builtin_ffsg((long)lhi) != 41;
  int sz = (int)vu, sm = (int)vu - 1, s1 = (int)vu + 1;
  fails += __builtin_clrsbg(sz) != 31;
  fails += __builtin_clrsbg(sm) != 31;
  fails += __builtin_clrsbg(s1) != 30;
  short h1 = (short)(vu + 1), hm = (short)(vu - 1);
  fails += __builtin_clrsbg(h1) != 14;
  fails += __builtin_clrsbg(hm) != 15;
  fails += __builtin_clrsbg((long)lhi) != 22;
  return fails;
}
