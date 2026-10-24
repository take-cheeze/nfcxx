// MEMORY64-TRAP
// A load from address 2^32 + 8. Under --memory64 the address is the i64 pointer itself, so it is outside the memory
// and traps. The default module wraps it to i32 and reads address 8, so the test runs under the mode only.
int main() {
  volatile int *p = (volatile int *)0x100000008ULL;
  return *p;
}
