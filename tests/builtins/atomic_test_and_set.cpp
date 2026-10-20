// EXPECT: 0
// __atomic_test_and_set and __atomic_clear (GCC's byte flags, libstdc++'s once_flag and condition code): cproc lowers
// them to an exchange of 1 and a store of 0 on the byte, so the flag's value is what the calls report.
static unsigned char flag;
int main() {
  if (__atomic_test_and_set(&flag, __ATOMIC_ACQUIRE)) return 1;   // the byte was clear
  if (!__atomic_test_and_set(&flag, __ATOMIC_SEQ_CST)) return 2; // now it is set
  __atomic_clear(&flag, __ATOMIC_RELEASE);
  if (flag != 0) return 3;
  return __atomic_test_and_set(&flag, __ATOMIC_SEQ_CST) ? 0 : 4;
}
