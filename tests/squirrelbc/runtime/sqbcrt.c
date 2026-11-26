/* The runtime helpers of the lowered Squirrel subset (sqbcrt.h). Each error text is the one the reference VM raises
 * (squirrel/sqvm.cpp ARITH_OP, ArithMetaMethod, NEG_OP, ObjCmp, Get, Set, NewSlot, StartCall, CLOSURE_OP;
 * squirrel/sqdebug.cpp Raise_IdxError, Raise_CompareError, PrintObjVal).
 *
 * Strings are interned, as the reference interns them: two equal strings are the same object, so equality is the raw
 * comparison the IR makes. Tables are open-addressing hash tables keyed by the raw value (a string by its object).
 * Nothing is freed. The methods of the subset are the ones sqbc_rt_get finds: `len` of a string or an array, `tostring` of a
 * number, a boolean, a string, an array or a table, `tofloat`, `tointeger` and `tochar` of a number or a boolean (`tofloat`
 * and `tointeger` of a string), `append`, `push`, `pop`, `reverse`, `slice`, `find`, `extend` and `insert` of an array,
 * `slice`, `find`, `tolower` and `toupper` of a string, `rawget`, `rawset`,
 * `rawin` of a class or an instance, `getbase` and `instance` of a class, `getclass` of an instance, and `print` in the root
 * table. `sort`, `map`, `apply`, `reduce` and `filter` of an array call a closure from inside the runtime (see
 * call_from_native). Any other method of a string, an array, a class or an instance is `unsupported ... method`; a table's
 * is "the index does not exist". */
#include "sqbcrt.h"

#include <ctype.h>
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The metamethods of a class (sqobject.h MT_*, the order of the reference's _metamethods table). A class keeps the closure
 * of each one it has (SQClass::NewSlot), apart from its members. */
enum {
  MT_ADD,
  MT_SUB,
  MT_MUL,
  MT_DIV,
  MT_UNM,
  MT_MODULO,
  MT_SET,
  MT_GET,
  MT_TYPEOF,
  MT_NEXTI,
  MT_CMP,
  MT_CALL,
  MT_CLONED,
  MT_NEWSLOT,
  MT_DELSLOT,
  MT_TOSTRING,
  MT_NEWMEMBER,
  MT_INHERITED,
  MT_LAST
};

static void call_from_native(const SQV *callee, SQV *ret, const SQV *args, int n);
static const SQV *inst_mm(const SQV *self, int mm);
static SQV make_null(void);
static SQV make_bool(int b);

/* ---- errors --------------------------------------------------------------------------------------------------------- */

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
    case SQBC_TAG_FLOAT: return "float";
    case SQBC_TAG_CLASS: return "class";
    case SQBC_TAG_INSTANCE: return "instance";
    case SQBC_TAG_STRING: return "string";
    case SQBC_TAG_TABLE: return "table";
    case SQBC_TAG_ARRAY: return "array";
    case SQBC_TAG_CLOSURE:
    case SQBC_TAG_NATIVE: return "function";
    default: return "?";
  }
}

/* ---- strings -------------------------------------------------------------------------------------------------------- */

typedef struct SqStr {
  size_t len;
  uint32_t hash;
  struct SqStr *next; /* the intern chain */
  char chars[1];      /* len bytes and a NUL */
} SqStr;

#define STR_BUCKETS 4096
static SqStr *g_strings[STR_BUCKETS];

static uint32_t fnv1a(const char *s, size_t n) {
  uint32_t h = 2166136261u;
  for (size_t i = 0; i < n; i++) {
    h ^= (unsigned char)s[i];
    h *= 16777619u;
  }
  return h;
}

static SqStr *intern(const char *s, size_t n) {
  uint32_t h = fnv1a(s, n);
  SqStr **head = &g_strings[h % STR_BUCKETS];
  for (SqStr *p = *head; p; p = p->next)
    if (p->len == n && p->hash == h && memcmp(p->chars, s, n) == 0) return p;
  SqStr *p = malloc(offsetof(SqStr, chars) + n + 1);
  if (!p) rt_error("out of memory");
  p->len = n;
  p->hash = h;
  memcpy(p->chars, s, n);
  p->chars[n] = 0;
  p->next = *head;
  *head = p;
  return p;
}

static SQV make_string(const char *s, size_t n) {
  SQV v;
  v.tag = SQBC_TAG_STRING;
  v.pad = 0;
  v.i = (int64_t)(intptr_t)intern(s, n);
  return v;
}

static SqStr *str_of(const SQV *v) { return (SqStr *)(intptr_t)v->i; }

/* A float (squirrel.h's SQFloat, the 4-byte float of this build) is the low 32 bits of the payload. */
static float float_of(const SQV *v) {
  uint32_t bits = (uint32_t)v->i;
  float f;
  memcpy(&f, &bits, sizeof f);
  return f;
}

static SQV make_float(float f) {
  uint32_t bits;
  memcpy(&bits, &f, sizeof bits);
  SQV v;
  v.tag = SQBC_TAG_FLOAT;
  v.pad = 0;
  v.i = (int64_t)bits;
  return v;
}

/* A number of the subset as a float (tofloat in sqobject.h: an integer converts). */
static float number_as_float(const SQV *v) {
  return v->tag == SQBC_TAG_INTEGER ? (float)v->i : float_of(v);
}

static int is_number(const SQV *v) { return v->tag == SQBC_TAG_INTEGER || v->tag == SQBC_TAG_FLOAT; }

/* ToString of the subset (sqvm.cpp): a string as itself, null, a boolean, an integer. A table or a function has no text
 * that is the same on every run, so it is refused. */
static size_t text_of(const SQV *v, char *buf, size_t bufsz, const char **out) {
  switch (v->tag) {
    case SQBC_TAG_STRING: *out = str_of(v)->chars; return str_of(v)->len;
    case SQBC_TAG_NULL: *out = "null"; return 4;
    case SQBC_TAG_BOOL: *out = v->i ? "true" : "false"; return v->i ? 4 : 5;
    case SQBC_TAG_INTEGER: {
      int n = snprintf(buf, bufsz, "%" PRId64, v->i);
      *out = buf;
      return (size_t)n;
    }
    case SQBC_TAG_FLOAT: {
      /* sqvm.cpp ToString: the float with %g (the float promoted to double). */
      int n = snprintf(buf, bufsz, "%g", (double)float_of(v));
      *out = buf;
      return (size_t)n;
    }
    case SQBC_TAG_INSTANCE: {
      /* ToString (sqvm.cpp): the class's _tostring, called with the instance as `this`, must return a string. Any other
       * result makes the reference print the instance's address, which is not the same on every run. */
      const SQV *m = inst_mm(v, MT_TOSTRING);
      SQV self = *v, r;
      if (!m) break;
      SQV f = *m;
      call_from_native(&f, &r, &self, 1);
      if (r.tag != SQBC_TAG_STRING)
        rt_error("tostring of an instance whose _tostring does not return a string is not lowered");
      *out = str_of(&r)->chars;
      return str_of(&r)->len;
    }
    default: break;
  }
  rt_error("tostring of an array, a table, a class, an instance or a function is not lowered");
  return 0;
}

const char *sqbc_rt_text(const SQV *v) { return str_of(v)->chars; }

void sqbc_rt_loadstr(SQV *dst, const char *s, int64_t len) {
  SQV v = make_string(s, (size_t)len);
  *dst = v;
}

/* PrintObjVal (sqdebug.cpp): a string as itself, an integer in decimal, anything else as its type name. */
static const char *print_obj(const SQV *v, char *buf, size_t bufsz) {
  if (v->tag == SQBC_TAG_STRING) return str_of(v)->chars;
  if (v->tag == SQBC_TAG_INTEGER) {
    snprintf(buf, bufsz, "%" PRId64, v->i);
    return buf;
  }
  if (v->tag == SQBC_TAG_FLOAT) {
    /* sqdebug.cpp PrintObjVal: %.14g for a float. */
    snprintf(buf, bufsz, "%.14g", (double)float_of(v));
    return buf;
  }
  return type_name(v->tag);
}

/* ---- tables --------------------------------------------------------------------------------------------------------- */

typedef struct TNode {
  SQV key; /* tag 0: an empty node (no value of the subset has tag 0) */
  SQV val;
} TNode;

typedef struct SqTable {
  size_t count;
  size_t cap; /* a power of two; the load stays below one half */
  TNode *nodes;
} SqTable;

static SqTable *tbl(const SQV *v) { return (SqTable *)(intptr_t)v->i; }

static size_t key_hash(const SQV *k) {
  uint64_t h = k->tag == SQBC_TAG_STRING ? str_of(k)->hash : (uint64_t)k->i;
  h = (h ^ ((uint64_t)k->tag << 32)) * 0x9E3779B97F4A7C15ull;
  return (size_t)(h ^ (h >> 29));
}

static int key_eq(const SQV *a, const SQV *b) { return a->tag == b->tag && a->i == b->i; }

static SQV make_table_val(void) {
  SqTable *t = calloc(1, sizeof *t);
  if (!t) rt_error("out of memory");
  t->cap = 8;
  t->nodes = calloc(t->cap, sizeof(TNode));
  if (!t->nodes) rt_error("out of memory");
  SQV v;
  v.tag = SQBC_TAG_TABLE;
  v.pad = 0;
  v.i = (int64_t)(intptr_t)t;
  return v;
}

static TNode *table_find(SqTable *t, const SQV *k) {
  size_t mask = t->cap - 1;
  for (size_t i = key_hash(k) & mask;; i = (i + 1) & mask) {
    TNode *n = &t->nodes[i];
    if (n->key.tag == 0) return NULL;
    if (key_eq(&n->key, k)) return n;
  }
}

static void table_grow(SqTable *t) {
  TNode *old = t->nodes;
  size_t oldcap = t->cap;
  t->cap *= 2;
  t->nodes = calloc(t->cap, sizeof(TNode));
  if (!t->nodes) rt_error("out of memory");
  size_t mask = t->cap - 1;
  for (size_t j = 0; j < oldcap; j++) {
    if (old[j].key.tag == 0) continue;
    size_t i = key_hash(&old[j].key) & mask;
    while (t->nodes[i].key.tag != 0) i = (i + 1) & mask;
    t->nodes[i] = old[j];
  }
  free(old);
}

