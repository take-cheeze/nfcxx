// Path B: __builtin_cpu_init() and __builtin_cpu_supports("feature") (x86). They used to be an (unsupported builtin) marker, which
// refused the whole function: nfcuop's AVX2 test (tests/uop/test_layout_avx2.cpp, "main: operator unsupported") asked for the CPU
// features in main. They are calls of the helpers of be/nfcxx_ldrt.c now, which ask the host's libgcc.
// Other hosts build an empty main: the built-ins are x86's here.
// EXPECT: 0
// The exit code is the number of wrong answers: x86-64 has SSE2 and cmov, the AVX2 answer is the same twice, and the avx2 and fma
// answers agree with the cpuid flags in /proc/cpuinfo (when it can be read).
#include <stdio.h>
#include <string.h>

#if defined(__x86_64__)
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

// whether /proc/cpuinfo's first "flags" line has the flag (-1: unreadable)
static int cpuinfo_has(const char *flag) {
  FILE *f = fopen("/proc/cpuinfo", "r");
  if (!f) return -1;
  static char line[16384];
  int found = 0;
  while (fgets(line, sizeof line, f)) {
    if (strncmp(line, "flags", 5) != 0) continue;
    char *p = strchr(line, ':');
    for (p = p ? p + 1 : line; *p; ++p) {
      while (*p == ' ') ++p;
      char *e = p;
      while (*e && *e != ' ' && *e != '\n') ++e;
      if ((size_t)(e - p) == strlen(flag) && strncmp(p, flag, e - p) == 0) found = 1;
      if (!*e) break;
      p = e;
    }
    break;
  }
  fclose(f);
  return found;
}

int main() {
  __builtin_cpu_init();
  CHECK(__builtin_cpu_supports("sse2"));
  CHECK(__builtin_cpu_supports("cmov"));
  int avx2 = __builtin_cpu_supports("avx2") != 0;
  CHECK(avx2 == (__builtin_cpu_supports("avx2") != 0));
  int want = cpuinfo_has("avx2");
  if (want >= 0) CHECK(avx2 == want);
  int fma = __builtin_cpu_supports("fma") != 0;
  want = cpuinfo_has("fma");
  if (want >= 0) CHECK(fma == want);
  return bad;
}
#else
int main() { return 0; }
#endif
