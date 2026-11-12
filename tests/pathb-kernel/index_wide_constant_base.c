// An array at an absolute address above 2 GB indexed by a variable (the kernel's `((long *)PAGE_OFFSET)[i]`, vgacon's
// `(u16 *)(PAGE_OFFSET + 0xa0000)` text buffer; namei.c, realmode/init.c). QBE folds `add CONST, x` into the displacement
// of the access without checking that CONST fits in 32 bits, and the assembler refused the result ("0xffff888000000000 out
// of range of signed 32bit displacement"). The addresses are never dereferenced: the program compares them.
#define BASE 0xffff888000000000UL
#define VGA ((volatile unsigned short *)(BASE + 0xa0000))

__attribute__((noinline)) static unsigned long *slot(long i) { return &((unsigned long *)BASE)[i]; }
__attribute__((noinline)) static volatile unsigned short *cell(int i) { return &VGA[i]; }

// Reached only when i is huge: the accesses are assembled, not executed.
__attribute__((noinline)) static unsigned long peek(long i) { return ((unsigned long *)BASE)[i]; }
__attribute__((noinline)) static void poke(int i, unsigned short v) { VGA[i] = v; }

// `__va(phys)`: the integer sum, converted to a pointer, then stored through at an index.
__attribute__((noinline)) static void clear(unsigned long phys, long n, long i) { ((char *)(phys + BASE))[n + i] = 0; }
__attribute__((noinline)) static void *va(unsigned long phys) { return (void *)(phys + BASE); }

int main(int argc, char **argv)
{
  if (argc > 5) { poke(argc, 1); clear(argc, 2, 3); return (int)peek(argc); }
  return ((unsigned long)slot(3) == BASE + 24 && (unsigned long)cell(5) == BASE + 0xa0000 + 10 &&
          (unsigned long)slot(-1) == BASE - 8 && (unsigned long)va(0x1000) == BASE + 0x1000) ? 9 : 1;
}