/* NewSlot of a table: the value of an existing key is replaced, a new key is inserted. The key is not null. */
static void table_newslot(SqTable *t, const SQV *k, const SQV *v) {
  TNode *n = table_find(t, k);
  if (n) {
    n->val = *v;
    return;
  }
  if ((t->count + 1) * 2 > t->cap) table_grow(t);
  size_t mask = t->cap - 1;
  size_t i = key_hash(k) & mask;
  while (t->nodes[i].key.tag != 0) i = (i + 1) & mask;
  t->nodes[i].key = *k;
  t->nodes[i].val = *v;
  t->count++;
}

/* ---- arrays --------------------------------------------------------------------------------------------------------- */

typedef struct SqArray {
  size_t count;
  size_t cap;
  SQV *items;
} SqArray;

static SqArray *array_of(const SQV *v) { return (SqArray *)(intptr_t)v->i; }

static SQV make_array_val(size_t reserve) {
  SqArray *a = calloc(1, sizeof *a);
  if (!a) rt_error("out of memory");
  a->cap = reserve > 0 ? reserve : 4;
  a->items = calloc(a->cap, sizeof(SQV));
  if (!a->items) rt_error("out of memory");
  SQV v;
  v.tag = SQBC_TAG_ARRAY;
  v.pad = 0;
  v.i = (int64_t)(intptr_t)a;
  return v;
}

void sqbc_rt_newarray(SQV *dst, int reserve) {
  SQV v = make_array_val(reserve > 0 ? (size_t)reserve : 0);
  *dst = v;
}

void sqbc_rt_append(const SQV *self, const SQV *val) {
  SQV v = *val;
  SqArray *a = array_of(self);
  if (a->count == a->cap) {
    size_t cap = a->cap * 2;
    SQV *items = realloc(a->items, cap * sizeof(SQV));
    if (!items) rt_error("out of memory");
    a->items = items;
    a->cap = cap;
  }
  a->items[a->count++] = v;
}

/* ---- closures and natives ------------------------------------------------------------------------------------------- */

/* An outer variable (sqobject.h SQOuter). While its local is live, valptr points into the stack; once closed (CLOSE, or the
 * return of the frame), the value moves into `value` and valptr points there. The open ones form a list by descending
 * valptr, as in the reference (FindOuter, CloseOuters). */
typedef struct SqOuter {
  SQV *valptr;
  SQV value;
  struct SqOuter *next;
} SqOuter;

static SqOuter *g_open_outers;

static SqOuter *find_outer(SQV *slot) {
  SqOuter **pp = &g_open_outers;
  SqOuter *p;
  while ((p = *pp) != NULL && p->valptr >= slot) {
    if (p->valptr == slot) return p;
    pp = &p->next;
  }
  p = calloc(1, sizeof *p);
  if (!p) rt_error("out of memory");
  p->valptr = slot;
  p->next = *pp;
  *pp = p;
  return p;
}

static void close_outers(SQV *from) {
  SqOuter *p;
  while ((p = g_open_outers) != NULL && p->valptr >= from) {
    p->value = *p->valptr;
    p->valptr = &p->value;
    g_open_outers = p->next;
    p->next = NULL;
  }
}

typedef struct SqClosure {
  int fn;        /* the module's prototype index (sq_dispatch) */
  int nparams;   /* the prototype's parameters, `this` included */
  int stacksize; /* the prototype's frame size */
  int has_env;   /* CLOSURE with a bound register: the callee's `this` is env */
  SQV env;
  int nouters;
  SqOuter **outers;
  struct SqClass *base; /* the class of a method of a class with a base (GETBASE), or NULL */
  int varparams;        /* the prototype's vararg flag: its last parameter is the array of the extra arguments */
  int ndef;             /* the number of default parameters, the last ones of the parameter list */
  SQV *defs;            /* the default values (CLOSURE_OP copies them when the closure is made), NDEF of them */
} SqClosure;

/* A native of the base library or a delegate: its operation (NAT_*), the parameter count sqvm.cpp's CallNative checks (`this`
 * included: a positive count is exact, a negative one is a minimum), and the types of the parameters, one letter each
 * (sqstate.cpp CompileTypemask: 'n' an integer or a float, 'a' an array, 's' a string, 'x' an instance, 'y' a class, '.' any);
 * NULL when no parameter is checked. */
typedef struct SqNative {
  int id;
  int nparams;
  const char *typemask;
} SqNative;

enum {
  NAT_PRINT,
  NAT_STR_LEN,
  NAT_ARR_LEN,
  NAT_TOSTRING,
  NAT_NUM_TOFLOAT,    /* number and bool delegate: tofloat, tointeger, tochar */
  NAT_NUM_TOINTEGER,
  NAT_NUM_TOCHAR,
  NAT_STR_TOFLOAT,    /* string delegate: tofloat, tointeger */
  NAT_STR_TOINTEGER,
  NAT_ARR_APPEND,     /* array delegate: append and push */
  NAT_ARR_POP,
  NAT_ARR_REVERSE,
  NAT_ARR_SLICE,
  NAT_ARR_FIND,
  NAT_ARR_EXTEND,     /* array delegate: extend and insert */
  NAT_ARR_INSERT,
  NAT_STR_SLICE,      /* string delegate: slice, find, tolower and toupper */
  NAT_STR_FIND,
  NAT_STR_TOLOWER,
  NAT_STR_TOUPPER,
  NAT_RAWGET,         /* class and instance delegate: rawget, rawset, rawin */
  NAT_RAWSET,
  NAT_RAWIN,
  NAT_CLS_GETBASE,    /* class delegate: getbase, instance */
  NAT_CLS_INSTANCE,
  NAT_INST_GETCLASS,  /* instance delegate: getclass */
  NAT_CLS_GETATTRIBUTES,
  NAT_CLS_SETATTRIBUTES,
  NAT_ARR_SORT,       /* array delegate: the callback methods (sqbaselib.cpp) */
  NAT_ARR_MAP,
  NAT_ARR_APPLY,
  NAT_ARR_REDUCE,
  NAT_ARR_FILTER
};

static SqNative g_nat_print = {NAT_PRINT, 2, NULL};          /* sqbaselib.cpp base_print: print(value) */
static SqNative g_nat_str_len = {NAT_STR_LEN, 1, NULL};      /* string delegate: len */
static SqNative g_nat_arr_len = {NAT_ARR_LEN, 1, NULL};      /* array delegate: len */
static SqNative g_nat_tostring = {NAT_TOSTRING, 1, NULL};    /* default delegate: tostring */
static SqNative g_nat_num_tofloat = {NAT_NUM_TOFLOAT, 1, NULL};
static SqNative g_nat_num_tointeger = {NAT_NUM_TOINTEGER, 1, NULL};
static SqNative g_nat_num_tochar = {NAT_NUM_TOCHAR, 1, NULL};
static SqNative g_nat_str_tofloat = {NAT_STR_TOFLOAT, 1, "s"};
static SqNative g_nat_str_tointeger = {NAT_STR_TOINTEGER, -1, "sn"};
static SqNative g_nat_arr_append = {NAT_ARR_APPEND, 2, "a"};
static SqNative g_nat_arr_pop = {NAT_ARR_POP, 1, "a"};
static SqNative g_nat_arr_reverse = {NAT_ARR_REVERSE, 1, "a"};
static SqNative g_nat_arr_slice = {NAT_ARR_SLICE, -1, "ann"};
static SqNative g_nat_arr_find = {NAT_ARR_FIND, 2, "a"};
static SqNative g_nat_arr_extend = {NAT_ARR_EXTEND, 2, "aa"};   /* sqbaselib.cpp array_extend */
static SqNative g_nat_arr_insert = {NAT_ARR_INSERT, 3, "an"};   /* array_insert */
static SqNative g_nat_str_slice = {NAT_STR_SLICE, -1, "snn"};   /* string_slice */
static SqNative g_nat_str_find = {NAT_STR_FIND, -2, "ssn"};     /* string_find */
static SqNative g_nat_str_tolower = {NAT_STR_TOLOWER, -1, "snn"}; /* string_tolower, string_toupper (STRING_TOFUNCZ) */
static SqNative g_nat_str_toupper = {NAT_STR_TOUPPER, -1, "snn"};
static SqNative g_nat_rawget = {NAT_RAWGET, 2, NULL};
static SqNative g_nat_rawset = {NAT_RAWSET, 3, NULL};
static SqNative g_nat_rawin = {NAT_RAWIN, 2, NULL};
static SqNative g_nat_cls_getbase = {NAT_CLS_GETBASE, 1, NULL};
static SqNative g_nat_cls_instance = {NAT_CLS_INSTANCE, 1, NULL};
static SqNative g_nat_inst_getclass = {NAT_INST_GETCLASS, 1, NULL};
static SqNative g_nat_cls_getattributes = {NAT_CLS_GETATTRIBUTES, 2, "y."};
static SqNative g_nat_cls_setattributes = {NAT_CLS_SETATTRIBUTES, 3, "y.."};
static SqNative g_nat_arr_sort = {NAT_ARR_SORT, -1, "ac"};      /* sqbaselib.cpp array_sort */
static SqNative g_nat_arr_map = {NAT_ARR_MAP, 2, "ac"};         /* array_map */
static SqNative g_nat_arr_apply = {NAT_ARR_APPLY, 2, "ac"};     /* array_apply */
static SqNative g_nat_arr_reduce = {NAT_ARR_REDUCE, -2, "ac."}; /* array_reduce */
static SqNative g_nat_arr_filter = {NAT_ARR_FILTER, 2, "ac"};   /* array_filter */

static SQV make_native(const SqNative *n) {
  SQV v;
  v.tag = SQBC_TAG_NATIVE;
  v.pad = 0;
  v.i = (int64_t)(intptr_t)n;
  return v;
}

/* Whether a value of tag TAG has the type of the typemask letter L (see SqNative). */
static int tag_has_type(uint32_t tag, char l) {
  switch (l) {
    case 'n': return tag == SQBC_TAG_INTEGER || tag == SQBC_TAG_FLOAT;
    case 'a': return tag == SQBC_TAG_ARRAY;
    case 's': return tag == SQBC_TAG_STRING;
    case 'x': return tag == SQBC_TAG_INSTANCE;
    case 'y': return tag == SQBC_TAG_CLASS;
    case 'c': return tag == SQBC_TAG_CLOSURE || tag == SQBC_TAG_NATIVE;
    default: return 1;
  }
}

