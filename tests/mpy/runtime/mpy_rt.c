/* The runtime that lowered MicroPython code calls (docs/notes/mpy-pathb.md, "Values").
 *
 * A value is one 64-bit word, with the tagging of MicroPython's MICROPY_OBJ_REPR_A (py/obj.h):
 *   xxxx...xxx1  a small int; the value is the word shifted right by one
 *   xxxx...x110  an immediate object: None, False, True (value 0, 1, 2 in bits 3 and up)
 * A pointer (low two bits clear, not zero) is a heap object. Its first member is a pointer to its type (MpyType), as
 * MicroPython's mp_obj_base_t has it. Two heap types exist: str (MpyStr) and function (MpyFunc). Other heap objects are
 * not here yet, so a value of another kind is an error.
 *
 * Strings (docs/notes/mpy-pathb.md, "Strings"): a MpyStr is the type pointer, the byte length, and the bytes followed by a
 * NUL. The bytes are immutable. A literal is allocated once, the first time its site runs, and kept (no GC yet); a
 * concatenation allocates a new one and it is kept too.
 *
 * Integers wider than the small-int range would be big ints in MicroPython (MICROPY_LONGINT_IMPL). They are an error here
 * until the runtime has them, so a test program must stay in the small-int range. Names are looked up in one module
 * globals table, keyed by the name's bytes. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t mpv;

#define MPY_NONE ((mpv)0x06)
#define MPY_FALSE ((mpv)0x0e)
#define MPY_TRUE ((mpv)0x16)

/* MP_BINARY_OP_* and MP_UNARY_OP_* (py/runtime0.h), as the bytecode carries them. */
enum {
  MPY_OP_LESS = 0, MPY_OP_MORE = 1, MPY_OP_EQUAL = 2, MPY_OP_LESS_EQUAL = 3, MPY_OP_MORE_EQUAL = 4, MPY_OP_NOT_EQUAL = 5,
  MPY_OP_OR = 22, MPY_OP_XOR = 23, MPY_OP_AND = 24, MPY_OP_LSHIFT = 25, MPY_OP_RSHIFT = 26, MPY_OP_ADD = 27,
  MPY_OP_SUBTRACT = 28, MPY_OP_MULTIPLY = 29, MPY_OP_FLOOR_DIVIDE = 31, MPY_OP_MODULO = 33
};
enum { MPY_UOP_POSITIVE = 0, MPY_UOP_NEGATIVE = 1, MPY_UOP_INVERT = 2, MPY_UOP_NOT = 3 };

#define MPY_SMALL_MAX ((int64_t)((1ULL << 62) - 1))
#define MPY_SMALL_MIN ((int64_t)(-(1LL << 62)))

static void fail(const char *what) {
  fprintf(stderr, "mpy: %s\n", what);
  exit(1);
}

static int is_small(mpv v) { return (v & 1) != 0; }
static int64_t small_value(mpv v) { return ((int64_t)v) >> 1; }

static mpv make_small(int64_t n) {
  if (n > MPY_SMALL_MAX || n < MPY_SMALL_MIN) fail("integer out of the small-int range (big ints are not implemented)");
  return ((mpv)n << 1) | 1;
}

static int is_bool(mpv v) { return v == MPY_FALSE || v == MPY_TRUE; }

/* Heap objects. The type is the first member of every heap record. */
typedef struct MpyType {
  const char *name;
} MpyType;

static const MpyType mpy_type_str = {"str"};
static const MpyType mpy_type_function = {"function"};

typedef struct {
  const MpyType *type;
  size_t len;
  char data[];   /* len bytes and a NUL */
} MpyStr;

static int is_heap(mpv v) { return v != 0 && (v & 3) == 0; }
static const MpyType *type_of(mpv v) { return *(const MpyType *const *)(uintptr_t)v; }
static int is_str(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_str; }
static const MpyStr *str_of(mpv v) { return (const MpyStr *)(uintptr_t)v; }

