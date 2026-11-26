/* The runtime helpers of the lowered Squirrel subset (sqbcrt.h). Each error text is the one the reference VM raises
 * (squirrel/sqvm.cpp ARITH_OP, ArithMetaMethod, NEG_OP, ObjCmp, Get, Set, NewSlot, StartCall, CLOSURE_OP;
 * squirrel/sqdebug.cpp Raise_IdxError, Raise_CompareError, PrintObjVal).
 *
 * Strings are interned, as the reference interns them: two equal strings are the same object, so equality is the raw
 * comparison the IR makes. Tables are open-addressing hash tables keyed by the raw value (a string by its object).
 * Nothing is freed. The methods of the subset are the ones sqbc_rt_get finds: `len` of a string or an array, `tostring` of a
 * number, a boolean, a string, an array or a table, and `print` in the root table. Any other method of a string or an array
 * is `unsupported ... method`; a table's is "the index does not exist". */
#include "sqbcrt.h"

#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    default: rt_error("tostring of an array, a table, a class, an instance or a function is not lowered");
  }
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
} SqMember;

typedef struct SqClass {
  SqMember *members;
  size_t count;
  size_t cap;
  int nfields;
  int locked; /* set by the first instance: the class can no longer get a field (SQClass::NewSlot) */
  int ctor;   /* the member index of `constructor`, or -1 */
} SqClass;

typedef struct SqInstance {
  SqClass *cls;
  SQV *values; /* the class's nfields fields */
} SqInstance;

static SqClass *class_of(const SQV *v) { return (SqClass *)(intptr_t)v->i; }
static SqInstance *inst_of(const SQV *v) { return (SqInstance *)(intptr_t)v->i; }

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
  return m;
}

void sqbc_rt_newclass(SQV *dst) {
  SqClass *c = calloc(1, sizeof *c);
  if (!c) rt_error("out of memory");
  c->ctor = -1;
  SQV v;
  v.tag = SQBC_TAG_CLASS;
  v.pad = 0;
  v.i = (int64_t)(intptr_t)c;
  *dst = v;
}

/* SQClass::NewSlot (sqclass.cpp), with the checks of SQVM::NewSlot: a closure or a static member is a shared member, any
 * other value is a field; a class with an instance takes only shared members; a name that is a method already is not
 * changed by a field of the same name (the reference's table keeps the method). */
static void class_newslot(SqClass *c, const SQV *k, const SQV *v, int bstatic) {
  int shared = v->tag == SQBC_TAG_CLOSURE || v->tag == SQBC_TAG_NATIVE || bstatic;
  if (c->locked && !shared) rt_error("trying to modify a class that has already been instantiated");
  SqMember *m = class_find(c, k);
  if (m && m->is_field) {
    m->val = *v; /* a field's default value is replaced, shared or not */
    return;
  }
  if (!shared) {
    if (!m) class_add(c, k, v, 1);
    return;
  }
  if (m) {
    m->val = *v;
    return;
  }
  class_add(c, k, v, 0);
  if (k->tag == SQBC_TAG_STRING && strcmp(str_of(k)->chars, "constructor") == 0) c->ctor = (int)(c->count - 1);
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
  c->locked = 1;
  SQV v;
  v.tag = SQBC_TAG_INSTANCE;
  v.pad = 0;
  v.i = (int64_t)(intptr_t)in;
  return v;
}

void sqbc_rt_newslota(const SQV *self, const SQV *key, const SQV *val, int bstatic) {
  SQV s = *self, k = *key, v = *val;
  if (s.tag != SQBC_TAG_CLASS) rt_error("object must be a class");
  if (k.tag == SQBC_TAG_NULL) rt_error("null cannot be used as index");
  refuse_float_key(&k);
  class_newslot(class_of(&s), &k, &v, bstatic);
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
} SqClosure;

/* A native of the base library or a delegate: its operation (NAT_*) and the parameter count sqvm.cpp's CallNative checks
 * (`this` included; a native without a count takes any). */
typedef struct SqNative {
  int id;
  int nparams;
} SqNative;

enum { NAT_PRINT, NAT_STR_LEN, NAT_ARR_LEN, NAT_TOSTRING };

static SqNative g_nat_print = {NAT_PRINT, 2};       /* sqbaselib.cpp base_print: print(value) */
static SqNative g_nat_str_len = {NAT_STR_LEN, 1};   /* string delegate: len */
static SqNative g_nat_arr_len = {NAT_ARR_LEN, 1};   /* array delegate: len */
static SqNative g_nat_tostring = {NAT_TOSTRING, 1}; /* default delegate: tostring */

