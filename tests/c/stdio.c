/* EXPECT: 11 */
/* stdio, string.h, ctype.h, stdlib.h, errno.h and limits.h from the host headers. */
#include <stdio.h>
#include <string.h>
#include <ctype.h>
#include <stdlib.h>
#include <limits.h>
#include <errno.h>
#include <stdarg.h>
#include <stddef.h>
static int fmt(char *buf, size_t n, const char *f, ...) {
  va_list ap; va_start(ap, f);
  int r = vsnprintf(buf, n, f, ap);
  va_end(ap); return r;
}
int main(void) {
  char buf[64];
  int n = fmt(buf, sizeof buf, "%d-%s-%c-%.2f", 42, "xy", 'z', 1.5);   /* "42-xy-z-1.50" */
  puts(buf);
  for (char *p = buf; *p; p++) *p = (char)toupper((unsigned char)*p);
  long v = strtol("123", NULL, 10);
  errno = 0;
  int ok = strcmp(buf, "42-XY-Z-1.50") == 0 && v == 123 && INT_MAX == 2147483647 && errno == 0;
  fprintf(stderr, "stderr ok\n");
  return ok ? n - 1 : 1;                                                 /* 12 - 1 */
}