/* The name of a value's type, as MicroPython's error messages give it. Booleans are reported as 'int' in operator errors. */
static const char *type_name(mpv v) {
  if (is_small(v) || is_bool(v)) return "int";
  if (v == MPY_NONE) return "NoneType";
  if (is_heap(v)) return type_of(v)->name;
  return "object";
}

/* Truth, as mp_obj_is_true: None and False are false; zero is false; an empty str is false; anything else is true. */
int mpy_truth(mpv v) {
  if (v == MPY_NONE || v == MPY_FALSE) return 0;
  if (v == MPY_TRUE) return 1;
  if (is_small(v)) return small_value(v) != 0;
  if (is_str(v)) return str_of(v)->len != 0;
  fail("truth of a value that is not a small int, bool, None or str is not implemented");
  return 0;
}

static int64_t need_int(mpv v) {
  if (is_small(v)) return small_value(v);
  if (is_bool(v)) return v == MPY_TRUE ? 1 : 0;
  fail("unsupported operand type");
  return 0;
}

static MpyStr *alloc_str(size_t n) {
  MpyStr *s = (MpyStr *)malloc(sizeof(MpyStr) + n + 1);
  if (s == NULL) fail("out of memory");
  s->type = &mpy_type_str;
  s->len = n;
  s->data[n] = '\0';
  return s;
}

/* A str operator: == and != compare the bytes (a str never equals a non-str), + concatenates two strs. The other operators
 * on a str are not lowered yet, and they fail here rather than give a wrong answer. */
static mpv str_binop(int op, mpv a, mpv b) {
  char msg[160];
  if (op == MPY_OP_EQUAL || op == MPY_OP_NOT_EQUAL) {
    int eq = 0;
    if (is_str(a) && is_str(b)) {
      const MpyStr *x = str_of(a), *y = str_of(b);
      eq = x->len == y->len && memcmp(x->data, y->data, x->len) == 0;
    }
    return (eq == (op == MPY_OP_EQUAL)) ? MPY_TRUE : MPY_FALSE;
  }
  if (op == MPY_OP_ADD) {
    if (!is_str(a) || !is_str(b)) {
      snprintf(msg, sizeof msg, "TypeError: unsupported types for __add__: '%s', '%s'", type_name(a), type_name(b));
      fail(msg);
    }
    {
      const MpyStr *x = str_of(a), *y = str_of(b);
      MpyStr *r;
      if (x->len + y->len < x->len) fail("string too long");
      r = alloc_str(x->len + y->len);
      memcpy(r->data, x->data, x->len);
      memcpy(r->data + x->len, y->data, y->len);
      return (mpv)(uintptr_t)r;
    }
  }
  if (op == MPY_OP_LESS || op == MPY_OP_MORE || op == MPY_OP_LESS_EQUAL || op == MPY_OP_MORE_EQUAL) {
    fail("str ordering (<, >, <=, >=) is not lowered yet");
  }
  snprintf(msg, sizeof msg, "str operator (code %d) is not lowered yet", op);
  fail(msg);
  return MPY_NONE;
}

mpv mpy_small(int64_t n) { return make_small(n); }

