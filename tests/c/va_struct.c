// EXPECT: 0
// SOURCES: va_struct.c va_struct_take.c
/* va_arg of 8- and 16-byte integer-class structs (cproc needs scripts/cproc-vaarg-aggregate.patch): the
   callee is in va_struct_take.c. Includes the case where one general register is left. */
extern long take(const char *, ...);
typedef struct { unsigned long w; } S8;
typedef struct { long a; int tag; } S16;
typedef struct { int x, y; } P8;
static long ref(long t, long v) { return t * 31 + v; }
int main(void) {
  S8 p = {1000}; S16 q = {20000, 3}; P8 r = {4, 6};
  long t;
  t = take("p", p);                                  if (t != ref(7, 1000)) return 1;
  t = take("q", q);                                  if (t != ref(7, 60003)) return 2;
  t = take("r", r);                                  if (t != ref(7, 26)) return 3;
  /* one gp register left (named arg + 4 ints = 5 used): the 16-byte struct goes wholly to the stack and the next int takes the last register */
  t = take("iiiiqi", 1, 2, 3, 4, q, 5);
  { long e = 7; e = ref(e,1); e = ref(e,2); e = ref(e,3); e = ref(e,4); e = ref(e,60003); e = ref(e,5); if (t != e) return 4; }
  /* 8-byte struct in the last register, then stack */
  t = take("iiiiipp", 1, 2, 3, 4, 5, p, p);
  { long e = 7; for (int i = 1; i <= 5; i++) e = ref(e, i); e = ref(e, 1000); e = ref(e, 1000); if (t != e) return 5; }
  /* everything on the stack */
  t = take("lllllllqrpq", 1L, 2L, 3L, 4L, 5L, 6L, 7L, q, r, p, q);
  { long e = 7; for (int i = 1; i <= 7; i++) e = ref(e, i); e = ref(e, 60003); e = ref(e, 26); e = ref(e, 1000); e = ref(e, 60003); if (t != e) return 6; }
  return 0;
}
