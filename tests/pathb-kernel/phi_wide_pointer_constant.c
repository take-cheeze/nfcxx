// A pointer that is the same wide constant on every edge of a phi, then indexed in a loop (vgacon.c's
// vgacon_do_font_op: `charmap = (char *) VGA_MAP_MEM(colourmap, 0)` or `blackwmap`, both 0xa0000, then `charmap[i]`).
// QBE propagates the constant through the phi into the displacement of the access, unchecked, and the assembler refused
// it ("0xffff8880000a0000 out of range of signed 32bit displacement"). A wide pointer constant is now loaded from a cell.
// The accesses are assembled, not executed.
#define BASE 0xffff888000000000UL
static inline void *phys_to_virt(unsigned long long address) { return (void *)((unsigned long)address + BASE); }
#define VGA_MAP_MEM(x, s) ({ unsigned long start = (unsigned long)phys_to_virt(x); start; })
#define VA(x) ((char *)VGA_MAP_MEM(x, 0))

static int ticks;
__attribute__((noinline)) static void resched(void) { ticks++; }

__attribute__((noinline)) static int font_op(char *arg, int set, int ch512, int type)
{
  char *charmap;
  int i, beg;
  if (type != 3) {
    charmap = VA(0xa0000);
    beg = 0x0e;
  } else {
    charmap = VA(0xa0000);
    beg = 0x0a;
  }
  if (!arg)
    return -22;
  if (set)
    for (i = 0; i < 8192; i++)
      { *(charmap + i) = arg[i]; resched(); }
  else
    for (i = 0; i < 8192; i++)
      { arg[i] = *(charmap + i); resched(); }
  if (ch512) {
    charmap += 2 * 8192;
    arg += 8192;
    if (set)
      for (i = 0; i < 8192; i++)
        { *(charmap + i) = arg[i]; resched(); }
    else
      for (i = 0; i < 8192; i++)
        { arg[i] = *(charmap + i); resched(); }
  }
  return beg;
}

int main(int argc, char **argv)
{
  static char buf[8192];
  if (argc > 7) return font_op(buf, argc & 1, argc & 2, argc);   /* never taken */
  return (unsigned long)VA(0xa0000) == 0xffff8880000a0000UL ? 13 : 1;
}