/* A binary operator (the MP_BINARY_OP_* codes). Booleans take part as 0 and 1, as in Python. */
mpv mpy_binop(int op, mpv a, mpv b) {
  int64_t x, y, r = 0;
  /* The in-place forms (MP_BINARY_OP_INPLACE_OR = 9 .. INPLACE_POWER = 21) are the same operators on immutable ints:
   * INPLACE_X is X + 13 (runtime0.h). The in-place matrix multiply, true divide and power stay unsupported. */
  if (op >= 9 && op <= 21) op += 13;
  if (is_str(a) || is_str(b)) return str_binop(op, a, b);
  x = need_int(a);
  y = need_int(b);
  switch (op) {
    case MPY_OP_LESS: return x < y ? MPY_TRUE : MPY_FALSE;
    case MPY_OP_MORE: return x > y ? MPY_TRUE : MPY_FALSE;
    case MPY_OP_EQUAL: return x == y ? MPY_TRUE : MPY_FALSE;
    case MPY_OP_LESS_EQUAL: return x <= y ? MPY_TRUE : MPY_FALSE;
    case MPY_OP_MORE_EQUAL: return x >= y ? MPY_TRUE : MPY_FALSE;
    case MPY_OP_NOT_EQUAL: return x != y ? MPY_TRUE : MPY_FALSE;
    case MPY_OP_OR: r = x | y; break;
    case MPY_OP_XOR: r = x ^ y; break;
    case MPY_OP_AND: r = x & y; break;
    case MPY_OP_ADD:
      if (__builtin_add_overflow(x, y, &r)) fail("integer overflow (big ints are not implemented)");
      break;
    case MPY_OP_SUBTRACT:
      if (__builtin_sub_overflow(x, y, &r)) fail("integer overflow (big ints are not implemented)");
      break;
    case MPY_OP_MULTIPLY:
      if (__builtin_mul_overflow(x, y, &r)) fail("integer overflow (big ints are not implemented)");
      break;
    case MPY_OP_FLOOR_DIVIDE:
      if (y == 0) fail("ZeroDivisionError: divide by zero");
      r = x / y;
      if ((x % y != 0) && ((x < 0) != (y < 0))) r -= 1;   /* Python's floor */
      break;
    case MPY_OP_MODULO:
      if (y == 0) fail("ZeroDivisionError: modulo by zero");
      r = x % y;
      if (r != 0 && ((r < 0) != (y < 0))) r += y;   /* the sign of the divisor */
      break;
    case MPY_OP_LSHIFT:
      if (y < 0) fail("negative shift count");
      if (y >= 63) {
        if (x == 0) r = 0;
        else fail("integer overflow (big ints are not implemented)");
      } else {
        r = (int64_t)((uint64_t)x << y);
        if ((r >> y) != x) fail("integer overflow (big ints are not implemented)");
      }
      break;
    case MPY_OP_RSHIFT:
      if (y < 0) fail("negative shift count");
      r = y >= 63 ? (x < 0 ? -1 : 0) : (x >> y);
      break;
    default: fail("unsupported binary operator");
  }
  return make_small(r);
}

/* A unary operator (the MP_UNARY_OP_* codes). */
mpv mpy_unop(int op, mpv a) {
  switch (op) {
    case MPY_UOP_NOT: return mpy_truth(a) ? MPY_FALSE : MPY_TRUE;
    case MPY_UOP_POSITIVE: return make_small(need_int(a));
    case MPY_UOP_NEGATIVE: {
      int64_t x = need_int(a), r;
      if (__builtin_sub_overflow((int64_t)0, x, &r)) fail("integer overflow (big ints are not implemented)");
      return make_small(r);
    }
    case MPY_UOP_INVERT: return make_small(~need_int(a));
    default: fail("unsupported unary operator");
  }
  return MPY_NONE;
}

/* The module's globals: names and values, in creation order. */
typedef struct {
  char *name;
  size_t len;
  mpv value;
} Global;

static Global *globals = NULL;
static size_t n_globals = 0, cap_globals = 0;

static Global *find_global(const char *name, size_t len) {
  for (size_t i = 0; i < n_globals; ++i) {
    if (globals[i].len == len && memcmp(globals[i].name, name, len) == 0) return &globals[i];
  }
  return NULL;
}

void mpy_store_name(const char *name, size_t len, mpv value) {
  Global *g = find_global(name, len);
  if (g == NULL) {
    if (n_globals == cap_globals) {
      cap_globals = cap_globals ? cap_globals * 2 : 16;
      globals = (Global *)realloc(globals, cap_globals * sizeof(Global));
      if (globals == NULL) fail("out of memory");
    }
    g = &globals[n_globals++];
    g->name = (char *)malloc(len + 1);
    if (g->name == NULL) fail("out of memory");
    memcpy(g->name, name, len);
    g->name[len] = '\0';
    g->len = len;
  }
  g->value = value;
}

