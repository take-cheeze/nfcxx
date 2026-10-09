// EXPECT: 0
// XFAIL-qbe: cproc has no __builtin_add_overflow family (EDG passes the name through to C)
// __builtin_{add,sub,mul}_overflow and the _p predicate forms.
int main() {
  int fails = 0;
  int r;
  fails += __builtin_add_overflow(2147483647, 1, &r) != 1;
  fails += __builtin_add_overflow(40, 2, &r) != 0 || r != 42;
  fails += __builtin_sub_overflow(-2147483647 - 1, 1, &r) != 1;
  fails += __builtin_sub_overflow(10, 4, &r) != 0 || r != 6;
  fails += __builtin_mul_overflow(65536, 65536, &r) != 1;
  fails += __builtin_mul_overflow(1000, 1000, &r) != 0 || r != 1000000;
  unsigned char uc;
  fails += __builtin_add_overflow((unsigned char)200, (unsigned char)100, &uc) != 1 || uc != 44;
  long long ll;
  fails += __builtin_mul_overflow(4000000000LL, 4000000000LL, &ll) != 1;
  unsigned u;
  fails += __builtin_sub_overflow(0u, 1u, &u) != 1 || u != 0xffffffffu;
  fails += !__builtin_add_overflow_p(2147483647, 1, 0);
  fails += __builtin_mul_overflow_p(3, 4, (long)0) != 0;
  return fails;
}
