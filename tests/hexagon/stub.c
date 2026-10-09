/* Appended to the generated C when running on qemu-hexagon (Linux user mode, no libc):
   raw syscalls via trap0(#0) with the syscall number in r6, then exit_group(main()). */
static long nfcxx_sys3(long n, long a, long b, long c) {
  register long r6 __asm__("r6") = n;
  register long r0 __asm__("r0") = a;
  register long r1 __asm__("r1") = b;
  register long r2 __asm__("r2") = c;
  __asm__ volatile("trap0(#0)" : "+r"(r0) : "r"(r6), "r"(r1), "r"(r2) : "memory");
  return r0;
}
void *memcpy(void *d, const void *s, unsigned n) { char *p = d; const char *q = s; while (n--) *p++ = *q++; return d; }
void *memset(void *d, int c, unsigned n) { char *p = d; while (n--) *p++ = (char)c; return d; }
void _start(void) { int r = main(); nfcxx_sys3(94, r, 0, 0); for (;;) {} }
