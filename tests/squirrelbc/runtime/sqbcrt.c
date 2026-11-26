/* The runtime helpers of the lowered Squirrel subset (sqbcrt.h). Each error text is the one the reference VM raises
 * (squirrel/sqvm.cpp ARITH_OP, ArithMetaMethod, NEG_OP, ObjCmp; squirrel/sqdebug.cpp Raise_CompareError). */
#include "sqbcrt.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

static void rt_error(const char *msg) {
  printf("error: %s\n", msg);
  exit(1);
}

/* GetTypeName of the subset: IdType2Name in squirrel/sqobject.cpp. */
static const char *type_name(uint32_t tag) {
  switch (tag) {
    case SQBC_TAG_NULL: return "null";
    case SQBC_TAG_INTEGER: return "integer";
    case SQBC_TAG_BOOL: return "bool";
    default: return "?";
  }
}

/* The result of `a OP b` for two integers, with the wrapping that the reference reaches on LP64 (a quotient of
 * INT64_MIN by -1 is INT64_MIN, and a remainder by -1 is 0). */
static int64_t int_div(int64_t a, int64_t b) {
  if (b == 0) rt_error("division by zero");
  if (b == -1) return (int64_t)(0u - (uint64_t)a);
  return a / b;
}

/* Only called with b != 0 (see sqbc_rt_arith). */
static int64_t int_mod(int64_t a, int64_t b) {
  if (b == -1) return 0;
  return a % b;
}

void sqbc_rt_arith(int op, SQV *dst, SQV *a, SQV *b) {
  /* Read both operands before dst is written: dst may be one of them. */
  SQV x = *a, y = *b;
  SQV r;
  if (op == SQBC_OP_MOD) {
    /* sqvm.cpp's _OP_MOD calls ARITH_OP and drops its result, and a failure only stores the message (Raise_Error): the
     * script goes on and the target keeps its value. So a zero divisor, or an operand that is not an integer, is not an
     * error here. */
    if (x.tag != SQBC_TAG_INTEGER || y.tag != SQBC_TAG_INTEGER || y.i == 0) return;
    r.tag = SQBC_TAG_INTEGER;
    r.pad = 0;
    r.i = int_mod(x.i, y.i);
    *dst = r;
    return;
  }
  if (x.tag == SQBC_TAG_INTEGER && y.tag == SQBC_TAG_INTEGER) {
    r.tag = SQBC_TAG_INTEGER;
    r.pad = 0;
    r.i = 0;
    switch (op) {
      case SQBC_OP_ADD: r.i = (int64_t)((uint64_t)x.i + (uint64_t)y.i); break;
      case SQBC_OP_SUB: r.i = (int64_t)((uint64_t)x.i - (uint64_t)y.i); break;
      case SQBC_OP_MUL: r.i = (int64_t)((uint64_t)x.i * (uint64_t)y.i); break;
      case SQBC_OP_DIV: r.i = int_div(x.i, y.i); break;
      case SQBC_OP_MOD: r.i = int_mod(x.i, y.i); break;
      default: rt_error("internal: bad arithmetic operator");
    }
    *dst = r;
    return;
  }
  /* sqvm.cpp ArithMetaMethod: no metamethods in the subset. */
  {
    char opc = op == SQBC_OP_ADD ? '+' : op == SQBC_OP_SUB ? '-' : op == SQBC_OP_MUL ? '*'
             : op == SQBC_OP_DIV ? '/' : '%';
    char msg[128];
    snprintf(msg, sizeof msg, "arith op %c on between '%s' and '%s'", opc, type_name(x.tag), type_name(y.tag));
    rt_error(msg);
  }
}

void sqbc_rt_neg(SQV *dst, SQV *a) {
  SQV x = *a;
  if (x.tag == SQBC_TAG_INTEGER) {
    SQV r;
    r.tag = SQBC_TAG_INTEGER;
    r.pad = 0;
    r.i = (int64_t)(0u - (uint64_t)x.i);
    *dst = r;
    return;
  }
  {
    char msg[128];
    snprintf(msg, sizeof msg, "attempt to negate a %s", type_name(x.tag));
    rt_error(msg);
  }
}

/* PrintObjVal: an integer as %lld, any other value as its type name. */
static void print_obj(const SQV *v, char *out, size_t n) {
  if (v->tag == SQBC_TAG_INTEGER)
    snprintf(out, n, "%" PRId64, v->i);
  else
    snprintf(out, n, "%s", type_name(v->tag));
}

/* ObjCmp (sqvm.cpp), then CMP_OP's operator on its result. */
int sqbc_rt_compare(int op, SQV *a, SQV *b) {
  SQV x = *a, y = *b;
  int64_t r;
  if (x.tag == y.tag) {
    if (x.i == y.i)
      r = 0;
    else if (x.tag == SQBC_TAG_INTEGER)
      r = x.i < y.i ? -1 : 1;
    else
      /* Booleans: the default branch compares the raw values. */
      r = (uint64_t)x.i < (uint64_t)y.i ? -1 : 1;
  } else if (x.tag == SQBC_TAG_NULL) {
    r = -1;
  } else if (y.tag == SQBC_TAG_NULL) {
    r = 1;
  } else {
    char s1[64], s2[64], msg[160];
    print_obj(&x, s1, sizeof s1);
    print_obj(&y, s2, sizeof s2);
    snprintf(msg, sizeof msg, "comparison between '%.50s' and '%.50s'", s1, s2);
    rt_error(msg);
    r = 0;
  }
  switch (op) {
    case SQBC_CMP_G: return r > 0;
    case SQBC_CMP_GE: return r >= 0;
    case SQBC_CMP_L: return r < 0;
    case SQBC_CMP_LE: return r <= 0;
    default: rt_error("internal: bad comparison operator");
  }
  return 0;
}
