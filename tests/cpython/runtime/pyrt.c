/* The CPython 3.13 Path B runtime helpers (tests/cpython/runtime/pyrt.h). Python's semantics for the values of the first
 * subset: ints (64-bit here; a result beyond that stops the program, see overflow), bools (ints with the values 0 and 1)
 * and None. The messages are those CPython 3.13 prints for the same errors. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pyrt.h"

static void raise_error(const char *kind, const char *msg) {
  fflush(stdout);
  fprintf(stderr, "%s: %s\n", kind, msg);
  exit(1);
}

/* A result that CPython would make a bignum. The first subset keeps ints in 64 bits; this stops the program. */
static void overflow(void) {
  raise_error("RuntimeError", "integer result beyond 64 bits (bignums are not lowered yet)");
}

static int is_intlike(const PV *v) { return v->tag == PV_INT || v->tag == PV_BOOL; }

static const char *type_name(const PV *v) {
  switch (v->tag) {
    case PV_INT: return "int";
    case PV_BOOL: return "bool";
    case PV_NONE: return "NoneType";
    case PV_FUNC: return "function";
    case PV_ITER: return "range_iterator";
    default: return "unbound";
  }
}

static int truth(const PV *v) {
  switch (v->tag) {
    case PV_INT:
    case PV_BOOL: return v->a != 0;
    case PV_NONE: return 0;
    default: return 1;   /* functions and iterators are true */
  }
}

static void set_int(PV *dst, int64_t x) {
  dst->tag = PV_INT;
  dst->a = x;
  dst->b = 0;
  dst->c = 0;
}

static void set_bool(PV *dst, int x) {
  dst->tag = PV_BOOL;
  dst->a = x ? 1 : 0;
  dst->b = 0;
  dst->c = 0;
}

void pyrt_binop(long op, PV *dst, PV *a, PV *b) {
  static const char *const sym[] = {"+", "-", "*", "//", "%"};
  if (!is_intlike(a) || !is_intlike(b)) {
    char msg[160];
    snprintf(msg, sizeof msg, "unsupported operand type(s) for %s: '%s' and '%s'", sym[op], type_name(a), type_name(b));
    raise_error("TypeError", msg);
  }
  int64_t x = a->a, y = b->a, r = 0;
  switch (op) {
    case 0:
      if (__builtin_add_overflow(x, y, &r)) overflow();
      break;
    case 1:
      if (__builtin_sub_overflow(x, y, &r)) overflow();
      break;
    case 2:
      if (__builtin_mul_overflow(x, y, &r)) overflow();
      break;
    case 3:   /* floor division: the quotient rounds toward minus infinity */
      if (y == 0) raise_error("ZeroDivisionError", "integer division or modulo by zero");
      if (y == -1) {
        if (__builtin_sub_overflow((int64_t)0, x, &r)) overflow();
        break;
      }
      r = x / y;
      if (x % y != 0 && ((x < 0) != (y < 0))) r -= 1;
      break;
    case 4:   /* modulo: the result takes the sign of the divisor */
      if (y == 0) raise_error("ZeroDivisionError", "integer modulo by zero");
      if (y == -1) {
        r = 0;
        break;
      }
      r = x % y;
      if (r != 0 && ((r < 0) != (y < 0))) r += y;
      break;
    default:
      raise_error("SystemError", "pyrt_binop: unknown operator");
  }
  set_int(dst, r);
}

void pyrt_cmp(long op, PV *dst, PV *a, PV *b) {
  static const char *const sym[] = {"<", "<=", "==", "!=", ">", ">="};
  int r;
  if (is_intlike(a) && is_intlike(b)) {
    int64_t x = a->a, y = b->a;
    switch (op) {
      case 0: r = x < y; break;
      case 1: r = x <= y; break;
      case 2: r = x == y; break;
      case 3: r = x != y; break;
      case 4: r = x > y; break;
      default: r = x >= y; break;
    }
  } else if (op == 2 || op == 3) {
    /* None equals only None; values of other types are never equal to a None, and two Nones are equal. */
    int same = (a->tag == PV_NONE && b->tag == PV_NONE);
    r = op == 2 ? same : !same;
  } else {
    char msg[200];
    snprintf(msg, sizeof msg, "'%s' not supported between instances of '%s' and '%s'", sym[op], type_name(a), type_name(b));
    raise_error("TypeError", msg);
    r = 0;
  }
  set_bool(dst, r);
}

void pyrt_unop(long op, PV *dst, PV *a) {
  if (op == 0) {
    if (!is_intlike(a)) {
      char msg[160];
      snprintf(msg, sizeof msg, "bad operand type for unary -: '%s'", type_name(a));
      raise_error("TypeError", msg);
    }
    int64_t r;
    if (__builtin_sub_overflow((int64_t)0, a->a, &r)) overflow();
    set_int(dst, r);
  } else if (op == 1) {
    set_bool(dst, !truth(a));
  } else {
    set_bool(dst, truth(a));
  }
}

int pyrt_truth(PV *a) { return truth(a); }

void pyrt_check_name(PV *g, const char *name) {
  if (g->tag == PV_UNBOUND) {
    char msg[200];
    snprintf(msg, sizeof msg, "name '%s' is not defined", name);
    raise_error("NameError", msg);
  }
}

void pyrt_check_local(PV *l, const char *name) {
  if (l->tag == PV_UNBOUND) {
    char msg[200];
    snprintf(msg, sizeof msg, "cannot access local variable '%s' where it is not associated with a value", name);
    raise_error("UnboundLocalError", msg);
  }
}

void pyrt_init_frame(PV *loc, long n) {
  if (n > 0) memset(loc, 0, (size_t)n * sizeof(PV));
}

void pyrt_range(PV *dst, long argc, PV *args) {
  int64_t v[3];
  for (long k = 0; k < argc; ++k) {
    if (!is_intlike(&args[k])) {
      char msg[160];
      snprintf(msg, sizeof msg, "'%s' object cannot be interpreted as an integer", type_name(&args[k]));
      raise_error("TypeError", msg);
    }
    v[k] = args[k].a;
  }
  int64_t start = 0, stop, step = 1;
  if (argc == 1) {
    stop = v[0];
  } else {
    start = v[0];
    stop = v[1];
    if (argc == 3) step = v[2];
  }
  if (step == 0) raise_error("ValueError", "range() arg 3 must not be zero");
  dst->tag = PV_ITER;
  dst->a = start;
  dst->b = stop;
  dst->c = step;
}

/* Yields the next value of a range iterator into dst, or returns 0 when it is exhausted. */
int pyrt_for_iter(PV *it, PV *dst) {
  if (it->tag != PV_ITER) raise_error("SystemError", "pyrt_for_iter: not an iterator");
  int64_t cur = it->a, stop = it->b, step = it->c;
  int more = step > 0 ? cur < stop : cur > stop;
  if (!more) return 0;
  set_int(dst, cur);
  int64_t next;
  /* a step past the 64-bit range is past the stop too, since the stop is a 64-bit value */
  it->a = __builtin_add_overflow(cur, step, &next) ? stop : next;
  return 1;
}