/* The type text of the letter L in the parameter type error (sqdebug.cpp Raise_ParamTypeError, IdType2Name). A closure and
 * a native closure are both "function", so the reference's text for 'c' repeats it. */
static const char *expected_type(char l) {
  switch (l) {
    case 'n': return "integer|float";
    case 'a': return "array";
    case 's': return "string";
    case 'x': return "instance";
    case 'y': return "class";
    case 'c': return "function|function";
    default: return "any";
  }
}

/* The default delegate of SELF (sqvm.cpp InvokeDefaultDelegate, sqbaselib.cpp's delegate tables) for the string KEY: the
 * native in OUT and 1, or 0 when the delegate has no such method (or it is one that is not lowered). */
static int delegate_native(const SQV *self, const SQV *key, SQV *out) {
  const char *name = str_of(key)->chars;
  const SqNative *n = NULL;
  switch (self->tag) {
    case SQBC_TAG_STRING:
      if (strcmp(name, "len") == 0) n = &g_nat_str_len;
      else if (strcmp(name, "tofloat") == 0) n = &g_nat_str_tofloat;
      else if (strcmp(name, "tointeger") == 0) n = &g_nat_str_tointeger;
      else if (strcmp(name, "tostring") == 0) n = &g_nat_tostring;
      else if (strcmp(name, "slice") == 0) n = &g_nat_str_slice;
      else if (strcmp(name, "find") == 0) n = &g_nat_str_find;
      else if (strcmp(name, "tolower") == 0) n = &g_nat_str_tolower;
      else if (strcmp(name, "toupper") == 0) n = &g_nat_str_toupper;
      break;
    case SQBC_TAG_ARRAY:
      if (strcmp(name, "len") == 0) n = &g_nat_arr_len;
      else if (strcmp(name, "append") == 0 || strcmp(name, "push") == 0) n = &g_nat_arr_append;
      else if (strcmp(name, "pop") == 0) n = &g_nat_arr_pop;
      else if (strcmp(name, "reverse") == 0) n = &g_nat_arr_reverse;
      else if (strcmp(name, "slice") == 0) n = &g_nat_arr_slice;
      else if (strcmp(name, "find") == 0) n = &g_nat_arr_find;
      else if (strcmp(name, "extend") == 0) n = &g_nat_arr_extend;
      else if (strcmp(name, "insert") == 0) n = &g_nat_arr_insert;
      else if (strcmp(name, "sort") == 0) n = &g_nat_arr_sort;
      else if (strcmp(name, "map") == 0) n = &g_nat_arr_map;
      else if (strcmp(name, "apply") == 0) n = &g_nat_arr_apply;
      else if (strcmp(name, "reduce") == 0) n = &g_nat_arr_reduce;
      else if (strcmp(name, "filter") == 0) n = &g_nat_arr_filter;
      else if (strcmp(name, "tostring") == 0) n = &g_nat_tostring;
      break;
    case SQBC_TAG_INTEGER:
    case SQBC_TAG_FLOAT:
    case SQBC_TAG_BOOL:
      if (strcmp(name, "tofloat") == 0) n = &g_nat_num_tofloat;
      else if (strcmp(name, "tointeger") == 0) n = &g_nat_num_tointeger;
      else if (strcmp(name, "tochar") == 0) n = &g_nat_num_tochar;
      else if (strcmp(name, "tostring") == 0) n = &g_nat_tostring;
      break;
    case SQBC_TAG_TABLE:
      if (strcmp(name, "tostring") == 0) n = &g_nat_tostring;
      break;
    case SQBC_TAG_CLASS:
      if (strcmp(name, "rawget") == 0) n = &g_nat_rawget;
      else if (strcmp(name, "rawset") == 0) n = &g_nat_rawset;
      else if (strcmp(name, "rawin") == 0) n = &g_nat_rawin;
      else if (strcmp(name, "getbase") == 0) n = &g_nat_cls_getbase;
      else if (strcmp(name, "instance") == 0) n = &g_nat_cls_instance;
      else if (strcmp(name, "getattributes") == 0) n = &g_nat_cls_getattributes;
      else if (strcmp(name, "setattributes") == 0) n = &g_nat_cls_setattributes;
      break;
    case SQBC_TAG_INSTANCE:
      if (strcmp(name, "getclass") == 0) n = &g_nat_inst_getclass;
      else if (strcmp(name, "rawget") == 0) n = &g_nat_rawget;
      else if (strcmp(name, "rawset") == 0) n = &g_nat_rawset;
      else if (strcmp(name, "rawin") == 0) n = &g_nat_rawin;
      else if (strcmp(name, "tostring") == 0) n = &g_nat_tostring;
      break;
    default: break;
  }
  if (!n) return 0;
  *out = make_native(n);
  return 1;
}

/* The methods of the class, instance, array and string delegates that are not lowered (sqbaselib.cpp): a call of one is
 * `unsupported ... method` at run time. */
static int is_class_method(const char *name) {
  static const char *const names[] = {"weakref", "newmember", "rawnewmember"};
  for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
    if (strcmp(name, names[i]) == 0) return 1;
  return 0;
}

static int is_instance_method(const char *name) {
  static const char *const names[] = {"weakref"};
  for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
    if (strcmp(name, names[i]) == 0) return 1;
  return 0;
}

static int is_array_method(const char *name) {
  static const char *const names[] = {"top", "remove", "resize", "weakref", "clear"};
  for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
    if (strcmp(name, names[i]) == 0) return 1;
  return 0;
}

static int is_string_method(const char *name) {
  static const char *const names[] = {"weakref"};
  for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
    if (strcmp(name, names[i]) == 0) return 1;
  return 0;
}

/* ---- classes and instances ------------------------------------------------------------------------------------------ */

static void refuse_float_key(const SQV *k);

/* A member of a class (sqclass.h's members table and its field and method lists, as one list). An instance field has
 * is_field 1 and its value in the instance, at index idx; `val` is its default. A method, or a static member, is shared
 * by the class: `val` is its value. */
typedef struct SqMember {
  SQV key;
  SQV val;
  int is_field;
  int idx;
  SQV attrs; /* the member's attributes (SQClass::SetAttributes), null when it has none */
} SqMember;

typedef struct SqClass {
  SqMember *members;
  size_t count;
  size_t cap;
  int nfields;
  int locked; /* set by the first instance: the class can no longer get a field (SQClass::NewSlot) */
  int ctor;   /* the member index of `constructor`, or -1 */
  struct SqClass *base; /* the class this one extends, or NULL */
  SQV attrs;            /* the class's attributes (CLASS_OP), null when it has none */
  SQV mm[MT_LAST];      /* the metamethods (SQClass::_metamethods): a closure, or a tag 0 when there is none */
} SqClass;

typedef struct SqInstance {
  SqClass *cls;
  SQV *values; /* the class's nfields fields */
} SqInstance;

static SqClass *class_of(const SQV *v) { return (SqClass *)(intptr_t)v->i; }
static SqInstance *inst_of(const SQV *v) { return (SqInstance *)(intptr_t)v->i; }

/* The metamethod MM of a class, or NULL (SQClass::GetMetaMethod). */
static const SQV *class_mm(const SqClass *c, int mm) { return c->mm[mm].tag ? &c->mm[mm] : NULL; }

/* SQInstance::GetMetaMethod: the metamethod of the instance's class, or NULL. A class or any other value has none. */
static const SQV *inst_mm(const SQV *self, int mm) {
  if (self->tag != SQBC_TAG_INSTANCE) return NULL;
  return class_mm(inst_of(self)->cls, mm);
}

static SqMember *class_find(SqClass *c, const SQV *key) {
  for (size_t i = 0; i < c->count; i++)
    if (key_eq(&c->members[i].key, key)) return &c->members[i];
  return NULL;
}

static SqMember *class_add(SqClass *c, const SQV *key, const SQV *val, int is_field) {
  if (c->count == c->cap) {
    size_t cap = c->cap ? c->cap * 2 : 4;
    SqMember *m = realloc(c->members, cap * sizeof(SqMember));
    if (!m) rt_error("out of memory");
    c->members = m;
    c->cap = cap;
  }
  SqMember *m = &c->members[c->count++];
  m->key = *key;
  m->val = *val;
  m->is_field = is_field;
  m->idx = is_field ? c->nfields++ : -1;
  m->attrs.tag = SQBC_TAG_NULL;
  m->attrs.pad = 0;
  m->attrs.i = 0;
  return m;
}

static SQV class_val(SqClass *c) {
  SQV v;
  v.tag = SQBC_TAG_CLASS;
  v.pad = 0;
  v.i = (int64_t)(intptr_t)c;
  return v;
}

void sqbc_rt_newclass(SQV *dst, const SQV *base, const SQV *attrs) {
  SqClass *c = calloc(1, sizeof *c);
  if (!c) rt_error("out of memory");
  c->ctor = -1;
  SQV attrs_val;
  attrs_val.tag = SQBC_TAG_NULL;
  attrs_val.pad = 0;
  attrs_val.i = 0;
  if (attrs) attrs_val = *attrs; /* CLASS_OP: a class without attributes has null (not the base's) */
  if (base) {
    /* CLASS_OP (sqvm.cpp): the base must be a class; the new class has the base's members (SQClass::SQClass). */
    if (base->tag != SQBC_TAG_CLASS) {
      char msg[96];
      snprintf(msg, sizeof msg, "trying to inherit from a %s", type_name(base->tag));
      rt_error(msg);
    }
    SqClass *b = class_of(base);
    c->base = b;
    c->nfields = b->nfields;
    c->ctor = b->ctor;
    if (b->count > 0) {
      c->members = malloc(b->count * sizeof(SqMember));
      if (!c->members) rt_error("out of memory");
      memcpy(c->members, b->members, b->count * sizeof(SqMember));
      c->count = c->cap = b->count;
    }
    /* SQClass::SQClass copies the base's metamethods. */
    memcpy(c->mm, b->mm, sizeof c->mm);
  }
  c->attrs = attrs_val; /* the reference sets the attributes after the _inherited call (CLASS_OP) */
  SQV cv = class_val(c);
  if (base) {
    /* CLASS_OP: the new class is pushed and the base's _inherited metamethod is called with it as `this` and the class
     * attributes as its parameter. Its result is ignored. */
    const SQV *m = class_mm(c, MT_INHERITED);
    if (m) {
      SQV f = *m;
      SQV args[2] = {cv, attrs_val}, r;
      call_from_native(&f, &r, args, 2);
    }
  }
  *dst = cv;
}

