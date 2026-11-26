/* The runtime that lowered MicroPython code calls (docs/notes/mpy-pathb.md, "Values").
 *
 * A value is one 64-bit word, with the tagging of MicroPython's MICROPY_OBJ_REPR_A (py/obj.h):
 *   xxxx...xxx1  a small int; the value is the word shifted right by one
 *   xxxx...x110  an immediate object: None, False, True (value 0, 1, 2 in bits 3 and up)
 * A pointer (low two bits clear, not zero) is a heap object. Its first member is a pointer to its type (MpyType), as
 * MicroPython's mp_obj_base_t has it. The heap types are str (MpyStr), function (MpyFunc), cell, list, tuple, iterator,
 * range (MpyRange), dict (MpyDict), slice (MpySlice) and builtin (MpyBuiltin: len, str, range, and the list methods append
 * and pop). A value of another kind is an error.
 *
 * Strings (docs/notes/mpy-pathb.md, "Strings"): a MpyStr is the type pointer, the byte length, and the bytes followed by a
 * NUL. The bytes are immutable. A literal is allocated once, the first time its site runs, and kept (no GC yet); a
 * concatenation allocates a new one and it is kept too.
 *
 * Dicts and slices (docs/notes/mpy-pathb.md, "Dicts" and "Slices"). A value 0 is never a value: it is the null that a
 * `del` stores (LOAD_NULL), so STORE_SUBSCR with it deletes.
 *
 * Integers wider than the small-int range would be big ints in MicroPython (MICROPY_LONGINT_IMPL). They are an error here
 * until the runtime has them, so a test program must stay in the small-int range. Names are looked up in one module
 * globals table, keyed by the name's bytes. */
#include <setjmp.h>
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
  MPY_OP_IN = 6, MPY_OP_IS = 7, MPY_OP_EXCEPTION_MATCH = 8,
  MPY_OP_OR = 22, MPY_OP_XOR = 23, MPY_OP_AND = 24, MPY_OP_LSHIFT = 25, MPY_OP_RSHIFT = 26, MPY_OP_ADD = 27,
  MPY_OP_SUBTRACT = 28, MPY_OP_MULTIPLY = 29, MPY_OP_FLOOR_DIVIDE = 31, MPY_OP_MODULO = 33
};
enum { MPY_UOP_POSITIVE = 0, MPY_UOP_NEGATIVE = 1, MPY_UOP_INVERT = 2, MPY_UOP_NOT = 3 };

#define MPY_SMALL_MAX ((int64_t)((1ULL << 62) - 1))
#define MPY_SMALL_MIN ((int64_t)(-(1LL << 62)))

/* An error. A message that starts with the name of an exception class ("ValueError: ...") raises that exception, which a
 * try block can catch; any other message is fatal (see raise_text). */
static void raise_text(const char *what);
static void fail(const char *what) { raise_text(what); }

static int is_small(mpv v) { return (v & 1) != 0; }
static int64_t small_value(mpv v) { return ((int64_t)v) >> 1; }

static mpv make_small(int64_t n) {
  if (n > MPY_SMALL_MAX || n < MPY_SMALL_MIN) fail("integer out of the small-int range (big ints are not implemented)");
  return ((mpv)n << 1) | 1;
}

static int is_bool(mpv v) { return v == MPY_FALSE || v == MPY_TRUE; }

/* Heap objects. The type is the first member of every heap record. */
struct MpyClass;

/* The type record that every heap object starts with. A class's info record is also the type of its instances: inst is
 * 1 for those, cls is the class, base the class it derives from, and exc is 1 for an exception class and its instances. */
typedef struct MpyType {
  const char *name;
  const struct MpyType *base;
  int exc;
  int inst;
  struct MpyClass *cls;
} MpyType;

static const MpyType mpy_type_str = {"str", NULL, 0, 0, NULL};
static const MpyType mpy_type_function = {"function", NULL, 0, 0, NULL};

/* The builtin exception classes (docs/notes/mpy-pathb.md, "Exceptions"), the bases first. */
enum {
  EXC_BASE_EXCEPTION, EXC_EXCEPTION, EXC_ARITHMETIC, EXC_LOOKUP, EXC_ZERO_DIVISION, EXC_INDEX, EXC_KEY, EXC_VALUE,
  EXC_TYPE, EXC_ATTRIBUTE, EXC_NAME, EXC_RUNTIME, EXC_NOT_IMPLEMENTED, EXC_COUNT
};
static const MpyType mpy_exc_info[EXC_COUNT] = {
  {"BaseException", NULL, 1, 1, NULL},
  {"Exception", &mpy_exc_info[EXC_BASE_EXCEPTION], 1, 1, NULL},
  {"ArithmeticError", &mpy_exc_info[EXC_EXCEPTION], 1, 1, NULL},
  {"LookupError", &mpy_exc_info[EXC_EXCEPTION], 1, 1, NULL},
  {"ZeroDivisionError", &mpy_exc_info[EXC_ARITHMETIC], 1, 1, NULL},
  {"IndexError", &mpy_exc_info[EXC_LOOKUP], 1, 1, NULL},
  {"KeyError", &mpy_exc_info[EXC_LOOKUP], 1, 1, NULL},
  {"ValueError", &mpy_exc_info[EXC_EXCEPTION], 1, 1, NULL},
  {"TypeError", &mpy_exc_info[EXC_EXCEPTION], 1, 1, NULL},
  {"AttributeError", &mpy_exc_info[EXC_EXCEPTION], 1, 1, NULL},
  {"NameError", &mpy_exc_info[EXC_EXCEPTION], 1, 1, NULL},
  {"RuntimeError", &mpy_exc_info[EXC_EXCEPTION], 1, 1, NULL},
  {"NotImplementedError", &mpy_exc_info[EXC_RUNTIME], 1, 1, NULL},
};
static const MpyType mpy_type_metaclass = {"type", NULL, 0, 0, NULL};   /* a user class object; its instances' type is its info */
static const MpyType mpy_type_bound = {"method", NULL, 0, 0, NULL};     /* a bound method: a function with its self */

typedef struct {
  const MpyType *type;
  size_t len;
  int interned;   /* a literal of the module (MicroPython's qstr); a str built at run time is not */
  char data[];    /* len bytes and a NUL */
} MpyStr;

static int is_heap(mpv v) { return v != 0 && (v & 3) == 0; }
static const MpyType *type_of(mpv v) { return *(const MpyType *const *)(uintptr_t)v; }
static int is_str(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_str; }
static int is_qstr(mpv v) { return is_str(v) && ((const MpyStr *)(uintptr_t)v)->interned; }
static const MpyStr *str_of(mpv v) { return (const MpyStr *)(uintptr_t)v; }

/* Lists, tuples and iterators. A list owns its item array; a tuple holds its items in place; an iterator names its sequence
 * and the next index. */
static const MpyType mpy_type_list = {"list", NULL, 0, 0, NULL};
static const MpyType mpy_type_tuple = {"tuple", NULL, 0, 0, NULL};
static const MpyType mpy_type_iter = {"iterator", NULL, 0, 0, NULL};
static const MpyType mpy_type_range = {"range", NULL, 0, 0, NULL};
static const MpyType mpy_type_dict = {"dict", NULL, 0, 0, NULL};
static const MpyType mpy_type_set = {"set", NULL, 0, 0, NULL};
static const MpyType mpy_type_view = {"dict_view", NULL, 0, 0, NULL};   /* keys(), values() and items() */
static const MpyType mpy_type_super = {"super", NULL, 0, 0, NULL};     /* super(cls, self): the bases of cls, for self */
static const MpyType mpy_type_cell = {"cell", NULL, 0, 0, NULL};       /* a closure's box (only the class body returns one) */
static const MpyType mpy_type_slice = {"slice", NULL, 0, 0, NULL};
/* The builtin functions are called builtin_function_or_method; str and range are types, which are called too. */
static const MpyType mpy_type_bfn = {"builtin_function_or_method", NULL, 0, 0, NULL};
static const MpyType mpy_type_type = {"type", NULL, 0, 0, NULL};

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

/* A dict (docs/notes/mpy-pathb.md, "Dicts") is MicroPython's mp_map_t (py/map.c), which the iteration order follows: a table of
 * alloc slots, with open addressing by linear probing from hash % alloc. A slot with key 0 is empty; a deleted slot holds the
 * sentinel key. The table grows by the sizes of py/map.c's hash_allocation_sizes when an insertion finds no free slot. */
typedef struct {
  mpv key, value;
} MpyEntry;

typedef struct {
  const MpyType *type;
  size_t alloc;            /* the table's slot count (map.c's alloc) */
  size_t used;             /* the live items */
  int all_keys_are_qstrs;  /* 1 while every key is an interned str (map.c's all_keys_are_qstrs) */
  MpyEntry *table;
} MpyDict;

/* The key of a deleted slot. It is never a value (the immediates are None, False and True only). */
#define MPY_SENTINEL ((mpv)0x1e)

/* A set (docs/notes/mpy-pathb.md, "Sets") is an MpyDict record with type mpy_type_set and no values: MicroPython's mp_set_t
 * has the same table, probing and growth (py/objset.c, py/map.c's mp_set_lookup). A dict view is the live keys(), values()
 * or items() of a dict. */
enum { VIEW_KEYS, VIEW_VALUES, VIEW_ITEMS };
typedef struct {
  const MpyType *type;
  mpv dict;   /* the MpyDict the view reads */
  int kind;   /* VIEW_KEYS, VIEW_VALUES or VIEW_ITEMS */
} MpyView;

/* A slice: its start, stop and step, each an int or None. */
typedef struct {
  const MpyType *type;
  mpv start, stop, step;
} MpySlice;

/* The builtins: len, str and range (str and range are types, called as functions), and the list methods append and pop
 * that LOAD_METHOD gives. A builtin is a static record {type, id}; the id is the index in mpy_builtins. */
/* BI_EXC + k is the builtin class of exception k (mpy_exc_info[k]). */
enum {
  BI_LEN, BI_STR, BI_RANGE, BI_APPEND, BI_POP, BI_BUILD_CLASS,
  BI_DICT_GET, BI_DICT_KEYS, BI_DICT_VALUES, BI_DICT_ITEMS, BI_DICT_POP, BI_DICT_UPDATE,
  BI_DICT_COPY, BI_DICT_CLEAR, BI_DICT_SETDEFAULT, BI_DICT_POPITEM, BI_DICT_FROMKEYS,
  BI_SET_ADD, BI_SET_DISCARD, BI_SET_REMOVE, BI_SET_UNION, BI_SET_INTERSECTION, BI_SET_DIFFERENCE,
  BI_SET_POP, BI_SET_UPDATE, BI_SET_DIFFERENCE_UPDATE, BI_SET_INTERSECTION_UPDATE, BI_SET_SYMDIFF, BI_SET_SYMDIFF_UPDATE,
  BI_SET_ISSUBSET, BI_SET_ISSUPERSET, BI_SET_ISDISJOINT,
  BI_SUPER, BI_INIT,
  BI_EXC, BI_COUNT = BI_EXC + EXC_COUNT
};
typedef struct {
  const MpyType *type;
  int id;
} MpyBuiltin;
static const MpyBuiltin mpy_builtins[BI_COUNT] = {
  {&mpy_type_bfn, BI_LEN}, {&mpy_type_type, BI_STR}, {&mpy_type_type, BI_RANGE},
  {&mpy_type_bfn, BI_APPEND}, {&mpy_type_bfn, BI_POP}, {&mpy_type_bfn, BI_BUILD_CLASS},
  {&mpy_type_bfn, BI_DICT_GET}, {&mpy_type_bfn, BI_DICT_KEYS}, {&mpy_type_bfn, BI_DICT_VALUES},
  {&mpy_type_bfn, BI_DICT_ITEMS}, {&mpy_type_bfn, BI_DICT_POP}, {&mpy_type_bfn, BI_DICT_UPDATE},
  {&mpy_type_bfn, BI_DICT_COPY}, {&mpy_type_bfn, BI_DICT_CLEAR}, {&mpy_type_bfn, BI_DICT_SETDEFAULT},
  {&mpy_type_bfn, BI_DICT_POPITEM}, {&mpy_type_bfn, BI_DICT_FROMKEYS},
  {&mpy_type_bfn, BI_SET_ADD}, {&mpy_type_bfn, BI_SET_DISCARD}, {&mpy_type_bfn, BI_SET_REMOVE},
  {&mpy_type_bfn, BI_SET_UNION}, {&mpy_type_bfn, BI_SET_INTERSECTION}, {&mpy_type_bfn, BI_SET_DIFFERENCE},
  {&mpy_type_bfn, BI_SET_POP}, {&mpy_type_bfn, BI_SET_UPDATE}, {&mpy_type_bfn, BI_SET_DIFFERENCE_UPDATE},
  {&mpy_type_bfn, BI_SET_INTERSECTION_UPDATE}, {&mpy_type_bfn, BI_SET_SYMDIFF}, {&mpy_type_bfn, BI_SET_SYMDIFF_UPDATE},
  {&mpy_type_bfn, BI_SET_ISSUBSET}, {&mpy_type_bfn, BI_SET_ISSUPERSET}, {&mpy_type_bfn, BI_SET_ISDISJOINT},
  {&mpy_type_type, BI_SUPER}, {&mpy_type_bfn, BI_INIT},
  {&mpy_type_type, BI_EXC + 0}, {&mpy_type_type, BI_EXC + 1}, {&mpy_type_type, BI_EXC + 2},
  {&mpy_type_type, BI_EXC + 3}, {&mpy_type_type, BI_EXC + 4}, {&mpy_type_type, BI_EXC + 5},
  {&mpy_type_type, BI_EXC + 6}, {&mpy_type_type, BI_EXC + 7}, {&mpy_type_type, BI_EXC + 8},
  {&mpy_type_type, BI_EXC + 9}, {&mpy_type_type, BI_EXC + 10}, {&mpy_type_type, BI_EXC + 11},
  {&mpy_type_type, BI_EXC + 12},
};

