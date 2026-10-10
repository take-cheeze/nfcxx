// Path B, hosted: <cstdio> from the host headers. printf/snprintf/puts/fputs/sscanf/FILE streams (stdout, tmpfile),
// and the varargs calls that go with them.
// EXPECT: 17
// STDOUT: same
#include <cstdio>

int main()
{
  int n = 0;
  char buf[64];
  std::printf("hello %d %s %c %5.2f\n", 42, "world", 'x', 3.14159);
  n += std::snprintf(buf, sizeof buf, "%d-%s-%lu", 7, "ab", 123456789012UL) > 0;
  std::puts(buf);
  n += buf[0] == '7' && buf[1] == '-';
  std::fputs("via fputs\n", stdout);
  std::fprintf(stderr, "to stderr %d\n", 1);
  int a = 0, b = 0;
  n += std::sscanf("12 34", "%d %d", &a, &b) == 2;
  n += a == 12 && b == 34;
  std::FILE *f = std::tmpfile();
  n += f != nullptr;
  if (f) {
    std::fprintf(f, "line1\nline2\n");
    std::rewind(f);
    char line[32];
    n += std::fgets(line, sizeof line, f) != nullptr;
    std::printf("read %s", line);
    n += line[4] == '1';
    std::fclose(f);
  }
  std::putchar('!'); std::putchar('\n');
  std::printf("%x %o %e %g %ld %lld\n", 255, 8, 1.5, 0.25, -5L, 1LL << 40);
  std::printf("n=%d\n", n);
  return n + 10;
}
