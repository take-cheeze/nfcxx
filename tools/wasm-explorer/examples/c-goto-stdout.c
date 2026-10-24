/* C: a state machine written with goto (the emitter lowers a body of labels as a dispatch loop) that counts the
   words, lines and digits of a string, printed with puts and putchar. */
int puts(const char *s);
int putchar(int c);

static const char text[] = "nfcxx compiles C\nto WebAssembly 1.0\nin 3 steps\n";

static void print_count(const char *label, int n) {
  for (const char *p = label; *p; p++) putchar(*p);
  putchar(':');
  putchar(' ');
  if (n >= 10) putchar('0' + n / 10);
  putchar('0' + n % 10);
  putchar('\n');
}

int main(void) {
  const char *p = text;
  int words = 0, lines = 0, digits = 0;
space:
  if (!*p) goto done;
  if (*p == '\n') lines++;
  if (*p == ' ' || *p == '\n') { p++; goto space; }
  words++;
word:
  if (*p >= '0' && *p <= '9') digits++;
  p++;
  if (!*p) goto done;
  if (*p == ' ' || *p == '\n') goto space;
  goto word;
done:
  puts("counts of the text:");
  print_count("words", words);
  print_count("lines", lines);
  print_count("digits", digits);
  return words * 100 + lines * 10 + digits;   /* 9 words, 3 lines, 3 digits */
}
