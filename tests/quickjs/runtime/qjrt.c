/* The operators of the QuickJS Path B producer (see qjrt.h). The results follow JavaScript for the int32 subset; every other
 * result stops the program (qjrt_fail) rather than being represented wrongly. */
#include "qjrt.h"

#include <stdio.h>
#include <stdlib.h>

__attribute__((noreturn)) static void qjrt_fail(const char *msg) {
  fprintf(stderr, "quickjs-pathb: %s\n", msg);
  exit(1);
}

static void set_bool(JV *dst, int v) {
  dst->tag = QJRT_BOOL;
  dst->val = v ? 1 : 0;
}

static void set_int(JV *dst, int64_t v) {
  dst->tag = QJRT_INT;
  dst->val = v;
}

/* The numeric value of a non-undefined operand: an int, a bool (0 or 1) or null (0). */
static int64_t numeric(const JV *a, const char *what) {
  switch (a->tag) {
    case QJRT_INT:
    case QJRT_BOOL: return a->val;
    case QJRT_NULL: return 0;
    case QJRT_UNDEF: qjrt_fail("undefined operand (NaN) is not an int32 result");
    default: break;
  }
  qjrt_fail(what);
}

/* An int32 result: an overflow, and -0 (a zero from a negative operand, which JavaScript keeps as -0), are not int32. */
static void int_result(JV *dst, int64_t v, int neg_zero) {
  if (neg_zero && v == 0) qjrt_fail("the result is -0, not an int32");
  if (v < -2147483647LL - 1 || v > 2147483647LL) qjrt_fail("the result is not an int32 (overflow)");
  set_int(dst, v);
}

static int is_undef_or_null(const JV *a) { return a->tag == QJRT_UNDEF || a->tag == QJRT_NULL; }

void qjrt_binop(int op, JV *dst, const JV *a, const JV *b) {
  if (a->tag == QJRT_UNINIT || b->tag == QJRT_UNINIT) qjrt_fail("a lexical variable is used before its declaration");
  switch (op) {
    case QJRT_ADD: {
      int64_t x = numeric(a, "operand is not a number"), y = numeric(b, "operand is not a number");
      int_result(dst, x + y, 0);
      return;
    }
    case QJRT_SUB: {
      int64_t x = numeric(a, "operand is not a number"), y = numeric(b, "operand is not a number");
      int_result(dst, x - y, 0);
      return;
    }
    case QJRT_MUL: {
      int64_t x = numeric(a, "operand is not a number"), y = numeric(b, "operand is not a number");
      int_result(dst, x * y, (x < 0) != (y < 0));
      return;
    }
    case QJRT_DIV: {
      int64_t x = numeric(a, "operand is not a number"), y = numeric(b, "operand is not a number");
      if (y == 0) qjrt_fail("division by zero (Infinity or NaN) is not an int32 result");
      if (x % y != 0) qjrt_fail("a fraction is not an int32 result");
      int_result(dst, x / y, (x < 0) != (y < 0));
      return;
    }
    case QJRT_MOD: {
      int64_t x = numeric(a, "operand is not a number"), y = numeric(b, "operand is not a number");
      if (y == 0) qjrt_fail("remainder by zero (NaN) is not an int32 result");
      /* the sign of the result is the sign of the dividend, as in JavaScript: a zero remainder of a negative dividend is -0 */
      int_result(dst, x % y, x < 0);
      return;
    }
    case QJRT_LT:
    case QJRT_LE:
    case QJRT_GT:
    case QJRT_GE: {
      /* a comparison with undefined is false (NaN), not an error */
      if (a->tag == QJRT_UNDEF || b->tag == QJRT_UNDEF) {
        set_bool(dst, 0);
        return;
      }
      int64_t x = numeric(a, "operand is not a number"), y = numeric(b, "operand is not a number");
      int r = op == QJRT_LT ? x < y : op == QJRT_LE ? x <= y : op == QJRT_GT ? x > y : x >= y;
      set_bool(dst, r);
      return;
    }
    case QJRT_EQ:
    case QJRT_NE: {
      int eq;
      if (is_undef_or_null(a) || is_undef_or_null(b)) {
        eq = is_undef_or_null(a) && is_undef_or_null(b);
      } else {
        eq = numeric(a, "operand is not a number") == numeric(b, "operand is not a number");
      }
      set_bool(dst, op == QJRT_EQ ? eq : !eq);
      return;
    }
    case QJRT_SEQ:
    case QJRT_SNE: {
      int eq = a->tag == b->tag && a->val == b->val;
      set_bool(dst, op == QJRT_SEQ ? eq : !eq);
      return;
    }
    default: qjrt_fail("unknown binary operator");
  }
}

void qjrt_unop(int op, JV *dst, const JV *a) {
  if (a->tag == QJRT_UNINIT) qjrt_fail("a lexical variable is used before its declaration");
  switch (op) {
    case QJRT_NEG: {
      int64_t x = numeric(a, "operand is not a number");
      int_result(dst, -x, x == 0);
      return;
    }
    case QJRT_PLUS: {
      int64_t x = numeric(a, "operand is not a number");
      set_int(dst, x);
      return;
    }
    case QJRT_LNOT: {
      int t = qjrt_truthy(a);
      set_bool(dst, !t);
      return;
    }
    default: qjrt_fail("unknown unary operator");
  }
}

void qjrt_inc(int delta, JV *dst, const JV *a) {
  if (a->tag == QJRT_UNINIT) qjrt_fail("a lexical variable is used before its declaration");
  int64_t x = numeric(a, "operand of ++ or -- is not a number");
  int_result(dst, x + delta, 0);
}

/* post_inc / post_dec: the old value (as a number) and the new one. `a` may be the storage of `old`: read it first. */
void qjrt_post(int delta, JV *old, JV *neu, const JV *a) {
  JV in = *a;
  if (in.tag == QJRT_UNINIT) qjrt_fail("a lexical variable is used before its declaration");
  int64_t x = numeric(&in, "operand of ++ or -- is not a number");
  int_result(neu, x + delta, 0);
  set_int(old, x);
}

int qjrt_truthy(const JV *a) {
  switch (a->tag) {
    case QJRT_INT:
    case QJRT_BOOL: return a->val != 0;
    case QJRT_NULL:
    case QJRT_UNDEF: return 0;
    default: qjrt_fail("a lexical variable is used before its declaration");
  }
}

/* A read or write of a `let` (a local or a global) before its declaration: the ReferenceError of the reference, which
 * prints the same message for both. */
void qjrt_check_init(const JV *a, const char *name) {
  if (a->tag == QJRT_UNINIT) {
    fprintf(stderr, "ReferenceError: %s is not initialized\n", name);
    exit(1);
  }
}

void qjrt_check_global(const JV *a, const char *name) { qjrt_check_init(a, name); }
