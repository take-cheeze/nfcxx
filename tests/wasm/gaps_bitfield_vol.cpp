// Path B: volatile bit-fields. Every access reads or read-modify-writes the whole storage unit through the volatile
// helpers (docs/notes/pathb-stage3.md): a volatile struct object, a pointer to a volatile struct, a volatile member.
// EXPECT: 0
// ASM-COUNT: bf_read_twice __pathb_vld_ 2
// ASM-COUNT: bf_write __pathb_v 2
struct Reg {
  unsigned a : 3;
  unsigned b : 5;
  int c : 7;
  unsigned long long d : 40;
};
struct Mixed {
  volatile unsigned f : 4;   // volatile member
  unsigned g : 4;
};

volatile Reg g_reg;
Mixed g_mixed;

extern "C" {
unsigned bf_read_twice(volatile Reg *r) { return r->a + r->a; }   // two unit reads
void bf_write(volatile Reg *r) { r->b = 17; }                      // one unit read + one unit write
}

int main() {
  int bad = 0;
  g_reg.a = 5; g_reg.b = 21; g_reg.c = -3; g_reg.d = 0x123456789aULL;
  if (g_reg.a != 5 || g_reg.b != 21 || g_reg.c != -3 || g_reg.d != 0x123456789aULL) bad |= 1;
  g_reg.a += 2;
  g_reg.c--;
  if (g_reg.a != 7 || g_reg.b != 21 || g_reg.c != -4) bad |= 2;
  g_reg.a++;                                   // wraps within 3 bits
  if (g_reg.a != 0 || g_reg.b != 21) bad |= 4;
  if (bf_read_twice(&g_reg) != 0) bad |= 8;
  bf_write(&g_reg);
  if (g_reg.b != 17 || g_reg.c != -4 || g_reg.d != 0x123456789aULL) bad |= 16;
  g_mixed.f = 9; g_mixed.g = 6;
  if (g_mixed.f != 9 || g_mixed.g != 6) bad |= 32;
  volatile Reg local;
  local.a = 3; local.b = 30; local.c = 63; local.d = 1;
  for (int i = 0; i < 5; i++) local.a = local.a + 1;
  if (local.a != 0 || local.b != 30 || local.c != 63 || local.d != 1) bad |= 64;
  return bad;
}
