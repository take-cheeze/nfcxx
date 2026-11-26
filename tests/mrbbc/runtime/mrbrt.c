/* mrbrt: integer operators and error exits of the mruby bytecode producer (mrbrt.h). C99, -Wall -Wextra clean. */
#include "mrbrt.h"

#include <stdio.h>
#include <stdlib.h>

const char *mrbbc_progname = "mrbbc";

/* The checked 64-bit multiply of the IR (scripts/pathb-qbe-emit.rb calls it for cmul): the same function as in
 * be/nfcxx_ldrt.c, defined here so the test links without that runtime. Nonzero when the product overflows. */
int __nfcxx_smul64_ovf(long a, long b) {
  long r;
  return __builtin_mul_overflow(a, b, &r);
}

void mrbbc_raise(const char *cls, const char *message) {
  fflush(stdout);
  fprintf(stderr, "%s: %s (%s)\n", mrbbc_progname, message, cls);
  exit(1);
}

void mrbbc_set_bool(MV *dst, int truth) {
  dst->tag = truth ? MRBBC_TRUE : MRBBC_FALSE;
}

void mrbbc_print(const MV *v) {
  switch (v->tag) {
    case MRBBC_NIL: printf("nil\n"); break;
    case MRBBC_FALSE: printf("false\n"); break;
    case MRBBC_TRUE: printf("true\n"); break;
    case MRBBC_INT: printf("%lld\n", (long long)v->i); break;
    default: mrbbc_raise("RuntimeError", "unknown value tag");
  }
}

/* The method name of an operator, as mruby's error messages show it. */
static const char *op_method(int op) {
  switch (op) {
    case MRBBC_OP_ADD: return "+";
    case MRBBC_OP_SUB: return "-";
    case MRBBC_OP_MUL: return "*";
    case MRBBC_OP_DIV: return "/";
    case MRBBC_OP_LT: return "<";
    case MRBBC_OP_LE: return "<=";
    case MRBBC_OP_GT: return ">";
    case MRBBC_OP_GE: return ">=";
    default: return "==";
  }
}

/* The class of a value in mruby's messages (NoMethodError and ArgumentError name the class). */
static const char *class_name(const MV *v) {
  switch (v->tag) {
    case MRBBC_NIL: return "NilClass";
    case MRBBC_TRUE: return "TrueClass";
    case MRBBC_FALSE: return "FalseClass";
    default: return "Integer";
  }
}

/* The value as mruby's TypeError messages show it (nil, true or false). */
static const char *value_text(const MV *v) {
  switch (v->tag) {
    case MRBBC_NIL: return "nil";
    case MRBBC_TRUE: return "true";
    default: return "false";
  }
}

/* Floor division, as mruby's Integer#/ rounds (toward negative infinity). The divisor is not zero. */
static int64_t floor_div(int64_t x, int64_t y) {
  int64_t q = x / y;
  if ((x % y != 0) && ((x < 0) != (y < 0))) q -= 1;
  return q;
}

void mrbbc_binop(int op, MV *dst, const MV *a, const MV *b) {
  char msg[96];
  int64_t r = 0;

  if (op == MRBBC_OP_EQ) {
    /* mruby's == on these values is identity, which for nil, true, false and integers is the tag and the value. */
    int same = a->tag == b->tag && (a->tag != MRBBC_INT || a->i == b->i);
    mrbbc_set_bool(dst, same);
    return;
  }
  /* The messages of mruby 4.0 (checked against the pinned interpreter, docs/notes/mrbbc-pathb.md). */
  if (a->tag != MRBBC_INT) {
    snprintf(msg, sizeof msg, "undefined method '%s' for %s", op_method(op), class_name(a));
    mrbbc_raise("NoMethodError", msg);
  }
  if (b->tag != MRBBC_INT) {
    if (op >= MRBBC_OP_LT) {
      snprintf(msg, sizeof msg, "comparison of Integer with %s failed", class_name(b));
      mrbbc_raise("ArgumentError", msg);
    }
    if (op == MRBBC_OP_ADD || op == MRBBC_OP_SUB) {
      if (b->tag == MRBBC_NIL) {
        mrbbc_raise("TypeError", "can't convert nil into Float");
      }
      snprintf(msg, sizeof msg, "%s cannot be converted to Float", value_text(b));
      mrbbc_raise("TypeError", msg);
    }
    snprintf(msg, sizeof msg, "can't convert %s into Integer", value_text(b));
    mrbbc_raise("TypeError", msg);
  }

  switch (op) {
    case MRBBC_OP_ADD:
      if (__builtin_add_overflow(a->i, b->i, &r)) break;
      dst->tag = MRBBC_INT;
      dst->i = r;
      return;
    case MRBBC_OP_SUB:
      if (__builtin_sub_overflow(a->i, b->i, &r)) break;
      dst->tag = MRBBC_INT;
      dst->i = r;
      return;
    case MRBBC_OP_MUL:
      if (__builtin_mul_overflow(a->i, b->i, &r)) break;
      dst->tag = MRBBC_INT;
      dst->i = r;
      return;
    case MRBBC_OP_DIV:
      if (b->i == 0) mrbbc_raise("ZeroDivisionError", "divided by 0");
      if (a->i == INT64_MIN && b->i == -1) break;
      dst->tag = MRBBC_INT;
      dst->i = floor_div(a->i, b->i);
      return;
    case MRBBC_OP_LT: mrbbc_set_bool(dst, a->i < b->i); return;
    case MRBBC_OP_LE: mrbbc_set_bool(dst, a->i <= b->i); return;
    case MRBBC_OP_GT: mrbbc_set_bool(dst, a->i > b->i); return;
    case MRBBC_OP_GE: mrbbc_set_bool(dst, a->i >= b->i); return;
    default: break;
  }
  /* Only an integer overflow gets here. mruby promotes it to a Bignum (or a Float); this producer does not. */
  mrbbc_raise("NotImplementedError", "integer overflow: mrbbc does not promote to Bignum");
}
