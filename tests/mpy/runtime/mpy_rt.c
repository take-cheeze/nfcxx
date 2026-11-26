/* The runtime that lowered MicroPython code calls (docs/notes/mpy-pathb.md, "Values").
 *
 * A value is one 64-bit word, with the tagging of MicroPython's MICROPY_OBJ_REPR_A (py/obj.h):
 *   xxxx...xxx1  a small int; the value is the word shifted right by one
 *   xxxx...x110  an immediate object: None, False, True (value 0, 1, 2 in bits 3 and up)
 * A pointer (low two bits clear, not zero) is a heap object. Its first member is a pointer to its type (MpyType), as
 * MicroPython's mp_obj_base_t has it. The heap types are str (MpyStr), function (MpyFunc), cell, list, tuple, iterator,
 * range (MpyRange) and builtin (MpyBuiltin: len, str, range, and the list methods append and pop). A value of another
 * kind is an error.
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
  MPY_OP_IN = 6, MPY_OP_IS = 7,
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

/* Lists, tuples and iterators. A list owns its item array; a tuple holds its items in place; an iterator names its sequence
 * and the next index. */
static const MpyType mpy_type_list = {"list"};
static const MpyType mpy_type_tuple = {"tuple"};
static const MpyType mpy_type_iter = {"iterator"};
static const MpyType mpy_type_range = {"range"};
/* The builtin functions are called builtin_function_or_method; str and range are types, which are called too. */
static const MpyType mpy_type_bfn = {"builtin_function_or_method"};
static const MpyType mpy_type_type = {"type"};

typedef struct {
  const MpyType *type;
  size_t len, cap;
  mpv *items;
} MpyList;

typedef struct {
  const MpyType *type;
  size_t len;
  mpv items[]; /* C99 flexible array member */
} MpyTuple;

typedef struct {
  const MpyType *type;
  mpv seq;      /* the list, tuple or range being iterated */
  size_t index; /* the next item to give (for a range, the number of items given) */
} MpyIter;

/* A range: its start, stop and step, and the number of items it gives. */
typedef struct {
  const MpyType *type;
  int64_t start, stop, step;
  size_t len;
} MpyRange;

/* The builtins: len, str and range (str and range are types, called as functions), and the list methods append and pop
 * that LOAD_METHOD gives. A builtin is a static record {type, id}; the id is the index in mpy_builtins. */
enum { BI_LEN, BI_STR, BI_RANGE, BI_APPEND, BI_POP };
typedef struct {
  const MpyType *type;
  int id;
} MpyBuiltin;
static const MpyBuiltin mpy_builtins[] = {
  {&mpy_type_bfn, BI_LEN}, {&mpy_type_type, BI_STR}, {&mpy_type_type, BI_RANGE},
  {&mpy_type_bfn, BI_APPEND}, {&mpy_type_bfn, BI_POP},
};

static int is_list(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_list; }
static int is_tuple(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_tuple; }
static int is_iter(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_iter; }
static int is_range(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_range; }
static int is_builtin(mpv v) { return is_heap(v) && (type_of(v) == &mpy_type_bfn || type_of(v) == &mpy_type_type); }
static const MpyRange *range_of(mpv v) { return (const MpyRange *)(uintptr_t)v; }
static mpv builtin_obj(int id) { return (mpv)(uintptr_t)&mpy_builtins[id]; }

/* The builtin with this name, or -1. The module's globals are searched first, so a program can shadow these. */
static int builtin_index(const char *name, size_t len) {
  if (len == 3 && memcmp(name, "len", 3) == 0) return BI_LEN;
  if (len == 3 && memcmp(name, "str", 3) == 0) return BI_STR;
  if (len == 5 && memcmp(name, "range", 5) == 0) return BI_RANGE;
  return -1;
}

/* The item count and items of a list or tuple; 0 when v is neither. */
static int seq_items(mpv v, size_t *len, const mpv **items) {
  if (is_list(v)) {
    *len = ((const MpyList *)(uintptr_t)v)->len;
    *items = ((const MpyList *)(uintptr_t)v)->items;
    return 1;
  }
  if (is_tuple(v)) {
    *len = ((const MpyTuple *)(uintptr_t)v)->len;
    *items = ((const MpyTuple *)(uintptr_t)v)->items;
    return 1;
  }
  return 0;
}