/* The metamethod named by key K (sqobject.h MM_*), or -1. Only a closure with one of these names is a metamethod. */
static int mm_index(const SQV *k) {
  static const char *const names[MT_LAST] = {"_add",   "_sub",     "_mul",     "_div",        "_unm",     "_modulo",
                                              "_set",   "_get",     "_typeof",  "_nexti",      "_cmp",     "_call",
                                              "_cloned", "_newslot", "_delslot", "_tostring",  "_newmember",
                                              "_inherited"};
  if (k->tag != SQBC_TAG_STRING) return -1;
  for (int i = 0; i < MT_LAST; i++)
    if (strcmp(str_of(k)->chars, names[i]) == 0) return i;
  return -1;
}

/* SQClass::NewSlot (sqclass.cpp), with the checks of SQVM::NewSlot: a closure or a static member is a shared member, any
 * other value is a field; a class with an instance takes only shared members; a name that is a method already is not
 * changed by a field of the same name (the reference's table keeps the method). */
/* A closure of a class with a base is a copy of it that knows the base (SQClass::NewSlot: `_closure(theval)->_base`), for
 * GETBASE. The copy shares the outer variables of the original. */
static SQV closure_with_base(const SQV *v, SqClass *base) {
  SqClosure *src = (SqClosure *)(intptr_t)v->i; /* closure_of, defined further down */
  SqClosure *c = calloc(1, sizeof *c);
  if (!c) rt_error("out of memory");
  *c = *src;
  if (src->nouters > 0) {
    c->outers = calloc((size_t)src->nouters, sizeof(SqOuter *));
    if (!c->outers) rt_error("out of memory");
    memcpy(c->outers, src->outers, (size_t)src->nouters * sizeof(SqOuter *));
  }
  c->base = base;
  SQV r;
  r.tag = SQBC_TAG_CLOSURE;
  r.pad = 0;
  r.i = (int64_t)(intptr_t)c;
  return r;
}

/* Returns 0 when the class refuses the slot (a non-shared member of a class already instantiated), with nothing done. */
static int class_try_newslot(SqClass *c, const SQV *k, const SQV *v, int bstatic) {
  int shared = v->tag == SQBC_TAG_CLOSURE || v->tag == SQBC_TAG_NATIVE || bstatic;
  if (c->locked && !shared) return 0;
  SqMember *m = class_find(c, k);
  if (m && m->is_field) {
    m->val = *v; /* a field's default value is replaced, shared or not */
    return 1;
  }
  if (!shared) {
    if (!m) class_add(c, k, v, 1);
    return 1;
  }
  /* SQClass::NewSlot: a closure named as a metamethod is the metamethod, and the members are not touched (no closure
   * copy, no member). */
  int mmi = (v->tag == SQBC_TAG_CLOSURE || v->tag == SQBC_TAG_NATIVE) ? mm_index(k) : -1;
  if (mmi >= 0) {
    c->mm[mmi] = *v;
    return 1;
  }
  SQV theval = *v;
  if (c->base && v->tag == SQBC_TAG_CLOSURE) theval = closure_with_base(v, c->base);
  if (m) {
    m->val = theval;
    return 1;
  }
  class_add(c, k, &theval, 0);
  if (k->tag == SQBC_TAG_STRING && strcmp(str_of(k)->chars, "constructor") == 0) c->ctor = (int)(c->count - 1);
  return 1;
}

static void class_newslot(SqClass *c, const SQV *k, const SQV *v, int bstatic) {
  if (!class_try_newslot(c, k, v, bstatic)) rt_error("trying to modify a class that has already been instantiated");
}

/* SQVM::Get on an instance or a class: a field of an instance is its value; anything else is the member's value. */
static int class_get(const SQV *self, const SQV *key, SQV *out) {
  SqClass *c = self->tag == SQBC_TAG_INSTANCE ? inst_of(self)->cls : class_of(self);
  SqMember *m = class_find(c, key);
  if (!m) return 0;
  if (m->is_field && self->tag == SQBC_TAG_INSTANCE) *out = inst_of(self)->values[m->idx];
  else *out = m->val;
  return 1;
}

/* CreateClassInstance (sqvm.cpp): the class is locked, and the instance has the class's field defaults. */
static SQV make_instance(SqClass *c) {
  SqInstance *in = calloc(1, sizeof *in);
  if (!in) rt_error("out of memory");
  in->cls = c;
  in->values = calloc(c->nfields > 0 ? (size_t)c->nfields : 1, sizeof(SQV));
  if (!in->values) rt_error("out of memory");
  for (size_t i = 0; i < c->count; i++)
    if (c->members[i].is_field) in->values[c->members[i].idx] = c->members[i].val;
  for (SqClass *b = c; b; b = b->base) b->locked = 1; /* SQClass::Lock locks the base too */
  SQV v;
  v.tag = SQBC_TAG_INSTANCE;
  v.pad = 0;
  v.i = (int64_t)(intptr_t)in;
  return v;
}

void sqbc_rt_newslota(const SQV *self, const SQV *key, const SQV *val, int bstatic, const SQV *attrs) {
  SQV s = *self, k = *key, v = *val;
  if (s.tag != SQBC_TAG_CLASS) rt_error("object must be a class");
  /* sqvm.cpp NewSlotA (not raw): a class with a _newmember metamethod is called with the class as `this` and the key, the
   * value, the attributes (null when none) and the static flag; the member is then not added, nor its attributes set. */
  const SQV *nm = class_mm(class_of(&s), MT_NEWMEMBER);
  if (nm) {
    SQV f = *nm;
    SQV args[5], r;
    args[0] = s;
    args[1] = k;
    args[2] = v;
    args[3] = attrs ? *attrs : make_null();
    args[4] = make_bool(bstatic);
    call_from_native(&f, &r, args, 5);
    return;
  }
  if (k.tag == SQBC_TAG_NULL) rt_error("null cannot be used as index");
  refuse_float_key(&k);
  class_newslot(class_of(&s), &k, &v, bstatic);
  /* sqvm.cpp NewSlotA: after the slot, the attributes are set on the member, unless they are null. */
  if (attrs && attrs->tag != SQBC_TAG_NULL) class_find(class_of(&s), &k)->attrs = *attrs;
}

/* ---- the stack and the root table ----------------------------------------------------------------------------------- */

static SQV *g_stack_end;
static SQV g_root;
/* The first value above the running frame: the frame of a closure ends at its stacksize, and a native's frame ends after its
 * arguments (sqbc_rt_call sets it and restores it). A native that calls a closure builds the callee's frame here. */
static SQV *g_top;

/* The main function's frame (sq_fn_0 calls it first): the first value above it is its end, as sqbc_rt_call sets it for a
 * closure. */
void sqbc_rt_enter(SQV *base, int stacksize) {
  if (base + stacksize > g_stack_end) rt_error("stack overflow");
  g_top = base + stacksize;
}

void sqbc_rt_init(SQV *base, size_t nslots) {
  g_stack_end = base + nslots;
  g_top = base;
  g_root = make_table_val();
  /* The base library in the root table: print only (sqbaselib.cpp). */
  SQV key = make_string("print", 5);
  SQV fn = make_native(&g_nat_print);
  table_newslot(tbl(&g_root), &key, &fn);
  base[0] = g_root;
}

void sqbc_rt_newtable(SQV *dst) {
  SQV v = make_table_val();
  *dst = v;
}

/* The default values of the closure being made, stashed by sqbc_rt_default_stash before sqbc_rt_closure takes them. */
#define SQBC_MAX_DEFAULTS 64
static SQV g_defs_stash[SQBC_MAX_DEFAULTS];

void sqbc_rt_default_stash(int i, const SQV *val) {
  if (i < 0 || i >= SQBC_MAX_DEFAULTS) rt_error("too many default parameters");
  g_defs_stash[i] = *val;
}

void sqbc_rt_closure(SQV *dst, int fn, int nparams, int stacksize, const SQV *env, int nouters, int varparams, int ndef) {
  SqClosure *c = calloc(1, sizeof *c);
  if (!c) rt_error("out of memory");
  c->fn = fn;
  c->nparams = nparams;
  c->stacksize = stacksize;
  c->nouters = nouters;
  c->varparams = varparams;
  c->ndef = ndef;
  if (ndef > 0) {
    /* CLOSURE_OP: the defaults are the values of their registers when the closure is made (the stash). */
    c->defs = calloc((size_t)ndef, sizeof *c->defs);
    if (!c->defs) rt_error("out of memory");
    for (int i = 0; i < ndef; i++) c->defs[i] = g_defs_stash[i];
  }
  if (nouters > 0) {
    c->outers = calloc((size_t)nouters, sizeof(SqOuter *));
    if (!c->outers) rt_error("out of memory");
  }
  if (env) {
    if (env->tag != SQBC_TAG_TABLE) {
      char msg[128];
      snprintf(msg, sizeof msg, "cannot bind a %s as environment object", type_name(env->tag));
      rt_error(msg);
    }
    c->has_env = 1;
    c->env = *env;
  }
  SQV v;
  v.tag = SQBC_TAG_CLOSURE;
  v.pad = 0;
  v.i = (int64_t)(intptr_t)c;
  *dst = v;
}

static SqClosure *closure_of(const SQV *v) { return (SqClosure *)(intptr_t)v->i; }


void sqbc_rt_outer_local(SQV *dst, int idx, SQV *slot) {
  closure_of(dst)->outers[idx] = find_outer(slot);
}

void sqbc_rt_outer_outer(SQV *dst, int idx, const SQV *cur, int src) {
  closure_of(dst)->outers[idx] = closure_of(cur)->outers[src];
}

void sqbc_rt_getouter(SQV *dst, const SQV *clo, int idx) {
  SQV v = *closure_of(clo)->outers[idx]->valptr;
  *dst = v;
}

void sqbc_rt_setouter(const SQV *clo, int idx, const SQV *val) {
  SQV v = *val;
  *closure_of(clo)->outers[idx]->valptr = v;
}

