// Inline asm that cannot be lowered: each statement prints an (unsupported stmt ...) marker and the emitter refuses the
// module with it. pause / rep nop / nop and the empty barrier are lowered (tests/pathb-qbe/cases/gaps_asm.cpp, asm_barrier.cpp).
void fence() { __asm__ __volatile__("mfence" ::: "memory"); }
unsigned cpuid_eax() {
  unsigned a, b, c, d;
  __asm__ __volatile__("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0));
  return a;
}
void lock_inc(int *p) { __asm__ __volatile__("lock; incl %0" : "+m"(*p)); }
void pause_ok() { __asm__ __volatile__("pause" ::: "memory"); }
void rep_nop_ok() { __asm__ volatile("rep; nop"); }
void clobber() { __asm__ volatile("pause" ::: "rax"); }
