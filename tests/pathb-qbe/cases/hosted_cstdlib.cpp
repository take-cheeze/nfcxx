// Path B, hosted: <cstdlib> and <cstring>: malloc/calloc/realloc/free, qsort with a callback, atoi/strtol/strtod,
// abs, memcpy/memmove/memset/memcmp, strcpy/strcat/strcmp/strchr/strstr. (std::div, which returns a two-int struct
// in registers, is a known Path B gap: aggregates are passed and returned by pointer, docs/notes/pathb-hosted.md.)
// EXPECT: 22
// STDOUT: same
#include <cstdlib>
#include <cstring>
#include <cstdio>

static int cmp(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }

int main()
{
  int n = 0;
  int *p = (int *)std::malloc(5 * sizeof(int));
  int src[5] = {5, 3, 9, 1, 7};
  std::memcpy(p, src, sizeof src);
  std::qsort(p, 5, sizeof(int), cmp);
  n += p[0] == 1 && p[1] == 3 && p[4] == 9;
  p = (int *)std::realloc(p, 10 * sizeof(int));
  std::memset(p + 5, 0, 5 * sizeof(int));
  n += p[7] == 0;
  n += std::memcmp(p, src, sizeof src) != 0;
  std::free(p);
  int *z = (int *)std::calloc(4, sizeof(int));
  n += z[3] == 0;
  std::free(z);
  n += std::atoi("123") == 123;
  char *end;
  n += std::strtol("0x1f rest", &end, 16) == 31;
  n += std::strcmp(end, " rest") == 0;
  n += std::strtod("2.5e1", nullptr) == 25.0;
  n += std::abs(-4) == 4;
  char buf[32];
  std::strcpy(buf, "foo");
  std::strcat(buf, "bar");
  n += std::strlen(buf) == 6;
  n += std::strchr(buf, 'b') == buf + 3;
  n += std::strstr(buf, "ob") == buf + 2;
  char m[8] = "abcdefg";
  std::memmove(m + 1, m, 5);
  n += m[1] == 'a' && m[5] == 'e';
  n += std::strncmp("abcx", "abcy", 3) == 0;
  n += std::labs(-9L) == 9;
  std::printf("n=%d\n", n);
  return n + 7;
}
