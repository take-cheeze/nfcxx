// EXPECT: 42
// Arithmetic on a 1- or 2-byte type wraps to the type, and the value of the expression is the wrapped one (before any
// store narrows it): ++ of unsigned char 255 is 0, -- of signed char -128 is 127, -- of unsigned char 0 is 255, and ++ of
// short 32767 is -32768. Each failed check returns its own status.
int main(void) {
  unsigned char a = 255;
  if (++a != 0) return 1;
  signed char s = -128;
  if (--s != 127) return 2;
  unsigned char c = 0;
  if (--c != 255) return 3;
  short h = 32767;
  if (++h != -32768) return 4;
  return 42;
}