void sqbc_rt_close(SQV *from) { close_outers(from); }

/* GETBASE: the class the running closure's class extends, or null (the main function has no closure). */
void sqbc_rt_getbase(SQV *dst, const SQV *clo) {
  SQV r;
  r.tag = SQBC_TAG_NULL;
  r.pad = 0;
  r.i = 0;
  if (clo && clo->tag == SQBC_TAG_CLOSURE && closure_of(clo)->base) r = class_val(closure_of(clo)->base);
  *dst = r;
}

/* ---- Get, Set, NewSlot ---------------------------------------------------------------------------------------------- */

static void raise_idx(const SQV *k) {
  char buf[32];
  char msg[160];
  const char *text = print_obj(k, buf, sizeof buf);
  snprintf(msg, sizeof msg, "the index '%.50s' does not exist", text);
  rt_error(msg);
}

/* A float as a key: the table and array lookups of the subset are by the raw value, which the reference's hashing of
 * floats is not; not lowered. */
static void refuse_float_key(const SQV *k) {
  if (k->tag == SQBC_TAG_FLOAT) rt_error("float keys are not lowered");
}

void sqbc_rt_get(SQV *dst, const SQV *self, const SQV *key, int root_fallback) {
  SQV s = *self, k = *key, out;
  refuse_float_key(&k);
  if (s.tag == SQBC_TAG_TABLE) {
    TNode *n = table_find(tbl(&s), &k);
    if (n) {
      out = n->val;
      *dst = out;
      return;
    }
  } else if (s.tag == SQBC_TAG_ARRAY && k.tag == SQBC_TAG_INTEGER) {
    /* sqvm.cpp Get: an integer index out of range is an error at once, with no fallback to the root table. */
    SqArray *a = array_of(&s);
    if (k.i < 0 || (uint64_t)k.i >= (uint64_t)a->count) raise_idx(&k);
    out = a->items[k.i];
    *dst = out;
    return;
  } else if ((s.tag == SQBC_TAG_CLASS || s.tag == SQBC_TAG_INSTANCE) && class_get(&s, &k, &out)) {
    *dst = out;
    return;
  } else if (s.tag == SQBC_TAG_STRING && k.tag == SQBC_TAG_INTEGER) {
    /* sqvm.cpp Get: the byte at that position (negative counts from the end), as a signed integer. */
    SqStr *str = str_of(&s);
    int64_t n = k.i;
    if (n < 0) n += (int64_t)str->len;
    if (n >= 0 && n < (int64_t)str->len) {
      out.tag = SQBC_TAG_INTEGER;
      out.pad = 0;
      out.i = (int64_t)(signed char)str->chars[n];
      *dst = out;
      return;
    }
    raise_idx(&k);
  }
  /* FallBackGet (sqvm.cpp): a miss on an instance calls its class's _get with the key, before the default delegate and the
   * root table. The closure's result is the value. */
  const SQV *gm = inst_mm(&s, MT_GET);
  if (gm) {
    SQV f = *gm;
    SQV args[2] = {s, k};
    call_from_native(&f, &out, args, 2);
    *dst = out;
    return;
  }
  /* The default delegate, then the root table (selfidx 0). */
  if (k.tag == SQBC_TAG_STRING && delegate_native(&s, &k, &out)) {
    *dst = out;
    return;
  }
  if (root_fallback) {
    TNode *n = table_find(tbl(&g_root), &k);
    if (n) {
      out = n->val;
      *dst = out;
      return;
    }
  }
  if (k.tag == SQBC_TAG_STRING) {
    char msg[160];
    if (s.tag == SQBC_TAG_CLASS && is_class_method(str_of(&k)->chars)) {
      snprintf(msg, sizeof msg, "unsupported class method '%.50s' (not lowered)", str_of(&k)->chars);
      rt_error(msg);
    }
    if (s.tag == SQBC_TAG_INSTANCE && is_instance_method(str_of(&k)->chars)) {
      snprintf(msg, sizeof msg, "unsupported instance method '%.50s' (not lowered)", str_of(&k)->chars);
      rt_error(msg);
    }
    if (s.tag == SQBC_TAG_STRING && is_string_method(str_of(&k)->chars)) {
      snprintf(msg, sizeof msg, "unsupported string method '%.50s' (not lowered)", str_of(&k)->chars);
      rt_error(msg);
    }
    if (s.tag == SQBC_TAG_ARRAY && is_array_method(str_of(&k)->chars)) {
      snprintf(msg, sizeof msg, "unsupported array method '%.50s' (not lowered)", str_of(&k)->chars);
      rt_error(msg);
    }
  }
  raise_idx(&k);
}

void sqbc_rt_set(const SQV *self, const SQV *key, const SQV *val, int root_fallback) {
  SQV s = *self, k = *key, v = *val;
  refuse_float_key(&k);
  if (s.tag == SQBC_TAG_TABLE) {
    TNode *n = table_find(tbl(&s), &k);
    if (n) {
      n->val = v;
      return;
    }
  } else if (s.tag == SQBC_TAG_ARRAY) {
    /* sqvm.cpp Set: a key that is not an integer is an error; an index out of range is an error, with no root fallback. */
    if (k.tag != SQBC_TAG_INTEGER) {
      char msg[96];
      snprintf(msg, sizeof msg, "indexing %s with %s", type_name(s.tag), type_name(k.tag));
      rt_error(msg);
    }
    SqArray *a = array_of(&s);
    if (k.i < 0 || (uint64_t)k.i >= (uint64_t)a->count) raise_idx(&k);
    a->items[k.i] = v;
    return;
  } else if (s.tag == SQBC_TAG_INSTANCE) {
    /* sqvm.cpp Set: a field of the instance; anything else goes to FallBackSet, the class's _set (called with the key and
     * the value; its result is not used), then the root fallback, then the index error. */
    SqMember *m = class_find(inst_of(&s)->cls, &k);
    if (m && m->is_field) {
      inst_of(&s)->values[m->idx] = v;
      return;
    }
    const SQV *sm = inst_mm(&s, MT_SET);
    if (sm) {
      SQV f = *sm;
      SQV args[3] = {s, k, v}, r;
      call_from_native(&f, &r, args, 3);
      return;
    }
  } else {
    /* sqvm.cpp Set, default case. */
    char msg[64];
    snprintf(msg, sizeof msg, "trying to set '%s'", type_name(s.tag));
    rt_error(msg);
  }
  if (root_fallback) {
    TNode *n = table_find(tbl(&g_root), &k);
    if (n) {
      n->val = v;
      return;
    }
  }
  raise_idx(&k);
}

void sqbc_rt_newslot(const SQV *self, const SQV *key, const SQV *val) {
  SQV s = *self, k = *key, v = *val;
  if (k.tag == SQBC_TAG_NULL) rt_error("null cannot be used as index");
  refuse_float_key(&k);
  if (s.tag == SQBC_TAG_TABLE) {
    table_newslot(tbl(&s), &k, &v);
    return;
  }
  if (s.tag == SQBC_TAG_CLASS) {
    class_newslot(class_of(&s), &k, &v, 0);
    return;
  }
  if (s.tag == SQBC_TAG_INSTANCE) {
    /* SQVM::NewSlot: an instance's _newslot metamethod, with the key and the value; else the error. */
    const SQV *nm = inst_mm(&s, MT_NEWSLOT);
    if (nm) {
      SQV f = *nm;
      SQV args[3] = {s, k, v}, r;
      call_from_native(&f, &r, args, 3);
      return;
    }
    rt_error("class instances do not support the new slot operator");
  }
  char msg[96];
  snprintf(msg, sizeof msg, "indexing %s with %s", type_name(s.tag), type_name(k.tag));
  rt_error(msg);
}

/* ---- calls ---------------------------------------------------------------------------------------------------------- */

/* ---- the base library's methods of numbers, strings, arrays, classes and instances (sqbaselib.cpp) ------------------------ */

static SQV make_int(int64_t i) {
  SQV v;
  v.tag = SQBC_TAG_INTEGER;
  v.pad = 0;
  v.i = i;
  return v;
}

static SQV make_bool(int b) {
  SQV v;
  v.tag = SQBC_TAG_BOOL;
  v.pad = 0;
  v.i = b ? 1 : 0;
  return v;
}

static SQV make_null(void) {
  SQV v;
  v.tag = SQBC_TAG_NULL;
  v.pad = 0;
  v.i = 0;
  return v;
}

/* tointeger and tofloat of a number or a boolean (sqobject.h): a float truncates; a boolean is 0 or 1 (its payload). */
static int64_t number_to_int(const SQV *v) { return v->tag == SQBC_TAG_FLOAT ? (int64_t)float_of(v) : v->i; }

static float number_to_float(const SQV *v) { return v->tag == SQBC_TAG_FLOAT ? float_of(v) : (float)v->i; }

/* str2num (sqbaselib.cpp): the number that TEXT starts with, in BASE. A text with a '.' (or an exponent, in a base of 13 or
 * less) is a float. False when no number starts the text; what follows the number is not looked at. */
static int str_to_num(const char *text, int64_t base, SQV *res) {
  int iseintbase = base > 13;
  int isfloat = 0;
  for (const char *p = text; *p; p++) {
    if (*p == '.' || (!iseintbase && (*p == 'E' || *p == 'e'))) {
      isfloat = 1;
      break;
    }
  }
  char *end = (char *)text;
  if (isfloat) {
    float r = (float)strtod(text, &end);
    if (text == end) return 0;
    *res = make_float(r);
  } else {
    long long r = strtoll(text, &end, (int)base);
    if (text == end) return 0;
    *res = make_int((int64_t)r);
  }
  return 1;
}

/* array.reverse (sq_arrayreverse): the items in reverse order, in place. */
static void array_reverse_items(const SQV *self) {
  SqArray *a = array_of(self);
  for (size_t i = 0; i < a->count / 2; i++) {
    SQV t = a->items[i];
    a->items[i] = a->items[a->count - 1 - i];
    a->items[a->count - 1 - i] = t;
  }
}

/* array.slice (sqbaselib.cpp array_slice, get_slice_params): a new array of the items from START up to END. A missing or
 * negative index counts from the start or the end; the typemask has made START and END numbers. */