/* An instance of a class, or of an exception class: its type is the class's info record. arg is the argument an exception
 * was given (0 for none); the dict holds the attributes. A class object is a MpyClass: its info is the type of its
 * instances, and dict its namespace. A bound method is a function with its self. */
typedef struct {
  const MpyType *type;
  mpv dict;
  mpv arg;
} MpyInst;

typedef struct MpyClass {
  const MpyType *type;   /* &mpy_type_metaclass */
  MpyType info;
  mpv dict;
} MpyClass;

typedef struct {
  const MpyType *type;
  mpv self;
  mpv fn;
} MpyBound;

/* super(cls, self): cls is the class's info record, whose base is searched; self is the instance (or class) it was given. */
typedef struct {
  const MpyType *type;
  const MpyType *cls;
  mpv self;
} MpySuper;

static int is_class(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_metaclass; }
static int is_inst(mpv v) { return is_heap(v) && type_of(v)->inst; }
static int is_exc(mpv v) { return is_heap(v) && type_of(v)->exc; }
static int is_function(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_function; }
static int is_bound(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_bound; }
static const MpyClass *class_of(mpv v) { return (const MpyClass *)(uintptr_t)v; }

static int is_list(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_list; }
static int is_tuple(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_tuple; }
static int is_iter(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_iter; }
static int is_range(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_range; }
static int is_dict(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_dict; }
static int is_set(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_set; }
static int is_view(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_view; }
static const MpyView *view_of(mpv v) { return (const MpyView *)(uintptr_t)v; }
static int is_slice(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_slice; }
static int is_builtin(mpv v) { return is_heap(v) && (type_of(v) == &mpy_type_bfn || type_of(v) == &mpy_type_type); }
static const MpyRange *range_of(mpv v) { return (const MpyRange *)(uintptr_t)v; }
static const MpyDict *dict_of(mpv v) { return (const MpyDict *)(uintptr_t)v; }
static const MpySlice *slice_of(mpv v) { return (const MpySlice *)(uintptr_t)v; }
static mpv builtin_obj(int id) { return (mpv)(uintptr_t)&mpy_builtins[id]; }

/* The builtin with this name, or -1. The module's globals are searched first, so a program can shadow these. */
static int builtin_index(const char *name, size_t len) {
  size_t k;
  if (len == 3 && memcmp(name, "len", 3) == 0) return BI_LEN;
  if (len == 3 && memcmp(name, "str", 3) == 0) return BI_STR;
  if (len == 5 && memcmp(name, "range", 5) == 0) return BI_RANGE;
  if (len == 5 && memcmp(name, "super", 5) == 0) return BI_SUPER;
  for (k = 0; k < EXC_COUNT; ++k) {
    size_t n = strlen(mpy_exc_info[k].name);
    if (n == len && memcmp(name, mpy_exc_info[k].name, len) == 0) return BI_EXC + (int)k;
  }
  return -1;
}

/* The builtin id of a dict method (get, keys, values, items, pop, update, copy, clear, setdefault, popitem, fromkeys), or -1. */
static int dict_method_index(const char *name, size_t len) {
  static const struct {
    const char *name;
    int id;
  } methods[] = {
    {"get", BI_DICT_GET}, {"keys", BI_DICT_KEYS}, {"values", BI_DICT_VALUES},
    {"items", BI_DICT_ITEMS}, {"pop", BI_DICT_POP}, {"update", BI_DICT_UPDATE},
    {"copy", BI_DICT_COPY}, {"clear", BI_DICT_CLEAR}, {"setdefault", BI_DICT_SETDEFAULT},
    {"popitem", BI_DICT_POPITEM}, {"fromkeys", BI_DICT_FROMKEYS},
  };
  size_t k;
  for (k = 0; k < sizeof methods / sizeof methods[0]; ++k) {
    if (strlen(methods[k].name) == len && memcmp(name, methods[k].name, len) == 0) return methods[k].id;
  }
  return -1;
}

/* The builtin id of a set method (add, discard, remove, pop, the union, intersection and difference methods and their in-place
 * forms, update, the symmetric difference methods, issubset, issuperset and isdisjoint), or -1. */
static int set_method_index(const char *name, size_t len) {
  static const struct {
    const char *name;
    int id;
  } methods[] = {
    {"add", BI_SET_ADD}, {"discard", BI_SET_DISCARD}, {"remove", BI_SET_REMOVE},
    {"union", BI_SET_UNION}, {"intersection", BI_SET_INTERSECTION}, {"difference", BI_SET_DIFFERENCE},
    {"pop", BI_SET_POP}, {"update", BI_SET_UPDATE}, {"difference_update", BI_SET_DIFFERENCE_UPDATE},
    {"intersection_update", BI_SET_INTERSECTION_UPDATE}, {"symmetric_difference", BI_SET_SYMDIFF},
    {"symmetric_difference_update", BI_SET_SYMDIFF_UPDATE}, {"issubset", BI_SET_ISSUBSET},
    {"issuperset", BI_SET_ISSUPERSET}, {"isdisjoint", BI_SET_ISDISJOINT},
  };
  size_t k;
  for (k = 0; k < sizeof methods / sizeof methods[0]; ++k) {
    if (strlen(methods[k].name) == len && memcmp(name, methods[k].name, len) == 0) return methods[k].id;
  }
  return -1;
}

/* The method names that a dict or a set has and the runtime does not have for the other types: a method call of one of these on
 * a value that is not a dict or a set fails as not lowered (the lowering does not know the receiver's type, so it cannot refuse
 * them). */
