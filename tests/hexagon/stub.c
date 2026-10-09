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
unsigned long strlen(const char *s) { const char *p = s; while (*p) p++; return (unsigned long)(p - s); }
/* Runtime storage for symbols the EDG code references but nothing here runs: EH bookkeeping
   (written on every scope entry even without a throw), and the C++ typeinfo vtables and sized
   operator delete named by typeinfo/vtable data. A case that throws gets the real EH runtime
   (eh_rt.c, appended with -DNFCXX_EH_RT), which defines the EH globals itself. */
__asm__(".pushsection .bss\n"
        ".p2align 3\n"
#ifndef NFCXX_EH_RT
        ".globl __eh_curr_region\n__eh_curr_region: .space 8\n"
        ".globl __curr_eh_stack_entry\n__curr_eh_stack_entry: .space 8\n"
#endif
        ".globl _ZTVN10__cxxabiv117__class_type_infoE\n_ZTVN10__cxxabiv117__class_type_infoE: .space 16\n"
        ".globl _ZTVN10__cxxabiv120__si_class_type_infoE\n_ZTVN10__cxxabiv120__si_class_type_infoE: .space 16\n"
        ".popsection");
/* Array destruction emitted for arrays of objects with destructors (reverse order). */
void nfcxx_vec_dtor(void *a, unsigned n, unsigned size, void (*d)(void *)) __asm__("__cxa_vec_dtor");
void nfcxx_vec_dtor(void *a, unsigned n, unsigned size, void (*d)(void *)) {
  while (n--) d((char *)a + (unsigned long)n * size);
}
void _ZdlPvj(void *p, unsigned n) { (void)p; (void)n; }
void _start(void) { int r = main(); nfcxx_sys3(94, r, 0, 0); for (;;) {} }