static void slice_bounds(const SQV *frame, int nargs, int64_t len, int64_t *sp, int64_t *ep) {
  int64_t sidx = 0, eidx = 0;
  if (nargs > 1 && is_number(&frame[1])) sidx = number_to_int(&frame[1]);
  if (nargs > 2) {
    if (is_number(&frame[2])) eidx = number_to_int(&frame[2]);
  } else {
    eidx = len;
  }
  if (sidx < 0) sidx = len + sidx;
  if (eidx < 0) eidx = len + eidx;
  if (eidx < sidx) rt_error("wrong indexes");
  if (eidx > len || sidx < 0) rt_error("slice out of range");
  *sp = sidx;
  *ep = eidx;
}

static SQV array_slice_of(const SQV *self, const SQV *frame, int nargs) {
  SqArray *a = array_of(self);
  int64_t sidx, eidx;
  slice_bounds(frame, nargs, (int64_t)a->count, &sidx, &eidx);
  SQV r = make_array_val((size_t)(eidx - sidx));
  for (int64_t i = sidx; i < eidx; i++) sqbc_rt_append(&r, &a->items[i]);
  return r;
}

/* array.insert (sqbaselib.cpp array_insert, SQArray::Insert): VAL goes before item IDX, which is at most the count. */
static void array_insert_at(const SQV *self, int64_t idx, const SQV *val) {
  SqArray *a = array_of(self);
  if (idx < 0 || idx > (int64_t)a->count) rt_error("index out of range");
  SQV v = *val;
  sqbc_rt_append(self, &v);
  memmove(a->items + idx + 1, a->items + idx, (a->count - 1 - (size_t)idx) * sizeof(SQV));
  a->items[idx] = v;
}

/* string.slice (sqbaselib.cpp string_slice): the bytes from START up to END, as a new string. */
static SQV string_slice_of(const SQV *self, const SQV *frame, int nargs) {
  SqStr *s = str_of(self);
  int64_t sidx, eidx;
  slice_bounds(frame, nargs, (int64_t)s->len, &sidx, &eidx);
  return make_string(s->chars + sidx, (size_t)(eidx - sidx));
}

/* string.find (sqbaselib.cpp string_find): the index of the first SUB at or after START (strstr, as the reference
 * does: a NUL byte ends the text), or null when there is none or START is past the end. */
static SQV string_find_of(const SQV *self, const SQV *frame, int nargs) {
  SqStr *s = str_of(self);
  int64_t start = nargs > 2 ? number_to_int(&frame[2]) : 0;
  if ((int64_t)s->len > start && start >= 0) {
    const char *hit = strstr(s->chars + start, str_of(&frame[1])->chars);
    if (hit) return make_int((int64_t)(hit - s->chars));
  }
  return make_null();
}

/* string.tolower and toupper (sqbaselib.cpp STRING_TOFUNCZ): the whole string, with the bytes from START up to END
 * changed (the reference copies the whole text and converts only that range). */
static SQV string_case_of(const SQV *self, const SQV *frame, int nargs, int upper) {
  SqStr *s = str_of(self);
  int64_t sidx, eidx;
  slice_bounds(frame, nargs, (int64_t)s->len, &sidx, &eidx);
  char *snew = malloc(s->len + 1);
  if (!snew) rt_error("out of memory");
  memcpy(snew, s->chars, s->len);
  for (int64_t i = sidx; i < eidx; i++)
    snew[i] = (char)(upper ? toupper((unsigned char)snew[i]) : tolower((unsigned char)snew[i]));
  SQV r = make_string(snew, s->len);
  free(snew);
  return r;
}

/* array.find (sqbaselib.cpp array_find): the index of the first item equal to VAL (IsEqual), or null. */
static SQV array_find_of(const SQV *self, const SQV *val) {
  SqArray *a = array_of(self);
  for (size_t i = 0; i < a->count; i++)
    if (sqbc_rt_equal(&a->items[i], val)) return make_int((int64_t)i);
  return make_null();
}

/* rawget and rawin of a class or an instance (sqbaselib.cpp container_rawget, container_rawexists; sqapi.cpp sq_rawget):
 * a member (a field or a shared member) by its key, with no metamethods. */
static SQV raw_get_member(const SQV *self, const SQV *key) {
  SQV out;
  refuse_float_key(key);
  if (!class_get(self, key, &out)) rt_error("the index doesn't exist");
  return out;
}

static SQV raw_in_member(const SQV *self, const SQV *key) {
  SqClass *c = self->tag == SQBC_TAG_INSTANCE ? inst_of(self)->cls : class_of(self);
  refuse_float_key(key);
  return make_bool(class_find(c, key) != NULL);
}

/* rawset (sqbaselib.cpp container_rawset; sqapi.cpp sq_rawset). A class takes the member as NewSlot does, and a refused
 * one (a field of a class already instantiated) is silently not done; an instance takes only one of its fields. */
static void raw_set_member(const SQV *self, const SQV *key, const SQV *val) {
  if (key->tag == SQBC_TAG_NULL) rt_error("null key");
  refuse_float_key(key);
  if (self->tag == SQBC_TAG_CLASS) {
    class_try_newslot(class_of(self), key, val, 0);
    return;
  }
  SqMember *m = class_find(inst_of(self)->cls, key);
  if (!m || !m->is_field) raise_idx(key);
  inst_of(self)->values[m->idx] = *val;
}

/* ---- ObjCmp, and the array methods that call a closure -------------------------------------------------------------- */

/* ObjCmp (sqvm.cpp): -1 when X orders before Y, 0 when they are the same value and 1 otherwise. Two values of one type
 * compare by their raw value first (so equal bits are 0, and -0.0 is not equal to 0.0), then by value; an integer and a
 * float compare as floats; null is before anything else. Any other pair raises the comparison error. */
static int64_t obj_cmp(const SQV *x, const SQV *y) {
  if (x->tag == y->tag) {
    if (x->i == y->i) return 0;
    /* ObjCmp: a table, userdata or instance whose class has _cmp is compared by it, with the other value as its
     * parameter; the result must be an integer and is the comparison's value as it is. */
    const SQV *cm = inst_mm(x, MT_CMP);
    if (cm) {
      SQV f = *cm;
      SQV args[2] = {*x, *y}, res;
      call_from_native(&f, &res, args, 2);
      if (res.tag != SQBC_TAG_INTEGER) rt_error("_cmp must return an integer");
      return res.i;
    }
    switch (x->tag) {
      case SQBC_TAG_STRING: {
        /* scstrcmp: the bytes in order, a proper prefix first. */
        SqStr *s1 = str_of(x), *s2 = str_of(y);
        size_t m = s1->len < s2->len ? s1->len : s2->len;
        int c = memcmp(s1->chars, s2->chars, m);
        if (c != 0) return c < 0 ? -1 : 1;
        return s1->len < s2->len ? -1 : (s1->len > s2->len ? 1 : 0);
      }
      case SQBC_TAG_INTEGER: return x->i < y->i ? -1 : 1;
      case SQBC_TAG_FLOAT: return float_of(x) < float_of(y) ? -1 : 1;
      default:
        /* Booleans, and the reference's default branch: the raw values (a pointer or a boolean) compare. */
        return (uint64_t)x->i < (uint64_t)y->i ? -1 : 1;
    }
  }
  if (is_number(x) && is_number(y)) {
    /* An integer and a float: both as floats. */
    float f1 = number_as_float(x), f2 = number_as_float(y);
    return f1 == f2 ? 0 : (f1 < f2 ? -1 : 1);
  }
  if (x->tag == SQBC_TAG_NULL) return -1;
  if (y->tag == SQBC_TAG_NULL) return 1;
  char s1[64], s2[64], msg[160];
  const char *t1 = print_obj(x, s1, sizeof s1);
  const char *t2 = print_obj(y, s2, sizeof s2);
  snprintf(msg, sizeof msg, "comparison between '%.50s' and '%.50s'", t1, t2);
  rt_error(msg);
  return 0;
}

/* Calls CALLEE with the N values of ARGS (`this` first) in a frame built above the running one, at g_top: the callee's
 * registers cannot overlap the registers of a frame that is still running (the caller's registers above its call are
 * dead, as the reference's StartCall makes them). RET takes the result. The callee's frame and its closed outers are
 * handled by sqbc_rt_call, as for a call from the lowered code, and g_top is the same again when this returns. */
static void call_from_native(const SQV *callee, SQV *ret, const SQV *args, int n) {
  SQV *frame = g_top;
  if (frame + n > g_stack_end) rt_error("stack overflow");
  for (int i = 0; i < n; i++) frame[i] = args[i];
  sqbc_rt_call(callee, ret, frame, n);
}

/* The number of values __map_array (sqbaselib.cpp) pushes for FN: the parameter count of a closure, or of a native that
 * checks one, else 4. */
static int callback_nargs(const SQV *fn) {
  if (fn->tag == SQBC_TAG_CLOSURE) return ((const SqClosure *)(intptr_t)fn->i)->nparams;
  const SqNative *n = (const SqNative *)(intptr_t)fn->i;
  return n->nparams > 0 ? n->nparams : 4;
}

/* IsFalse (sqvm.cpp): a float is false when it is zero, anything else when its payload is 0. */
static int is_false(const SQV *v) { return v->tag == SQBC_TAG_FLOAT ? sqbc_rt_float_zero(v) : v->i == 0; }

/* __map_array: FN is called on each item of SRC with the values the reference pushes: `this` (the array), the item, the
 * index when FN takes three, and the array when it takes four. The result is stored at DST[n] (a store past the end of DST
 * is dropped, as SQArray::Set does). Past the end of SRC the item is the last one read: the reference keeps its
 * temporary. A callee that takes one parameter is called with the array below the item (the reference reads the callee
 * from there, and raises "attempt to call 'array'"). */