static int refused_method_name(const char *name, size_t len) {
  static const char *const names[] = {"copy", "clear", "setdefault", "popitem", "fromkeys", "add", "discard", "remove",
                                      "union", "intersection", "difference"};
  size_t k;
  for (k = 0; k < sizeof names / sizeof names[0]; ++k) {
    if (strlen(names[k]) == len && memcmp(name, names[k], len) == 0) return 1;
  }
  return 0;
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

/* A growing text buffer, for the reprs and the messages that carry a value. */
typedef struct {
  char *p;
  size_t n, cap;
} Buf;

static void buf_put(Buf *b, const char *s, size_t n) {
  if (b->n + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap : 64;
    char *p;
    while (cap < b->n + n + 1) cap *= 2;
    p = (char *)realloc(b->p, cap);
    if (p == NULL) fail("out of memory");
    b->p = p;
    b->cap = cap;
  }
  memcpy(b->p + b->n, s, n);
  b->n += n;
  b->p[b->n] = '\0';
}

static void buf_str(Buf *b, const char *s) { buf_put(b, s, strlen(s)); }

static void buf_int(Buf *b, long long v) {
  char t[32];
  int k = snprintf(t, sizeof t, "%lld", v);
  buf_put(b, t, (size_t)k);
}

static void repr_into(Buf *b, mpv v);

/* Truth, as mp_obj_is_true: None and False are false; zero is false; an empty str is false; anything else is true. */
int mpy_truth(mpv v) {
  if (v == MPY_NONE || v == MPY_FALSE) return 0;
  if (v == MPY_TRUE) return 1;
  if (is_small(v)) return small_value(v) != 0;
  if (is_str(v)) return str_of(v)->len != 0;
  if (is_iter(v)) return 1;
  if (is_range(v)) return range_of(v)->len != 0;
  if (is_dict(v) || is_set(v)) return dict_of(v)->used != 0;
  if (is_view(v)) return dict_of(view_of(v)->dict)->used != 0;
  if (is_inst(v) || is_class(v) || is_bound(v)) return 1;   /* no __bool__ or __len__ yet: an object is true */
  {
    size_t n;
    const mpv *items;
    if (seq_items(v, &n, &items)) return n != 0;
  }
  fail("truth of a value that is not a small int, bool, None, str, list, tuple or dict is not implemented");
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
  s->interned = 0;
  s->data[n] = '\0';
  return s;
}

static mpv new_str(const char *bytes, size_t n) {
  MpyStr *s = alloc_str(n);
  memcpy(s->data, bytes, n);
  return (mpv)(uintptr_t)s;
}

/* The characters of a str: its bytes that do not continue a UTF-8 sequence (the same count for valid UTF-8). */
static size_t str_chars(const MpyStr *s) {
  size_t i, n = 0;
  for (i = 0; i < s->len; ++i) {
    if ((s->data[i] & 0xc0) != 0x80) ++n;
  }
  return n;
}

/* The byte offset of character k of s (k may be the character count, which gives s->len). */
static size_t byte_offset(const MpyStr *s, size_t k) {
  size_t i = 0, c = 0;
  while (i < s->len) {
    if (c == k) return i;
    ++c;
    ++i;
    while (i < s->len && (((unsigned char)s->data[i]) & 0xc0) == 0x80) ++i;
  }
  return s->len;
}

/* A list's item array, grown as needed. A new list has room for at least one item (see list_new). */
static MpyList *list_new(size_t cap) {
  MpyList *l = (MpyList *)malloc(sizeof *l);
  if (l == NULL) fail("out of memory");
  l->type = &mpy_type_list;
  l->len = 0;
  l->cap = cap ? cap : 1;
  l->items = (mpv *)malloc(l->cap * sizeof(mpv));
  if (l->items == NULL) fail("out of memory");
  return l;
}

static void list_append(MpyList *l, mpv v) {
  if (l->len == l->cap) {   /* cap is at least 1 */
    size_t cap = l->cap * 2;
    mpv *items = (mpv *)realloc(l->items, cap * sizeof(mpv));
    if (items == NULL) fail("out of memory");
    l->items = items;
    l->cap = cap;
  }
  l->items[l->len++] = v;
}

static int str_equal(mpv a, mpv b) {
  const MpyStr *x = str_of(a), *y = str_of(b);
  return x->len == y->len && memcmp(x->data, y->data, x->len) == 0;
}

static int set_equal_contents(mpv a, mpv b);

/* Equality, as mp_obj_equal gives it (used by `in`, by dict and set keys, and inside lists and tuples): the same word, two strs
 * with the same bytes, two numbers (bools as 0 and 1) with the same value, two lists or two tuples with equal items, and two
 * sets with the same items. Two dicts or two ranges that are different objects are not compared yet, so that fails rather
 * than answers. */
static int obj_equal(mpv a, mpv b) {
  if (a == b) return 1;
  if (is_str(a) || is_str(b)) return is_str(a) && is_str(b) && str_equal(a, b);
  if ((is_small(a) || is_bool(a)) && (is_small(b) || is_bool(b))) return need_int(a) == need_int(b);
  if ((is_list(a) && is_list(b)) || (is_tuple(a) && is_tuple(b))) {
    size_t na, nb, i;
    const mpv *ia, *ib;
    seq_items(a, &na, &ia);
    seq_items(b, &nb, &ib);
    if (na != nb) return 0;
    for (i = 0; i < na; ++i) {
      if (!obj_equal(ia[i], ib[i])) return 0;
    }
    return 1;
  }
  if (is_set(a) && is_set(b)) return set_equal_contents(a, b);
  if ((is_dict(a) && is_dict(b)) || (is_range(a) && is_range(b))) {
    fail("TypeError: equality of dicts and ranges that are different objects is not lowered yet");
  }
  return 0;
}

/* The hash of a key, as MicroPython's mp_map_lookup computes it: a small int or a bool is its value (a negative value
 * wraps, as mp_uint_t does), None is its word (6), and a str is qstr_compute_hash with the hash masked to 16 bits
 * (MICROPY_QSTR_BYTES_IN_HASH is 1 at the unix port's default ROM level). A list, dict or slice is unhashable. Any other
 * kind of key is not lowered yet. */
/* The hash of a tuple starts from the address of MicroPython's mp_const_empty_tuple_obj (mp_obj_tuple_unary_op). In the
 * reference build that address is 16-aligned (hash(()) is a multiple of 16), so tables of up to 16 slots take the same order
 * here, whatever the address is. Larger tables depend on that address in the reference, so their order is not fixed there. */
static const unsigned char mpy_hash_anchor[32];
static uint64_t tuple_hash_base(void) { return ((uint64_t)(uintptr_t)mpy_hash_anchor + 15) & ~(uint64_t)15; }

static size_t key_hash(mpv k) {
  char msg[120];
  if (is_small(k)) return (size_t)small_value(k);
  if (is_bool(k)) return k == MPY_TRUE ? 1 : 0;
  if (k == MPY_NONE) return 6;
  if (is_str(k)) {
    const MpyStr *s = str_of(k);
    size_t h = 5381, i;   /* djb2, as qstr_compute_hash */
    for (i = 0; i < s->len; ++i) h = ((h << 5) + h) ^ (unsigned char)s->data[i];
    h &= 0xffff;   /* MICROPY_QSTR_BYTES_IN_HASH is 2 in the reference build */
    return h == 0 ? 1 : h;
  }
  if (is_tuple(k)) {
    /* The sum of the items' hashes (the same for an int item, whose hash is its value, as mp_int_t adds it). The result is a
     * small int, so it keeps 63 bits and reads back sign-extended, as MP_OBJ_NEW_SMALL_INT and its value do. */
    const MpyTuple *t = (const MpyTuple *)(uintptr_t)k;
    uint64_t h = tuple_hash_base();
    size_t i;
    for (i = 0; i < t->len; ++i) h += (uint64_t)key_hash(t->items[i]);
    return (size_t)((int64_t)((h << 1) | 1) >> 1);
  }
  if (is_list(k) || is_dict(k) || is_set(k) || is_view(k) || is_range(k) || is_slice(k)) {
    snprintf(msg, sizeof msg, "TypeError: unsupported type for __hash__: '%s'", type_of(k)->name);
    fail(msg);
  }
  /* A function, a class or an instance hashes by its address, as MicroPython does for an object without a hash. */
  if (is_heap(k)) return (size_t)k;
  fail("TypeError: a key of this type is not lowered yet");
  return 0;
}

/* py/map.c's hash_allocation_sizes: the table sizes a growing map takes. */
static const size_t hash_allocation_sizes[] = {
  0, 2, 4, 6, 8, 10, 12,
  17, 23, 29, 37, 47, 59, 73,
  97, 127, 167, 223, 293, 389, 521, 691, 919, 1223, 1627, 2161,
  3229, 4831, 7243, 10861, 16273, 24407, 36607, 54907,
};

static size_t hash_alloc_greater_or_equal_to(size_t x) {
  size_t i;
  for (i = 0; i < sizeof hash_allocation_sizes / sizeof hash_allocation_sizes[0]; ++i) {
    if (hash_allocation_sizes[i] >= x) return hash_allocation_sizes[i];
  }
  return (x + x / 2) | 1;
}

/* A map lookup kind (map.c's mp_map_lookup_kind_t). MAP_TOGGLE is a set's ADD_IF_NOT_FOUND_OR_REMOVE_IF_FOUND: it adds the key
 * when it is not there and removes it when it is (symmetric difference). */
enum { MAP_LOOKUP, MAP_ADD, MAP_REMOVE, MAP_TOGGLE };

static void map_rehash_table(MpyDict *d);

/* map.c's mp_map_lookup for a hash table: the slot index of key, or -1 when it is not there (MAP_LOOKUP and MAP_REMOVE), or
 * the slot it was added to (MAP_ADD, with the value 0). A MAP_REMOVE leaves the slot's key as the sentinel (or empty when
 * the next slot is empty). An empty table, and a key that cannot be in a table of interned strs, are answered without a
 * hash, so a load of an unhashable key from such a table is a KeyError, as in MicroPython. */
static long map_lookup(MpyDict *d, mpv key, int kind) {
  /* A set has no such shortcut (mp_set_lookup compares with mp_obj_equal), so only a dict uses it. */
  int compare_only_ptrs = d->all_keys_are_qstrs && d->type == &mpy_type_dict;
  int adds = kind == MAP_ADD || kind == MAP_TOGGLE;
  int removes = kind == MAP_REMOVE || kind == MAP_TOGGLE;
  size_t hash, pos, start;
  long avail = -1;
  if (compare_only_ptrs) {
    if (is_qstr(key)) {
      /* a pointer compare is enough */
    } else if (is_str(key)) {
      compare_only_ptrs = 0;
    } else if (!adds) {
      return -1;
    }
  }
  if (d->alloc == 0) {
    if (!adds) return -1;
    map_rehash_table(d);
  }
  hash = key_hash(key);
  pos = hash % d->alloc;
  start = pos;
  for (;;) {
    MpyEntry *slot = &d->table[pos];
    if (slot->key == 0) {
      long at = avail >= 0 ? avail : (long)pos;
      if (!adds) return -1;
      d->used += 1;
      d->table[at].key = key;
      d->table[at].value = 0;
      if (!is_qstr(key)) d->all_keys_are_qstrs = 0;
      return at;
    } else if (slot->key == MPY_SENTINEL) {
      if (avail < 0) avail = (long)pos;
    } else if (slot->key == key || (!compare_only_ptrs && obj_equal(slot->key, key))) {
      if (removes) {
        d->used--;
        if (d->table[(pos + 1) % d->alloc].key == 0) slot->key = 0;
        else slot->key = MPY_SENTINEL;
      }
      return (long)pos;
    }
    pos = (pos + 1) % d->alloc;
    if (pos == start) {
      if (!adds) return -1;
      if (avail >= 0) {
        d->used += 1;
        d->table[avail].key = key;
        d->table[avail].value = 0;
        if (!is_qstr(key)) d->all_keys_are_qstrs = 0;
        return avail;
      }
      map_rehash_table(d);
      start = pos = hash % d->alloc;
    }
  }
}

/* map.c's mp_map_rehash: the table grows to the next size, and the live items are added to it in the old table's order. */
static void map_rehash_table(MpyDict *d) {
  size_t old_alloc = d->alloc, new_alloc = hash_alloc_greater_or_equal_to(d->alloc + 1), i;
  MpyEntry *old = d->table;
  d->table = (MpyEntry *)calloc(new_alloc, sizeof(MpyEntry));
  if (d->table == NULL) fail("out of memory");
  d->alloc = new_alloc;
  d->used = 0;
  d->all_keys_are_qstrs = 1;
  for (i = 0; i < old_alloc; ++i) {
    if (old[i].key != 0 && old[i].key != MPY_SENTINEL) {
      long at = map_lookup(d, old[i].key, MAP_ADD);
      d->table[at].value = old[i].value;
    }
  }
  free(old);
}

/* d[key] = value. An existing key keeps its place and its key object. */
static void dict_store(mpv dv, mpv key, mpv value) {
  MpyDict *d = (MpyDict *)(uintptr_t)dv;
  long at = map_lookup(d, key, MAP_ADD);
  d->table[at].value = value;
}

/* The text of a key in a KeyError: a str as its text, anything else as its repr (MicroPython prints the exception's argument
 * with str). */
static void key_text(Buf *b, mpv v) {
  if (is_str(v)) buf_put(b, str_of(v)->data, str_of(v)->len);
  else repr_into(b, v);
}

static void key_error(mpv key) {
  Buf b = {NULL, 0, 0};
  buf_str(&b, "KeyError: ");
  key_text(&b, key);
  fail(b.p);
}

static mpv dict_get(mpv dv, mpv key) {
  MpyDict *d = (MpyDict *)(uintptr_t)dv;
  long at = map_lookup(d, key, MAP_LOOKUP);
  if (at < 0) key_error(key);
  return d->table[at].value;
}

static void dict_delete(mpv dv, mpv key) {
  MpyDict *d = (MpyDict *)(uintptr_t)dv;
  long at = map_lookup(d, key, MAP_REMOVE);
  if (at < 0) key_error(key);
}

/* A new dict with a table of n slots (MicroPython's mp_obj_new_dict(n) sizes it by the number of items the literal has). */
mpv mpy_build_map(uint64_t n) {
  MpyDict *d = (MpyDict *)malloc(sizeof *d);
  if (d == NULL) fail("out of memory");
  d->type = &mpy_type_dict;
  d->alloc = (size_t)n;
  d->used = 0;
  d->all_keys_are_qstrs = 1;
  d->table = n ? (MpyEntry *)calloc((size_t)n, sizeof(MpyEntry)) : NULL;
  if (n && d->table == NULL) fail("out of memory");
  return (mpv)(uintptr_t)d;
}

/* STORE_MAP: dict[key] = value. */
void mpy_dict_store(mpv dv, mpv key, mpv value) { dict_store(dv, key, value); }

/* A set comprehension's store (STORE_COMP with kind 2): adds the item to the set (mp_obj_set_store). */
void mpy_set_store(mpv sv, mpv item) { map_lookup((MpyDict *)(uintptr_t)sv, item, MAP_ADD); }

/* The value of a dict view's item: keys, values, or (key, value) pairs. */
static mpv view_item_tuple(mpv key, mpv value) {
  MpyTuple *t = (MpyTuple *)malloc(sizeof *t + 2 * sizeof(mpv));
  if (t == NULL) fail("out of memory");
  t->type = &mpy_type_tuple;
  t->len = 2;
  t->items[0] = key;
  t->items[1] = value;
  return (mpv)(uintptr_t)t;
}

/* `x in v` for a dict view: a key of keys(), a value of values(), and a (key, value) pair of items(). */
static int view_contains(const MpyView *v, mpv x) {
  MpyDict *d = (MpyDict *)(uintptr_t)v->dict;
  size_t i;
  if (v->kind == VIEW_KEYS) return map_lookup(d, x, MAP_LOOKUP) >= 0;
  if (v->kind == VIEW_VALUES) {
    for (i = 0; i < d->alloc; ++i) {
      if (d->table[i].key != 0 && d->table[i].key != MPY_SENTINEL && obj_equal(d->table[i].value, x)) return 1;
    }
    return 0;
  }
  {
    size_t n;
    const mpv *items;
    long at;
    if (!is_tuple(x)) return 0;
    seq_items(x, &n, &items);
    if (n != 2) return 0;
    at = map_lookup(d, items[0], MAP_LOOKUP);
    return at >= 0 && obj_equal(d->table[at].value, items[1]);
  }
}

/* `x in c` is contains(c, x): a str holds a substring, a list or tuple an equal item, a dict or a set a key, and a view its
 * keys, values or items. */
static int contains(mpv c, mpv x) {
  char msg[160];
  size_t n, i;
  const mpv *items;
  if (is_set(c)) return map_lookup((MpyDict *)(uintptr_t)c, x, MAP_LOOKUP) >= 0;
  if (is_view(c)) return view_contains(view_of(c), x);
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
  if (is_dict(c)) return map_lookup((MpyDict *)(uintptr_t)c, x, MAP_LOOKUP) >= 0;
  if (seq_items(c, &n, &items)) {
    for (i = 0; i < n; ++i) {
      if (obj_equal(items[i], x)) return 1;
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
/* The class an except clause names: a builtin exception class, a user class that derives from one, or a tuple of those. */
static const MpyType *exc_class_info(mpv cls) {
  if (is_builtin(cls) && ((const MpyBuiltin *)(uintptr_t)cls)->id >= BI_EXC) {
    return &mpy_exc_info[((const MpyBuiltin *)(uintptr_t)cls)->id - BI_EXC];
  }
  if (is_class(cls) && class_of(cls)->info.exc) return &class_of(cls)->info;
  fail("TypeError: catching classes that do not inherit from BaseException is not allowed");
  return NULL;
}

/* exc is an except clause's class (or tuple of classes) matched against the raised exception (MP_BINARY_OP_EXCEPTION_MATCH). */
static mpv exc_match(mpv exc, mpv cls) {
  size_t n, i;
  const mpv *items;
  const MpyType *want, *t;
  if (is_tuple(cls)) {
    seq_items(cls, &n, &items);
    for (i = 0; i < n; ++i) {
      if (exc_match(exc, items[i]) == MPY_TRUE) return MPY_TRUE;
    }
    return MPY_FALSE;
  }
  want = exc_class_info(cls);
  if (!is_exc(exc)) return MPY_FALSE;
  for (t = type_of(exc); t != NULL; t = t->base) {
    if (t == want) return MPY_TRUE;
  }
  return MPY_FALSE;
}

mpv mpy_get_iter(mpv obj);
mpv mpy_iter_next(mpv iter);

/* Sets (docs/notes/mpy-pathb.md, "Sets"): the table of a new set, and the copies and updates of objset.c. A new set has alloc slots
 * (mp_obj_new_set(n, NULL) for 0). */
static mpv set_new(size_t alloc) {
  mpv r = mpy_build_map((uint64_t)alloc);
  ((MpyDict *)(uintptr_t)r)->type = &mpy_type_set;
  return r;
}

/* set_copy: the same table, slot for slot. */
static mpv set_copy_of(mpv sv) {
  const MpyDict *s = dict_of(sv);
  mpv r = set_new(s->alloc);
  MpyDict *c = (MpyDict *)(uintptr_t)r;
  if (s->alloc) memcpy(c->table, s->table, s->alloc * sizeof(MpyEntry));
  c->used = s->used;
  c->all_keys_are_qstrs = s->all_keys_are_qstrs;
  return r;
}

/* set_update_int: the items of other (any iterable) are added to s. */
static void set_add_items(mpv sv, mpv other) {
  mpv it = mpy_get_iter(other), item;
  while ((item = mpy_iter_next(it)) != 0) map_lookup((MpyDict *)(uintptr_t)sv, item, MAP_ADD);
}

/* The items of other are removed from s (set_diff_int). When other is s itself, s is cleared. */
static void set_remove_items(mpv sv, mpv other) {
  MpyDict *s = (MpyDict *)(uintptr_t)sv;
  mpv it, item;
  if (sv == other) {
    free(s->table);
    s->table = NULL;
    s->alloc = 0;
    s->used = 0;
    return;
  }
  it = mpy_get_iter(other);
  while ((item = mpy_iter_next(it)) != 0) map_lookup(s, item, MAP_REMOVE);
}

/* set_intersect_int, not in place: a new set of the items of other that are in s, added in other's order. */
static mpv set_intersect_of(mpv sv, mpv other) {
  mpv out, it, item;
  if (sv == other) return set_copy_of(sv);
  out = set_new(0);
  it = mpy_get_iter(other);
  while ((item = mpy_iter_next(it)) != 0) {
    if (map_lookup((MpyDict *)(uintptr_t)sv, item, MAP_LOOKUP) >= 0) map_lookup((MpyDict *)(uintptr_t)out, item, MAP_ADD);
  }
  return out;
}

/* set_intersect_int, in place: s takes the table of the intersection (none when other is s itself). */
static void set_intersect_inplace(mpv sv, mpv other) {
  MpyDict *s, *o;
  mpv out;
  if (sv == other) return;
  out = set_intersect_of(sv, other);
  s = (MpyDict *)(uintptr_t)sv;
  o = (MpyDict *)(uintptr_t)out;
  free(s->table);
  s->table = o->table;
  s->alloc = o->alloc;
  s->used = o->used;
}

/* objset.c's set_issubset_internal for two sets: every item of a is in b. With proper, a must also be smaller than b (the used
 * counts differ). The items are visited in a's table order, and only an item of a is hashed (none when a is empty). */
static int set_is_subset(mpv a, mpv b, int proper) {
  const MpyDict *s = dict_of(a);
  size_t i;
  if (proper && s->used == dict_of(b)->used) return 0;
  for (i = 0; i < s->alloc; ++i) {
    mpv k = s->table[i].key;
    if (k == 0 || k == MPY_SENTINEL) continue;
    if (map_lookup((MpyDict *)(uintptr_t)b, k, MAP_LOOKUP) < 0) return 0;
  }
  return 1;
}

/* set_equal: the same number of items, and a's items all in b. */
static int set_equal_contents(mpv a, mpv b) {
  if (dict_of(a)->used != dict_of(b)->used) return 0;
  return set_is_subset(a, b, 0);
}

/* The argument of issubset and issuperset as a set: a set as it is, any other iterable as a new set of its items (set_make_new). */
static mpv as_set(mpv v) {
  mpv r;
  if (is_set(v)) return v;
  r = set_new(0);
  set_add_items(r, v);
  return r;
}

/* mp_set_remove_first: the first item in table order is removed and returned (0 when the set is empty). The slot is left empty
 * when the next slot is empty, and as the sentinel otherwise. */
static mpv set_pop_first(mpv sv) {
  MpyDict *s = (MpyDict *)(uintptr_t)sv;
  size_t pos;
  for (pos = 0; pos < s->alloc; ++pos) {
    mpv k = s->table[pos].key;
    if (k == 0 || k == MPY_SENTINEL) continue;
    s->used--;
    s->table[pos].key = s->table[(pos + 1) % s->alloc].key == 0 ? 0 : MPY_SENTINEL;
    return k;
  }
  return 0;
}

/* set_symmetric_difference_update: each item of other is added to sv when it is not there, and removed when it is. */
static void set_symdiff_update_items(mpv sv, mpv other) {
  mpv it = mpy_get_iter(other), item;
  while ((item = mpy_iter_next(it)) != 0) map_lookup((MpyDict *)(uintptr_t)sv, item, MAP_TOGGLE);
}

/* set_symmetric_difference: a copy of sv (slot for slot), then the symmetric difference update with other. */
static mpv set_symdiff_of(mpv sv, mpv other) {
  mpv r = set_copy_of(sv);
  set_symdiff_update_items(r, other);
  return r;
}

/* The method a binary operator on a set falls back to, which the reference names in its TypeError for an operand that is not a
 * set (mp_binary_op_method_name). NULL for an operator that is not named here. */
static const char *set_op_name(int op) {
  switch (op) {
    case MPY_OP_LESS: return "__lt__";
    case MPY_OP_MORE: return "__gt__";
    case MPY_OP_LESS_EQUAL: return "__le__";
    case MPY_OP_MORE_EQUAL: return "__ge__";
    case MPY_OP_OR: return "__or__";
    case MPY_OP_XOR: return "__xor__";
    case MPY_OP_AND: return "__and__";
    case MPY_OP_LSHIFT: return "__lshift__";
    case MPY_OP_RSHIFT: return "__rshift__";
    case MPY_OP_ADD: return "__add__";
    case MPY_OP_SUBTRACT: return "__sub__";
    case MPY_OP_MULTIPLY: return "__mul__";
    case MPY_OP_FLOOR_DIVIDE: return "__floordiv__";
    case MPY_OP_MODULO: return "__mod__";
    default: return NULL;
  }
}

/* The set operators (set_binary_op): | ^ & - and the comparisons, with their in-place forms, on two sets. An operator on a set that
 * a set does not have, or an operand that is not a set, is a TypeError that names the operator without the in-place prefix. A
 * == or != of a set and another value is identity, as the reference falls back to it (mp_obj_equal). */
static mpv set_binop(int op, int inplace, mpv a, mpv b) {
  const char *name = set_op_name(op);
  int both = is_set(a) && is_set(b);
  char msg[200];
  if (op == MPY_OP_EQUAL || op == MPY_OP_NOT_EQUAL) {
    int eq = a == b || (both && set_equal_contents(a, b));
    return (op == MPY_OP_EQUAL ? eq : !eq) ? MPY_TRUE : MPY_FALSE;
  }
  if (name == NULL) fail("an operator on a set is not lowered yet");
  if (!both || (op != MPY_OP_OR && op != MPY_OP_XOR && op != MPY_OP_AND && op != MPY_OP_SUBTRACT && op != MPY_OP_LESS &&
                op != MPY_OP_MORE && op != MPY_OP_LESS_EQUAL && op != MPY_OP_MORE_EQUAL)) {
    snprintf(msg, sizeof msg, "TypeError: unsupported types for %s: '%s', '%s'", name, real_type_name(a), real_type_name(b));
    fail(msg);
  }
  if (op == MPY_OP_LESS) return set_is_subset(a, b, 1) ? MPY_TRUE : MPY_FALSE;
  if (op == MPY_OP_MORE) return set_is_subset(b, a, 1) ? MPY_TRUE : MPY_FALSE;
  if (op == MPY_OP_LESS_EQUAL) return set_is_subset(a, b, 0) ? MPY_TRUE : MPY_FALSE;
  if (op == MPY_OP_MORE_EQUAL) return set_is_subset(b, a, 0) ? MPY_TRUE : MPY_FALSE;
  if (op == MPY_OP_XOR) {
    if (!inplace) return set_symdiff_of(a, b);
    set_symdiff_update_items(a, b);
    return a;
  }
  if (op == MPY_OP_OR) {
    if (!inplace) {
      mpv r = set_copy_of(a);
      set_add_items(r, b);
      return r;
    }
    set_add_items(a, b);
    return a;
  }
  if (op == MPY_OP_AND) {
    if (!inplace) return set_intersect_of(a, b);
    set_intersect_inplace(a, b);
    return a;
  }
  if (!inplace) {
    mpv r = set_copy_of(a);
    set_remove_items(r, b);
    return r;
  }
  set_remove_items(a, b);
  return a;
}

mpv mpy_binop(int op, mpv a, mpv b) {
  int64_t x, y, r = 0;
  /* The in-place forms (MP_BINARY_OP_INPLACE_OR = 9 .. INPLACE_POWER = 21) are the same operators on immutable ints:
   * INPLACE_X is X + 13 (runtime0.h). The in-place matrix multiply, true divide and power stay unsupported. */
  int inplace = op >= 9 && op <= 21;
  if (op == MPY_OP_EXCEPTION_MATCH) return exc_match(a, b);   /* the except clause: a is the exception, b the class */
  if (inplace) op += 13;
  if (op == MPY_OP_IN) return contains(b, a) ? MPY_TRUE : MPY_FALSE;   /* a in b: the right operand is the container */
  if (op == MPY_OP_IS) return a == b ? MPY_TRUE : MPY_FALSE;           /* the same word: one immediate or one object */
  if (is_str(a) || is_str(b)) return str_binop(op, a, b);
  if (is_set(a) || is_set(b)) return set_binop(op, inplace, a, b);
  if (is_view(a) || is_view(b)) {
    fail("an operator on a dict view (other than in and is) is not lowered yet");
  }
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

/* The class body being run: its namespace is a dict on this stack (a class body's names go there, and the stack is empty
 * at module level). A block saves the depth, so an exception leaves the namespaces of the frames it skips. */
static mpv *ns_stack = NULL;
static size_t ns_n = 0, ns_cap = 0;

static void ns_push(mpv dict) {
  if (ns_n == ns_cap) {
    ns_cap = ns_cap ? ns_cap * 2 : 8;
    ns_stack = (mpv *)realloc(ns_stack, ns_cap * sizeof(mpv));
    if (ns_stack == NULL) fail("out of memory");
  }
  ns_stack[ns_n++] = dict;
}

/* The one str object of each attribute or class-namespace name, so that a dict keyed by names finds them by pointer. */
static mpv intern_name(const char *s, size_t len) {
  static mpv *names = NULL;
  static size_t n = 0, cap = 0;
  size_t i;
  for (i = 0; i < n; ++i) {
    const MpyStr *t = str_of(names[i]);
    if (t->len == len && memcmp(t->data, s, len) == 0) return names[i];
  }
  if (n == cap) {
    cap = cap ? cap * 2 : 16;
    names = (mpv *)realloc(names, cap * sizeof(mpv));
    if (names == NULL) fail("out of memory");
  }
  {
    MpyStr *t = alloc_str(len);
    memcpy(t->data, s, len);
    t->interned = 1;
    names[n++] = (mpv)(uintptr_t)t;
  }
  return names[n - 1];
}

/* The value of key in dict dv, when it has one. */
static int dict_find(mpv dv, mpv key, mpv *out) {
  MpyDict *d = (MpyDict *)(uintptr_t)dv;
  long at = map_lookup(d, key, MAP_LOOKUP);
  if (at < 0) return 0;
  *out = d->table[at].value;
  return 1;
}

void mpy_store_global(const char *name, size_t len, mpv value) {
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

/* STORE_NAME: into the class body's namespace when one is running, else into the module's globals. */
void mpy_store_name(const char *name, size_t len, mpv value) {
  if (ns_n) dict_store(ns_stack[ns_n - 1], intern_name(name, len), value);
  else mpy_store_global(name, len, value);
}

/* LOAD_GLOBAL: the module's globals, then the builtins. */
mpv mpy_load_global(const char *name, size_t len) {
  Global *g = find_global(name, len);
  int b;
  if (g != NULL && g->value != 0) return g->value;   /* 0 is a deleted global */
  b = builtin_index(name, len);
  /* A class statement reads the module's __name__ for its __module__ (the module itself runs as __main__ here). */
  if (b < 0 && len == 8 && memcmp(name, "__name__", 8) == 0) return new_str("__main__", 8);
  if (b < 0) fail("NameError: name is not defined");
  return builtin_obj(b);
}

/* LOAD_NAME: a class body's namespace first (when one is running), then the globals and the builtins. */
mpv mpy_load_name(const char *name, size_t len) {
  mpv v;
  if (ns_n && dict_find(ns_stack[ns_n - 1], intern_name(name, len), &v)) return v;
  return mpy_load_global(name, len);
}

/* DELETE_NAME: removes the name from the class body's namespace, or from the globals (where a deleted name is 0). */
void mpy_delete_name(const char *name, size_t len) {
  Global *g;
  if (ns_n && map_lookup((MpyDict *)(uintptr_t)ns_stack[ns_n - 1], intern_name(name, len), MAP_REMOVE) >= 0) return;
  g = find_global(name, len);
  if (g == NULL || g->value == 0) fail("NameError: name is not defined");
  g->value = 0;
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
    s->interned = 1;
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
mpv mpy_call(mpv fn, uint64_t nargs);

/* str(v) for one argument: a str is itself, None and the bools and small ints as their text, and an exception its argument's
 * text (as str() gives it). */
static mpv str_of_value(mpv v) {
  char buf[32];
  int k;
  if (is_str(v)) return v;
  if (v == MPY_NONE) return new_str("None", 4);
  if (v == MPY_TRUE) return new_str("True", 4);
  if (v == MPY_FALSE) return new_str("False", 5);
  if (is_small(v)) {
    k = snprintf(buf, sizeof buf, "%lld", (long long)small_value(v));
    return new_str(buf, (size_t)k);
  }
  if (is_exc(v)) return ((const MpyInst *)(uintptr_t)v)->arg ? str_of_value(((const MpyInst *)(uintptr_t)v)->arg) : new_str("", 0);
  fail("str() of this value is not lowered yet");
  return MPY_NONE;
}

/* Exceptions and the try blocks (docs/notes/mpy-pathb.md, "Exceptions"). A try block is a record that holds a jmp_buf. The
 * lowered code calls _setjmp on it in the frame that owns the try; a raise longjmps to the innermost block that is not
 * already running its handler. The block records the value stack's height and the namespace depth, which the landing
 * restores. A landed block stays on the stack until its handler ends (POP_EXCEPT_JUMP, END_FINALLY), as MicroPython keeps its
 * exception block; an exception raised by the handler skips it. */
typedef struct MpyBlock {
  jmp_buf jb;   /* first, so the block is the jmp_buf the lowered code passes to _setjmp */
  struct MpyBlock *prev;
  size_t vtop, ns_n;
  int landed;   /* the handler is running (or is about to) */
  mpv exc;
} MpyBlock;

static MpyBlock *blocks = NULL;
static mpv pending_exc = 0;   /* the exception a landing hands to its handler */
static mpv method_self = 0;   /* the self LOAD_METHOD found for the method it returned (0 for none) */

static mpv new_inst_of(const MpyType *t) {
  MpyInst *o = (MpyInst *)malloc(sizeof *o);
  if (o == NULL) fail("out of memory");
  o->type = t;
  o->dict = mpy_build_map(0);
  o->arg = 0;
  return (mpv)(uintptr_t)o;
}

static mpv new_exc(int k, mpv arg) {
  mpv e = new_inst_of(&mpy_exc_info[k]);
  ((MpyInst *)(uintptr_t)e)->arg = arg;
  return e;
}

/* An uncaught exception: the reference's last line, "Name: text". */
static void uncaught(mpv exc) {
  const MpyInst *e = (const MpyInst *)(uintptr_t)exc;
  if (e->arg) {
    const MpyStr *s = str_of(str_of_value(e->arg));
    fprintf(stderr, "mpy: %s: ", type_of(exc)->name);
    fwrite(s->data, 1, s->len, stderr);
    fputc('\n', stderr);
  } else {
    fprintf(stderr, "mpy: %s: \n", type_of(exc)->name);
  }
  exit(1);
}

/* Raises exc (an exception instance): the innermost block that is not running its handler takes it. */
static void raise_value(mpv exc) {
  MpyBlock *b;
  while (blocks != NULL && blocks->landed) {   /* a handler's own exception goes past its block */
    b = blocks;
    blocks = b->prev;
    free(b);
  }
  if (blocks == NULL) uncaught(exc);
  b = blocks;
  vtop = b->vtop;
  ns_n = b->ns_n;
  b->landed = 1;
  b->exc = exc;
  pending_exc = exc;
  longjmp(b->jb, 1);   /* to the _setjmp that the lowered code called in the frame that owns b */
}

/* A message that starts with an exception class's name raises that class (see fail). Otherwise it is fatal. */
static void raise_text(const char *what) {
  size_t k;
  for (k = 0; k < EXC_COUNT; ++k) {
    size_t n = strlen(mpy_exc_info[k].name);
    if (strncmp(what, mpy_exc_info[k].name, n) == 0 && what[n] == ':') {
      const char *msg = what + n + 1;
      if (*msg == ' ') msg++;
      raise_value(new_exc((int)k, new_str(msg, strlen(msg))));
    }
  }
  fprintf(stderr, "mpy: %s\n", what);
  exit(1);
}

/* SETUP_EXCEPT and SETUP_FINALLY: a new block; the lowered code then calls _setjmp on it. */
mpv mpy_try_enter(void) {
  MpyBlock *b = (MpyBlock *)malloc(sizeof *b);
  if (b == NULL) fail("out of memory");
  b->prev = blocks;
  b->vtop = vtop;
  b->ns_n = ns_n;
  b->landed = 0;
  b->exc = 0;
  blocks = b;
  return (mpv)(uintptr_t)b;
}

/* The exception a landing gives to its handler. */
mpv mpy_take_exc(void) { return pending_exc; }

/* POP_EXCEPT_JUMP: the block of the try (or of its handler) ends. */
void mpy_block_pop(void) {
  MpyBlock *b = blocks;
  if (b == NULL) fail("internal: no try block to end");
  blocks = b->prev;
  free(b);
}

/* END_FINALLY: the block ends; then None goes on, and an exception is raised again. */
void mpy_end_finally(mpv v) {
  mpy_block_pop();
  if (v == MPY_NONE) return;
  if (is_exc(v)) raise_value(v);
  fail("internal: END_FINALLY with a return or an unwind is not lowered yet");
}

/* RAISE_OBJ: raises a class (instantiated with no argument) or an exception instance. */
void mpy_raise_obj(mpv v) {
  if ((is_builtin(v) && ((const MpyBuiltin *)(uintptr_t)v)->id >= BI_EXC) || (is_class(v) && class_of(v)->info.exc)) {
    v = mpy_call(v, 0);
  }
  if (!is_exc(v)) fail("TypeError: exceptions must derive from BaseException");
  raise_value(v);
}

/* RAISE_FROM: raise v from cause. MicroPython 1.29 does not set a cause: when there is one it warns (on stderr, as mp_warning
 * prints it) and raises v as RAISE_OBJ does. */
void mpy_raise_from(mpv v, mpv cause) {
  if (cause != MPY_NONE) fprintf(stderr, "Warning: exception chaining not supported\n");
  mpy_raise_obj(v);
}

/* RAISE_LAST: a bare raise re-raises the exception of the innermost handler that runs. */
void mpy_reraise(void) {
  MpyBlock *b;
  for (b = blocks; b != NULL; b = b->prev) {
    if (b->landed) raise_value(b->exc);
  }
  fail("RuntimeError: no active exception to reraise");
}

/* The classes and their instances. An instance's dict holds its attributes; a class's dict is its namespace, and a
 * method is a function in it. Attribute names are interned, so the dicts compare them by pointer. */
static mpv make_bound(mpv self, mpv fn) {
  MpyBound *m = (MpyBound *)malloc(sizeof *m);
  if (m == NULL) fail("out of memory");
  m->type = &mpy_type_bound;
  m->self = self;
  m->fn = fn;
  return (mpv)(uintptr_t)m;
}

/* The value of key in a class or one of its bases (an exception class has no dict). */
static int class_find(const MpyType *t, mpv key, mpv *out) {
  for (; t != NULL; t = t->base) {
    if (t->cls == NULL) break;
    if (dict_find(((const MpyClass *)t->cls)->dict, key, out)) return 1;
  }
  return 0;
}

static void attr_error(mpv obj, const char *name, size_t len) {
  char msg[200];
  snprintf(msg, sizeof msg, "AttributeError: '%s' object has no attribute '%.*s'", type_name(obj), (int)len, name);
  fail(msg);
}

/* super objects. super_find is super_attr (py/objtype.c): the value of name in the bases of the class, the class itself is not
 * searched. __init__ is found in object and in an exception's base even though they have no dict here: it is BI_INIT, and
 * method is set when the value takes the self (a function, or BI_INIT). */
static int is_super(mpv v) { return is_heap(v) && type_of(v) == &mpy_type_super; }

static int super_find(const MpySuper *s, const char *name, size_t len, mpv *v, int *method) {
  mpv key = intern_name(name, len);
  if (s->cls->base != NULL && class_find(s->cls->base, key, v)) {
    *method = is_function(*v);
    return 1;
  }
  if (len == 8 && memcmp(name, "__init__", 8) == 0) {
    *v = builtin_obj(BI_INIT);
    *method = 1;
    return 1;
  }
  return 0;
}

static void super_error(const char *name, size_t len) {
  char msg[200];
  snprintf(msg, sizeof msg, "AttributeError: 'super' object has no attribute '%.*s'", (int)len, name);
  fail(msg);
}

/* super(cls, self), the builtin: self is an instance of cls or of a class derived from it, or a class that is (checked as a
 * type). A failed check is a TypeError with no text, as the reference raises it. */
static mpv super_new(mpv clsv, mpv self) {
  MpySuper *s;
  const MpyType *st;
  const MpyType *want;
  if (!is_class(clsv)) fail("TypeError: ");
  want = &class_of(clsv)->info;
  st = is_class(self) ? &class_of(self)->info : (is_inst(self) ? type_of(self) : NULL);
  while (st != NULL && st != want) st = st->base;
  if (st == NULL) fail("TypeError: ");
  s = (MpySuper *)malloc(sizeof *s);
  if (s == NULL) fail("out of memory");
  s->type = &mpy_type_super;
  s->cls = want;
  s->self = self;
  return (mpv)(uintptr_t)s;
}

/* obj.name as a value (LOAD_ATTR). A function found in the class is bound to the instance. */
mpv mpy_load_attr(mpv obj, const char *name, size_t len) {
  mpv key = intern_name(name, len), v;
  if (is_inst(obj)) {
    if (dict_find(((const MpyInst *)(uintptr_t)obj)->dict, key, &v)) return v;
    if (class_find(type_of(obj), key, &v)) return is_function(v) ? make_bound(obj, v) : v;
  } else if (is_class(obj)) {
    if (class_find(&class_of(obj)->info, key, &v)) return v;
  } else if (is_super(obj)) {
    const MpySuper *s = (const MpySuper *)(uintptr_t)obj;
    int method = 0;
    if (super_find(s, name, len, &v, &method)) return method ? make_bound(s->self, v) : v;
    super_error(name, len);
  } else if (is_dict(obj) && dict_method_index(name, len) >= 0) {
    fail("a dict method read as a value (not called at once) is not lowered yet");
  } else if (is_set(obj)) {
    fail("an attribute of a set is not lowered yet");
  }
  attr_error(obj, name, len);
  return MPY_NONE;
}

/* obj.name = value (STORE_ATTR). Only an instance or a class has attributes. A value of 0 is a del (LOAD_NULL, STORE_ATTR, as
 * MicroPython 1.29 compiles it), which removes the attribute. */
void mpy_store_attr(mpv obj, const char *name, size_t len, mpv value) {
  mpv key = intern_name(name, len);
  mpv dict = 0;
  if (is_inst(obj)) dict = ((const MpyInst *)(uintptr_t)obj)->dict;
  else if (is_class(obj)) dict = class_of(obj)->dict;
  else attr_error(obj, name, len);
  if (value != 0) {
    dict_store(dict, key, value);
    return;
  }
  if (map_lookup((MpyDict *)(uintptr_t)dict, key, MAP_REMOVE) < 0) attr_error(obj, name, len);
}

/* The with statement (SETUP_WITH and WITH_CLEANUP, py/vm.c). __exit__ is looked up before __enter__, as mp_load_method does, and
 * the exit method is bound to the context manager; the value of __enter__ is the statement's `as` value. */
mpv mpy_with_exit(mpv ctx) { return mpy_load_attr(ctx, "__exit__", 8); }

mpv mpy_with_enter(mpv ctx) {
  mpv enter = mpy_load_attr(ctx, "__enter__", 9);
  return mpy_call(enter, 0);
}

/* The class of an exception instance, as its __exit__ gets it: a user class, or the builtin class of a builtin exception. */
static mpv exc_class_value(mpv exc) {
  const MpyType *t = type_of(exc);
  if (t->cls != NULL) return (mpv)(uintptr_t)t->cls;
  return builtin_obj(BI_EXC + (int)(t - mpy_exc_info));
}

/* WITH_CLEANUP: when the body ended normally (top is None), __exit__(None, None, None) is called. When it raised (top is the
 * exception), __exit__(class, exception, None) is called, and the exception is suppressed when that is true, else it stays
 * on top for END_FINALLY to raise again. The result takes the place of the exit method. */
mpv mpy_with_cleanup(mpv exit, mpv top) {
  mpv r;
  if (top == MPY_NONE) {
    mpy_push(MPY_NONE);
    mpy_push(MPY_NONE);
    mpy_push(MPY_NONE);
    mpy_call(exit, 3);
    return MPY_NONE;
  }
  if (!is_exc(top)) fail("unwinding a with statement (a return or a break in its body) is not lowered yet");
  mpy_push(exc_class_value(top));
  mpy_push(top);
  mpy_push(MPY_NONE);
  r = mpy_call(exit, 3);
  return mpy_truth(r) ? MPY_NONE : top;
}

/* LOAD_METHOD: the method of obj named name. The self it goes with is left in method_self (0 when the attribute is not a
 * method of the class, so the call takes no self). A list has append and pop. */
mpv mpy_load_method(mpv obj, const char *name, size_t len) {
  mpv key = intern_name(name, len), v;
  method_self = 0;
  if (is_list(obj)) {
    method_self = obj;
    if (len == 6 && memcmp(name, "append", 6) == 0) return builtin_obj(BI_APPEND);
    if (len == 3 && memcmp(name, "pop", 3) == 0) return builtin_obj(BI_POP);
    method_self = 0;
  } else if (is_dict(obj) && dict_method_index(name, len) >= 0) {
    /* fromkeys is a classmethod: it is called with no self */
    if (dict_method_index(name, len) != BI_DICT_FROMKEYS) method_self = obj;
    return builtin_obj(dict_method_index(name, len));
  } else if (is_set(obj)) {
    if (set_method_index(name, len) < 0) fail("a method of a set is not lowered yet");
    method_self = obj;
    return builtin_obj(set_method_index(name, len));
  } else if (is_super(obj)) {
    const MpySuper *s = (const MpySuper *)(uintptr_t)obj;
    int method = 0;
    if (!super_find(s, name, len, &v, &method)) super_error(name, len);
    if (method) method_self = s->self;
    return v;
  } else if (is_inst(obj)) {
    if (dict_find(((const MpyInst *)(uintptr_t)obj)->dict, key, &v)) return v;
    if (class_find(type_of(obj), key, &v)) {
      if (is_function(v)) method_self = obj;
      return v;
    }
  } else if (is_class(obj)) {
    if (class_find(&class_of(obj)->info, key, &v)) return v;
  }
  if (!is_inst(obj) && !is_class(obj) && refused_method_name(name, len)) {
    char msg[200];
    snprintf(msg, sizeof msg, "a method %.*s of a '%s' is not lowered yet", (int)len, name, type_name(obj));
    fail(msg);
  }
  attr_error(obj, name, len);
  return MPY_NONE;
}

/* LOAD_SUPER_METHOD: the method name of super(cls, self), looked up as mp_load_super_method does, with the self it goes with
 * (left in method_self, as mpy_load_method leaves it). cls is the class, self the instance. */
mpv mpy_load_super_method(mpv clsv, mpv self, const char *name, size_t len) {
  MpySuper s;
  mpv v = 0;
  int method = 0;
  method_self = 0;
  if (!is_class(clsv)) fail("TypeError: ");
  s.type = &mpy_type_super;
  s.cls = &class_of(clsv)->info;
  s.self = self;
  if (!super_find(&s, name, len, &v, &method)) super_error(name, len);
  if (method) method_self = self;
  return v;
}

/* The self that the last mpy_load_method left (0 for none). */
mpv mpy_method_self(void) { return method_self; }

/* CALL_METHOD: [self, args...] on the value stack, with the self 0 when there is none. */
mpv mpy_call_method(mpv meth, uint64_t n) {
  size_t base;
  if (n + 1 > vtop) fail("mpy_call_method: the arguments are not on the value stack");
  base = vtop - n - 1;
  if (vstk[base] == 0) {   /* no self: drop the null, the arguments are the call's */
    memmove(vstk + base, vstk + base + 1, n * sizeof(mpv));
    vtop -= 1;
    return mpy_call(meth, n);
  }
  return mpy_call(meth, n + 1);
}

/* Inserts v below the nargs values on top of the value stack (the self of a bound method, or of __init__). */
static void insert_front(uint64_t nargs, mpv v) {
  size_t base = vtop - nargs;
  vstk_reserve(vtop + 1);
  memmove(vstk + base + 1, vstk + base, nargs * sizeof(mpv));
  vstk[base] = v;
  vtop += 1;
}

/* Calling a class: a new instance, initialized by its __init__ (with the arguments). Without one, an exception takes its
 * single argument, and other classes take none. */
static mpv instantiate(mpv clsv, uint64_t nargs) {
  const MpyClass *c = class_of(clsv);
  mpv key = intern_name("__init__", 8), init = 0;
  size_t base;
  mpv self;
  if (nargs > vtop) fail("mpy_call: the arguments are not on the value stack");
  base = vtop - nargs;
  self = new_inst_of(&((MpyClass *)(uintptr_t)clsv)->info);
  if (class_find(&c->info, key, &init)) {
    if (!is_function(init)) fail("TypeError: __init__ is not a function");
    insert_front(nargs, self);
    mpy_call(init, nargs + 1);
    vtop = base;
    return self;
  }
  if (nargs > 1 || (nargs == 1 && !c->info.exc)) fail("TypeError: this class takes no arguments");
  if (nargs == 1) ((MpyInst *)(uintptr_t)self)->arg = vstk[base];
  vtop = base;
  return self;
}

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
  if (is_class(fn)) return instantiate(fn, nargs);
  if (is_bound(fn)) {
    const MpyBound *m = (const MpyBound *)(uintptr_t)fn;
    mpv target = m->fn;
    insert_front(nargs, m->self);
    return mpy_call(target, nargs + 1);
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

/* A new set with a table of n slots, filled with the n values on the value stack (BUILD_SET; mp_obj_new_set(n, items)). */
mpv mpy_build_set(uint64_t n) {
  MpyDict *s = (MpyDict *)malloc(sizeof *s);
  size_t base, i;
  if (s == NULL) fail("out of memory");
  if (n > vtop) fail("mpy_build_set: the items are not on the value stack");
  base = vtop - n;
  s->type = &mpy_type_set;
  s->alloc = (size_t)n;
  s->used = 0;
  s->all_keys_are_qstrs = 0;
  s->table = n ? (MpyEntry *)calloc((size_t)n, sizeof(MpyEntry)) : NULL;
  if (n && s->table == NULL) fail("out of memory");
  for (i = 0; i < n; ++i) map_lookup(s, vstk[base + i], MAP_ADD);
  vtop = base;
  return (mpv)(uintptr_t)s;
}

/* LIST_APPEND of a list comprehension (STORE_COMP with kind 0): appends to the list. */
void mpy_list_append(mpv l, mpv v) {
  if (!is_list(l)) fail("internal: a list comprehension's collection is not a list");
  list_append((MpyList *)(uintptr_t)l, v);
}

/* A slice of start, stop and step (each an int or None): BUILD_SLICE. */
mpv mpy_make_slice(mpv start, mpv stop, mpv step) {
  MpySlice *s = (MpySlice *)malloc(sizeof *s);
  if (s == NULL) fail("out of memory");
  s->type = &mpy_type_slice;
  s->start = start;
  s->stop = stop;
  s->step = step;
  return (mpv)(uintptr_t)s;
}

/* The integer of a slice bound: an int or a bool. */
static int64_t slice_int(mpv v) {
  char msg[120];
  if (is_small(v) || is_bool(v)) return need_int(v);
  snprintf(msg, sizeof msg, "TypeError: can't convert %s to int", real_type_name(v));
  fail(msg);
  return 0;
}

static int64_t clamp_i(int64_t v, int64_t lo, int64_t hi) { return v < lo ? lo : (v > hi ? hi : v); }

/* The bounds of a slice over a sequence of len items, as MicroPython's mp_obj_slice_indices and
 * mp_seq_get_fast_slice_indexes give them: the items are start, start + step, ... while they are below stop (above it for a
 * negative step). Returns 1 when the step is 1. */
static int slice_indices(mpv sv, int64_t len, int64_t *out_start, int64_t *out_stop, int64_t *out_step) {
  const MpySlice *s = slice_of(sv);
  int64_t start, stop, step;
  if (s->step == MPY_NONE) {
    step = 1;
  } else {
    step = slice_int(s->step);
    if (step == 0) fail("ValueError: slice step can't be zero");
  }
  if (step > 0) {
    if (s->start == MPY_NONE) {
      start = 0;
    } else {
      start = slice_int(s->start);
      if (start < 0) start += len;
      start = clamp_i(start, 0, len);
    }
    if (s->stop == MPY_NONE) {
      stop = len;
    } else {
      stop = slice_int(s->stop);
      if (stop < 0) stop += len;
      stop = clamp_i(stop, 0, len);
    }
  } else {
    if (s->start == MPY_NONE) {
      start = len - 1;
    } else {
      start = slice_int(s->start);
      if (start < 0) start += len;
      start = clamp_i(start, -1, len - 1);
    }
    if (s->stop == MPY_NONE) {
      stop = -1;
    } else {
      stop = slice_int(s->stop);
      if (stop < 0) stop += len;
      stop = clamp_i(stop, -1, len - 1);
    }
  }
  /* mp_seq_get_fast_slice_indexes: a negative step's stop is one past the last item; an empty slice has stop at start. */
  if (step < 0) stop++;
  if (step > 0 && start > stop) stop = start;
  else if (step < 0 && start < stop) stop = start + 1;
  *out_start = start;
  *out_stop = stop;
  *out_step = step;
  return step == 1;
}

/* list[slice] and tuple[slice]: a new list or tuple. A tuple takes only a step of 1, as MicroPython does. */
static mpv seq_slice(mpv obj, mpv sv) {
  size_t len;
  const mpv *items;
  int64_t start, stop, step, i;
  int fast;
  seq_items(obj, &len, &items);
  fast = slice_indices(sv, (int64_t)len, &start, &stop, &step);
  if (is_tuple(obj)) {
    MpyTuple *t;
    size_t n;
    if (!fast) fail("NotImplementedError: only slices with step=1 (aka None) are supported");
    n = (size_t)(stop - start);
    t = (MpyTuple *)malloc(sizeof *t + n * sizeof(mpv));
    if (t == NULL) fail("out of memory");
    t->type = &mpy_type_tuple;
    t->len = n;
    for (i = 0; i < (int64_t)n; ++i) t->items[i] = items[start + i];
    return (mpv)(uintptr_t)t;
  }
  {
    MpyList *l = list_new(0);
    for (i = start; step > 0 ? i < stop : i >= stop; i += step) list_append(l, items[i]);
    return (mpv)(uintptr_t)l;
  }
}

/* list[slice] = value, or del list[slice] when value is 0: only a step of 1 is lowered (MicroPython's NotImplementedError
 * for the others). The value is copied first, since it may be the list itself. */
static void list_slice_store(MpyList *l, mpv sv, mpv value) {
  int64_t start, stop, step;
  size_t n = 0, newlen, i;
  mpv *tmp = NULL;
  char msg[120];
  if (!slice_indices(sv, (int64_t)l->len, &start, &stop, &step)) fail("NotImplementedError: ");
  if (value != 0) {
    size_t vl;
    const mpv *vi;
    if (!seq_items(value, &vl, &vi)) {
      snprintf(msg, sizeof msg, "TypeError: object '%s' isn't a tuple or list", real_type_name(value));
      fail(msg);
    }
    n = vl;
    tmp = (mpv *)malloc((n ? n : 1) * sizeof(mpv));
    if (tmp == NULL) fail("out of memory");
    for (i = 0; i < n; ++i) tmp[i] = vi[i];
  }
  newlen = l->len - (size_t)(stop - start) + n;
  if (newlen > l->cap) {
    mpv *items = (mpv *)realloc(l->items, newlen * sizeof(mpv));
    if (items == NULL) fail("out of memory");
    l->items = items;
    l->cap = newlen;
  }
  memmove(l->items + start + n, l->items + stop, (l->len - (size_t)stop) * sizeof(mpv));
  if (n) memcpy(l->items + start, tmp, n * sizeof(mpv));
  l->len = newlen;
  free(tmp);
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

/* A str index (a str is indexed by character). The index is an int or a bool. */
static int64_t str_index_value(mpv idx, size_t n, int is_slice_bound) {
  int64_t i;
  char msg[160];
  if (!is_small(idx) && !is_bool(idx)) {
    snprintf(msg, sizeof msg, "TypeError: string indices must be integers, not %s", real_type_name(idx));
    fail(msg);
  }
  i = need_int(idx);
  if (i < 0) i += (int64_t)n;
  if (is_slice_bound) return clamp_i(i, 0, (int64_t)n);
  return i;
}

/* str[i]: the one-character str. */
static mpv str_item(const MpyStr *s, mpv idx) {
  size_t n = str_chars(s);
  int64_t i = str_index_value(idx, n, 0);
  size_t a, b;
  if (i < 0 || i >= (int64_t)n) fail("IndexError: string index out of range");
  a = byte_offset(s, (size_t)i);
  b = byte_offset(s, (size_t)i + 1);
  return new_str(s->data + a, b - a);
}

/* str[slice]: only a step of 1 (or None) is lowered. The bounds are clamped to the characters of the str, and a stop before
 * the start gives an empty str. */
static mpv str_slice(const MpyStr *s, mpv sv) {
  const MpySlice *sl = slice_of(sv);
  size_t n = str_chars(s);
  int64_t a, b;
  size_t ba, bb;
  if (sl->step != MPY_NONE && sl->step != (mpv)3) fail("NotImplementedError: only slices with step=1 (aka None) are supported");
  a = sl->start == MPY_NONE ? 0 : str_index_value(sl->start, n, 1);
  b = sl->stop == MPY_NONE ? (int64_t)n : str_index_value(sl->stop, n, 1);
  if (b < a) b = a;
  ba = byte_offset(s, (size_t)a);
  bb = byte_offset(s, (size_t)b);
  return new_str(s->data + ba, bb - ba);
}

mpv mpy_getitem(mpv obj, mpv idx) {
  size_t len;
  const mpv *items;
  char msg[120];
  if (is_dict(obj)) return dict_get(obj, idx);
  if (is_str(obj)) return is_slice(idx) ? str_slice(str_of(obj), idx) : str_item(str_of(obj), idx);
  if (!seq_items(obj, &len, &items)) {
    snprintf(msg, sizeof msg, "TypeError: '%s' object isn't subscriptable", type_name(obj));
    fail(msg);
  }
  if (is_slice(idx)) return seq_slice(obj, idx);
  return items[checked_index(obj, idx, len,
                             is_list(obj) ? "IndexError: list index out of range" : "IndexError: tuple index out of range")];
}

/* obj[idx] = value, or del obj[idx] when value is 0. */
void mpy_setitem(mpv obj, mpv idx, mpv value) {
  MpyList *l;
  size_t i;
  char msg[120];
  if (is_dict(obj)) {
    if (value == 0) dict_delete(obj, idx);
    else dict_store(obj, idx, value);
    return;
  }
  if (!is_list(obj)) {
    snprintf(msg, sizeof msg, "TypeError: '%s' object doesn't support item %s", type_name(obj),
             value == 0 ? "deletion" : "assignment");
    fail(msg);
  }
  l = (MpyList *)(uintptr_t)obj;
  if (is_slice(idx)) {
    list_slice_store(l, idx, value);
    return;
  }
  i = checked_index(obj, idx, l->len, "IndexError: list index out of range");
  if (value == 0) {
    memmove(l->items + i, l->items + i + 1, (l->len - i - 1) * sizeof(mpv));
    l->len -= 1;
  } else {
    l->items[i] = value;
  }
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
  if (!is_range(obj) && !is_str(obj) && !is_dict(obj) && !is_set(obj) && !is_view(obj) && !seq_items(obj, &len, &items)) {
    snprintf(msg, sizeof msg, "TypeError: '%s' object isn't iterable", real_type_name(obj));
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
  if (is_dict(it->seq) || is_set(it->seq) || is_view(it->seq)) {
    /* The table in order, from the next slot: a dict or a set gives its keys, a view what it shows. */
    int kind = is_view(it->seq) ? view_of(it->seq)->kind : VIEW_KEYS;
    const MpyDict *d = dict_of(is_view(it->seq) ? view_of(it->seq)->dict : it->seq);
    while (it->index < d->alloc) {
      const MpyEntry *e = &d->table[it->index++];
      if (e->key == 0 || e->key == MPY_SENTINEL) continue;
      if (kind == VIEW_VALUES) return e->value;
      if (kind == VIEW_ITEMS) return view_item_tuple(e->key, e->value);
      return e->key;
    }
    return 0;
  }
  if (is_str(it->seq)) {
    /* One character: the index is a byte offset, and the character runs to the next byte that does not continue it. */
    const MpyStr *s = str_of(it->seq);
    size_t i = it->index, j = i + 1;
    if (i >= s->len) return 0;
    while (j < s->len && (((unsigned char)s->data[j]) & 0xc0) == 0x80) ++j;
    it->index = j;
    return new_str(s->data + i, j - i);
  }
  seq_items(it->seq, &len, &items);
  if (it->index >= len) return 0;
  return items[it->index++];
}

/* Cells. A cell is a heap box holding one value; a closure and the function that owns the variable share it. The value 0
 * is unbound (the variable has not been assigned yet). Cells are never values a program can name: lowered code reaches them
 * only through its locals and the captured cells of a closure. */
typedef struct {
  const MpyType *type;
  mpv value;
} MpyCell;

mpv mpy_make_cell(mpv value) {
  MpyCell *c = (MpyCell *)malloc(sizeof *c);
  if (c == NULL) fail("out of memory");
  c->type = &mpy_type_cell;
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

/* d.update(other) (dict_update in py/objdict.c): the items of another dict, or the (key, value) pairs that an iterable gives. A
 * pair is a list or a tuple of two items; a non-iterable item is a TypeError, and another iterable item is not lowered. */
static void dict_update(mpv dv, mpv other) {
  if (is_dict(other)) {
    const MpyDict *s = dict_of(other);
    size_t e;
    for (e = 0; e < s->alloc; ++e) {
      if (s->table[e].key != 0 && s->table[e].key != MPY_SENTINEL) dict_store(dv, s->table[e].key, s->table[e].value);
    }
    return;
  }
  {
    mpv it = mpy_get_iter(other), item;
    while ((item = mpy_iter_next(it)) != 0) {
      size_t n;
      const mpv *items;
      if (!seq_items(item, &n, &items)) {
        mpy_get_iter(item);   /* a non-iterable item is a TypeError from here */
        fail("an item of dict.update that is not a list or a tuple is not lowered yet");
      }
      if (n != 2) fail("ValueError: dict update sequence has wrong length");
      dict_store(dv, items[0], items[1]);
    }
  }
}

/* Builtins. A builtin's arguments are args[0..n-1] on the value stack (mpy_call leaves them there until it returns). */

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

static mpv builtin_call(int id, const mpv *args, uint64_t n) {
  char msg[160];
  if (id >= BI_EXC) {   /* an exception class: its instance, with the one argument it may take */
    if (n > 1) fail("TypeError: exceptions with more than one argument are not lowered yet");
    return new_exc(id - BI_EXC, n ? args[0] : 0);
  }
  switch (id) {
    case BI_LEN: {
      size_t len;
      const mpv *items;
      if (n != 1) fail("TypeError: len() takes exactly one argument");
      if (is_str(args[0])) return make_small((int64_t)str_chars(str_of(args[0])));
      if (seq_items(args[0], &len, &items)) return make_small((int64_t)len);
      if (is_range(args[0])) return make_small((int64_t)range_of(args[0])->len);
      if (is_dict(args[0]) || is_set(args[0])) return make_small((int64_t)dict_of(args[0])->used);
      if (is_view(args[0])) return make_small((int64_t)dict_of(view_of(args[0])->dict)->used);
      snprintf(msg, sizeof msg, "TypeError: object of type '%s' has no len()", real_type_name(args[0]));
      fail(msg);
      return MPY_NONE;
    }
    case BI_STR: {
      if (n == 0) return new_str("", 0);
      if (n != 1) fail("TypeError: str() takes at most 1 argument");
      return str_of_value(args[0]);   /* str(s) is s, as in MicroPython */
    }
    case BI_BUILD_CLASS: {
      /* __build_class__(body, name[, base]): the body runs with a namespace on the stack, then the class is made of it. The
       * arguments are copied first: the body's call may move the value stack. */
      mpv body, name_v, base_v = 0, ns, cv, cell_v;
      MpyClass *c;
      const MpyType *base = NULL;
      size_t i;
      if (n < 2 || n > 3) fail("TypeError: __build_class__ takes 2 or 3 arguments");
      body = args[0];
      name_v = args[1];
      if (n == 3) base_v = args[2];
      if (!is_str(name_v)) fail("TypeError: class name must be a str");
      if (n == 3) {
        if (is_class(base_v)) base = &class_of(base_v)->info;
        else if (is_builtin(base_v) && ((const MpyBuiltin *)(uintptr_t)base_v)->id >= BI_EXC) {
          base = &mpy_exc_info[((const MpyBuiltin *)(uintptr_t)base_v)->id - BI_EXC];
        } else fail("TypeError: a base class must be a class");
      }
      ns = mpy_build_map(0);
      ns_push(ns);
      cell_v = mpy_call(body, 0);   /* the body returns the cell of __class__ when a method uses super(), else None */
      ns_n -= 1;
      c = (MpyClass *)malloc(sizeof *c);
      if (c == NULL) fail("out of memory");
      c->type = &mpy_type_metaclass;
      c->dict = ns;
      c->info.base = base;
      c->info.exc = base ? base->exc : 0;
      c->info.inst = 1;
      c->info.cls = c;
      {
        const MpyStr *s = str_of(name_v);
        char *nm = (char *)malloc(s->len + 1);
        if (nm == NULL) fail("out of memory");
        for (i = 0; i < s->len; ++i) nm[i] = s->data[i];
        nm[s->len] = '\0';
        c->info.name = nm;
      }
      cv = (mpv)(uintptr_t)c;
      if (is_heap(cell_v) && type_of(cell_v) == &mpy_type_cell) ((MpyCell *)(uintptr_t)cell_v)->value = cv;
      return cv;
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
    case BI_DICT_GET:
    case BI_DICT_POP: {
      /* d.get(key[, default]) and d.pop(key[, default]): args[0] is the dict. The count includes it. */
      MpyDict *d = (MpyDict *)(uintptr_t)args[0];
      long at;
      if (n < 2) fail("TypeError: function missing 1 required positional arguments");
      if (n > 3) {
        snprintf(msg, sizeof msg, "TypeError: function expected at most 3 arguments, got %d", (int)n);
        fail(msg);
      }
      if (id == BI_DICT_GET) {
        at = map_lookup(d, args[1], MAP_LOOKUP);
        if (at >= 0) return d->table[at].value;
      } else {
        at = map_lookup(d, args[1], MAP_REMOVE);   /* the value stays in the slot the removal leaves */
        if (at >= 0) return d->table[at].value;
      }
      if (n == 3) return args[2];
      if (id == BI_DICT_GET) return MPY_NONE;
      key_error(args[1]);
      return MPY_NONE;
    }
    case BI_DICT_KEYS:
    case BI_DICT_VALUES:
    case BI_DICT_ITEMS: {
      MpyView *v;
      if (n != 1) {
        snprintf(msg, sizeof msg, "TypeError: function takes 1 positional arguments but %d were given", (int)n);
        fail(msg);
      }
      v = (MpyView *)malloc(sizeof *v);
      if (v == NULL) fail("out of memory");
      v->type = &mpy_type_view;
      v->dict = args[0];
      v->kind = id == BI_DICT_KEYS ? VIEW_KEYS : (id == BI_DICT_VALUES ? VIEW_VALUES : VIEW_ITEMS);
      return (mpv)(uintptr_t)v;
    }
    case BI_DICT_UPDATE: {
      /* d.update([other]): another dict, or an iterable of (key, value) pairs. Returns None. */
      if (n > 2) {
        snprintf(msg, sizeof msg, "TypeError: function expected at most 2 arguments, got %d", (int)n);
        fail(msg);
      }
      if (n == 2) dict_update(args[0], args[1]);
      return MPY_NONE;
    }
    case BI_DICT_COPY:
    case BI_DICT_CLEAR:
    case BI_DICT_POPITEM: {
      /* d.copy(), d.clear() and d.popitem(): args[0] is the dict, and the count includes it (objdict.c). */
      MpyDict *s;
      if (n != 1) {
        snprintf(msg, sizeof msg, "TypeError: function takes 1 positional arguments but %d were given", (int)n);
        fail(msg);
      }
      s = (MpyDict *)(uintptr_t)args[0];
      if (id == BI_DICT_COPY) {
        /* the same table, slot for slot, deleted slots included (mp_obj_dict_copy copies the table) */
        MpyDict *c = (MpyDict *)(uintptr_t)mpy_build_map(s->alloc);
        if (s->alloc) memcpy(c->table, s->table, s->alloc * sizeof(MpyEntry));
        c->used = s->used;
        c->all_keys_are_qstrs = s->all_keys_are_qstrs;
        return (mpv)(uintptr_t)c;
      }
      if (id == BI_DICT_CLEAR) {
        /* mp_map_clear: no table, and the keys are all strs again */
        free(s->table);
        s->table = NULL;
        s->alloc = 0;
        s->used = 0;
        s->all_keys_are_qstrs = 1;
        return MPY_NONE;
      }
      /* popitem: the first live slot in table order, which is removed (its key becomes the sentinel) */
      if (s->used == 0) fail("KeyError: popitem(): dictionary is empty");
      {
        size_t e;
        mpv k, v;
        for (e = 0; e < s->alloc; ++e) {
          if (s->table[e].key != 0 && s->table[e].key != MPY_SENTINEL) break;
        }
        k = s->table[e].key;
        v = s->table[e].value;
        s->used -= 1;
        s->table[e].key = MPY_SENTINEL;
        s->table[e].value = 0;
        return view_item_tuple(k, v);
      }
    }
    case BI_DICT_SETDEFAULT: {
      /* d.setdefault(key[, default]): the value of key, which is added with default (None) when it is not there */
      MpyDict *s;
      long at;
      if (n < 2) fail("TypeError: function missing 1 required positional arguments");
      if (n > 3) {
        snprintf(msg, sizeof msg, "TypeError: function expected at most 3 arguments, got %d", (int)n);
        fail(msg);
      }
      s = (MpyDict *)(uintptr_t)args[0];
      at = map_lookup(s, args[1], MAP_ADD);   /* the key is hashed here, as MicroPython's ADD lookup does */
      if (s->table[at].value == 0) s->table[at].value = n == 3 ? args[2] : MPY_NONE;
      return s->table[at].value;
    }
    case BI_DICT_FROMKEYS: {
      /* dict.fromkeys(iterable[, value]): no self, so the arguments are the iterable and the value. The table is sized by the
       * iterable's length when it has one (mp_obj_len_maybe), else it starts empty. The count in a message includes the class. */
      mpv it, item, r, value = MPY_NONE;
      size_t len = 0, items;
      const mpv *elems;
      if (n < 1) fail("TypeError: function missing 1 required positional arguments");
      if (n > 2) {
        snprintf(msg, sizeof msg, "TypeError: function expected at most 3 arguments, got %d", (int)n + 1);
        fail(msg);
      }
      if (n == 2) value = args[1];
      it = mpy_get_iter(args[0]);
      if (is_dict(args[0]) || is_set(args[0])) len = dict_of(args[0])->used;
      else if (is_view(args[0])) len = dict_of(view_of(args[0])->dict)->used;
      else if (is_range(args[0])) len = range_of(args[0])->len;
      else if (seq_items(args[0], &items, &elems)) len = items;
      r = mpy_build_map(len);
      while ((item = mpy_iter_next(it)) != 0) dict_store(r, item, value);
      return r;
    }
    case BI_SET_ADD:
    case BI_SET_DISCARD:
    case BI_SET_REMOVE: {
      /* s.add(item), s.discard(item) and s.remove(item) (objset.c): None, and remove raises KeyError for a missing item */
      long at;
      if (n != 2) {
        snprintf(msg, sizeof msg, "TypeError: function takes 2 positional arguments but %d were given", (int)n);
        fail(msg);
      }
      if (id == BI_SET_ADD) {
        map_lookup((MpyDict *)(uintptr_t)args[0], args[1], MAP_ADD);
        return MPY_NONE;
      }
      at = map_lookup((MpyDict *)(uintptr_t)args[0], args[1], MAP_REMOVE);
      if (at < 0 && id == BI_SET_REMOVE) key_error(args[1]);
      return MPY_NONE;
    }
    case BI_SET_UNION:
    case BI_SET_INTERSECTION: {
      /* s.union(other) and s.intersection(other): other is any iterable */
      if (n != 2) {
        snprintf(msg, sizeof msg, "TypeError: function takes 2 positional arguments but %d were given", (int)n);
        fail(msg);
      }
      if (id == BI_SET_UNION) {
        mpv r = set_copy_of(args[0]);
        set_add_items(r, args[1]);
        return r;
      }
      return set_intersect_of(args[0], args[1]);
    }
    case BI_SET_DIFFERENCE: {
      /* s.difference(*others): a copy of s from which the items of each other are removed */
      mpv r;
      uint64_t k;
      if (n < 1) fail("TypeError: function takes at least 1 positional arguments");
      r = set_copy_of(args[0]);
      for (k = 1; k < n; ++k) set_remove_items(r, args[k]);
      return r;
    }
    case BI_SET_POP: {
      /* s.pop(): the first item in table order is removed and returned (objset.c's set_pop) */
      mpv item;
      if (n != 1) {
        snprintf(msg, sizeof msg, "TypeError: function takes 1 positional arguments but %d were given", (int)n);
        fail(msg);
      }
      item = set_pop_first(args[0]);
      if (item == 0) fail("KeyError: pop from an empty set");
      return item;
    }
    case BI_SET_UPDATE:
    case BI_SET_DIFFERENCE_UPDATE: {
      /* s.update(*others) adds the items of each other, and s.difference_update(*others) removes them: None either way */
      uint64_t k;
      for (k = 1; k < n; ++k) {
        if (id == BI_SET_UPDATE) set_add_items(args[0], args[k]);
        else set_remove_items(args[0], args[k]);
      }
      return MPY_NONE;
    }
    case BI_SET_INTERSECTION_UPDATE:
    case BI_SET_SYMDIFF:
    case BI_SET_SYMDIFF_UPDATE:
    case BI_SET_ISSUBSET:
    case BI_SET_ISSUPERSET:
    case BI_SET_ISDISJOINT: {
      /* two arguments: the set and the other one (an iterable, or a set for the subset tests, where any other iterable is made
       * into a set first) */
      mpv it, item;
      if (n != 2) {
        snprintf(msg, sizeof msg, "TypeError: function takes 2 positional arguments but %d were given", (int)n);
        fail(msg);
      }
      if (id == BI_SET_INTERSECTION_UPDATE) {
        set_intersect_inplace(args[0], args[1]);
        return MPY_NONE;
      }
      if (id == BI_SET_SYMDIFF) return set_symdiff_of(args[0], args[1]);
      if (id == BI_SET_SYMDIFF_UPDATE) {
        set_symdiff_update_items(args[0], args[1]);
        return MPY_NONE;
      }
      if (id == BI_SET_ISSUBSET) return set_is_subset(args[0], as_set(args[1]), 0) ? MPY_TRUE : MPY_FALSE;
      if (id == BI_SET_ISSUPERSET) return set_is_subset(as_set(args[1]), args[0], 0) ? MPY_TRUE : MPY_FALSE;
      it = mpy_get_iter(args[1]);   /* isdisjoint: false at the first item that is in s */
      while ((item = mpy_iter_next(it)) != 0) {
        if (map_lookup((MpyDict *)(uintptr_t)args[0], item, MAP_LOOKUP) >= 0) return MPY_FALSE;
      }
      return MPY_TRUE;
    }
    case BI_SUPER: {
      /* super(cls, self), as the lowering calls it for a super() whose class and self it has loaded */
      if (n != 2) fail("TypeError: function takes exactly 2 arguments");
      return super_new(args[0], args[1]);
    }
    case BI_INIT: {
      /* object.__init__ and the exception's __init__, reached by super().__init__(...): self is args[0]. An exception keeps its
       * one argument; object takes none. */
      if (n < 1) fail("TypeError: __init__ needs self");
      if (n == 1) return MPY_NONE;
      if (n == 2 && is_inst(args[0]) && type_of(args[0])->exc) {
        ((MpyInst *)(uintptr_t)args[0])->arg = args[1];
        return MPY_NONE;
      }
      fail("TypeError: object.__init__() takes exactly one argument (the instance to initialize)");
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

/* repr of a str, as MicroPython writes it: single quotes unless the text has a single quote and no double quote. */
static void repr_str(Buf *b, const MpyStr *s) {
  int has_sq = memchr(s->data, '\'', s->len) != NULL;
  int has_dq = memchr(s->data, '"', s->len) != NULL;
  char q = (has_sq && !has_dq) ? '"' : '\'';
  size_t i;
  buf_put(b, &q, 1);
  for (i = 0; i < s->len; ++i) {
    unsigned char c = (unsigned char)s->data[i];
    if (c == (unsigned char)q || c == '\\') {
      buf_put(b, "\\", 1);
      buf_put(b, (const char *)&c, 1);
    } else if (c == '\n') buf_str(b, "\\n");
    else if (c == '\r') buf_str(b, "\\r");
    else if (c == '\t') buf_str(b, "\\t");
    else if (c < 0x20 || c == 0x7f) {
      char t[8];
      snprintf(t, sizeof t, "\\x%02x", c);
      buf_str(b, t);
    } else buf_put(b, (const char *)&c, 1);
  }
  buf_put(b, &q, 1);
}

/* repr of a value: numbers, bools and None by name, str quoted, lists and tuples with their items' repr, and dicts as
 * key: value pairs in insertion order. */
static void repr_into(Buf *b, mpv v) {
  size_t n, i;
  const mpv *items;
  if (is_small(v)) buf_int(b, (long long)small_value(v));
  else if (v == MPY_TRUE) buf_str(b, "True");
  else if (v == MPY_FALSE) buf_str(b, "False");
  else if (v == MPY_NONE) buf_str(b, "None");
  else if (is_str(v)) repr_str(b, str_of(v));
  else if (is_range(v)) {
    const MpyRange *r = range_of(v);
    char t[96];
    int k;
    if (r->step == 1) k = snprintf(t, sizeof t, "range(%lld, %lld)", (long long)r->start, (long long)r->stop);
    else k = snprintf(t, sizeof t, "range(%lld, %lld, %lld)", (long long)r->start, (long long)r->stop, (long long)r->step);
    buf_put(b, t, (size_t)k);
  } else if (is_set(v)) {
    /* MicroPython prints a set's items in table order, and an empty set as set() */
    const MpyDict *s = dict_of(v);
    size_t e;
    int first = 1;
    if (s->used == 0) {
      buf_str(b, "set()");
      return;
    }
    buf_put(b, "{", 1);
    for (e = 0; e < s->alloc; ++e) {
      if (s->table[e].key == 0 || s->table[e].key == MPY_SENTINEL) continue;
      if (!first) buf_str(b, ", ");
      first = 0;
      repr_into(b, s->table[e].key);
    }
    buf_put(b, "}", 1);
  } else if (is_view(v)) {
    /* dict_keys([...]), dict_values([...]) or dict_items([(key, value), ...]), in table order */
    const MpyView *view = view_of(v);
    const MpyDict *d = dict_of(view->dict);
    size_t e;
    int first = 1;
    buf_str(b, view->kind == VIEW_KEYS ? "dict_keys([" : (view->kind == VIEW_VALUES ? "dict_values([" : "dict_items(["));
    for (e = 0; e < d->alloc; ++e) {
      if (d->table[e].key == 0 || d->table[e].key == MPY_SENTINEL) continue;
      if (!first) buf_str(b, ", ");
      first = 0;
      if (view->kind == VIEW_ITEMS) {
        buf_put(b, "(", 1);
        repr_into(b, d->table[e].key);
        buf_str(b, ", ");
        repr_into(b, d->table[e].value);
        buf_put(b, ")", 1);
      } else {
        repr_into(b, view->kind == VIEW_KEYS ? d->table[e].key : d->table[e].value);
      }
    }
    buf_str(b, "])");
  } else if (is_dict(v)) {
    const MpyDict *d = dict_of(v);
    size_t e;
    int first = 1;
    buf_put(b, "{", 1);
    for (e = 0; e < d->alloc; ++e) {   /* MicroPython prints the items in table order */
      if (d->table[e].key == 0 || d->table[e].key == MPY_SENTINEL) continue;
      if (!first) buf_str(b, ", ");
      first = 0;
      repr_into(b, d->table[e].key);
      buf_str(b, ": ");
      repr_into(b, d->table[e].value);
    }
    buf_put(b, "}", 1);
  } else if (is_slice(v)) {
    const MpySlice *s = slice_of(v);
    buf_str(b, "slice(");
    repr_into(b, s->start);
    buf_str(b, ", ");
    repr_into(b, s->stop);
    buf_str(b, ", ");
    repr_into(b, s->step);
    buf_put(b, ")", 1);
  } else if (seq_items(v, &n, &items)) {
    int is_l = is_list(v);
    buf_put(b, is_l ? "[" : "(", 1);
    for (i = 0; i < n; ++i) {
      if (i) buf_str(b, ", ");
      repr_into(b, items[i]);
    }
    if (!is_l && n == 1) buf_put(b, ",", 1);
    buf_put(b, is_l ? "]" : ")", 1);
  } else if (is_exc(v)) {
    const MpyInst *e = (const MpyInst *)(uintptr_t)v;
    buf_str(b, type_of(v)->name);
    buf_put(b, "(", 1);
    if (e->arg) {
      repr_into(b, e->arg);
      buf_str(b, ",");
    }
    buf_put(b, ")", 1);
  } else if (is_class(v)) {
    buf_str(b, "<class '");
    buf_str(b, class_of(v)->info.name);
    buf_str(b, "'>");
  } else fail("repr of this value is not lowered yet");
}

/* LOAD_BUILD_CLASS: the builtin __build_class__. */
mpv mpy_build_class_fn(void) { return builtin_obj(BI_BUILD_CLASS); }

/* Prints a value as the driver reports the result of the module: a str as its text, anything else as repr. */
void mpy_print_value(mpv v) {
  Buf b = {NULL, 0, 0};
  if (is_str(v)) {
    fwrite(str_of(v)->data, 1, str_of(v)->len, stdout);   /* the bytes may hold NULs */
  } else {
    repr_into(&b, v);
    fwrite(b.p, 1, b.n, stdout);
    free(b.p);
  }
  putchar('\n');
}