static SQV make_native(const SqNative *n) {
  SQV v;
  v.tag = SQBC_TAG_NATIVE;
  v.pad = 0;
  v.i = (int64_t)(intptr_t)n;
  return v;
}

/* The default delegate of SELF (sqvm.cpp InvokeDefaultDelegate, for the methods of the subset) for the string KEY: the
 * native in OUT and 1, or 0 when there is none. */
static int delegate_native(const SQV *self, const SQV *key, SQV *out) {
  const char *name = str_of(key)->chars;
  if (strcmp(name, "len") == 0) {
    if (self->tag == SQBC_TAG_STRING) {
      *out = make_native(&g_nat_str_len);
      return 1;
    }
    if (self->tag == SQBC_TAG_ARRAY) {
      *out = make_native(&g_nat_arr_len);
      return 1;
    }
    return 0;
  }
  if (strcmp(name, "tostring") == 0) {
    switch (self->tag) {
      case SQBC_TAG_INTEGER:
      case SQBC_TAG_FLOAT:
      case SQBC_TAG_BOOL:
      case SQBC_TAG_STRING:
      case SQBC_TAG_ARRAY:
      case SQBC_TAG_TABLE:
        *out = make_native(&g_nat_tostring);
        return 1;
      default: return 0;
    }
  }
  return 0;
}

/* The other methods of the number delegate (sqbaselib.cpp: tofloat, tointeger, tochar), for an integer or a float. */
static int is_number_method(const char *name) {
  return strcmp(name, "tofloat") == 0 || strcmp(name, "tointeger") == 0 || strcmp(name, "tochar") == 0;
}

/* The other methods of the class and instance default delegates (sqbaselib.cpp): not lowered. */
static int is_class_method(const char *name) {
  static const char *const names[] = {"getattributes", "setattributes", "rawget", "rawset", "rawin", "weakref"};
  for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
    if (strcmp(name, names[i]) == 0) return 1;
  return 0;
}

static int is_instance_method(const char *name) {
  static const char *const names[] = {"getclass", "rawget", "rawset", "rawin", "weakref", "tostring"};
  for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
    if (strcmp(name, names[i]) == 0) return 1;
  return 0;
}

/* The other methods of the array delegate (sqbaselib.cpp, _array_default_delegate_funcz): not lowered. */
static int is_array_method(const char *name) {
  static const char *const names[] = {"append", "extend", "push",  "pop",     "top",    "insert", "remove",
                                      "resize", "reverse", "sort", "slice",   "weakref", "clear",  "map",
                                      "apply",  "reduce",  "filter", "find"};
  for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
    if (strcmp(name, names[i]) == 0) return 1;
  return 0;
}

/* ---- the stack and the root table ----------------------------------------------------------------------------------- */

static SQV *g_stack_end;
static SQV g_root;

