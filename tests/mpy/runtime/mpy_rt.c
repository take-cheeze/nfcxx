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

/* Lists, tuples and iterators. A list owns its item array; a tuple holds its items in place; an iterator names its sequence
 * and the next index. */
static const MpyType mpy_type_list = {"list"};
static const MpyType mpy_type_tuple = {"tuple"};
static const MpyType mpy_type_iter = {"iterator"};

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
  mpv seq;      /* the list or tuple being iterated */
  size_t index; /* the next item to give */
} MpyIter;

static int is_list(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_list; }
static int is_tuple(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_tuple; }
static int is_iter(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_iter; }

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

/* Truth, as mp_obj_is_true: None and False are false; zero is false; an empty str is false; anything else is true. */
int mpy_truth(mpv v) {
  if (v == MPY_NONE || v == MPY_FALSE) return 0;
  if (v == MPY_TRUE) return 1;
  if (is_small(v)) return small_value(v) != 0;
  if (is_str(v)) return str_of(v)->len != 0;
  if (is_iter(v)) return 1;
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
mpv mpy_call(mpv fn, uint64_t nargs) {
  MpyFunc *f;
  size_t base, k;
  mpv ret = MPY_NONE;
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
  if (!seq_items(obj, &len, &items)) {
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
