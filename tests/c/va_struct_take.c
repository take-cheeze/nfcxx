/* helper for va_struct.c: the variadic callee */
#include <stdarg.h>
typedef struct { unsigned long w; } S8;
typedef struct { long a; int tag; } S16;
typedef struct { int x, y; } P8;   /* two ints in one eightbyte */
/* kinds: i = int, p = S8, q = S16, r = P8, l = long. Returns a checksum of everything read. */
long take(const char *kinds, ...) {
  va_list ap;
  long t = 7;
  va_start(ap, kinds);
  for (; *kinds; kinds++) {
    switch (*kinds) {
    case 'i': t = t * 31 + va_arg(ap, int); break;
    case 'l': t = t * 31 + va_arg(ap, long); break;
    case 'p': { S8 s = va_arg(ap, S8); t = t * 31 + (long)s.w; break; }
    case 'q': { S16 s = va_arg(ap, S16); t = t * 31 + s.a * 3 + s.tag; break; }
    case 'r': { P8 s = va_arg(ap, P8); t = t * 31 + s.x * 5 + s.y; break; }
    }
  }
  va_end(ap);
  return t;
}
