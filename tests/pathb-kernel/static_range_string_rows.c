// A static table of 2-character strings with a range designator (task_mmu.c's show_smap_vma_flags: `static const char
// mnemonics[BITS_PER_LONG][2] = { [0 ... 63] = "??", [3] = "rd", ... }`). The front end keeps the repeated string as one
// repeat constant over whole rows; Path B refused the table for any repeat over a multidimensional array, and with it
// every function that read it ("global \"mnemonics\"").
static const char mnemonics[64][2] = {
  [0 ... 63] = "??",
  [3] = "rd", [4] = "wr", [63] = "zz",
};

__attribute__((noinline)) static int checksum(void)
{
  static const char local[8][3] = { [0 ... 7] = "ab", [2] = "xy" };
  int s = 0, i;
  for (i = 0; i < 64; i++) s = s * 31 + mnemonics[i][0] * 3 + mnemonics[i][1];
  for (i = 0; i < 8; i++) s = s * 7 + local[i][0] + local[i][1] * 2 + local[i][2];
  return s;
}

int main(void)
{
  return (checksum() & 0x7f) | 0x40;
}
