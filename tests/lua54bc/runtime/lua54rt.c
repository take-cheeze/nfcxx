/* The runtime helpers that lowered Lua 5.4 IR calls (docs/notes/lua54-pathb.md, "Runtime helpers").
 * Numbers only for now: integer and float arithmetic and comparisons. A non-number operand is an error here; the
 * metamethod path and the error messages of lvm.c come with the full runtime. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct LV {
  uint8_t tag;
  uint8_t pad[7];
  union {
    int64_t i;
    double n;
  } v;
} LV;

enum { TAG_INT = 0x03, TAG_FLOAT = 0x13 };
enum { OP_ADD = 34, OP_SUB = 35, OP_MUL = 36 };   /* lopcodes.h order */

static double as_float(const LV *x) { return x->tag == TAG_INT ? (double)x->v.i : x->v.n; }

static int is_number(const LV *x) { return x->tag == TAG_INT || x->tag == TAG_FLOAT; }

static void die(const char *what) {
  fprintf(stderr, "lua54rt: %s\n", what);
  exit(4);
}

void lua54rt_arith(int op, LV *dst, LV *a, LV *b) {
  if (!is_number(a) || !is_number(b)) die("arithmetic on a non-number");
  if (a->tag == TAG_INT && b->tag == TAG_INT) {
    uint64_t x = (uint64_t)a->v.i, y = (uint64_t)b->v.i, r;
    if (op == OP_ADD) r = x + y;
    else if (op == OP_SUB) r = x - y;
    else r = x * y;   /* wrapping, as Lua's integers */
    dst->tag = TAG_INT;
    dst->v.i = (int64_t)r;
    return;
  }
  double x = as_float(a), y = as_float(b), r;
  if (op == OP_ADD) r = x + y;
  else if (op == OP_SUB) r = x - y;
  else r = x * y;
  dst->tag = TAG_FLOAT;
  dst->v.n = r;
}

/* kind 0: a < b, 1: a <= b, 2: a == b */
int lua54rt_cmp(int kind, LV *a, LV *b) {
  if (!is_number(a) || !is_number(b)) die("comparison of a non-number");
  if (a->tag == TAG_INT && b->tag == TAG_INT) {
    if (kind == 0) return a->v.i < b->v.i;
    if (kind == 1) return a->v.i <= b->v.i;
    return a->v.i == b->v.i;
  }
  double x = as_float(a), y = as_float(b);
  if (kind == 0) return x < y;
  if (kind == 1) return x <= y;
  return x == y;
}