static void map_items(const SQV *src, const SQV *fn, SqArray *dst) {
  size_t size = array_of(src)->count;
  int nargs = callback_nargs(fn);
  /* The reference's stack for the call, as sqbaselib.cpp __map_array builds it: S[0] is the map's `this` (the array), S[1]
   * its argument (the callback), then the callback pushed once more, and then per item the array, the item, the index
   * (nargs >= 3) and the array (nargs >= 4). sq_call(nargs) takes the callee from the value below the nargs values on top,
   * pops the arguments, pushes the result and __map_array pops it. So the callback's own copy is consumed by a call whose
   * callee is S[1] (nargs 5): the next item then finds the array below, and fails. The values below S[0] are the caller's
   * stack, which is not modelled: a callee read there (nargs 7 and more) is refused. */
  SQV stk[8];
  int top = 0;
  stk[top++] = *src;
  stk[top++] = *fn;
  stk[top++] = *fn;
  SQV temp = make_null();
  for (size_t n = 0; n < size; n++) {
    SqArray *a = array_of(src);
    if (n < a->count) temp = a->items[n];
    stk[top++] = *src;
    stk[top++] = temp;
    if (nargs >= 3) stk[top++] = make_int((int64_t)n);
    if (nargs >= 4) stk[top++] = *src;
    int callee = top - nargs - 1;
    if (callee < 0)
      rt_error("callback with 6 or more parameters is not lowered (sq_call reads its callee below the map's frame)");
    SQV res;
    call_from_native(&stk[callee], &res, &stk[callee + 1], nargs);
    top -= nargs;
    if (n < dst->count) dst->items[n] = res;
  }
}

/* array.map (array_map): a new array of the results. */
static SQV array_map_of(const SQV *self, const SQV *fn) {
  size_t size = array_of(self)->count;
  SQV dst = make_array_val(size);
  for (size_t i = 0; i < size; i++) {
    SQV nul = make_null();
    sqbc_rt_append(&dst, &nul);
  }
  map_items(self, fn, array_of(&dst));
  return dst;
}

/* array.reduce (array_reduce): the initial value (or the first item) folded with the callback, which takes three values:
 * `this`, the accumulated value, the item. An empty array without an initial value is null. */
static SQV array_reduce_of(const SQV *self, const SQV *fn, int nargs, const SQV *init) {
  SqArray *a = array_of(self);
  size_t size = a->count;
  SQV res = make_null();
  size_t start;
  if (nargs > 2) {
    res = *init;
    start = 0;
  } else if (size == 0) {
    return make_null();
  } else {
    res = a->items[0];
    start = 1;
  }
  SQV other = make_null();
  for (size_t n = start; n < size; n++) {
    if (n < a->count) other = a->items[n];
    SQV args[3] = {*self, res, other};
    SQV next;
    call_from_native(fn, &next, args, 3);
    res = next;
  }
  return res;
}

/* array.filter (array_filter): a new array of the items for which the callback, given `this`, the index and the item,
 * is not false. */
static SQV array_filter_of(const SQV *self, const SQV *fn) {
  SqArray *a = array_of(self);
  size_t size = a->count;
  SQV ret = make_array_val(0);
  SQV val = make_null();
  for (size_t n = 0; n < size; n++) {
    if (n < a->count) val = a->items[n];
    SQV args[3] = {*self, make_int((int64_t)n), val};
    SQV keep;
    call_from_native(fn, &keep, args, 3);
    if (!is_false(&keep)) sqbc_rt_append(&ret, &val);
  }
  return ret;
}

/* One comparison of the sort: ObjCmp of items I and J (FN NULL), or the callback's result, which is an integer, a float
 * (truncated, as sq_getinteger does) or a boolean. The array must keep its size and its buffer while the callback runs. */
static int64_t sort_compare(SqArray *a, int64_t i, int64_t j, const SQV *fn) {
  if (!fn) return obj_cmp(&a->items[i], &a->items[j]);
  SQV args[3] = {g_root, a->items[i], a->items[j]};
  SQV res;
  size_t count = a->count;
  SQV *items = a->items;
  call_from_native(fn, &res, args, 3);
  int64_t r;
  if (res.tag == SQBC_TAG_INTEGER || res.tag == SQBC_TAG_BOOL) {
    r = res.i;
  } else if (res.tag == SQBC_TAG_FLOAT) {
    r = (int64_t)float_of(&res);
  } else {
    rt_error("numeric value expected as return value of the compare function");
    r = 0;
  }
  if (a->count != count || a->items != items) rt_error("array resized during sort operation");
  return r;
}

/* _hsort_sift_down (sqbaselib.cpp): a heap of items ROOT..BOTTOM, sifted down from ROOT. */
static void sort_sift_down(SqArray *a, int64_t root, int64_t bottom, const SQV *fn) {
  while (root * 2 <= bottom) {
    int64_t root2 = root * 2;
    int64_t maxChild;
    if (root2 == bottom) {
      maxChild = root2;
    } else {
      maxChild = sort_compare(a, root2, root2 + 1, fn) > 0 ? root2 : root2 + 1;
    }
    if (sort_compare(a, root, maxChild, fn) < 0) {
      if (root == maxChild) rt_error("inconsistent compare function");
      SQV t = a->items[root];
      a->items[root] = a->items[maxChild];
      a->items[maxChild] = t;
      root = maxChild;
    } else {
      break;
    }
  }
}

/* array.sort (array_sort, _hsort): a heapsort, in place, so equal items are not kept in order. FN is the comparison
 * function, or NULL for ObjCmp. */
static void array_sort_items(SqArray *a, const SQV *fn) {
  int64_t size = (int64_t)a->count;
  if (size <= 1) return;
  for (int64_t i = size / 2; i >= 0; i--) sort_sift_down(a, i, size - 1, fn);
  for (int64_t i = size - 1; i >= 1; i--) {
    SQV t = a->items[0];
    a->items[0] = a->items[i];
    a->items[i] = t;
    sort_sift_down(a, 0, i - 1, fn);
  }
}