/* The name of a value's type, as MicroPython's error messages give it. Booleans are reported as 'int' in operator errors. */
static const char *type_name(mpv v) {
  if (is_small(v) || is_bool(v)) return "int";
  if (v == MPY_NONE) return "NoneType";
  if (is_heap(v)) return type_of(v)->name;
  return "object";
}

/* The name of a value's type as its own error messages give it (a bool is 'bool'). */
static const char *real_type_name(mpv v) {
  if (is_bool(v)) return "bool";
  return type_name(v);
}

/* Truth, as mp_obj_is_true: None and False are false; zero is false; an empty str is false; anything else is true. */
int mpy_truth(mpv v) {
  if (v == MPY_NONE || v == MPY_FALSE) return 0;
  if (v == MPY_TRUE) return 1;
  if (is_small(v)) return small_value(v) != 0;
  if (is_str(v)) return str_of(v)->len != 0;
  if (is_iter(v)) return 1;
  if (is_range(v)) return range_of(v)->len != 0;
  {
    size_t n;
    const mpv *items;
    if (seq_items(v, &n, &items)) return n != 0;
  }
  fail("truth of a value that is not a small int, bool, None, str, list or tuple is not implemented");
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

/* Equality for `in`: the same word (one object, or one immediate or small int), two strs with the same bytes, two numbers
 * (bools as 0 and 1) with the same value. Two lists or tuples that are different objects are not compared yet, so that
 * fails rather than answers. */
static int str_equal(mpv a, mpv b) {
  const MpyStr *x = str_of(a), *y = str_of(b);
  return x->len == y->len && memcmp(x->data, y->data, x->len) == 0;
}

static int values_equal(mpv a, mpv b) {
  if (a == b) return 1;
  if (is_str(a) || is_str(b)) return is_str(a) && is_str(b) && str_equal(a, b);
  if ((is_small(a) || is_bool(a)) && (is_small(b) || is_bool(b))) return need_int(a) == need_int(b);
  if ((is_list(a) || is_tuple(a)) && (is_list(b) || is_tuple(b))) {
    fail("TypeError: equality of lists and tuples is not lowered yet");
  }
  return 0;
}

/* `x in c` is contains(c, x): a str holds a substring, a list or tuple an equal item. */
static int contains(mpv c, mpv x) {
  char msg[160];
  size_t n, i;
  const mpv *items;
  if (is_str(c)) {
    const MpyStr *hay, *needle;
    if (!is_str(x)) {
      snprintf(msg, sizeof msg, "TypeError: can't convert '%s' object to str implicitly", real_type_name(x));
      fail(msg);
    }
    hay = str_of(c);
    needle = str_of(x);
    for (i = 0; i + needle->len <= hay->len; ++i) {
      if (memcmp(hay->data + i, needle->data, needle->len) == 0) return 1;
    }
    return 0;
  }
  if (seq_items(c, &n, &items)) {
    for (i = 0; i < n; ++i) {
      if (values_equal(items[i], x)) return 1;
    }
    return 0;
  }
  if (is_small(c) || is_bool(c)) {
    snprintf(msg, sizeof msg, "TypeError: unsupported types for : '%s', '%s'", type_name(x), type_name(c));
    fail(msg);
  }
  if (is_range(c) || is_iter(c)) fail("TypeError: containment in a range or an iterator is not lowered yet");
  snprintf(msg, sizeof msg, "TypeError: '%s' object isn't iterable", real_type_name(c));
  fail(msg);
  return 0;
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
  if (op == MPY_OP_IN) return contains(b, a) ? MPY_TRUE : MPY_FALSE;   /* a in b: the right operand is the container */
  if (op == MPY_OP_IS) return a == b ? MPY_TRUE : MPY_FALSE;           /* the same word: one immediate or one object */
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
  int b;
  if (g != NULL) return g->value;
  b = builtin_index(name, len);
  if (b < 0) fail("NameError: name is not defined");
  return builtin_obj(b);
}

/* For the driver: the value of a global, or MPY_NONE and 0 when there is none. */
mpv mpy_get_global(const char *name, int *found) {
  Global *g = find_global(name, strlen(name));
  *found = g != NULL;
  return g != NULL ? g->value : MPY_NONE;
}

/* The value stack that calls take their arguments from: the lowered code pushes each argument, then calls. */
static mpv *vstk = NULL;
static size_t vtop = 0, vcap = 0;

/* Makes room for n values on the value stack. */
static void vstk_reserve(size_t n) {
  size_t cap = vcap ? vcap : 64;
  if (n <= vcap) return;
  while (cap < n) cap *= 2;
  vstk = (mpv *)realloc(vstk, cap * sizeof(mpv));
  if (vstk == NULL) fail("out of memory");
  vcap = cap;
}

void mpy_push(mpv v) {
  vstk_reserve(vtop + 1);
  vstk[vtop++] = v;
}

/* Functions. A function object is a heap record: the number of its IR function (mpy_dispatch's K), its positional
 * argument count (the count the caller passes), and the cells it captured (n_closed of them; 0 for a plain function). A
 * closure is the same record with captured cells. The pointer has its low two bits clear, so it is not a small int or an
 * immediate. */
typedef struct {
  const MpyType *type;
  uint64_t index;
  uint64_t nargs;
  uint64_t n_closed;
  mpv closed[]; /* C99 flexible array member: the captured cells, the first free variables of the function */
} MpyFunc;

/* Generated by the lowering (mpy_dispatch): calls function number idx with args[0..nargs-1], storing the result in ret. */
void mpy_dispatch(uint64_t idx, mpv *ret, const mpv *args, uint64_t nargs);

mpv mpy_make_function(uint64_t index, uint64_t nargs) {
  MpyFunc *f = (MpyFunc *)malloc(sizeof *f);
  if (f == NULL) fail("out of memory");
  f->type = &mpy_type_function;
  f->index = index;
  f->nargs = nargs;
  f->n_closed = 0;
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

/* A closure: its n captured cells are the top n values of the value stack, which they leave (as MAKE_CLOSURE pops them). */
mpv mpy_make_closure(uint64_t index, uint64_t nargs, uint64_t n) {
  MpyFunc *f;
  if (n > vtop) fail("mpy_make_closure: the captured cells are not on the value stack");
  f = (MpyFunc *)malloc(sizeof *f + n * sizeof(mpv));
  if (f == NULL) fail("out of memory");
  f->type = &mpy_type_function;
  f->index = index;
  f->nargs = nargs;
  f->n_closed = n;
  if (n) memcpy(f->closed, vstk + (vtop - n), n * sizeof(mpv));
  vtop -= n;
  return (mpv)(uintptr_t)f;
}

/* Calls fn with the nargs values on top of the value stack, which they leave. A closure's captured cells go in front of
 * the arguments, as MicroPython's closure_call puts them, so the function sees its free variables as its first locals. */
static mpv builtin_call(int id, const mpv *args, uint64_t n);

mpv mpy_call(mpv fn, uint64_t nargs) {
  MpyFunc *f;
  size_t base, k;
  mpv ret = MPY_NONE;
  if (is_builtin(fn)) {
    if (nargs > vtop) fail("mpy_call: the arguments are not on the value stack");
    base = vtop - nargs;
    ret = builtin_call(((const MpyBuiltin *)(uintptr_t)fn)->id, nargs ? vstk + base : NULL, nargs);
    vtop = base;
    return ret;
  }
  if (!is_heap(fn) || type_of(fn) != &mpy_type_function) fail("TypeError: object is not callable");
  f = (MpyFunc *)(uintptr_t)fn;
  if (nargs != f->nargs) fail("TypeError: wrong number of arguments");
  base = vtop - nargs;
  k = (size_t)f->n_closed;
  if (k) {
    vstk_reserve(vtop + k);
    memmove(vstk + base + k, vstk + base, nargs * sizeof(mpv));
    memcpy(vstk + base, f->closed, k * sizeof(mpv));
    vtop += k;
  }
  mpy_dispatch(f->index, &ret, (nargs + k) ? vstk + base : NULL, nargs + k);
  vtop = base;
  return ret;
}

/* Container operations. Each returns a value or fails with the message MicroPython gives. The lowering passes the operands
 * on the value stack for the builders, and as arguments for the rest. */
mpv mpy_build_list(uint64_t n) {
  MpyList *l = (MpyList *)malloc(sizeof *l);
  size_t base = vtop - n, i;
  if (l == NULL) fail("out of memory");
  l->type = &mpy_type_list;
  l->len = n;
  l->cap = n ? n : 1;
  l->items = (mpv *)malloc(l->cap * sizeof(mpv));
  if (l->items == NULL) fail("out of memory");
  for (i = 0; i < n; ++i) l->items[i] = vstk[base + i];
  vtop = base;
  return (mpv)(uintptr_t)l;
}

mpv mpy_build_tuple(uint64_t n) {
  MpyTuple *t = (MpyTuple *)malloc(sizeof *t + n * sizeof(mpv));
  size_t base = vtop - n, i;
  if (t == NULL) fail("out of memory");
  t->type = &mpy_type_tuple;
  t->len = n;
  for (i = 0; i < n; ++i) t->items[i] = vstk[base + i];
  vtop = base;
  return (mpv)(uintptr_t)t;
}

/* An index into a sequence of len items: negative counts from the end. */
static size_t checked_index(mpv seq, mpv idx, size_t len, const char *out_of_range) {
  int64_t i;
  char msg[160];
  if (!is_small(idx) && !is_bool(idx)) {
    snprintf(msg, sizeof msg, "TypeError: %s indices must be integers, not %s", type_name(seq), type_name(idx));
    fail(msg);
  }
  i = need_int(idx);
  if (i < 0) i += (int64_t)len;
  if (i < 0 || i >= (int64_t)len) fail(out_of_range);
  return (size_t)i;
}

mpv mpy_getitem(mpv obj, mpv idx) {
  size_t len;
  const mpv *items;
  char msg[120];
  if (!seq_items(obj, &len, &items)) {
    snprintf(msg, sizeof msg, "TypeError: '%s' object isn't subscriptable", type_name(obj));
    fail(msg);
  }
  return items[checked_index(obj, idx, len,
                             is_list(obj) ? "IndexError: list index out of range" : "IndexError: tuple index out of range")];
}

void mpy_setitem(mpv obj, mpv idx, mpv value) {
  MpyList *l;
  char msg[120];
  if (is_tuple(obj)) fail("TypeError: 'tuple' object doesn't support item assignment");
  if (!is_list(obj)) {
    snprintf(msg, sizeof msg, "TypeError: '%s' object doesn't support item assignment", type_name(obj));
    fail(msg);
  }
  l = (MpyList *)(uintptr_t)obj;
  l->items[checked_index(obj, idx, l->len, "IndexError: list index out of range")] = value;
}

/* The value that unpacking n items of seq gives to the i-th slot from the bottom: the first item is on top. */
mpv mpy_unpack_get(mpv seq, uint64_t n, uint64_t i) {
  size_t len;
  const mpv *items;
  char msg[120];
  if (!seq_items(seq, &len, &items)) {
    snprintf(msg, sizeof msg, "TypeError: cannot unpack non-iterable %s object", type_name(seq));
    fail(msg);
  }
  if (len < n) {
    snprintf(msg, sizeof msg, "ValueError: need more than %d values to unpack", (int)len);
    fail(msg);
  }
  if (len > n) {
    snprintf(msg, sizeof msg, "ValueError: too many values to unpack (expected %d)", (int)n);
    fail(msg);
  }
  return items[n - 1 - i];
}

mpv mpy_get_iter(mpv obj) {
  MpyIter *it;
  size_t len;
  const mpv *items;
  char msg[120];
  if (is_iter(obj)) return obj;
  if (!is_range(obj) && !seq_items(obj, &len, &items)) {
    snprintf(msg, sizeof msg, "TypeError: '%s' object isn't iterable", type_name(obj));
    fail(msg);
  }
  it = (MpyIter *)malloc(sizeof *it);
  if (it == NULL) fail("out of memory");
  it->type = &mpy_type_iter;
  it->seq = obj;
  it->index = 0;
  return (mpv)(uintptr_t)it;
}

/* The next item, or 0 when the sequence is exhausted (0 is never a value). A list may grow while it is iterated. */
mpv mpy_iter_next(mpv iter) {
  MpyIter *it = (MpyIter *)(uintptr_t)iter;
  size_t len;
  const mpv *items;
  if (is_range(it->seq)) {
    const MpyRange *r = range_of(it->seq);
    int64_t v;
    if (it->index >= r->len) return 0;
    v = r->start + (int64_t)it->index * r->step;
    it->index++;
    return make_small(v);
  }
  seq_items(it->seq, &len, &items);
  if (it->index >= len) return 0;
  return items[it->index++];
}

/* Cells. A cell is a heap box holding one value; a closure and the function that owns the variable share it. The value 0
 * is unbound (the variable has not been assigned yet). Cells are never values a program can name: lowered code reaches them
 * only through its locals and the captured cells of a closure. */
typedef struct {
  mpv value;
} MpyCell;

mpv mpy_make_cell(mpv value) {
  MpyCell *c = (MpyCell *)malloc(sizeof *c);
  if (c == NULL) fail("out of memory");
  c->value = value;
  return (mpv)(uintptr_t)c;
}

mpv mpy_cell_get(mpv cell) {
  MpyCell *c = (MpyCell *)(uintptr_t)cell;
  if (c->value == 0) fail("NameError: local variable referenced before assignment");
  return c->value;
}

void mpy_cell_set(mpv cell, mpv value) {
  ((MpyCell *)(uintptr_t)cell)->value = value;
}

/* Builtins. A builtin's arguments are args[0..n-1] on the value stack (mpy_call leaves them there until it returns). */
static mpv new_str(const char *bytes, size_t n) {
  MpyStr *s = alloc_str(n);
  memcpy(s->data, bytes, n);
  return (mpv)(uintptr_t)s;
}

/* range(start, stop, step): the number of items is that of the arithmetic sequence. */
static mpv new_range(int64_t start, int64_t stop, int64_t step) {
  MpyRange *r;
  if (step == 0) fail("ValueError: zero step");
  r = (MpyRange *)malloc(sizeof *r);
  if (r == NULL) fail("out of memory");
  r->type = &mpy_type_range;
  r->start = start;
  r->stop = stop;
  r->step = step;
  if (step > 0) r->len = start < stop ? (size_t)((stop - start - 1) / step + 1) : 0;
  else r->len = start > stop ? (size_t)((start - stop - 1) / -step + 1) : 0;
  return (mpv)(uintptr_t)r;
}

static void list_append(MpyList *l, mpv v) {
  if (l->len == l->cap) {   /* cap is at least 1 (mpy_build_list) */
    size_t cap = l->cap * 2;
    mpv *items = (mpv *)realloc(l->items, cap * sizeof(mpv));
    if (items == NULL) fail("out of memory");
    l->items = items;
    l->cap = cap;
  }
  l->items[l->len++] = v;
}

/* The characters of a str: its bytes that do not continue a UTF-8 sequence (the same count for valid UTF-8). */
static size_t str_chars(const MpyStr *s) {
  size_t i, n = 0;
  for (i = 0; i < s->len; ++i) {
    if ((s->data[i] & 0xc0) != 0x80) ++n;
  }
  return n;
}

static mpv builtin_call(int id, const mpv *args, uint64_t n) {
  char msg[160];
  switch (id) {
    case BI_LEN: {
      size_t len;
      const mpv *items;
      if (n != 1) fail("TypeError: len() takes exactly one argument");
      if (is_str(args[0])) return make_small((int64_t)str_chars(str_of(args[0])));
      if (seq_items(args[0], &len, &items)) return make_small((int64_t)len);
      if (is_range(args[0])) return make_small((int64_t)range_of(args[0])->len);
      snprintf(msg, sizeof msg, "TypeError: object of type '%s' has no len()", real_type_name(args[0]));
      fail(msg);
      return MPY_NONE;
    }
    case BI_STR: {
      char buf[32];
      int k;
      if (n == 0) return new_str("", 0);
      if (n != 1) fail("TypeError: str() takes at most 1 argument");
      if (is_str(args[0])) return args[0];   /* str(s) is s, as in MicroPython */
      if (args[0] == MPY_NONE) return new_str("None", 4);
      if (args[0] == MPY_TRUE) return new_str("True", 4);
      if (args[0] == MPY_FALSE) return new_str("False", 5);
      if (is_small(args[0])) {
        k = snprintf(buf, sizeof buf, "%lld", (long long)small_value(args[0]));
        return new_str(buf, (size_t)k);
      }
      fail("str() of this value is not lowered yet");
      return MPY_NONE;
    }
    case BI_RANGE: {
      uint64_t i;
      if (n < 1 || n > 3) fail("TypeError: range expected 1 to 3 arguments");
      for (i = 0; i < n; ++i) {
        if (!is_small(args[i]) && !is_bool(args[i])) {
          snprintf(msg, sizeof msg, "TypeError: can't convert %s to int", real_type_name(args[i]));
          fail(msg);
        }
      }
      if (n == 1) return new_range(0, need_int(args[0]), 1);
      if (n == 2) return new_range(need_int(args[0]), need_int(args[1]), 1);
      return new_range(need_int(args[0]), need_int(args[1]), need_int(args[2]));
    }
    case BI_APPEND: {
      if (n != 2) fail("TypeError: append() takes exactly one argument");
      if (!is_list(args[0])) fail("TypeError: append() needs a list");
      list_append((MpyList *)(uintptr_t)args[0], args[1]);
      return MPY_NONE;
    }
    case BI_POP: {
      MpyList *l;
      size_t i;
      mpv v;
      if (n < 1 || n > 2) fail("TypeError: pop() takes at most 1 argument");
      if (!is_list(args[0])) fail("TypeError: pop() needs a list");
      l = (MpyList *)(uintptr_t)args[0];
      if (l->len == 0) fail("IndexError: pop from empty list");
      i = n == 2 ? checked_index(args[0], args[1], l->len, "IndexError: list index out of range") : l->len - 1;
      v = l->items[i];
      memmove(l->items + i, l->items + i + 1, (l->len - i - 1) * sizeof(mpv));
      l->len -= 1;
      return v;
    }
    default:
      fail("internal: unknown builtin");
  }
  return MPY_NONE;
}

/* LOAD_METHOD: the method of obj named name. The lowering passes only append and pop. A list has them; any other value
 * fails with MicroPython's attribute error. */
mpv mpy_load_method(mpv obj, const char *name, size_t len) {
  char msg[160];
  if (is_list(obj)) {
    if (len == 6 && memcmp(name, "append", 6) == 0) return builtin_obj(BI_APPEND);
    if (len == 3 && memcmp(name, "pop", 3) == 0) return builtin_obj(BI_POP);
  }
  snprintf(msg, sizeof msg, "AttributeError: '%s' object has no attribute '%.*s'", real_type_name(obj), (int)len, name);
  fail(msg);
  return MPY_NONE;
}

/* repr of a str, as MicroPython writes it: single quotes unless the text has a single quote and no double quote. */
static void print_str_repr(const MpyStr *s) {
  int has_sq = memchr(s->data, '\'', s->len) != NULL;
  int has_dq = memchr(s->data, '"', s->len) != NULL;
  char q = (has_sq && !has_dq) ? '"' : '\'';
  size_t i;
  putchar(q);
  for (i = 0; i < s->len; ++i) {
    unsigned char c = (unsigned char)s->data[i];
    if (c == (unsigned char)q || c == '\\') {
      putchar('\\');
      putchar(c);
    } else if (c == '\n') fputs("\\n", stdout);
    else if (c == '\r') fputs("\\r", stdout);
    else if (c == '\t') fputs("\\t", stdout);
    else if (c < 0x20 || c == 0x7f) printf("\\x%02x", c);
    else putchar(c);
  }
  putchar(q);
}

/* repr of a value: numbers, bools and None by name, str quoted, and lists and tuples with their items' repr. */
static void print_repr(mpv v) {
  size_t n, i;
  const mpv *items;
  if (is_small(v)) printf("%lld", (long long)small_value(v));
  else if (v == MPY_TRUE) fputs("True", stdout);
  else if (v == MPY_FALSE) fputs("False", stdout);
  else if (v == MPY_NONE) fputs("None", stdout);
  else if (is_str(v)) print_str_repr(str_of(v));
  else if (is_range(v)) {
    const MpyRange *r = range_of(v);
    if (r->step == 1) printf("range(%lld, %lld)", (long long)r->start, (long long)r->stop);
    else printf("range(%lld, %lld, %lld)", (long long)r->start, (long long)r->stop, (long long)r->step);
  }
  else if (seq_items(v, &n, &items)) {
    int is_l = is_list(v);
    putchar(is_l ? '[' : '(');
    for (i = 0; i < n; ++i) {
      if (i) fputs(", ", stdout);
      print_repr(items[i]);
    }
    if (!is_l && n == 1) putchar(',');
    putchar(is_l ? ']' : ')');
  } else fail("repr of this value is not lowered yet");
}

/* Prints a value as the driver reports the result of the module: a str as its text, anything else as repr. */
void mpy_print_value(mpv v) {
  if (is_str(v)) fwrite(str_of(v)->data, 1, str_of(v)->len, stdout);   /* the bytes may hold NULs */
  else print_repr(v);
  putchar('\n');
}