mpv mpy_load_name(const char *name, size_t len) {
  Global *g = find_global(name, len);
  if (g == NULL) fail("NameError: name is not defined");
  return g->value;
}

/* For the driver: the value of a global, or MPY_NONE and 0 when there is none. */
mpv mpy_get_global(const char *name, int *found) {
  Global *g = find_global(name, strlen(name));
  *found = g != NULL;
  return g != NULL ? g->value : MPY_NONE;
}

/* Functions. A function object is a heap record: the number of its IR function (mpy_dispatch's K) and its positional
 * argument count. The pointer has its low two bits clear, so it is not a small int or an immediate. */
typedef struct {
  const MpyType *type;
  uint64_t index;
  uint64_t nargs;
} MpyFunc;

/* Generated by the lowering (mpy_dispatch): calls function number idx with args[0..nargs-1], storing the result in ret. */
void mpy_dispatch(uint64_t idx, mpv *ret, const mpv *args, uint64_t nargs);

mpv mpy_make_function(uint64_t index, uint64_t nargs) {
  MpyFunc *f = (MpyFunc *)malloc(sizeof *f);
  if (f == NULL) fail("out of memory");
  f->type = &mpy_type_function;
  f->index = index;
  f->nargs = nargs;
  return (mpv)(uintptr_t)f;
}

/* A str literal: the bytes at bytes (len of them, NUL-terminated in the data). id numbers the literal sites of the module,
 * densely from 0, and the record of each one is allocated the first time its site runs. */
mpv mpy_str_lit(const char *bytes, size_t len, uint64_t id) {
  static mpv *lits = NULL;
  static size_t n_lits = 0;
  if (id >= n_lits) {
    size_t n = (size_t)id + 1, k;
    lits = (mpv *)realloc(lits, n * sizeof(mpv));
    if (lits == NULL) fail("out of memory");
    for (k = n_lits; k < n; ++k) lits[k] = 0;
    n_lits = n;
  }
  if (lits[id] == 0) {
    MpyStr *s = alloc_str(len);
    memcpy(s->data, bytes, len);
    lits[id] = (mpv)(uintptr_t)s;
  }
  return lits[id];
}

/* The value stack that calls take their arguments from: the lowered code pushes each argument, then calls. */
static mpv *vstk = NULL;
static size_t vtop = 0, vcap = 0;

void mpy_push(mpv v) {
  if (vtop == vcap) {
    vcap = vcap ? vcap * 2 : 64;
    vstk = (mpv *)realloc(vstk, vcap * sizeof(mpv));
    if (vstk == NULL) fail("out of memory");
  }
  vstk[vtop++] = v;
}

/* Calls fn with the nargs values on top of the value stack, which they leave. */
mpv mpy_call(mpv fn, uint64_t nargs) {
  MpyFunc *f;
  size_t base;
  mpv ret = MPY_NONE;
  if (!is_heap(fn) || type_of(fn) != &mpy_type_function) fail("TypeError: object is not callable");
  f = (MpyFunc *)(uintptr_t)fn;
  if (nargs != f->nargs) fail("TypeError: wrong number of arguments");
  base = vtop - nargs;
  mpy_dispatch(f->index, &ret, vstk ? vstk + base : NULL, nargs);
  vtop = base;
  return ret;
}

/* Prints a value as the driver reports a result: small ints in decimal, booleans and None by name, a str as its text. */
void mpy_print_value(mpv v) {
  if (is_small(v)) printf("%lld\n", (long long)small_value(v));
  else if (v == MPY_TRUE) printf("True\n");
  else if (v == MPY_FALSE) printf("False\n");
  else if (v == MPY_NONE) printf("None\n");
  else if (is_str(v)) {   /* print(str) writes the text itself, no quotes; the bytes may hold NULs */
    fwrite(str_of(v)->data, 1, str_of(v)->len, stdout);
    printf("\n");
  }
  else printf("(not printed: %llx)\n", (unsigned long long)v);
}