void sqbc_rt_call(const SQV *callee, SQV *ret, SQV *frame, int nargs) {
  SQV clo = *callee;
  SQV scratch;
  if (!ret) ret = &scratch;
  if (clo.tag == SQBC_TAG_CLOSURE) {
    SqClosure *c = (SqClosure *)(intptr_t)clo.i;
    /* StartCall (sqvm.cpp): a vararg function takes the parameters before its last one, and the extra arguments go into an
     * array that is that last parameter (the reference nulls the arguments it packed). Otherwise the arguments must be the
     * parameters, or the missing ones are the last default parameters, whose values the closure has. */
    if (c->varparams) {
      int fixed = c->nparams - 1;
      if (nargs < fixed) {
        char msg[128];
        snprintf(msg, sizeof msg, "wrong number of parameters (%d passed, at least %d required)", nargs, fixed);
        rt_error(msg);
      }
      if (frame + fixed + 1 > g_stack_end) rt_error("stack overflow");
      SQV arr = make_array_val((size_t)(nargs - fixed));
      for (int k = fixed; k < nargs; k++) {
        sqbc_rt_append(&arr, &frame[k]);
        frame[k] = make_null();
      }
      frame[fixed] = arr;
    } else if (nargs != c->nparams) {
      int diff = c->nparams - nargs;
      if (!(nargs < c->nparams && c->ndef > 0 && diff <= c->ndef)) {
        char msg[128];
        snprintf(msg, sizeof msg, "wrong number of parameters (%d passed, %d required)", nargs, c->nparams);
        rt_error(msg);
      }
      if (frame + c->nparams > g_stack_end) rt_error("stack overflow");
      for (int k = 0; k < diff; k++) frame[nargs + k] = c->defs[c->ndef - diff + k];
    }
    if (frame + c->stacksize > g_stack_end) rt_error("stack overflow");
    if (c->has_env) frame[0] = c->env;
    /* The callee's closure value is copied: the caller's register may not hold it for the whole call. */
    SQV running = clo;
    SQV *outer_top = g_top;
    g_top = frame + c->stacksize;
    sq_dispatch(c->fn, ret, frame, &running);
    g_top = outer_top;
    /* LeaveFrame: the outer variables of the frame are closed (sqvm.cpp). */
    close_outers(frame);
    return;
  }
  if (clo.tag == SQBC_TAG_CLASS) {
    /* sqvm.cpp _OP_CALL of a class: the instance is the target, and the constructor, if the class has one, runs with the
     * instance as `this` (the frame's first value). Without a constructor the arguments are not used. */
    SqClass *c = class_of(&clo);
    SQV inst = make_instance(c);
    *ret = inst;
    if (c->ctor >= 0 && c->members[c->ctor].val.tag == SQBC_TAG_CLOSURE) {
      frame[0] = inst;
      SQV ctor = c->members[c->ctor].val;
      sqbc_rt_call(&ctor, NULL, frame, nargs);
    }
    return;
  }
  if (clo.tag == SQBC_TAG_INSTANCE && inst_mm(&clo, MT_CALL)) {
    /* sqvm.cpp _OP_CALL of an instance: the _call metamethod is called with the instance as `this`, and the call's nargs
     * values (the caller's `this` first) as its parameters. */
    SQV f = *inst_mm(&clo, MT_CALL);
    SQV *args = malloc(((size_t)nargs + 1) * sizeof *args);
    if (!args) rt_error("out of memory");
    args[0] = clo;
    for (int i = 0; i < nargs; i++) args[i + 1] = frame[i];
    call_from_native(&f, ret, args, nargs + 1);
    free(args);
    return;
  }
  if (clo.tag == SQBC_TAG_NATIVE) {
    const SqNative *nat = (const SqNative *)(intptr_t)clo.i;
    /* sqvm.cpp CallNative: the count (a minimum when negative) with this text, with no counts; then the types. */
    if (nat->nparams > 0 ? nargs != nat->nparams : nargs < -nat->nparams) rt_error("wrong number of parameters");
    if (nat->typemask) {
      size_t tm = strlen(nat->typemask);
      for (int i = 0; i < nargs && (size_t)i < tm; i++) {
        if (!tag_has_type(frame[i].tag, nat->typemask[i])) {
          char msg[160];
          snprintf(msg, sizeof msg, "parameter %d has an invalid type '%s' ; expected: '%s'", i,
                   type_name(frame[i].tag), expected_type(nat->typemask[i]));
          rt_error(msg);
        }
      }
    }
    char buf[32];
    const char *text;
    SQV r = make_null();
    /* A native that calls a closure builds its frame after the arguments (call_from_native). */
    SQV *outer_top = g_top;
    g_top = frame + nargs;
    switch (nat->id) {
      case NAT_PRINT:
        /* sqbaselib.cpp base_print: the text of the value, through the print function, with no newline of its own. */
        text_of(frame + 1, buf, sizeof buf, &text);
        printf("%s", text);
        break;
      case NAT_STR_LEN:
        r = make_int((int64_t)str_of(frame)->len);
        break;
      case NAT_ARR_LEN:
        r = make_int((int64_t)array_of(frame)->count);
        break;
      case NAT_TOSTRING: {
        size_t n = text_of(frame, buf, sizeof buf, &text);
        r = make_string(text, n);
        break;
      }
      case NAT_NUM_TOFLOAT: r = make_float(number_to_float(frame)); break;
      case NAT_NUM_TOINTEGER: r = make_int(number_to_int(frame)); break;
      case NAT_NUM_TOCHAR: {
        /* sqbaselib.cpp number_delegate_tochar: (SQChar)tointeger(o), a string of that one byte. */
        unsigned char c = (unsigned char)number_to_int(frame);
        r = make_string((const char *)&c, 1);
        break;
      }
      case NAT_STR_TOFLOAT:
      case NAT_STR_TOINTEGER: {
        /* default_delegate_tofloat / _tointeger: the text as a number (base 10, or the base argument); a text with no
         * number is "cannot convert the string". */
        int64_t base = nat->id == NAT_STR_TOINTEGER && nargs > 1 ? number_to_int(frame + 1) : 10;
        SQV res;
        if (!str_to_num(str_of(frame)->chars, base, &res)) rt_error("cannot convert the string");
        if (nat->id == NAT_STR_TOFLOAT) r = make_float(number_to_float(&res));
        else r = make_int(number_to_int(&res));
        break;
      }
      case NAT_ARR_APPEND:
        /* sq_arrayappend: the value is appended, and the result is the array. */
        sqbc_rt_append(frame, frame + 1);
        r = frame[0];
        break;
      case NAT_ARR_POP: {
        SqArray *a = array_of(frame);
        if (a->count == 0) rt_error("empty array");
        r = a->items[--a->count];
        break;
      }
      case NAT_ARR_REVERSE:
        array_reverse_items(frame);
        r = frame[0];
        break;
      case NAT_ARR_SLICE: r = array_slice_of(frame, frame, nargs); break;
      case NAT_ARR_FIND: r = array_find_of(frame, frame + 1); break;
      case NAT_ARR_EXTEND: {
        /* sqbaselib.cpp array_extend: the items of the argument are appended, and the result is the array */
        SqArray *other = array_of(frame + 1);
        size_t n = other->count;
        for (size_t i = 0; i < n; i++) sqbc_rt_append(frame, &other->items[i]);
        r = frame[0];
        break;
      }
      case NAT_ARR_INSERT:
        array_insert_at(frame, number_to_int(frame + 1), frame + 2);
        r = frame[0];
        break;
      case NAT_STR_SLICE: r = string_slice_of(frame, frame, nargs); break;
      case NAT_STR_FIND: r = string_find_of(frame, frame, nargs); break;
      case NAT_STR_TOLOWER: r = string_case_of(frame, frame, nargs, 0); break;
      case NAT_STR_TOUPPER: r = string_case_of(frame, frame, nargs, 1); break;
      case NAT_RAWGET: r = raw_get_member(frame, frame + 1); break;
      case NAT_RAWSET:
        raw_set_member(frame, frame + 1, frame + 2);
        r = frame[0];
        break;
      case NAT_RAWIN: r = raw_in_member(frame, frame + 1); break;
      case NAT_CLS_GETBASE: {
        SqClass *c = class_of(frame);
        r = c->base ? class_val(c->base) : make_null();
        break;
      }
      case NAT_CLS_INSTANCE: r = make_instance(class_of(frame)); break;
      case NAT_INST_GETCLASS: r = class_val(inst_of(frame)->cls); break;
      case NAT_CLS_GETATTRIBUTES:
      case NAT_CLS_SETATTRIBUTES: {
        /* sqapi.cpp sq_getattributes and sq_setattributes: a null key is the class's own attributes; a member's are those
         * of the member (a missing one is "wrong index"). The result is the attributes before a set. */
        SqClass *c = class_of(frame);
        SQV *slot;
        if (frame[1].tag == SQBC_TAG_NULL) {
          slot = &c->attrs;
        } else {
          refuse_float_key(frame + 1);
          SqMember *m = class_find(c, frame + 1);
          if (!m) rt_error("wrong index");
          slot = &m->attrs;
        }
        r = *slot;
        if (nat->id == NAT_CLS_SETATTRIBUTES) *slot = frame[2];
        break;
      }
      case NAT_ARR_SORT:
        /* sqbaselib.cpp array_sort: a comparison function only when there is one argument besides `this`. */
        array_sort_items(array_of(frame), nargs == 2 ? frame + 1 : NULL);
        r = frame[0];
        break;
      case NAT_ARR_MAP: r = array_map_of(frame, frame + 1); break;
      case NAT_ARR_APPLY:
        /* array_apply: the items are replaced by the results, in place; the result is the array. */
        map_items(frame, frame + 1, array_of(frame));
        r = frame[0];
        break;
      case NAT_ARR_REDUCE: r = array_reduce_of(frame, frame + 1, nargs, frame + 2); break;
      case NAT_ARR_FILTER: r = array_filter_of(frame, frame + 1); break;
      default: rt_error("internal: bad native");
    }
    g_top = outer_top;
    *ret = r;
    return;
  }
  char msg[96];
  snprintf(msg, sizeof msg, "attempt to call '%s'", type_name(clo.tag));
  rt_error(msg);
}

/* ---- arithmetic and comparison -------------------------------------------------------------------------------------- */

/* The result of `a OP b` for two integers, with the wrapping that the reference reaches on LP64 (a quotient of
 * INT64_MIN by -1 is INT64_MIN). */
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
  if (is_number(&x) && is_number(&y) && (x.tag == SQBC_TAG_FLOAT || y.tag == SQBC_TAG_FLOAT)) {
    /* sqvm.cpp _ARITH_ and ARITH_OP, the float case: both operands as floats, no check of a zero divisor (`/` gives inf
     * or nan); `%` is fmod of the two as doubles. */
    float f1 = number_as_float(&x), f2 = number_as_float(&y), res = 0;
    switch (op) {
      case SQBC_OP_ADD: res = f1 + f2; break;
      case SQBC_OP_SUB: res = f1 - f2; break;
      case SQBC_OP_MUL: res = f1 * f2; break;
      case SQBC_OP_DIV: res = f1 / f2; break;
      case SQBC_OP_MOD: res = (float)fmod((double)f1, (double)f2); break;
      default: rt_error("internal: bad arithmetic operator");
    }
    *dst = make_float(res);
    return;
  }
  /* ArithMetaMethod (sqvm.cpp): an instance on the left has the operator's metamethod, called with the right operand as its
   * parameter. A `+` with a string operand is a concatenation (ARITH_OP's StringCat), not this. */
  if (x.tag == SQBC_TAG_INSTANCE && !(op == SQBC_OP_ADD && y.tag == SQBC_TAG_STRING)) {
    int mmi = op == SQBC_OP_ADD   ? MT_ADD
              : op == SQBC_OP_SUB ? MT_SUB
              : op == SQBC_OP_MUL ? MT_MUL
              : op == SQBC_OP_DIV ? MT_DIV
                                  : MT_MODULO;
    const SQV *m = inst_mm(&x, mmi);
    if (m) {
      SQV f = *m;
      SQV args[2] = {x, y}, res;
      call_from_native(&f, &res, args, 2);
      *dst = res;
      return;
    }
    if (op == SQBC_OP_MOD) return; /* no metamethod: the message is only recorded, as below */
  }
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
      default: rt_error("internal: bad arithmetic operator");
    }
    *dst = r;
    return;
  }
  /* sqvm.cpp ARITH_OP: `+` with a string operand concatenates (StringCat, both sides through ToString). */
  if (op == SQBC_OP_ADD && (x.tag == SQBC_TAG_STRING || y.tag == SQBC_TAG_STRING)) {
    char b1[32], b2[32];
    const char *t1, *t2;
    size_t n1 = text_of(&x, b1, sizeof b1, &t1);
    size_t n2 = text_of(&y, b2, sizeof b2, &t2);
    char *buf = malloc(n1 + n2 + 1);
    if (!buf) rt_error("out of memory");
    memcpy(buf, t1, n1);
    memcpy(buf + n1, t2, n2);
    r = make_string(buf, n1 + n2);
    free(buf);
    *dst = r;
    return;
  }
  /* sqvm.cpp ArithMetaMethod: no metamethod of the left operand. */
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
  if (x.tag == SQBC_TAG_FLOAT) {
    *dst = make_float(-float_of(&x));
    return;
  }
  /* NEG_OP: an instance's _unm metamethod, called with the instance as `this` and no parameter. */
  const SQV *um = inst_mm(&x, MT_UNM);
  if (um) {
    SQV f = *um;
    SQV args[1] = {x}, r;
    call_from_native(&f, &r, args, 1);
    *dst = r;
    return;
  }
  {
    char msg[128];
    snprintf(msg, sizeof msg, "attempt to negate a %s", type_name(x.tag));
    rt_error(msg);
  }
}

/* ObjCmp (sqvm.cpp), then CMP_OP's operator on its result. */
int sqbc_rt_compare(int op, SQV *a, SQV *b) {
  int64_t r = obj_cmp(a, b);
  switch (op) {
    case SQBC_CMP_G: return r > 0;
    case SQBC_CMP_GE: return r >= 0;
    case SQBC_CMP_L: return r < 0;
    case SQBC_CMP_LE: return r <= 0;
    default: rt_error("internal: bad comparison operator");
  }
  return 0;
}

/* IsEqual (sqvm.cpp): the same type compares the raw value (a float by its value); two numbers of different types compare
 * as floats; anything else is not equal. */
int sqbc_rt_equal(const SQV *a, const SQV *b) {
  SQV x = *a, y = *b;
  if (x.tag == y.tag) {
    if (x.tag == SQBC_TAG_FLOAT) return float_of(&x) == float_of(&y);
    return x.i == y.i;
  }
  if (is_number(&x) && is_number(&y)) return number_as_float(&x) == number_as_float(&y);
  return 0;
}

/* IsFalse of a float: 0.0 and -0.0 are false. The bits of a float that is not zero have a nonzero magnitude. */
int sqbc_rt_float_zero(const SQV *v) { return float_of(v) == 0.0f; }