void sqbc_rt_init(SQV *base, size_t nslots) {
  g_stack_end = base + nslots;
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

void sqbc_rt_closure(SQV *dst, int fn, int nparams, int stacksize, const SQV *env, int nouters) {
  SqClosure *c = calloc(1, sizeof *c);
  if (!c) rt_error("out of memory");
  c->fn = fn;
  c->nparams = nparams;
  c->stacksize = stacksize;
  c->nouters = nouters;
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
    if (s.tag == SQBC_TAG_STRING) {
      snprintf(msg, sizeof msg, "unsupported string method '%.50s' (only len and tostring are lowered)", str_of(&k)->chars);
      rt_error(msg);
    }
    if (s.tag == SQBC_TAG_ARRAY && is_array_method(str_of(&k)->chars)) {
      snprintf(msg, sizeof msg, "unsupported array method '%.50s' (only len and tostring are lowered)", str_of(&k)->chars);
      rt_error(msg);
    }
    if (is_number(&s) && is_number_method(str_of(&k)->chars)) {
      snprintf(msg, sizeof msg, "unsupported number method '%.50s' (only tostring is lowered)", str_of(&k)->chars);
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
    /* sqvm.cpp Set: a field of the instance; anything else falls through to the root fallback, then the index error. */
    SqMember *m = class_find(inst_of(&s)->cls, &k);
    if (m && m->is_field) {
      inst_of(&s)->values[m->idx] = v;
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
  if (s.tag == SQBC_TAG_INSTANCE) rt_error("class instances do not support the new slot operator");
  char msg[96];
  snprintf(msg, sizeof msg, "indexing %s with %s", type_name(s.tag), type_name(k.tag));
  rt_error(msg);
}

/* ---- calls ---------------------------------------------------------------------------------------------------------- */

void sqbc_rt_call(const SQV *callee, SQV *ret, SQV *frame, int nargs) {
  SQV clo = *callee;
  SQV scratch;
  if (!ret) ret = &scratch;
  if (clo.tag == SQBC_TAG_CLOSURE) {
    SqClosure *c = (SqClosure *)(intptr_t)clo.i;
    if (nargs != c->nparams) {
      char msg[128];
      snprintf(msg, sizeof msg, "wrong number of parameters (%d passed, %d required)", nargs, c->nparams);
      rt_error(msg);
    }
    if (frame + c->stacksize > g_stack_end) rt_error("stack overflow");
    if (c->has_env) frame[0] = c->env;
    /* The callee's closure value is copied: the caller's register may not hold it for the whole call. */
    SQV running = clo;
    sq_dispatch(c->fn, ret, frame, &running);
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
  if (clo.tag == SQBC_TAG_NATIVE) {
    const SqNative *nat = (const SqNative *)(intptr_t)clo.i;
    /* sqvm.cpp CallNative: a count other than the native's is this text, with no counts. */
    if (nargs != nat->nparams) rt_error("wrong number of parameters");
    char buf[32];
    const char *text;
    SQV r;
    r.tag = SQBC_TAG_NULL;
    r.pad = 0;
    r.i = 0;
    switch (nat->id) {
      case NAT_PRINT:
        /* sqbaselib.cpp base_print: the text of the value, through the print function, with no newline of its own. */
        text_of(frame + 1, buf, sizeof buf, &text);
        printf("%s", text);
        break;
      case NAT_STR_LEN:
        r.tag = SQBC_TAG_INTEGER;
        r.i = (int64_t)str_of(frame)->len;
        break;
      case NAT_ARR_LEN:
        r.tag = SQBC_TAG_INTEGER;
        r.i = (int64_t)array_of(frame)->count;
        break;
      case NAT_TOSTRING: {
        size_t n = text_of(frame, buf, sizeof buf, &text);
        r = make_string(text, n);
        break;
      }
      default: rt_error("internal: bad native");
    }
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
  if (x.tag == SQBC_TAG_FLOAT) {
    *dst = make_float(-float_of(&x));
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
  SQV x = *a, y = *b;
  int64_t r;
  if (x.tag == SQBC_TAG_FLOAT && y.tag == SQBC_TAG_FLOAT) {
    /* ObjCmp: equal values are 0, else -1 when the first is less, and 1 otherwise. */
    float f1 = float_of(&x), f2 = float_of(&y);
    r = f1 == f2 ? 0 : (f1 < f2 ? -1 : 1);
  } else if (is_number(&x) && is_number(&y) && x.tag != y.tag) {
    /* An integer and a float: both as floats. */
    float f1 = number_as_float(&x), f2 = number_as_float(&y);
    r = f1 == f2 ? 0 : (f1 < f2 ? -1 : 1);
  } else if (x.tag == y.tag) {
    if (x.i == y.i) {
      r = 0;
    } else if (x.tag == SQBC_TAG_STRING) {
      /* scstrcmp: the bytes in order, a proper prefix first. */
      SqStr *s1 = str_of(&x), *s2 = str_of(&y);
      size_t m = s1->len < s2->len ? s1->len : s2->len;
      int c = memcmp(s1->chars, s2->chars, m);
      r = c != 0 ? c : (s1->len < s2->len ? -1 : (s1->len > s2->len ? 1 : 0));
    } else if (x.tag == SQBC_TAG_INTEGER) {
      r = x.i < y.i ? -1 : 1;
    } else {
      /* Booleans: the default branch compares the raw values. */
      r = (uint64_t)x.i < (uint64_t)y.i ? -1 : 1;
    }
  } else if (x.tag == SQBC_TAG_NULL) {
    r = -1;
  } else if (y.tag == SQBC_TAG_NULL) {
    r = 1;
  } else {
    char s1[64], s2[64], msg[160];
    const char *t1 = print_obj(&x, s1, sizeof s1);
    const char *t2 = print_obj(&y, s2, sizeof s2);
    snprintf(msg, sizeof msg, "comparison between '%.50s' and '%.50s'", t1, t2);
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
