/* The runtime helpers of the lowered Squirrel subset (sqbcrt.h). Each error text is the one the reference VM raises
 * (squirrel/sqvm.cpp ARITH_OP, ArithMetaMethod, NEG_OP, ObjCmp, Get, Set, NewSlot, StartCall, CLOSURE_OP;
 * squirrel/sqdebug.cpp Raise_IdxError, Raise_CompareError, PrintObjVal).
 *
 * Strings are interned, as the reference interns them: two equal strings are the same object, so equality is the raw
 * comparison the IR makes. Tables are open-addressing hash tables keyed by the raw value (a string by its object).
 * Nothing is freed. The string delegate has only `len`, and a table has no delegate: those are the only methods of the
 * subset. */
#include "sqbcrt.h"

#include <inttypes.h>
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
    case SQBC_TAG_STRING: return "string";
    case SQBC_TAG_TABLE: return "table";
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
    default: rt_error("tostring of a table or a function is not lowered");
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

/* ---- closures and natives ------------------------------------------------------------------------------------------- */

typedef struct SqClosure {
  int fn;        /* the module's prototype index (sq_dispatch) */
  int nparams;   /* the prototype's parameters, `this` included */
  int stacksize; /* the prototype's frame size */
  int has_env;   /* CLOSURE with a bound register: the callee's `this` is env */
  SQV env;
} SqClosure;

typedef struct SqNative {
  int id;
} SqNative;

#define NATIVE_LEN 1
static SqNative g_native_len = {NATIVE_LEN};

/* ---- the stack and the root table ----------------------------------------------------------------------------------- */

static SQV *g_stack_end;
static SQV g_root;

void sqbc_rt_init(SQV *base, size_t nslots) {
  g_stack_end = base + nslots;
  g_root = make_table_val();
  base[0] = g_root;
}

void sqbc_rt_newtable(SQV *dst) {
  SQV v = make_table_val();
  *dst = v;
}

void sqbc_rt_closure(SQV *dst, int fn, int nparams, int stacksize, const SQV *env) {
  SqClosure *c = calloc(1, sizeof *c);
  if (!c) rt_error("out of memory");
  c->fn = fn;
  c->nparams = nparams;
  c->stacksize = stacksize;
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

/* ---- Get, Set, NewSlot ---------------------------------------------------------------------------------------------- */

static void raise_idx(const SQV *k) {
  char buf[32];
  char msg[160];
  const char *text = print_obj(k, buf, sizeof buf);
  snprintf(msg, sizeof msg, "the index '%.50s' does not exist", text);
  rt_error(msg);
}

void sqbc_rt_get(SQV *dst, const SQV *self, const SQV *key, int root_fallback) {
  SQV s = *self, k = *key, out;
  if (s.tag == SQBC_TAG_TABLE) {
    TNode *n = table_find(tbl(&s), &k);
    if (n) {
      out = n->val;
      *dst = out;
      return;
    }
  } else if (s.tag == SQBC_TAG_STRING) {
    /* sqvm.cpp Get: an integer index is the byte at that position (negative counts from the end); a name is looked up in
     * the string delegate, which has only `len` here. */
    if (k.tag == SQBC_TAG_INTEGER) {
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
    if (k.tag == SQBC_TAG_STRING && strcmp(str_of(&k)->chars, "len") == 0) {
      out.tag = SQBC_TAG_NATIVE;
      out.pad = 0;
      out.i = (int64_t)(intptr_t)&g_native_len;
      *dst = out;
      return;
    }
  }
  if (root_fallback) {
    TNode *n = table_find(tbl(&g_root), &k);
    if (n) {
      out = n->val;
      *dst = out;
      return;
    }
  }
  if (s.tag == SQBC_TAG_STRING && k.tag == SQBC_TAG_STRING) {
    char msg[160];
    snprintf(msg, sizeof msg, "unsupported string method '%.50s' (only len is lowered)", str_of(&k)->chars);
    rt_error(msg);
  }
  raise_idx(&k);
}

void sqbc_rt_set(const SQV *self, const SQV *key, const SQV *val, int root_fallback) {
  SQV s = *self, k = *key, v = *val;
  if (s.tag == SQBC_TAG_TABLE) {
    TNode *n = table_find(tbl(&s), &k);
    if (n) {
      n->val = v;
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
  if (s.tag == SQBC_TAG_TABLE) {
    table_newslot(tbl(&s), &k, &v);
    return;
  }
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
    sq_dispatch(c->fn, ret, frame);
    return;
  }
  if (clo.tag == SQBC_TAG_NATIVE) {
    /* The string delegate's len: one parameter, the string itself (sqbaselib.cpp default_delegate_len). */
    if (nargs != 1) {
      char msg[128];
      snprintf(msg, sizeof msg, "wrong number of parameters (%d passed, 1 required)", nargs);
      rt_error(msg);
    }
    SQV n;
    n.tag = SQBC_TAG_INTEGER;
    n.pad = 0;
    n.i = (int64_t)str_of(frame)->len;
    *ret = n;
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
  if (x.tag == y.tag) {
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
