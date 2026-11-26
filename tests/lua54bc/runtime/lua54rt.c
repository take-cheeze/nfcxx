#define _GNU_SOURCE
/* The runtime helpers that lowered Lua 5.4 IR calls (docs/notes/lua54-pathb.md, "Runtime helpers").
 * Values, numbers with lvm.c's rules, strings, tables with metatables, closures and upvalues, the calling protocol,
 * the operators with their metamethods, the host library, and the errors of ldebug.c with their variable names. */
#include <ctype.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <setjmp.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct LV {
  uint8_t tag;
  uint8_t pad[7];
  union {
    int64_t i;
    double n;
    void *p;
  } v;
} LV;

/* lobject.h variants: type | variant << 4. */
enum {
  TAG_NIL = 0x00, TAG_FALSE = 0x01, TAG_TRUE = 0x11, TAG_INT = 0x03, TAG_FLOAT = 0x13,
  TAG_STR = 0x04, TAG_TABLE = 0x05, TAG_LCL = 0x06, TAG_LCF = 0x16
};

/* lopcodes.h opcode numbers of the binary ops (the helper takes the base op, not the K or I form). */
enum {
  OP_ADD = 34, OP_SUB = 35, OP_MUL = 36, OP_MOD = 37, OP_POW = 38, OP_DIV = 39, OP_IDIV = 40,
  OP_BAND = 41, OP_BOR = 42, OP_BXOR = 43, OP_SHL = 44, OP_SHR = 45
};
enum { OP_UNM = 49, OP_BNOT = 50 };

/* The header of every collected object (the collector is further down). */
typedef struct GCObj {
  struct GCObj *next;
  size_t size;
  uint8_t kind;
  uint8_t marked;
} GCObj;
enum { GC_STR = 1, GC_TABLE, GC_LCL, GC_UPVAL, GC_LCF, GC_VARARGS };
static void *gc_alloc(uint8_t kind, size_t size);
static int host_collectgarbage(LV *out, LV *args, int nargs);

typedef struct LString {
  GCObj gc;
  size_t len;
  char bytes[1];   /* len bytes and a NUL */
} LString;

static LV make_str(const char *p, size_t len);
static const char *type_name(uint8_t tag);
static void arg_fail(int k, const char *fname, const char *msg);
static void lib_arg_error(int k, const char *fname, const char *what, const char *got);
static int64_t arg_int(const LV *args, int nargs, int k, const char *fname);
static int64_t opt_int(const LV *args, int nargs, int k, const char *fname, int64_t def);

/* An internal inconsistency of the runtime, not a Lua error. */
static void die(const char *what) {
  fprintf(stderr, "lua54rt: internal error: %s\n", what);
  exit(4);
}

/* ---- errors (ldebug.c) ----
 * The site is set by the IR before each operation that can fail: its first line is "source:line:", and each further line
 * is the variable info of one operand, " (local 'x')" or "" (the kinds of getobjname). An error is reported as lua.c
 * reports one: "lua: source:line: message", and the process stops with status 1. */
static const char *site = NULL;

void lua54rt_site(const char *s) { site = s; }

static void site_line(int n, char *buf, size_t size) {
  buf[0] = '\0';
  if (site == NULL) return;
  const char *p = site;
  for (int k = 0; k < n; ++k) {
    const char *nl = strchr(p, '\n');
    if (nl == NULL) return;
    p = nl + 1;
  }
  const char *end = strchr(p, '\n');
  size_t len = end != NULL ? (size_t)(end - p) : strlen(p);
  if (len >= size) len = size - 1;
  memcpy(buf, p, len);
  buf[len] = '\0';
}

/* lua_error: the error value goes to the innermost protected call (pcall), which longjmps back to it; without one, lua.c
 * reports the value and stops with status 1. */
typedef struct PCall {
  jmp_buf jb;
  LV err;
  struct PCall *prev;
  LV *base;   /* the arguments of the protected call: the frames above it are closed on error */
} PCall;
static PCall *pcall_top = NULL;

static void close_to(LV *level, const LV *err);

static void raise_value(LV err) {
  if (pcall_top != NULL) {
    pcall_top->err = err;
    longjmp(pcall_top->jb, 1);
  }
  close_to(NULL, &err);   /* lua.c's protected call closes the to-be-closed variables before it reports the error */
  if (err.tag == TAG_STR) fprintf(stderr, "lua: %s\n", ((LString *)err.v.p)->bytes);
  else fprintf(stderr, "lua: (error object is a %s value)\n", type_name(err.tag));
  exit(1);
}

/* luaG_runerror with the info of operand (or none when operand < 0): before + info + after. */
static void rt_fail3(const char *before, int operand, const char *after) {
  char where[512], info[512], msg[1400];
  info[0] = '\0';
  site_line(0, where, sizeof where);
  if (operand >= 0) site_line(1 + operand, info, sizeof info);
  if (where[0] != '\0') snprintf(msg, sizeof msg, "%s %s%s%s", where, before, info, after);
  else snprintf(msg, sizeof msg, "%s%s%s", before, info, after);
  raise_value(make_str(msg, strlen(msg)));
}

static void rt_fail(const char *msg, int operand) { rt_fail3(msg, operand, ""); }

static const char *type_name(uint8_t tag) {
  switch (tag) {
    case TAG_NIL: return "nil";
    case TAG_FALSE:
    case TAG_TRUE: return "boolean";
    case TAG_INT:
    case TAG_FLOAT: return "number";
    case TAG_STR: return "string";
    case TAG_TABLE: return "table";
    case TAG_LCL:
    case TAG_LCF: return "function";
    default: return "?";
  }
}

/* luaG_typeerror: "attempt to <op> a <type> value" with the info of the operand. */
static void type_fail(const char *op, uint8_t tag, int operand) {
  char buf[160];
  snprintf(buf, sizeof buf, "attempt to %s a %s value", op, type_name(tag));
  rt_fail(buf, operand);
}

/* ---- strings: immutable, compared by content; no interning ---- */

static LV make_str(const char *p, size_t len) {
  LString *s = (LString *)gc_alloc(GC_STR, sizeof(LString) + len);
  if (s == NULL) die("out of memory");
  s->len = len;
  if (len > 0) memcpy(s->bytes, p, len);
  s->bytes[len] = '\0';
  LV v;
  v.tag = TAG_STR;
  v.v.p = s;
  return v;
}

void lua54rt_str(LV *dst, const char *p, long len) { *dst = make_str(p, (size_t)len); }

static int is_number(const LV *x) { return x->tag == TAG_INT || x->tag == TAG_FLOAT; }
static double as_float(const LV *x) { return x->tag == TAG_INT ? (double)x->v.i : x->v.n; }

/* luaV_tointegerns with F2Ieq: an int, or a float with an exact integer value. */
static int to_int_exact(const LV *x, int64_t *out) {
  if (x->tag == TAG_INT) {
    *out = x->v.i;
    return 1;
  }
  if (x->tag != TAG_FLOAT) return 0;
  double f = floor(x->v.n);
  if (f != x->v.n) return 0;
  if (!(f >= -9223372036854775808.0 && f < 9223372036854775808.0)) return 0;
  *out = (int64_t)f;
  return 1;
}

/* luaV_tointeger with F2Ifloor or F2Iceil (ceil_mode 1 is ceil). */
static int to_int_round(const LV *x, int64_t *out, int ceil_mode) {
  if (x->tag == TAG_INT) {
    *out = x->v.i;
    return 1;
  }
  if (x->tag != TAG_FLOAT) return 0;
  double f = ceil_mode ? ceil(x->v.n) : floor(x->v.n);
  if (!(f >= -9223372036854775808.0 && f < 9223372036854775808.0)) return 0;
  *out = (int64_t)f;
  return 1;
}

/* luaV_idiv */
static int64_t int_idiv(int64_t m, int64_t n) {
  if ((uint64_t)n + 1u <= 1u) {
    if (n == 0) rt_fail("attempt to divide by zero", -1);
    return (int64_t)(0u - (uint64_t)m);
  }
  int64_t q = m / n;
  if ((m ^ n) < 0 && m % n != 0) q -= 1;
  return q;
}

/* luaV_mod */
static int64_t int_mod(int64_t m, int64_t n) {
  if ((uint64_t)n + 1u <= 1u) {
    if (n == 0) rt_fail("attempt to perform 'n%0'", -1);
    return 0;
  }
  int64_t r = m % n;
  if (r != 0 && (r ^ n) < 0) r += n;
  return r;
}

/* luai_nummod */
static double float_mod(double m, double n) {
  double r = fmod(m, n);
  if ((r > 0) ? n < 0 : (r < 0 && n > 0)) r += n;
  return r;
}

/* luaV_shiftl: shift left, or right for a negative y. */
static int64_t shift_l(int64_t x, int64_t y) {
  const int nbits = 64;
  if (y < 0) {
    if (y <= -nbits) return 0;
    return (int64_t)((uint64_t)x >> (uint64_t)(-y));
  }
  if (y >= nbits) return 0;
  return (int64_t)((uint64_t)x << (uint64_t)y);
}

/* luaO_str2num for the arithmetic coercion: surrounding spaces allowed; decimal and hex integers (hex wraps); floats
 * by strtod, except the words inf and nan, which Lua does not accept. */
static int str_to_number(const LString *s, LV *out) {
  char *buf = (char *)malloc(s->len + 1);
  if (buf == NULL) die("out of memory");
  memcpy(buf, s->bytes, s->len);
  buf[s->len] = '\0';
  int ok = 0;
  char *p = buf;
  while (isspace((unsigned char)*p)) p++;
  char *e = p + strlen(p);
  while (e > p && isspace((unsigned char)e[-1])) e--;
  *e = '\0';
  if (strpbrk(p, "nN") == NULL && *p != '\0') {
    const char *q = p;
    int neg = 0;
    if (*q == '+' || *q == '-') neg = *q++ == '-';
    if (q[0] == '0' && (q[1] == 'x' || q[1] == 'X') && q[2] != '\0' && strpbrk(q, ".pP") == NULL) {
      uint64_t acc = 0;
      const char *d = q + 2;
      int digits = 0;
      while (isxdigit((unsigned char)*d)) {
        int v = isdigit((unsigned char)*d) ? *d - '0' : (tolower((unsigned char)*d) - 'a' + 10);
        acc = acc * 16u + (uint64_t)v;
        digits++;
        d++;
      }
      if (digits > 0 && *d == '\0') {
        out->tag = TAG_INT;
        out->v.i = (int64_t)(neg ? 0u - acc : acc);
        ok = 1;
      }
    } else {
      const char *d = q;
      int all_digits = *d != '\0';
      uint64_t acc = 0;
      int overflow = 0;
      for (; *d; ++d) {
        if (!isdigit((unsigned char)*d)) {
          all_digits = 0;
          break;
        }
        if (acc > (UINT64_MAX - 9) / 10) overflow = 1;
        else acc = acc * 10u + (uint64_t)(*d - '0');
      }
      if (all_digits && !overflow && (neg ? acc <= (uint64_t)INT64_MAX + 1u : acc <= (uint64_t)INT64_MAX)) {
        out->tag = TAG_INT;
        out->v.i = (int64_t)(neg ? 0u - acc : acc);
        ok = 1;
      } else {
        char *end;
        double f = strtod(p, &end);
        if (end != p && *end == '\0') {
          out->tag = TAG_FLOAT;
          out->v.n = f;
          ok = 1;
        }
      }
    }
  }
  free(buf);
  return ok;
}

/* A number or a string convertible to one. */
static int to_number(const LV *x, LV *out) {
  if (is_number(x)) {
    *out = *x;
    return 1;
  }
  if (x->tag == TAG_STR) return str_to_number((const LString *)x->v.p, out);
  return 0;
}

/* ---- tables: a hash of key/value nodes with linear probing; keys normalized as lvm.c does (a float with an exact
 * integer value is the integer key). A nil value keeps its node until the next resize. No array part yet. ---- */
typedef struct Node {
  LV key;
  LV val;
  int used;
} Node;

typedef struct Table {
  GCObj gc;
  Node *nodes;
  size_t cap;      /* a power of two, or 0 */
  size_t count;    /* used nodes, including those with a nil value */
  struct Table *meta;   /* the metatable, or NULL */
} Table;

static uint64_t mix(uint64_t x) {
  x ^= x >> 33;
  x *= 0xff51afd7ed558ccdULL;
  x ^= x >> 33;
  return x;
}

static uint64_t hash_key(const LV *k) {
  switch (k->tag) {
    case TAG_INT: return mix((uint64_t)k->v.i);
    case TAG_FLOAT: {
      uint64_t bits;
      memcpy(&bits, &k->v.n, sizeof bits);
      return mix(bits);
    }
    case TAG_STR: {
      const LString *s = (const LString *)k->v.p;
      uint64_t h = 1469598103934665603ULL;
      for (size_t i = 0; i < s->len; ++i) h = (h ^ (unsigned char)s->bytes[i]) * 1099511628211ULL;
      return h;
    }
    case TAG_NIL:
    case TAG_FALSE:
    case TAG_TRUE: return k->tag;
    default: return mix((uint64_t)(uintptr_t)k->v.p);
  }
}

static int same_key(const LV *a, const LV *b) {
  if (a->tag != b->tag) return 0;
  switch (a->tag) {
    case TAG_INT: return a->v.i == b->v.i;
    case TAG_FLOAT: return a->v.n == b->v.n;
    case TAG_STR: {
      const LString *x = (const LString *)a->v.p, *y = (const LString *)b->v.p;
      return x->len == y->len && memcmp(x->bytes, y->bytes, x->len) == 0;
    }
    case TAG_NIL:
    case TAG_FALSE:
    case TAG_TRUE: return 1;
    default: return a->v.p == b->v.p;
  }
}

/* The key as lvm.c stores it. Only valid for a key that is not nil or NaN. */
static LV normal_key(const LV *k) {
  LV r = *k;
  if (k->tag == TAG_FLOAT && floor(k->v.n) == k->v.n && k->v.n >= -9223372036854775808.0 &&
      k->v.n < 9223372036854775808.0) {
    r.tag = TAG_INT;
    r.v.i = (int64_t)k->v.n;
  }
  return r;
}

static Node *table_find(const Table *t, const LV *key) {
  if (t->cap == 0) return NULL;
  size_t mask = t->cap - 1;
  for (size_t i = (size_t)hash_key(key) & mask;; i = (i + 1) & mask) {
    Node *n = &t->nodes[i];
    if (!n->used) return NULL;
    if (same_key(&n->key, key)) return n;
  }
}

static void table_resize(Table *t, size_t cap) {
  Node *old = t->nodes;
  size_t oldcap = t->cap;
  t->nodes = (Node *)calloc(cap, sizeof(Node));
  if (t->nodes == NULL) die("out of memory");
  t->cap = cap;
  t->count = 0;
  for (size_t i = 0; i < oldcap; ++i) {
    if (old[i].used && old[i].val.tag != TAG_NIL) {
      size_t mask = t->cap - 1;
      size_t j = (size_t)hash_key(&old[i].key) & mask;
      while (t->nodes[j].used) j = (j + 1) & mask;
      t->nodes[j] = old[i];
      t->count++;
    }
  }
  free(old);
}

static Node *table_slot(Table *t, const LV *key) {
  Node *n = table_find(t, key);
  if (n != NULL) return n;
  if ((t->count + 1) * 2 > t->cap) table_resize(t, t->cap == 0 ? 4 : t->cap * 2);
  size_t mask = t->cap - 1;
  size_t j = (size_t)hash_key(key) & mask;
  while (t->nodes[j].used) j = (j + 1) & mask;
  t->nodes[j].used = 1;
  t->nodes[j].key = *key;
  t->nodes[j].val.tag = TAG_NIL;
  t->count++;
  return &t->nodes[j];
}

/* lua_rawget: nil for a nil or NaN key, as Lua reads them. */
static LV raw_get(const Table *t, const LV *key) {
  LV v;
  v.tag = TAG_NIL;
  if (key->tag == TAG_NIL) return v;
  if (key->tag == TAG_FLOAT && key->v.n != key->v.n) return v;
  LV k = normal_key(key);
  Node *n = table_find(t, &k);
  if (n != NULL) return n->val;
  return v;
}

/* lua_rawset: nil and NaN keys are errors. */
static void raw_set(Table *t, const LV *key, const LV *val) {
  if (key->tag == TAG_NIL) rt_fail("table index is nil", -1);
  if (key->tag == TAG_FLOAT && key->v.n != key->v.n) rt_fail("table index is NaN", -1);
  LV k = normal_key(key);
  if (val->tag == TAG_NIL) {
    Node *n = table_find(t, &k);
    if (n != NULL) n->val.tag = TAG_NIL;
    return;
  }
  Node *n = table_slot(t, &k);
  n->val = *val;
}

void lua54rt_newtable(LV *dst) {
  Table *t = (Table *)gc_alloc(GC_TABLE, sizeof *t);
  if (t == NULL) die("out of memory");
  dst->tag = TAG_TABLE;
  dst->v.p = t;
}

/* The border: the largest n with t[1..n] all non-nil, found by counting from 1. */
static int64_t table_border(const Table *t) {
  int64_t n = 0;
  for (;;) {
    LV k;
    k.tag = TAG_INT;
    k.v.i = n + 1;
    LV v = raw_get(t, &k);
    if (v.tag == TAG_NIL) return n;
    n++;
  }
}

/* ---- metamethods (ltm.c): looked up in the metatable of a table; only tables have metatables here ---- */
static Table *string_meta = NULL;   /* the metatable of every string; its __index is the string library */

static int get_mt(const LV *o, const char *event, LV *out) {
  const Table *mt;
  if (o->tag == TAG_TABLE) mt = ((const Table *)o->v.p)->meta;
  else if (o->tag == TAG_STR) mt = string_meta;
  else return 0;
  if (mt == NULL) return 0;
  LV key = make_str(event, strlen(event));
  LV v = raw_get(mt, &key);
  if (v.tag == TAG_NIL) return 0;
  *out = v;
  return 1;
}

static int truthy(const LV *v) { return v->tag != TAG_NIL && v->tag != TAG_FALSE; }

void lua54rt_call(LV *fn, int nargs, LV *args, LV *ret, int wanted, int a);
static void install_more(LV *env);
void lua54rt_install_library(LV *env);

/* Calls a metamethod with nargs values and returns its first result (luaT_callTMres). */
static LV call_mmv(const LV *fn, const LV *args, int nargs) {
  LV frame[1024], ret[4];
  for (int k = 0; k < nargs; ++k) frame[k] = args[k];
  lua54rt_call((LV *)fn, nargs, frame, ret, 1, 0);
  return ret[0];
}

/* Functions and closures (docs/notes/lua54-pathb.md, "Calls and upvalues").
 * A lowered function is fn(ret, base, cl): ret receives the one result, base is the frame, cl is the closure.
 * An upvalue is a cell. While its variable is on the stack it is open: v points at the stack slot. When the frame
 * ends, or a CLOSE covers the slot, the value moves into closed and v points there (lfunc.c's luaF_close). */
typedef struct UpVal UpVal;
struct UpVal {
  GCObj gc;
  LV *v;
  LV closed;
  UpVal *open_next;   /* the open list, highest address first */
};

typedef void (*lua_fn)(LV *ret, LV *base, void *cl);
typedef struct LClosure {
  GCObj gc;
  lua_fn fn;
  int numparams;
  int nupvals;
  UpVal *upvals[1];   /* nupvals entries; the closure is allocated with room for them */
} LClosure;

static UpVal *open_upvals = NULL;

void lua54rt_closure(LV *dst, void *fn, int numparams, int nupvals) {
  size_t size = sizeof(LClosure) + sizeof(UpVal *) * (size_t)(nupvals > 0 ? nupvals - 1 : 0);
  LClosure *c = (LClosure *)gc_alloc(GC_LCL, size);
  if (c == NULL) die("out of memory");
  c->fn = (lua_fn)fn;
  c->numparams = numparams;
  c->nupvals = nupvals;
  for (int k = 0; k < nupvals; ++k) c->upvals[k] = NULL;
  dst->tag = TAG_LCL;
  dst->v.p = c;
}

/* The open upvalue for stack slot level, made if there is none (luaF_findupval). */
static UpVal *find_upval(LV *level) {
  UpVal **pp = &open_upvals;
  while (*pp != NULL && (*pp)->v > level) pp = &(*pp)->open_next;
  if (*pp != NULL && (*pp)->v == level) return *pp;
  UpVal *uv = (UpVal *)gc_alloc(GC_UPVAL, sizeof *uv);
  if (uv == NULL) die("out of memory");
  uv->v = level;
  uv->open_next = *pp;
  *pp = uv;
  return uv;
}

/* Upvalue k of the new closure dst: captured from the frame (instack) or from the enclosing closure. */
void lua54rt_capture(LV *dst, int k, int instack, int idx, void *encl, LV *base) {
  LClosure *c = (LClosure *)dst->v.p;
  if (instack) c->upvals[k] = find_upval(&base[idx]);
  else c->upvals[k] = ((LClosure *)encl)->upvals[idx];
}

/* Closes the open upvalues at or above level: their values move into the cells (luaF_close). */
/* To-be-closed variables (lfunc.c): the slots that TBC registered (and the fourth value of a generic for), in the order
 * they were registered. A registered slot at or above level is closed by close_to, last first. */
typedef struct Tbc {
  LV *slot;
  const char *name;
} Tbc;
static Tbc *tbc_list = NULL;
static int tbc_n = 0, tbc_cap = 0;

/* Closes the upvalues and the to-be-closed variables at or above level: each variable's __close is called with its value
 * and err (nil when the block ends normally). An entry is removed before its __close runs, so an error in it is not
 * closed again. */
static void close_to(LV *level, const LV *err) {
  while (open_upvals != NULL && open_upvals->v >= level) {
    UpVal *uv = open_upvals;
    uv->closed = *uv->v;
    uv->v = &uv->closed;
    open_upvals = uv->open_next;
  }
  while (tbc_n > 0 && tbc_list[tbc_n - 1].slot >= level) {
    LV v = *tbc_list[--tbc_n].slot, h;
    if (!get_mt(&v, "__close", &h)) continue;
    LV frame[1024], ret[256];
    frame[0] = v;
    frame[1] = err != NULL ? *err : (LV){0};
    lua54rt_call(&h, 2, frame, ret, 0, 0);
  }
}

void lua54rt_close(LV *level) { close_to(level, NULL); }

/* TBC A: the variable in slot is to be closed. nil and false are not registered; any other value needs a __close
 * metamethod (lfunc.c's checkclosemth). */
void lua54rt_tbc(LV *slot, const char *name) {
  if (slot->tag == TAG_NIL || slot->tag == TAG_FALSE) return;
  LV h;
  if (!get_mt(slot, "__close", &h)) {
    char msg[160];
    snprintf(msg, sizeof msg, "variable '%s' got a non-closable value", name);
    rt_fail(msg, -1);
  }
  if (tbc_n == tbc_cap) {
    tbc_cap = tbc_cap == 0 ? 16 : tbc_cap * 2;
    tbc_list = (Tbc *)realloc(tbc_list, sizeof(Tbc) * (size_t)tbc_cap);
    if (tbc_list == NULL) die("out of memory");
  }
  tbc_list[tbc_n].slot = slot;
  tbc_list[tbc_n].name = name;
  tbc_n++;
}

void lua54rt_getupval(LV *dst, void *cl, int idx) { *dst = *((LClosure *)cl)->upvals[idx]->v; }

void lua54rt_setupval(void *cl, int idx, LV *src) { *((LClosure *)cl)->upvals[idx]->v = *src; }
/* ---- the calling protocol (docs/notes/lua54-pathb.md, "Calls") ----
 * A callee writes its results to ret[0..n-1] and records n in lua54rt_nret. The stack top, lua54rt_top, is the index
 * after the last value of a multi-result op; the next op that takes "up to top" reads it at once. The callee's
 * arguments are the caller's registers. A vararg function saves its extra arguments at entry (lua54rt_varargprep),
 * while their count is still in lua54rt_nargs. */
static int lua54rt_nret = 0;
static int lua54rt_top = 0;
static int lua54rt_nargs = 0;

int lua54rt_gettop(void) { return lua54rt_top; }

/* RETURN: copy n values from src to ret. ret lies below src (it is the caller's register A), so a forward copy is safe. */
void lua54rt_setret(LV *ret, LV *src, int n) {
  for (int k = 0; k < n; ++k) ret[k] = src[k];
  lua54rt_nret = n;
}

/* A host function (the library): it reads args and writes up to 64 results to out, returning their count. */
typedef int (*lua_cfn)(LV *out, LV *args, int nargs);
/* A host closure has up to four state values (up[0..nup-1]), which the collector marks. The library's gmatch iterator
 * keeps its subject, pattern and positions there. cur_host is the host function being called, set for the call. */
typedef struct HostFn {
  GCObj gc;
  lua_cfn fn;
  int nup;
  LV up[4];
} HostFn;
static HostFn *cur_host = NULL;

static void make_host_nup(LV *dst, lua_cfn fn, int nup) {
  HostFn *h = (HostFn *)gc_alloc(GC_LCF, sizeof *h);
  if (h == NULL) die("out of memory");
  h->fn = fn;
  h->nup = nup;
  dst->tag = TAG_LCF;
  dst->v.p = h;
}

static void make_host(LV *dst, lua_cfn fn) { make_host_nup(dst, fn, 0); }

/* The call stack for error levels: one entry per call, the position of the caller at the time of the call (NULL when the
 * caller is not a Lua function, e.g. pcall). The top entry is the call of the running function, so level 1 (the caller of
 * error) is the top, and level 2 is the entry below it. Entries past CALLSTACK_MAX are not kept. */
#define CALLSTACK_MAX 4096
static const char *callsite[CALLSTACK_MAX];
static int call_depth = 0;

static void push_callsite(const char *s) {
  if (call_depth < CALLSTACK_MAX) callsite[call_depth] = s;
  call_depth++;
}

static void pop_callsite(void) { call_depth--; }

/* The results of a call are in ret[0..lua54rt_nret-1]: all of them, or wanted of them with nil after. */
static void finish_call(LV *ret, int wanted, int a) {
  if (wanted < 0) {
    lua54rt_top = a + lua54rt_nret;
    return;
  }
  for (int k = lua54rt_nret; k < wanted; ++k) ret[k].tag = TAG_NIL;
}

/* OP_CALL: the callee's base is args; its results go to ret. wanted is the number of results the caller takes, or -1
 * for all of them, which sets the stack top to a + n (a is the caller's register index of the call). A value that is
 * not a function is called through its __call metamethod, with the value as the first argument. The site of the call
 * is restored after it returns, so an error after a call reports the call's own operation. */
void lua54rt_call(LV *fn, int nargs, LV *args, LV *ret, int wanted, int a) {
  if (fn->tag == TAG_LCF) {
    LV out[64];
    const char *saved = site;
    HostFn *saved_host = cur_host;
    push_callsite(saved);
    cur_host = (HostFn *)fn->v.p;
    int n = cur_host->fn(out, args, nargs);
    cur_host = saved_host;
    pop_callsite();
    site = saved;
    lua54rt_nret = n;
    for (int k = 0; k < n; ++k) ret[k] = out[k];
    finish_call(ret, wanted, a);
    return;
  }
  if (fn->tag == TAG_LCL) {
    LClosure *c = (LClosure *)fn->v.p;
    for (int k = nargs; k < c->numparams; ++k) args[k].tag = TAG_NIL;
    lua54rt_nargs = nargs;
    lua54rt_nret = 0;
    const char *saved = site;
    push_callsite(saved);
    c->fn(ret, args, c);
    pop_callsite();
    site = saved;
    finish_call(ret, wanted, a);
    return;
  }
  LV h;
  if (!get_mt(fn, "__call", &h)) type_fail("call", fn->tag, 0);
  for (int k = nargs; k > 0; --k) args[k] = args[k - 1];
  args[0] = *fn;
  lua54rt_call(&h, nargs + 1, args, ret, wanted, a);
}

/* VARARGPREP: the extra arguments of the current call, saved for VARARG. */
typedef struct VarArgs {
  GCObj gc;
  int count;
  LV *vals;
} VarArgs;

void *lua54rt_varargprep(LV *base, int nfixed) {
  VarArgs *va = (VarArgs *)gc_alloc(GC_VARARGS, sizeof *va);
  if (va == NULL) die("out of memory");
  va->count = lua54rt_nargs > nfixed ? lua54rt_nargs - nfixed : 0;
  va->vals = (LV *)malloc(sizeof(LV) * (size_t)(va->count > 0 ? va->count : 1));
  if (va->vals == NULL) die("out of memory");
  for (int k = 0; k < va->count; ++k) va->vals[k] = base[nfixed + k];
  return va;
}

/* VARARG A C: R[a..] := the saved extra arguments; wanted < 0 takes them all and sets the stack top. */
void lua54rt_vararg(void *vap, LV *dst, int wanted, int a) {
  VarArgs *va = (VarArgs *)vap;
  int n = wanted < 0 ? va->count : wanted;
  for (int k = 0; k < n; ++k) {
    if (k < va->count) dst[k] = va->vals[k];
    else dst[k].tag = TAG_NIL;
  }
  if (wanted < 0) lua54rt_top = a + va->count;
}

static void for_fail(const char *what, uint8_t tag) {
  char buf[160];
  snprintf(buf, sizeof buf, "bad 'for' %s (number expected, got %s)", what, type_name(tag));
  rt_fail(buf, -1);
}

/* lvm.c forprep. ra: ra[0] init, ra[1] limit, ra[2] step, ra[3] control. Returns 1 to skip the loop. */
int lua54rt_forprep(LV *ra) {
  LV *pinit = &ra[0], *plimit = &ra[1], *pstep = &ra[2];
  if (pinit->tag == TAG_INT && pstep->tag == TAG_INT) {
    int64_t init = pinit->v.i, step = pstep->v.i, limit;
    if (step == 0) rt_fail("'for' step is zero", -1);
    ra[3].tag = TAG_INT;
    ra[3].v.i = init;
    /* forlimit */
    if (!to_int_round(plimit, &limit, step < 0)) {
      if (!is_number(plimit)) for_fail("limit", plimit->tag);
      double flim = as_float(plimit);
      if (0 < flim) {
        if (step < 0) return 1;
        limit = INT64_MAX;
      } else {
        if (step > 0) return 1;
        limit = INT64_MIN;
      }
    }
    if (step > 0 ? init > limit : init < limit) return 1;
    uint64_t count;
    if (step > 0) {
      count = (uint64_t)limit - (uint64_t)init;
      if (step != 1) count /= (uint64_t)step;
    } else {
      count = (uint64_t)init - (uint64_t)limit;
      count /= (uint64_t)(-(step + 1)) + 1u;
    }
    plimit->tag = TAG_INT;
    plimit->v.i = (int64_t)count;
    return 0;
  }
  if (!is_number(plimit)) for_fail("limit", plimit->tag);
  if (!is_number(pstep)) for_fail("step", pstep->tag);
  if (!is_number(pinit)) for_fail("initial value", pinit->tag);
  double limit = as_float(plimit), step = as_float(pstep), init = as_float(pinit);
  if (step == 0) rt_fail("'for' step is zero", -1);
  if (0 < step ? limit < init : init < limit) return 1;
  plimit->tag = TAG_FLOAT;
  plimit->v.n = limit;
  pstep->tag = TAG_FLOAT;
  pstep->v.n = step;
  ra[0].tag = TAG_FLOAT;
  ra[0].v.n = init;
  ra[3].tag = TAG_FLOAT;
  ra[3].v.n = init;
  return 0;
}

/* lvm.c OP_FORLOOP. Returns 1 to jump back. */
int lua54rt_forloop(LV *ra) {
  if (ra[2].tag == TAG_INT) {
    uint64_t count = (uint64_t)ra[1].v.i;
    if (count > 0) {
      int64_t step = ra[2].v.i;
      int64_t idx = ra[0].v.i;
      ra[1].v.i = (int64_t)(count - 1);
      idx = (int64_t)((uint64_t)idx + (uint64_t)step);
      ra[0].v.i = idx;
      ra[3].tag = TAG_INT;
      ra[3].v.i = idx;
      return 1;
    }
    return 0;
  }
  /* floatforloop */
  double step = ra[2].v.n, limit = ra[1].v.n, idx = ra[0].v.n;
  idx = idx + step;
  if (0 < step ? idx <= limit : limit <= idx) {
    ra[0].v.n = idx;
    ra[3].tag = TAG_FLOAT;
    ra[3].v.n = idx;
    return 1;
  }
  return 0;
}


/* ---- operators (lvm.c, ltm.c, ldebug.c) ---- */

static const char *arith_event(int op) {
  switch (op) {
    case OP_ADD: return "__add";
    case OP_SUB: return "__sub";
    case OP_MUL: return "__mul";
    case OP_MOD: return "__mod";
    case OP_POW: return "__pow";
    case OP_DIV: return "__div";
    case OP_IDIV: return "__idiv";
    case OP_BAND: return "__band";
    case OP_BOR: return "__bor";
    case OP_BXOR: return "__bxor";
    case OP_SHL: return "__shl";
    case OP_SHR: return "__shr";
    default: return "?";
  }
}

/* Both operands are numbers (after the coercion): the operation itself. */
static void numeric_arith(int op, LV *dst, const LV *a, const LV *b) {
  if (op == OP_ADD || op == OP_SUB || op == OP_MUL) {
    if (a->tag == TAG_INT && b->tag == TAG_INT) {
      uint64_t x = (uint64_t)a->v.i, y = (uint64_t)b->v.i, r;
      if (op == OP_ADD) r = x + y;
      else if (op == OP_SUB) r = x - y;
      else r = x * y;
      dst->tag = TAG_INT;
      dst->v.i = (int64_t)r;
      return;
    }
    double x = as_float(a), y = as_float(b), r;
    if (op == OP_ADD) r = x + y;
    else if (op == OP_SUB) r = x - y;
    else r = x * y;
    dst->tag = TAG_FLOAT;
    dst->v.n = r;
    return;
  }
  if (op == OP_DIV) {
    dst->tag = TAG_FLOAT;
    dst->v.n = as_float(a) / as_float(b);
    return;
  }
  if (op == OP_POW) {
    double x = as_float(a), y = as_float(b);
    dst->tag = TAG_FLOAT;
    dst->v.n = (y == 2) ? x * x : pow(x, y);
    return;
  }
  if (op == OP_IDIV || op == OP_MOD) {
    if (a->tag == TAG_INT && b->tag == TAG_INT) {
      dst->tag = TAG_INT;
      dst->v.i = op == OP_IDIV ? int_idiv(a->v.i, b->v.i) : int_mod(a->v.i, b->v.i);
      return;
    }
    dst->tag = TAG_FLOAT;
    if (op == OP_IDIV) dst->v.n = floor(as_float(a) / as_float(b));
    else dst->v.n = float_mod(as_float(a), as_float(b));
    return;
  }
  /* bitwise: both operands need an exact integer value (luaG_tointerror names the first that does not have one) */
  int64_t x, y;
  if (!to_int_exact(a, &x)) rt_fail3("number", 0, " has no integer representation");
  if (!to_int_exact(b, &y)) rt_fail3("number", 1, " has no integer representation");
  int64_t r;
  if (op == OP_BAND) r = x & y;
  else if (op == OP_BOR) r = x | y;
  else if (op == OP_BXOR) r = x ^ y;
  else if (op == OP_SHL) r = shift_l(x, y);
  else r = shift_l(x, (int64_t)(0u - (uint64_t)y)); /* OP_SHR: shiftl by -y */
  dst->tag = TAG_INT;
  dst->v.i = r;
}

/* lstrlib.c's trymt: an arithmetic operation on a string that does not convert to a number, with no metamethod to take it,
 * is an error that names both types. */
static void string_arith_fail(const char *event, const LV *x, const LV *y) {
  char buf[200];
  snprintf(buf, sizeof buf, "attempt to %s a '%s' with a '%s'", event + 2, type_name(x->tag), type_name(y->tag));
  rt_fail(buf, -1);
}

/* The binary arithmetic and bitwise ops. Strings are coerced to numbers for arithmetic (lstrlib's metamethods do that in
 * Lua), not for bitwise ops. Otherwise the metamethods of the first operand, then the second, decide; without one the
 * error names the operand that is not a number. */
void lua54rt_arith(int op, LV *dst, LV *a, LV *b) {
  LV x = *a, y = *b;
  int bitwise = op >= OP_BAND && op <= OP_SHR;
  LV nx, ny;
  if (!bitwise && to_number(&x, &nx) && to_number(&y, &ny)) {
    numeric_arith(op, dst, &nx, &ny);
    return;
  }
  if (bitwise && is_number(&x) && is_number(&y)) {
    numeric_arith(op, dst, &x, &y);
    return;
  }
  LV h;
  const char *ev = arith_event(op);
  if (!bitwise && (x.tag == TAG_STR || y.tag == TAG_STR)) {
    /* the string library's metamethod takes the operation: a table operand with the event runs it instead */
    if (x.tag != TAG_STR && get_mt(&x, ev, &h)) {
      LV args[2] = {x, y};
      *dst = call_mmv(&h, args, 2);
      return;
    }
    if (y.tag != TAG_STR && get_mt(&y, ev, &h)) {
      LV args[2] = {x, y};
      *dst = call_mmv(&h, args, 2);
      return;
    }
    string_arith_fail(ev, &x, &y);
  }
  if (get_mt(&x, ev, &h) || get_mt(&y, ev, &h)) {
    LV args[2] = {x, y};
    *dst = call_mmv(&h, args, 2);
    return;
  }
  if (bitwise) {
    int culprit = is_number(&x) ? 1 : 0;
    type_fail("perform bitwise operation on", culprit ? y.tag : x.tag, culprit);
  }
  int culprit = to_number(&x, &nx) ? 1 : 0;   /* luaG_opinterror: the first operand unless it is a number */
  type_fail("perform arithmetic on", culprit ? y.tag : x.tag, culprit);
}

/* UNM and BNOT (the unary ops; their metamethods get the operand twice). */
void lua54rt_unary(int op, LV *dst, LV *a) {
  LV x = *a, nx, h;
  if (op == OP_UNM) {
    if (to_number(&x, &nx)) {
      if (nx.tag == TAG_INT) {
        dst->tag = TAG_INT;
        dst->v.i = (int64_t)(0u - (uint64_t)nx.v.i);
      } else {
        dst->tag = TAG_FLOAT;
        dst->v.n = -nx.v.n;
      }
      return;
    }
    if (x.tag == TAG_STR) string_arith_fail("__unm", &x, &x);
    if (get_mt(&x, "__unm", &h)) {
      LV args[2] = {x, x};
      *dst = call_mmv(&h, args, 2);
      return;
    }
    type_fail("perform arithmetic on", x.tag, 0);
  }
  /* OP_BNOT */
  int64_t i;
  if (is_number(&x)) {
    if (!to_int_exact(&x, &i)) rt_fail3("number", 0, " has no integer representation");
    dst->tag = TAG_INT;
    dst->v.i = (int64_t)~(uint64_t)i;
    return;
  }
  if (get_mt(&x, "__bnot", &h)) {
    LV args[2] = {x, x};
    *dst = call_mmv(&h, args, 2);
    return;
  }
  type_fail("perform bitwise operation on", x.tag, 0);
}

static int equal_values(const LV *a, const LV *b) {
  if (is_number(a) && is_number(b)) {
    if (a->tag == TAG_INT && b->tag == TAG_INT) return a->v.i == b->v.i;
    return as_float(a) == as_float(b);
  }
  if (a->tag != b->tag) return 0;
  return same_key(a, b);
}

static void order_fail(const LV *a, const LV *b) {
  const char *t1 = type_name(a->tag), *t2 = type_name(b->tag);
  char buf[160];
  if (strcmp(t1, t2) == 0) snprintf(buf, sizeof buf, "attempt to compare two %s values", t1);
  else snprintf(buf, sizeof buf, "attempt to compare %s with %s", t1, t2);
  rt_fail(buf, -1);
}

/* kind 0: a < b, 1: a <= b, 2: a == b. Returns 0 or 1. Metamethods __eq (for two tables), __lt and __le are tried on the
 * first operand, then the second. */
int lua54rt_cmp(int kind, LV *a, LV *b) {
  if (kind == 2) {
    if (equal_values(a, b)) return 1;
    LV h;
    if (a->tag == TAG_TABLE && b->tag == TAG_TABLE && (get_mt(a, "__eq", &h) || get_mt(b, "__eq", &h))) {
      LV args[2] = {*a, *b};
      LV r = call_mmv(&h, args, 2);
      return truthy(&r);
    }
    return 0;
  }
  if (a->tag == TAG_INT && b->tag == TAG_INT) {
    if (kind == 0) return a->v.i < b->v.i;
    return a->v.i <= b->v.i;
  }
  if (is_number(a) && is_number(b)) {
    double x = as_float(a), y = as_float(b);
    if (kind == 0) return x < y;
    return x <= y;
  }
  if (a->tag == TAG_STR && b->tag == TAG_STR) {
    const LString *x = (const LString *)a->v.p, *y = (const LString *)b->v.p;
    size_t m = x->len < y->len ? x->len : y->len;
    int c = memcmp(x->bytes, y->bytes, m);
    if (c == 0) c = x->len < y->len ? -1 : (x->len > y->len ? 1 : 0);
    return kind == 0 ? c < 0 : c <= 0;
  }
  LV h;
  const char *ev = kind == 0 ? "__lt" : "__le";
  if (get_mt(a, ev, &h) || get_mt(b, ev, &h)) {
    LV args[2] = {*a, *b};
    LV r = call_mmv(&h, args, 2);
    return truthy(&r);
  }
  order_fail(a, b);
  return 0;
}

/* OP_LEN: the length of a string, or the border of a table, or the __len metamethod. */
void lua54rt_len(LV *dst, LV *src) {
  LV x = *src, h;
  int64_t n;
  if (x.tag == TAG_STR) {
    n = (int64_t)((LString *)x.v.p)->len;
  } else if (x.tag == TAG_TABLE) {
    if (get_mt(&x, "__len", &h)) {
      LV args[2] = {x, x};
      *dst = call_mmv(&h, args, 2);
      return;
    }
    n = table_border((const Table *)x.v.p);
  } else {
    type_fail("get length of", x.tag, 0);
    return;
  }
  dst->tag = TAG_INT;
  dst->v.i = n;
}

/* Number to string as lobject.c's tostring: integers as %d, floats as %.14g, with ".0" when that looks like an integer. */
static size_t number_text(const LV *x, char *buf, size_t size) {
  if (x->tag == TAG_INT) return (size_t)snprintf(buf, size, "%lld", (long long)x->v.i);
  size_t n = (size_t)snprintf(buf, size, "%.14g", x->v.n);
  if (strspn(buf, "-0123456789") == n && n + 2 < size) {
    buf[n++] = '.';
    buf[n++] = '0';
    buf[n] = '\0';
  }
  return n;
}

/* Two strings or numbers as one string. */
static LV concat2(const LV *x, const LV *y) {
  char nx[64], ny[64];
  const char *px;
  const char *py;
  size_t lx, ly;
  if (x->tag == TAG_STR) {
    px = ((LString *)x->v.p)->bytes;
    lx = ((LString *)x->v.p)->len;
  } else {
    lx = number_text(x, nx, sizeof nx);
    px = nx;
  }
  if (y->tag == TAG_STR) {
    py = ((LString *)y->v.p)->bytes;
    ly = ((LString *)y->v.p)->len;
  } else {
    ly = number_text(y, ny, sizeof ny);
    py = ny;
  }
  char *buf = (char *)malloc(lx + ly + 1);
  if (buf == NULL) die("out of memory");
  memcpy(buf, px, lx);
  memcpy(buf + lx, py, ly);
  LV r = make_str(buf, lx + ly);
  free(buf);
  return r;
}

/* OP_CONCAT: R[dst] := base[0] .. ... .. base[n-1], from the right (luaV_concat), with __concat for other values. */
void lua54rt_concat(LV *dst, LV *base, int n) {
  LV acc = base[n - 1];
  for (int i = n - 2; i >= 0; --i) {
    LV l = base[i];
    int l_ok = l.tag == TAG_STR || is_number(&l);
    int acc_ok = acc.tag == TAG_STR || is_number(&acc);
    if (l_ok && acc_ok) {
      acc = concat2(&l, &acc);
      continue;
    }
    LV h;
    if (get_mt(&l, "__concat", &h) || get_mt(&acc, "__concat", &h)) {
      LV args[2] = {l, acc};
      acc = call_mmv(&h, args, 2);
      continue;
    }
    /* the culprit: l, unless l is fine; then acc, which is operand i+1 only while it is still the original value */
    if (!l_ok) type_fail("concatenate", l.tag, i);
    type_fail("concatenate", acc.tag, i + 1 == n - 1 ? i + 1 : -1);
  }
  *dst = acc;
}

/* Indexing. t[key] with __index: a table gives its raw value, then its __index (a function is called, a table is indexed
 * the same way). The first object is operand 0 for the error. */
void lua54rt_gettable(LV *dst, LV *t, LV *key) {
  LV obj = *t, k = *key;
  for (int loop = 0; loop < 2000; ++loop) {
    int operand = loop == 0 ? 0 : -1;
    LV h;
    if (obj.tag == TAG_TABLE) {
      LV v = raw_get((const Table *)obj.v.p, &k);
      if (v.tag != TAG_NIL) {
        *dst = v;
        return;
      }
      if (!get_mt(&obj, "__index", &h)) {
        dst->tag = TAG_NIL;
        return;
      }
    } else if (!get_mt(&obj, "__index", &h)) {
      type_fail("index", obj.tag, operand);
    }
    if (h.tag == TAG_LCL || h.tag == TAG_LCF) {
      LV args[2] = {obj, k};
      *dst = call_mmv(&h, args, 2);
      return;
    }
    obj = h;
  }
  rt_fail("'__index' chain too long; possible loop", -1);
}

/* Assignment t[key] = val, with __newindex when the key is absent. */
void lua54rt_settable(LV *t, LV *key, LV *val) {
  LV obj = *t, k = *key, v = *val;
  for (int loop = 0; loop < 2000; ++loop) {
    int operand = loop == 0 ? 0 : -1;
    LV h;
    if (obj.tag == TAG_TABLE) {
      LV cur = raw_get((const Table *)obj.v.p, &k);
      if (cur.tag != TAG_NIL || !get_mt(&obj, "__newindex", &h)) {
        raw_set((Table *)obj.v.p, &k, &v);
        return;
      }
    } else if (!get_mt(&obj, "__newindex", &h)) {
      type_fail("index", obj.tag, operand);
    }
    if (h.tag == TAG_LCL || h.tag == TAG_LCF) {
      LV args[3] = {obj, k, v};
      call_mmv(&h, args, 3);
      return;
    }
    obj = h;
  }
  rt_fail("'__newindex' chain too long; possible loop", -1);
}

/* OP_SETLIST: t[offset + j] := vals[j - 1] for j = 1..count. */
void lua54rt_setlist(LV *t, long offset, LV *vals, int count) {
  if (t->tag != TAG_TABLE) type_fail("index", t->tag, 0);
  for (int j = 1; j <= count; ++j) {
    LV k;
    k.tag = TAG_INT;
    k.v.i = offset + j;
    raw_set((Table *)t->v.p, &k, &vals[j - 1]);
  }
}

/* A closure for the main function of a chunk: upvalue 0 is _ENV, a fresh table; the others are nil. */
static void set_global(LV *env, const char *name, LV *value) {
  LV key = make_str(name, strlen(name));
  raw_set((Table *)env->v.p, &key, value);
}

void *lua54rt_make_main(void *fn, int nupvals) {
  LV cl;
  lua54rt_closure(&cl, fn, 0, nupvals);
  LClosure *c = (LClosure *)cl.v.p;
  for (int k = 0; k < nupvals; ++k) {
    UpVal *uv = (UpVal *)gc_alloc(GC_UPVAL, sizeof *uv);
    if (uv == NULL) die("out of memory");
    uv->open_next = NULL;
    if (k == 0) lua54rt_newtable(&uv->closed);
    else uv->closed.tag = TAG_NIL;
    uv->v = &uv->closed;
    c->upvals[k] = uv;
  }
  if (nupvals > 0) lua54rt_install_library(&c->upvals[0]->closed);
  return c;
}

/* ---- the host library: print, type, tostring, pairs, next, ipairs, select, setmetatable, getmetatable ---- */
static void write_value(FILE *f, const LV *v) {
  char buf[64];
  switch (v->tag) {
    case TAG_INT: fprintf(f, "%lld", (long long)v->v.i); break;
    case TAG_FLOAT:
      snprintf(buf, sizeof buf, "%.14g", v->v.n);
      if (strspn(buf, "-0123456789") == strlen(buf)) strcat(buf, ".0");
      fputs(buf, f);
      break;
    case TAG_STR: fwrite(((LString *)v->v.p)->bytes, 1, ((LString *)v->v.p)->len, f); break;
    case TAG_NIL: fputs("nil", f); break;
    case TAG_FALSE: fputs("false", f); break;
    case TAG_TRUE: fputs("true", f); break;
    case TAG_TABLE: fprintf(f, "table: %p", v->v.p); break;
    case TAG_LCL:
    case TAG_LCF: fprintf(f, "function: %p", v->v.p); break;
    default: fprintf(f, "?"); break;
  }
}

static void expect_arg(int nargs, int k, const char *fname, const char *what) {
  if (nargs < k) {
    char buf[160];
    snprintf(buf, sizeof buf, "bad argument #%d to '%s' (%s expected, got no value)", k, fname, what);
    rt_fail(buf, -1);
  }
}

static Table *expect_table(const LV *v, int k, const char *fname) {
  if (v->tag != TAG_TABLE) {
    char buf[160];
    snprintf(buf, sizeof buf, "bad argument #%d to '%s' (table expected, got %s)", k, fname, type_name(v->tag));
    rt_fail(buf, -1);
  }
  return (Table *)v->v.p;
}

/* luaL_tolstring's __tostring: the string the metamethod returns, when the value has one. */
static int tostring_mm(const LV *v, LV *out) {
  LV h;
  if (!get_mt(v, "__tostring", &h)) return 0;
  LV args[1] = {*v};
  LV r = call_mmv(&h, args, 1);
  if (r.tag != TAG_STR) rt_fail("'__tostring' must return a string", -1);
  *out = r;
  return 1;
}

static int host_print(LV *out, LV *args, int nargs) {
  (void)out;
  for (int k = 0; k < nargs; ++k) {
    if (k > 0) fputc('\t', stdout);
    LV s;
    if (tostring_mm(&args[k], &s)) fwrite(((LString *)s.v.p)->bytes, 1, ((LString *)s.v.p)->len, stdout);
    else write_value(stdout, &args[k]);
  }
  fputc('\n', stdout);
  return 0;
}

static void set_string(LV *dst, const char *s) { *dst = make_str(s, strlen(s)); }

static int host_type(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "type", "value");
  set_string(&out[0], type_name(args[0].tag));
  return 1;
}

static int host_tostring(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "tostring", "value");
  if (args[0].tag == TAG_STR) {
    out[0] = args[0];
    return 1;
  }
  if (tostring_mm(&args[0], &out[0])) return 1;
  char *buf = NULL;
  size_t size = 0;
  FILE *f = open_memstream(&buf, &size);
  if (f == NULL) die("out of memory");
  write_value(f, &args[0]);
  fclose(f);
  out[0] = make_str(buf, size);
  free(buf);
  return 1;
}

static LV next_fn, ipairs_iter_fn;

/* next(t, k): the entry after k, in the order of the nodes; nil at the end. */
static int host_next(LV *out, LV *args, int nargs) {
  Table *t = expect_table(&args[0], 1, "next");
  size_t start = 0;
  if (nargs >= 2 && args[1].tag != TAG_NIL) {
    LV k = normal_key(&args[1]);
    Node *nd = table_find(t, &k);
    if (nd == NULL) rt_fail("invalid key to 'next'", -1);
    start = (size_t)(nd - t->nodes) + 1;
  }
  for (size_t i = start; i < t->cap; ++i) {
    if (t->nodes[i].used && t->nodes[i].val.tag != TAG_NIL) {
      out[0] = t->nodes[i].key;
      out[1] = t->nodes[i].val;
      return 2;
    }
  }
  out[0].tag = TAG_NIL;
  return 1;
}

static int host_pairs(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "pairs", "table");
  expect_table(&args[0], 1, "pairs");
  out[0] = next_fn;
  out[1] = args[0];
  out[2].tag = TAG_NIL;
  return 3;
}

static int host_ipairs_iter(LV *out, LV *args, int nargs) {
  (void)nargs;
  LV i;
  i.tag = TAG_INT;
  i.v.i = args[1].v.i + 1;
  LV v;
  lua54rt_gettable(&v, &args[0], &i);
  if (v.tag == TAG_NIL) {
    out[0].tag = TAG_NIL;
    return 1;
  }
  out[0] = i;
  out[1] = v;
  return 2;
}

static int host_ipairs(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "ipairs", "table");
  out[0] = ipairs_iter_fn;
  out[1] = args[0];
  out[2].tag = TAG_INT;
  out[2].v.i = 0;
  return 3;
}

/* select('#', ...) or select(n, ...): the values from the n-th on. */
/* lbaselib.c's luaB_select: the index counts the selector too, so the values are args[i..nargs-1]; a negative index counts
 * from the end. */
static int host_select(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "select", "number");
  if (args[0].tag == TAG_STR && ((LString *)args[0].v.p)->bytes[0] == '#') {
    out[0].tag = TAG_INT;
    out[0].v.i = nargs - 1;
    return 1;
  }
  int64_t i = arg_int(args, nargs, 1, "select");
  if (i < 0) i = nargs + i;
  else if (i > nargs) i = nargs;
  if (i < 1) arg_fail(1, "select", "index out of range");
  int produced = 0;
  for (int64_t k = i; k < nargs && produced < 64; ++k) out[produced++] = args[k];
  return produced;
}

static int host_setmetatable(LV *out, LV *args, int nargs) {
  Table *t = expect_table(&args[0], 1, "setmetatable");
  if (nargs < 2 || (args[1].tag != TAG_NIL && args[1].tag != TAG_TABLE))
    rt_fail("bad argument #2 to 'setmetatable' (nil or table expected)", -1);
  t->meta = args[1].tag == TAG_TABLE ? (Table *)args[1].v.p : NULL;
  out[0] = args[0];
  return 1;
}

static int host_getmetatable(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "getmetatable", "value");
  out[0].tag = TAG_NIL;
  if (args[0].tag == TAG_TABLE && ((Table *)args[0].v.p)->meta != NULL) {
    out[0].tag = TAG_TABLE;
    out[0].v.p = ((Table *)args[0].v.p)->meta;
  }
  return 1;
}

void lua54rt_install_library(LV *env) {
  make_host(&next_fn, host_next);
  make_host(&ipairs_iter_fn, host_ipairs_iter);
  LV f;
  make_host(&f, host_print);
  set_global(env, "print", &f);
  make_host(&f, host_type);
  set_global(env, "type", &f);
  make_host(&f, host_tostring);
  set_global(env, "tostring", &f);
  make_host(&f, host_pairs);
  set_global(env, "pairs", &f);
  set_global(env, "next", &next_fn);
  make_host(&f, host_ipairs);
  set_global(env, "ipairs", &f);
  make_host(&f, host_select);
  set_global(env, "select", &f);
  make_host(&f, host_setmetatable);
  set_global(env, "setmetatable", &f);
  make_host(&f, host_getmetatable);
  set_global(env, "getmetatable", &f);
  install_more(env);
}

/* ---- the base library's errors and protected calls (lbaselib.c) ---- */

/* lua_error with a value: a protected call (pcall) takes it; otherwise lua.c reports it and stops. */
static void host_raise(LV v) { raise_value(v); }

/* The first line of a site (its "source:line:"), copied to buf. */
static void first_line(const char *s, char *buf, size_t size) {
  buf[0] = '\0';
  if (s == NULL) return;
  const char *nl = strchr(s, '\n');
  size_t len = nl != NULL ? (size_t)(nl - s) : strlen(s);
  if (len >= size) len = size - 1;
  memcpy(buf, s, len);
  buf[len] = '\0';
}

/* luaL_where for level: the position of the function at that level of the call stack, "" when it is not a Lua function. */
static void level_where(int64_t level, char *buf, size_t size) {
  int64_t idx = call_depth - level;
  if (idx < 0 || idx >= CALLSTACK_MAX) {
    buf[0] = '\0';
    return;
  }
  first_line(callsite[idx], buf, size);
}

/* error(msg [, level]): a string message gets the position of the level, as luaB_error does. */
static int host_error(LV *out, LV *args, int nargs) {
  (void)out;
  LV msg = nargs >= 1 ? args[0] : (LV){0};
  int64_t level = opt_int(args, nargs, 2, "error", 1);
  if (msg.tag == TAG_STR && level > 0) {
    char where[512];
    level_where(level, where, sizeof where);
    if (where[0] != '\0') {
      size_t n = strlen(where) + 1 + ((LString *)msg.v.p)->len;
      char *buf = (char *)malloc(n + 1);
      if (buf == NULL) die("out of memory");
      snprintf(buf, n + 1, "%s %s", where, ((LString *)msg.v.p)->bytes);
      msg = make_str(buf, n);
      free(buf);
    }
  }
  host_raise(msg);
  return 0;
}

static int host_assert(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "assert", "value");
  if (truthy(&args[0])) {
    for (int k = 0; k < nargs && k < 64; ++k) out[k] = args[k];
    return nargs < 64 ? nargs : 64;
  }
  if (nargs >= 2) host_raise(args[1]);
  rt_fail("assertion failed!", -1);
  return 0;
}

/* pcall(f, ...): the results of f behind true, or false and the error value. The error longjmps to here. */
/* pcall(f, ...) and xpcall(f, msgh, ...): the results of f behind true, or false and the error value (xpcall gives
 * msgh's result for it). The error longjmps to here, with the call stack restored to its depth at the call. */
static int protected_call(LV *out, LV *args, int nargs, int handler_arg) {
  LV handler = args[handler_arg ? 1 : 0];   /* the callee's frame overwrites args[1..], so it is taken first */
  PCall p;
  p.prev = pcall_top;
  p.base = args + (handler_arg ? 2 : 1);
  const char *saved_site = site;
  int saved_depth = call_depth;
  pcall_top = &p;
  if (setjmp(p.jb) == 0) {
    LV fn = args[0];
    LV res[64];
    site = NULL;   /* a function called from here has no caller position, as in Lua */
    lua54rt_call(&fn, nargs - (handler_arg ? 2 : 1), args + (handler_arg ? 2 : 1), res, -1, 0);
    site = saved_site;
    pcall_top = p.prev;
    int n = lua54rt_top < 63 ? lua54rt_top : 63;
    out[0].tag = TAG_TRUE;
    for (int k = 0; k < n; ++k) out[k + 1] = res[k];
    return n + 1;
  }
  site = saved_site;
  call_depth = saved_depth;
  pcall_top = p.prev;
  close_to(p.base, &p.err);   /* the upvalues and to-be-closed variables of the frames the error left */
  out[0].tag = TAG_FALSE;
  if (!handler_arg) {
    out[1] = p.err;
    return 2;
  }
  LV frame[1] = {p.err}, ret[4];
  lua54rt_call(&handler, 1, frame, ret, 1, 0);
  out[1] = ret[0];
  return 2;
}

static int host_pcall(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "pcall", "value");
  return protected_call(out, args, nargs, 0);
}

static int host_xpcall(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 2, "xpcall", "function");
  if (args[1].tag != TAG_LCL && args[1].tag != TAG_LCF) lib_arg_error(2, "xpcall", "function", type_name(args[1].tag));
  return protected_call(out, args, nargs, 1);
}

/* ---- argument checks (lauxlib.c's luaL_check*) ---- */
static void lib_arg_error(int k, const char *fname, const char *what, const char *got) {
  char buf[256];
  snprintf(buf, sizeof buf, "bad argument #%d to '%s' (%s expected, got %s)", k, fname, what, got);
  rt_fail(buf, -1);
}

/* luaL_argerror with a message of its own: "bad argument #k to 'fname' (msg)". */
static void arg_fail(int k, const char *fname, const char *msg) {
  char buf[256];
  snprintf(buf, sizeof buf, "bad argument #%d to '%s' (%s)", k, fname, msg);
  rt_fail(buf, -1);
}

static const char *arg_typename(const LV *args, int nargs, int k) {
  return k > nargs ? "no value" : type_name(args[k - 1].tag);
}

static LV arg_str(const LV *args, int nargs, int k, const char *fname) {
  if (k <= nargs && args[k - 1].tag == TAG_STR) return args[k - 1];
  if (k <= nargs && is_number(&args[k - 1])) {
    char buf[64];
    size_t n = number_text(&args[k - 1], buf, sizeof buf);
    return make_str(buf, n);
  }
  lib_arg_error(k, fname, "string", arg_typename(args, nargs, k));
  return make_str("", 0);
}

static int64_t arg_int(const LV *args, int nargs, int k, const char *fname) {
  LV n;
  if (k <= nargs && to_number(&args[k - 1], &n)) {
    if (n.tag == TAG_INT) return n.v.i;
    int64_t i;
    if (to_int_exact(&n, &i)) return i;
    arg_fail(k, fname, "number has no integer representation");
  }
  lib_arg_error(k, fname, "number", arg_typename(args, nargs, k));
  return 0;
}

static int64_t opt_int(const LV *args, int nargs, int k, const char *fname, int64_t def) {
  if (k > nargs || args[k - 1].tag == TAG_NIL) return def;
  return arg_int(args, nargs, k, fname);
}

static Table *arg_table(const LV *args, int nargs, int k, const char *fname) {
  if (k <= nargs && args[k - 1].tag == TAG_TABLE) return (Table *)args[k - 1].v.p;
  lib_arg_error(k, fname, "table", arg_typename(args, nargs, k));
  return NULL;
}

static int host_tonumber(LV *out, LV *args, int nargs) {
  if (nargs < 2 || args[1].tag == TAG_NIL) {
    expect_arg(nargs, 1, "tonumber", "value");
    LV n;
    if (to_number(&args[0], &n)) out[0] = n;
    else out[0].tag = TAG_NIL;
    return 1;
  }
  int64_t base = arg_int(args, nargs, 2, "tonumber");
  if (args[0].tag != TAG_STR) lib_arg_error(1, "tonumber", "string", arg_typename(args, nargs, 1));
  if (base < 2 || base > 36) rt_fail("bad argument #2 to 'tonumber' (base out of range)", -1);
  const LString *s = (const LString *)args[0].v.p;
  size_t i = 0;
  while (i < s->len && isspace((unsigned char)s->bytes[i])) i++;
  int neg = 0;
  if (i < s->len && (s->bytes[i] == '-' || s->bytes[i] == '+')) neg = s->bytes[i++] == '-';
  int digits = 0;
  uint64_t acc = 0;
  while (i < s->len) {
    int c = (unsigned char)s->bytes[i];
    int d = isdigit(c) ? c - '0' : isalpha(c) ? tolower(c) - 'a' + 10 : 99;
    if (d >= base) break;
    acc = acc * (uint64_t)base + (uint64_t)d;
    digits++;
    i++;
  }
  while (i < s->len && isspace((unsigned char)s->bytes[i])) i++;
  if (digits == 0 || i != s->len) out[0].tag = TAG_NIL;
  else {
    out[0].tag = TAG_INT;
    out[0].v.i = (int64_t)(neg ? 0u - acc : acc);
  }
  return 1;
}

static int host_rawget(LV *out, LV *args, int nargs) {
  Table *t = arg_table(args, nargs, 1, "rawget");
  expect_arg(nargs, 2, "rawget", "value");
  out[0] = raw_get(t, &args[1]);
  return 1;
}

static int host_rawset(LV *out, LV *args, int nargs) {
  Table *t = arg_table(args, nargs, 1, "rawset");
  expect_arg(nargs, 3, "rawset", "value");
  raw_set(t, &args[1], &args[2]);
  out[0] = args[0];
  return 1;
}

static int host_rawequal(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 2, "rawequal", "value");
  out[0].tag = equal_values(&args[0], &args[1]) ? TAG_TRUE : TAG_FALSE;
  return 1;
}

static int host_rawlen(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "rawlen", "table or string");
  out[0].tag = TAG_INT;
  if (args[0].tag == TAG_STR) out[0].v.i = (int64_t)((LString *)args[0].v.p)->len;
  else if (args[0].tag == TAG_TABLE) out[0].v.i = table_border((const Table *)args[0].v.p);
  else lib_arg_error(1, "rawlen", "table or string", arg_typename(args, nargs, 1));
  return 1;
}

/* ---- table ---- */
static int host_tinsert(LV *out, LV *args, int nargs) {
  (void)out;
  Table *t = arg_table(args, nargs, 1, "insert");
  int64_t e = table_border(t) + 1;
  LV key;
  if (nargs == 2) {
    key.tag = TAG_INT;
    key.v.i = e;
    raw_set(t, &key, &args[1]);
    return 0;
  }
  if (nargs != 3) rt_fail("wrong number of arguments to 'insert'", -1);
  int64_t pos = arg_int(args, nargs, 2, "insert");
  if ((uint64_t)pos - 1u >= (uint64_t)e) arg_fail(2, "insert", "position out of bounds");
  for (int64_t i = e; i > pos; --i) {
    LV from, to;
    to.tag = TAG_INT;
    to.v.i = i;
    from.tag = TAG_INT;
    from.v.i = i - 1;
    LV v = raw_get(t, &from);
    raw_set(t, &to, &v);
  }
  key.tag = TAG_INT;
  key.v.i = pos;
  raw_set(t, &key, &args[2]);
  return 0;
}

static int host_tremove(LV *out, LV *args, int nargs) {
  Table *t = arg_table(args, nargs, 1, "remove");
  int64_t size = table_border(t);
  int64_t pos = opt_int(args, nargs, 2, "remove", size);
  if (pos != size && (uint64_t)pos - 1u > (uint64_t)size) arg_fail(2, "remove", "position out of bounds");
  LV key;
  key.tag = TAG_INT;
  key.v.i = pos;
  out[0] = raw_get(t, &key);
  for (; pos < size; pos++) {
    LV from, to;
    from.tag = TAG_INT;
    from.v.i = pos + 1;
    to.tag = TAG_INT;
    to.v.i = pos;
    LV x = raw_get(t, &from);
    raw_set(t, &to, &x);
  }
  LV nil;
  nil.tag = TAG_NIL;
  key.v.i = pos;
  raw_set(t, &key, &nil);
  return 1;
}

static int host_tconcat(LV *out, LV *args, int nargs) {
  Table *t = arg_table(args, nargs, 1, "concat");
  LV sep = nargs >= 2 && args[1].tag != TAG_NIL ? arg_str(args, nargs, 2, "concat") : make_str("", 0);
  int64_t i = opt_int(args, nargs, 3, "concat", 1);
  int64_t j = opt_int(args, nargs, 4, "concat", table_border(t));
  size_t cap = 64, len = 0;
  char *buf = (char *)malloc(cap);
  if (buf == NULL) die("out of memory");
  for (int64_t k = i; k <= j; ++k) {
    LV key;
    key.tag = TAG_INT;
    key.v.i = k;
    LV v = raw_get(t, &key);
    const char *text;
    size_t n;
    char num[64];
    if (v.tag == TAG_STR) {
      text = ((LString *)v.v.p)->bytes;
      n = ((LString *)v.v.p)->len;
    } else if (is_number(&v)) {
      n = number_text(&v, num, sizeof num);
      text = num;
    } else {
      char msg[160];
      snprintf(msg, sizeof msg, "invalid value (at index %lld) in table for 'concat'", (long long)k);
      free(buf);
      rt_fail(msg, -1);
      return 0;
    }
    size_t sepn = k > i ? ((LString *)sep.v.p)->len : 0;
    while (len + n + sepn + 1 > cap) {
      cap *= 2;
      buf = (char *)realloc(buf, cap);
      if (buf == NULL) die("out of memory");
    }
    if (sepn > 0) {
      memcpy(buf + len, ((LString *)sep.v.p)->bytes, sepn);
      len += sepn;
    }
    memcpy(buf + len, text, n);
    len += n;
  }
  out[0] = make_str(buf, len);
  free(buf);
  return 1;
}

static int host_tunpack(LV *out, LV *args, int nargs) {
  Table *t = nargs >= 1 && args[0].tag == TAG_TABLE ? (Table *)args[0].v.p : NULL;
  int64_t i = opt_int(args, nargs, 2, "unpack", 1);
  int64_t j = opt_int(args, nargs, 3, "unpack", t ? table_border(t) : 0);
  if (t == NULL) lib_arg_error(1, "unpack", "table", arg_typename(args, nargs, 1));
  if (j - i >= 63) rt_fail("too many results to unpack", -1);
  int n = 0;
  for (int64_t k = i; k <= j; ++k) {
    LV key;
    key.tag = TAG_INT;
    key.v.i = k;
    out[n++] = raw_get(t, &key);
  }
  return n;
}

/* ---- math ---- */
static int host_mfloor(LV *out, LV *args, int nargs) {
  LV n = nargs >= 1 ? args[0] : (LV){0};
  LV x;
  if (!to_number(&n, &x)) lib_arg_error(1, "floor", "number", arg_typename(args, nargs, 1));
  if (x.tag == TAG_INT) {
    out[0] = x;
    return 1;
  }
  double f = floor(x.v.n);
  out[0].tag = TAG_FLOAT;
  out[0].v.n = f;
  if (f >= -9223372036854775808.0 && f < 9223372036854775808.0) {
    out[0].tag = TAG_INT;
    out[0].v.i = (int64_t)f;
  }
  return 1;
}

static int host_mceil(LV *out, LV *args, int nargs) {
  LV n = nargs >= 1 ? args[0] : (LV){0};
  LV x;
  if (!to_number(&n, &x)) lib_arg_error(1, "ceil", "number", arg_typename(args, nargs, 1));
  if (x.tag == TAG_INT) {
    out[0] = x;
    return 1;
  }
  double f = ceil(x.v.n);
  out[0].tag = TAG_FLOAT;
  out[0].v.n = f;
  if (f >= -9223372036854775808.0 && f < 9223372036854775808.0) {
    out[0].tag = TAG_INT;
    out[0].v.i = (int64_t)f;
  }
  return 1;
}

static int host_mabs(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "abs", "number");
  LV x;
  if (!to_number(&args[0], &x)) lib_arg_error(1, "abs", "number", arg_typename(args, nargs, 1));
  if (x.tag == TAG_INT) {
    out[0].tag = TAG_INT;
    out[0].v.i = x.v.i < 0 ? (int64_t)(0u - (uint64_t)x.v.i) : x.v.i;
  } else {
    out[0].tag = TAG_FLOAT;
    out[0].v.n = fabs(x.v.n);
  }
  return 1;
}

static int host_mminmax(LV *out, LV *args, int nargs, int want_max, const char *fname) {
  if (nargs < 1) lib_arg_error(1, fname, "number", "no value");
  LV best;
  if (!to_number(&args[0], &best)) lib_arg_error(1, fname, "number", arg_typename(args, nargs, 1));
  for (int k = 2; k <= nargs; ++k) {
    LV x;
    if (!to_number(&args[k - 1], &x)) lib_arg_error(k, fname, "number", arg_typename(args, nargs, k));
    if (want_max ? lua54rt_cmp(0, &best, &x) : lua54rt_cmp(0, &x, &best)) best = x;
  }
  out[0] = best;
  return 1;
}
static int host_mmax(LV *out, LV *args, int nargs) { return host_mminmax(out, args, nargs, 1, "max"); }
static int host_mmin(LV *out, LV *args, int nargs) { return host_mminmax(out, args, nargs, 0, "min"); }

static int host_msqrt(LV *out, LV *args, int nargs) {
  LV x;
  if (nargs < 1 || !to_number(&args[0], &x)) lib_arg_error(1, "sqrt", "number", arg_typename(args, nargs, 1));
  out[0].tag = TAG_FLOAT;
  out[0].v.n = sqrt(as_float(&x));
  return 1;
}

static int host_mtointeger(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "tointeger", "value");
  int64_t i;
  if (args[0].tag == TAG_INT) out[0] = args[0];
  else if (args[0].tag == TAG_FLOAT && to_int_exact(&args[0], &i)) {
    out[0].tag = TAG_INT;
    out[0].v.i = i;
  } else out[0].tag = TAG_NIL;
  return 1;
}

/* ---- string ---- */
static int host_slen(LV *out, LV *args, int nargs) {
  LV s = arg_str(args, nargs, 1, "len");
  out[0].tag = TAG_INT;
  out[0].v.i = (int64_t)((LString *)s.v.p)->len;
  return 1;
}

/* Lua's index translation for string.sub and friends: negative counts from the end. */
static int64_t str_posrelat(int64_t pos, size_t len) {
  if (pos >= 0) return pos;
  if ((size_t)(-pos) > len) return 0;
  return (int64_t)len + pos + 1;
}

static int host_ssub(LV *out, LV *args, int nargs) {
  LV s = arg_str(args, nargs, 1, "sub");
  const LString *str = (const LString *)s.v.p;
  int64_t i = str_posrelat(opt_int(args, nargs, 2, "sub", 1), str->len);
  int64_t j = str_posrelat(opt_int(args, nargs, 3, "sub", -1), str->len);
  if (i < 1) i = 1;
  if (j > (int64_t)str->len) j = (int64_t)str->len;
  if (i > j) out[0] = make_str("", 0);
  else out[0] = make_str(str->bytes + i - 1, (size_t)(j - i + 1));
  return 1;
}

static int host_supper(LV *out, LV *args, int nargs) {
  LV s = arg_str(args, nargs, 1, "upper");
  const LString *str = (const LString *)s.v.p;
  char *buf = (char *)malloc(str->len + 1);
  if (buf == NULL) die("out of memory");
  for (size_t k = 0; k < str->len; ++k) buf[k] = (char)toupper((unsigned char)str->bytes[k]);
  out[0] = make_str(buf, str->len);
  free(buf);
  return 1;
}

static int host_slower(LV *out, LV *args, int nargs) {
  LV s = arg_str(args, nargs, 1, "lower");
  const LString *str = (const LString *)s.v.p;
  char *buf = (char *)malloc(str->len + 1);
  if (buf == NULL) die("out of memory");
  for (size_t k = 0; k < str->len; ++k) buf[k] = (char)tolower((unsigned char)str->bytes[k]);
  out[0] = make_str(buf, str->len);
  free(buf);
  return 1;
}

static int host_srep(LV *out, LV *args, int nargs) {
  LV s = arg_str(args, nargs, 1, "rep");
  int64_t n = arg_int(args, nargs, 2, "rep");
  LV sep = nargs >= 3 && args[2].tag != TAG_NIL ? arg_str(args, nargs, 3, "rep") : make_str("", 0);
  const LString *str = (const LString *)s.v.p, *sp = (const LString *)sep.v.p;
  if (n <= 0) {
    out[0] = make_str("", 0);
    return 1;
  }
  size_t total = (size_t)n * str->len + (size_t)(n - 1) * sp->len;
  char *buf = (char *)malloc(total + 1);
  if (buf == NULL) die("out of memory");
  size_t pos = 0;
  for (int64_t k = 0; k < n; ++k) {
    if (k > 0) {
      memcpy(buf + pos, sp->bytes, sp->len);
      pos += sp->len;
    }
    memcpy(buf + pos, str->bytes, str->len);
    pos += str->len;
  }
  out[0] = make_str(buf, total);
  free(buf);
  return 1;
}

static int host_sreverse(LV *out, LV *args, int nargs) {
  LV s = arg_str(args, nargs, 1, "reverse");
  const LString *str = (const LString *)s.v.p;
  char *buf = (char *)malloc(str->len + 1);
  if (buf == NULL) die("out of memory");
  for (size_t k = 0; k < str->len; ++k) buf[k] = str->bytes[str->len - 1 - k];
  out[0] = make_str(buf, str->len);
  free(buf);
  return 1;
}

static int host_sbyte(LV *out, LV *args, int nargs) {
  LV s = arg_str(args, nargs, 1, "byte");
  const LString *str = (const LString *)s.v.p;
  int64_t i = str_posrelat(opt_int(args, nargs, 2, "byte", 1), str->len);
  int64_t j = str_posrelat(opt_int(args, nargs, 3, "byte", i), str->len);
  if (i < 1) i = 1;
  if (j > (int64_t)str->len) j = (int64_t)str->len;
  int n = 0;
  for (int64_t k = i; k <= j && n < 64; ++k) {
    out[n].tag = TAG_INT;
    out[n].v.i = (unsigned char)str->bytes[k - 1];
    n++;
  }
  return n;
}

static int host_schar(LV *out, LV *args, int nargs) {
  char *buf = (char *)malloc((size_t)nargs + 1);
  if (buf == NULL) die("out of memory");
  for (int k = 1; k <= nargs; ++k) buf[k - 1] = (char)arg_int(args, nargs, k, "char");
  out[0] = make_str(buf, (size_t)nargs);
  free(buf);
  return 1;
}

/* string.format: %d %i %u %c %x %X %o %e %E %f %g %G %s %q %% with flags, width and precision as printf. */
/* %q (lstrlib.c's addliteral): a literal that reads back as the same value. Strings are quoted with the escapes of
 * addquoted; integers are decimal (the minimum as hex); floats are hexadecimal, or 1e9999, -1e9999 and (0/0). */
static LV literal_of(const LV *v, int argno) {
  char buf[64];
  switch (v->tag) {
    case TAG_STR: {
      const LString *s = (const LString *)v->v.p;
      char *out = (char *)malloc(s->len * 4 + 3);
      if (out == NULL) die("out of memory");
      size_t n = 0;
      out[n++] = '"';
      for (size_t k = 0; k < s->len; ++k) {
        unsigned char c = (unsigned char)s->bytes[k];
        if (c == '"' || c == '\\' || c == '\n') {
          out[n++] = '\\';
          out[n++] = (char)c;
        } else if (iscntrl(c)) {
          int next = k + 1 < s->len ? (unsigned char)s->bytes[k + 1] : 0;
          n += (size_t)sprintf(out + n, isdigit(next) ? "\\%03d" : "\\%d", (int)c);
        } else {
          out[n++] = (char)c;
        }
      }
      out[n++] = '"';
      LV r = make_str(out, n);
      free(out);
      return r;
    }
    case TAG_INT:
      if (v->v.i == INT64_MIN) snprintf(buf, sizeof buf, "0x%llx", (unsigned long long)v->v.i);
      else snprintf(buf, sizeof buf, "%lld", (long long)v->v.i);
      return make_str(buf, strlen(buf));
    case TAG_FLOAT: {
      double n = v->v.n;
      const char *s = buf;
      if (n == HUGE_VAL) s = "1e9999";
      else if (n == -HUGE_VAL) s = "-1e9999";
      else if (n != n) s = "(0/0)";
      else snprintf(buf, sizeof buf, "%a", n);
      return make_str(s, strlen(s));
    }
    case TAG_NIL: return make_str("nil", 3);
    case TAG_FALSE: return make_str("false", 5);
    case TAG_TRUE: return make_str("true", 4);
    default: break;
  }
  arg_fail(argno, "format", "value has no literal form");
  return make_str("", 0);
}

static int host_sformat(LV *out, LV *args, int nargs) {
  LV fmt = arg_str(args, nargs, 1, "format");
  const LString *f = (const LString *)fmt.v.p;
  size_t cap = 256, len = 0;
  char *buf = (char *)malloc(cap);
  if (buf == NULL) die("out of memory");
  int arg = 1;
  for (size_t i = 0; i < f->len; ++i) {
    char c = f->bytes[i];
    if (c != '%') {
      buf[len++] = c;
      if (len + 1 >= cap) {
        cap *= 2;
        buf = (char *)realloc(buf, cap);
      }
      continue;
    }
    if (i + 1 < f->len && f->bytes[i + 1] == '%') {
      buf[len++] = '%';
      i++;
      continue;
    }
    size_t start = i;
    i++;
    while (i < f->len && strchr("-+ #0123456789.", f->bytes[i]) != NULL) i++;
    if (i >= f->len) rt_fail("invalid conversion to 'format'", -1);
    char conv = f->bytes[i];
    char spec[32];
    size_t sl = i - start;
    if (sl + 2 > sizeof spec) rt_fail("invalid conversion to 'format'", -1);
    memcpy(spec, f->bytes + start, sl);
    spec[sl] = '\0';
    arg++;
    if (arg > nargs) arg_fail(arg, "format", "no value");
    char piece[512];
    int pl = 0;
    switch (conv) {
      case 'd':
      case 'i': {
        int64_t v = arg_int(args, nargs, arg, "format");
        snprintf(spec + sl, 4, "lld");
        pl = snprintf(piece, sizeof piece, spec, (long long)v);
        break;
      }
      case 'u':
      case 'x':
      case 'X':
      case 'o': {
        int64_t v = arg_int(args, nargs, arg, "format");
        char cv[3] = {conv == 'u' ? 'd' : conv, '\0', '\0'};
        snprintf(spec + sl, 4, "ll%c", cv[0]);
        pl = snprintf(piece, sizeof piece, spec, (unsigned long long)v);
        break;
      }
      case 'c': {
        int64_t v = arg_int(args, nargs, arg, "format");
        snprintf(spec + sl, 2, "c");
        pl = snprintf(piece, sizeof piece, spec, (int)v);
        break;
      }
      case 'q': {
        if (sl != 1) rt_fail("specifier '%q' cannot have modifiers", -1);
        LV lit = literal_of(&args[arg - 1], arg);
        const LString *ls = (const LString *)lit.v.p;
        if (len + ls->len + 1 >= cap) {
          while (len + ls->len + 1 >= cap) cap *= 2;
          buf = (char *)realloc(buf, cap);
        }
        memcpy(buf + len, ls->bytes, ls->len);
        len += ls->len;
        pl = 0;
        break;
      }
      case 'a':
      case 'A':
      case 'e':
      case 'E':
      case 'f':
      case 'g':
      case 'G': {
        LV n;
        if (arg > nargs || !to_number(&args[arg - 1], &n)) lib_arg_error(arg, "format", "number", arg_typename(args, nargs, arg));
        snprintf(spec + sl, 2, "%c", conv);
        pl = snprintf(piece, sizeof piece, spec, as_float(&n));
        break;
      }
      case 's': {
        LV s;
        if (arg > nargs) lib_arg_error(arg, "format", "value", "no value");
        if (args[arg - 1].tag == TAG_STR) s = args[arg - 1];
        else if (!tostring_mm(&args[arg - 1], &s)) {
          char num[64];
          if (is_number(&args[arg - 1])) {
            size_t n = number_text(&args[arg - 1], num, sizeof num);
            s = make_str(num, n);
          } else {
            char *tb = NULL;
            size_t tsz = 0;
            FILE *tf = open_memstream(&tb, &tsz);
            write_value(tf, &args[arg - 1]);
            fclose(tf);
            s = make_str(tb, tsz);
            free(tb);
          }
        }
        const LString *ss = (const LString *)s.v.p;
        if (sl == 1) {
          if (len + ss->len + 1 >= cap) {
            while (len + ss->len + 1 >= cap) cap *= 2;
            buf = (char *)realloc(buf, cap);
          }
          memcpy(buf + len, ss->bytes, ss->len);
          len += ss->len;
          pl = 0;
        } else {
          snprintf(spec + sl, 2, "s");
          char *big = (char *)malloc(ss->len + 512);
          if (big == NULL) die("out of memory");
          pl = snprintf(big, ss->len + 512, spec, ss->bytes);
          if (len + (size_t)pl + 1 >= cap) {
            while (len + (size_t)pl + 1 >= cap) cap *= 2;
            buf = (char *)realloc(buf, cap);
          }
          memcpy(buf + len, big, (size_t)pl);
          len += (size_t)pl;
          free(big);
          pl = 0;
        }
        break;
      }
      default: {
        char msg[96];
        snprintf(msg, sizeof msg, "invalid conversion '%%%c' to 'format'", conv);
        rt_fail(msg, -1);
      }
    }
    if (conv != 's' || sl != 1) {
      if (len + (size_t)pl + 1 >= cap) {
        while (len + (size_t)pl + 1 >= cap) cap *= 2;
        buf = (char *)realloc(buf, cap);
      }
      memcpy(buf + len, piece, (size_t)pl);
      len += (size_t)pl;
    }
  }
  out[0] = make_str(buf, len);
  free(buf);
  return 1;
}

/* Keeps the object of a string alive until here: the matcher holds only pointers into its bytes. */
static void keep_alive(const void *p) { __asm__ volatile("" : : "g"(p) : "memory"); }

/* ---- string: pattern matching (lstrlib.c's matching functions, ported) ----
 * find, match, gmatch and gsub. The matcher reads the bytes of the subject and the pattern, which are strings, so the byte
 * after each end is the NUL of the string, as in C. A capture is a Lua value: a substring, or an integer for a position
 * capture "()". An error is raised as luaL_error raises it: at the position of the call. */
#define MAXCAPTURES 32
#define MAXCCALLS 200
#define CAP_UNFINISHED (-1)
#define CAP_POSITION (-2)
#define L_ESC '%'
#define SPECIALS "^$*+?.([%-"

typedef struct MatchCapture {
  const char *init;
  ptrdiff_t len;
} MatchCapture;

typedef struct MatchState {
  const char *src_init;
  const char *src_end;
  const char *p_end;
  int matchdepth;
  int level;
  MatchCapture capture[MAXCAPTURES];
} MatchState;

static const char *pat_match(MatchState *ms, const char *s, const char *p);

static void pat_prepstate(MatchState *ms, const char *s, size_t ls, const char *p, size_t lp) {
  ms->src_init = s;
  ms->src_end = s + ls;
  ms->p_end = p + lp;
}

static void pat_reprepstate(MatchState *ms) {
  ms->matchdepth = MAXCCALLS;
  ms->level = 0;
}

static int pat_check_capture(MatchState *ms, int l) {
  l -= '1';
  if (l < 0 || l >= ms->level || ms->capture[l].len == CAP_UNFINISHED) {
    char buf[64];
    snprintf(buf, sizeof buf, "invalid capture index %%%d", l + 1);
    rt_fail(buf, -1);
  }
  return l;
}

static int pat_capture_to_close(MatchState *ms) {
  int level = ms->level;
  for (level--; level >= 0; level--)
    if (ms->capture[level].len == CAP_UNFINISHED) return level;
  rt_fail("invalid pattern capture", -1);
  return 0;
}

/* The end of the single-character class that starts at p (its suffix, if any, is at the result). */
static const char *pat_classend(MatchState *ms, const char *p) {
  switch (*p++) {
    case L_ESC: {
      if (p == ms->p_end) rt_fail("malformed pattern (ends with '%')", -1);
      return p + 1;
    }
    case '[': {
      if (*p == '^') p++;
      do {  /* look for a ']' */
        if (p == ms->p_end) rt_fail("malformed pattern (missing ']')", -1);
        if (*(p++) == L_ESC && p < ms->p_end) p++;  /* skip escapes (e.g. '%]') */
      } while (*p != ']');
      return p + 1;
    }
    default: return p;
  }
}

static int pat_match_class(int c, int cl) {
  int res;
  switch (tolower(cl)) {
    case 'a': res = isalpha(c); break;
    case 'c': res = iscntrl(c); break;
    case 'd': res = isdigit(c); break;
    case 'g': res = isgraph(c); break;
    case 'l': res = islower(c); break;
    case 'p': res = ispunct(c); break;
    case 's': res = isspace(c); break;
    case 'u': res = isupper(c); break;
    case 'w': res = isalnum(c); break;
    case 'x': res = isxdigit(c); break;
    case 'z': res = (c == 0); break;  /* deprecated option */
    default: return (cl == c);
  }
  return (islower(cl) ? res : !res);
}

/* [set] at p, whose closing ']' is at ec. */
static int pat_match_bracket_class(int c, const char *p, const char *ec) {
  int sig = 1;
  if (*(p + 1) == '^') {
    sig = 0;
    p++;  /* skip the '^' */
  }
  while (++p < ec) {
    if (*p == L_ESC) {
      p++;
      if (pat_match_class(c, (unsigned char)*p)) return sig;
    } else if (*(p + 1) == '-' && (p + 2 < ec)) {
      p += 2;
      if ((unsigned char)*(p - 2) <= c && c <= (unsigned char)*p) return sig;
    } else if ((unsigned char)*p == c) {
      return sig;
    }
  }
  return !sig;
}

static int pat_single_match(MatchState *ms, const char *s, const char *p, const char *ep) {
  if (s >= ms->src_end) return 0;
  int c = (unsigned char)*s;
  switch (*p) {
    case '.': return 1;  /* matches any char */
    case L_ESC: return pat_match_class(c, (unsigned char)*(p + 1));
    case '[': return pat_match_bracket_class(c, p, ep - 1);
    default: return ((unsigned char)*p == c);
  }
}

static const char *pat_matchbalance(MatchState *ms, const char *s, const char *p) {
  if (p >= ms->p_end - 1) rt_fail("malformed pattern (missing arguments to '%b')", -1);
  if (*s != *p) return NULL;
  int b = *p;
  int e = *(p + 1);
  int cont = 1;
  while (++s < ms->src_end) {
    if (*s == e) {
      if (--cont == 0) return s + 1;
    } else if (*s == b) {
      cont++;
    }
  }
  return NULL;  /* string ends out of balance */
}

static const char *pat_max_expand(MatchState *ms, const char *s, const char *p, const char *ep) {
  ptrdiff_t i = 0;  /* counts maximum expand for item */
  while (pat_single_match(ms, s + i, p, ep)) i++;
  /* keeps trying to match with the maximum repetitions */
  while (i >= 0) {
    const char *res = pat_match(ms, s + i, ep + 1);
    if (res) return res;
    i--;  /* else didn't match; reduce 1 repetition to try again */
  }
  return NULL;
}

static const char *pat_min_expand(MatchState *ms, const char *s, const char *p, const char *ep) {
  for (;;) {
    const char *res = pat_match(ms, s, ep + 1);
    if (res != NULL) return res;
    if (pat_single_match(ms, s, p, ep)) s++;  /* try with one more repetition */
    else return NULL;
  }
}

static const char *pat_start_capture(MatchState *ms, const char *s, const char *p, ptrdiff_t what) {
  int level = ms->level;
  if (level >= MAXCAPTURES) rt_fail("too many captures", -1);
  ms->capture[level].init = s;
  ms->capture[level].len = what;
  ms->level = level + 1;
  const char *res = pat_match(ms, s, p);
  if (res == NULL) ms->level--;  /* undo capture */
  return res;
}

static const char *pat_end_capture(MatchState *ms, const char *s, const char *p) {
  int l = pat_capture_to_close(ms);
  ms->capture[l].len = s - ms->capture[l].init;  /* close capture */
  const char *res = pat_match(ms, s, p);
  if (res == NULL) ms->capture[l].len = CAP_UNFINISHED;  /* undo capture */
  return res;
}

static const char *pat_match_capture(MatchState *ms, const char *s, int l) {
  l = pat_check_capture(ms, l);
  size_t len = (size_t)ms->capture[l].len;
  if ((size_t)(ms->src_end - s) >= len && memcmp(ms->capture[l].init, s, len) == 0) return s + len;
  return NULL;
}

/* do_match: the end of the match of the pattern p at s, or NULL (lstrlib.c's match). */
static const char *pat_match(MatchState *ms, const char *s, const char *p) {
  if (ms->matchdepth-- == 0) rt_fail("pattern too complex", -1);
init: /* using goto to optimize tail recursion */
  if (p != ms->p_end) {  /* end of pattern? */
    switch (*p) {
      case '(': {  /* start capture */
        if (*(p + 1) == ')')  /* position capture? */
          s = pat_start_capture(ms, s, p + 2, CAP_POSITION);
        else
          s = pat_start_capture(ms, s, p + 1, CAP_UNFINISHED);
        break;
      }
      case ')': {  /* end capture */
        s = pat_end_capture(ms, s, p + 1);
        break;
      }
      case '$': {
        if ((p + 1) != ms->p_end) goto dflt;  /* the '$' is not the last char: default */
        s = (s == ms->src_end) ? s : NULL;  /* check end of string */
        break;
      }
      case L_ESC: {  /* escaped sequences not in the format class[*+?-]? */
        switch (*(p + 1)) {
          case 'b': {  /* balanced string? */
            s = pat_matchbalance(ms, s, p + 2);
            if (s != NULL) {
              p += 4;
              goto init;
            }
            break;
          }
          case 'f': {  /* frontier? */
            const char *ep;
            char previous;
            p += 2;
            if (*p != '[') rt_fail("missing '[' after '%f' in pattern", -1);
            ep = pat_classend(ms, p);  /* points to what is next */
            previous = (s == ms->src_init) ? '\0' : *(s - 1);
            if (!pat_match_bracket_class((unsigned char)previous, p, ep - 1) &&
                pat_match_bracket_class((unsigned char)*s, p, ep - 1)) {
              p = ep;
              goto init;
            }
            s = NULL;  /* match failed */
            break;
          }
          case '0': case '1': case '2': case '3': case '4':
          case '5': case '6': case '7': case '8': case '9': {  /* capture results (%0-%9)? */
            s = pat_match_capture(ms, s, (unsigned char)*(p + 1));
            if (s != NULL) {
              p += 2;
              goto init;
            }
            break;
          }
          default: goto dflt;
        }
        break;
      }
      default: dflt: {  /* pattern class plus optional suffix */
        const char *ep = pat_classend(ms, p);  /* points to optional suffix */
        /* does not match at least once? */
        if (!pat_single_match(ms, s, p, ep)) {
          if (*ep == '*' || *ep == '?' || *ep == '-') {  /* accept empty? */
            p = ep + 1;
            goto init;
          }
          s = NULL;  /* '+' or no suffix: fail */
        } else {  /* matched once */
          switch (*ep) {  /* handle optional suffix */
            case '?': {
              const char *res = pat_match(ms, s + 1, ep + 1);
              if (res != NULL) {
                s = res;
              } else {
                p = ep + 1;
                goto init;
              }
              break;
            }
            case '+':  /* 1 or more repetitions: 1 match already done */
              s = pat_max_expand(ms, s + 1, p, ep);
              break;
            case '*':  /* 0 or more repetitions */
              s = pat_max_expand(ms, s, p, ep);
              break;
            case '-':  /* 0 or more repetitions (minimum) */
              s = pat_min_expand(ms, s, p, ep);
              break;
            default:  /* no suffix */
              s++;
              p = ep;
              goto init;
          }
        }
        break;
      }
    }
  }
  ms->matchdepth++;
  return s;
}

/* A growing buffer for the result of gsub (luaL_Buffer). */
typedef struct Buf {
  char *p;
  size_t len, cap;
} Buf;

static void buf_add(Buf *b, const char *s, size_t n) {
  if (b->len + n + 1 > b->cap) {
    size_t cap = b->cap > 0 ? b->cap : 64;
    while (b->len + n + 1 > cap) cap *= 2;
    char *np = (char *)realloc(b->p, cap);
    if (np == NULL) die("out of memory");
    b->p = np;
    b->cap = cap;
  }
  if (n > 0) memcpy(b->p + b->len, s, n);
  b->len += n;
}

/* get_onecapture + push_onecapture: capture i as a value in *dst. With no captures, capture 0 is the whole match. */
static void pat_one_capture(MatchState *ms, int i, const char *s, const char *e, LV *dst) {
  if (i >= ms->level) {
    if (i != 0) {
      char buf[64];
      snprintf(buf, sizeof buf, "invalid capture index %%%d", i + 1);
      rt_fail(buf, -1);
    }
    *dst = make_str(s, (size_t)(e - s));
    return;
  }
  ptrdiff_t l = ms->capture[i].len;
  if (l == CAP_UNFINISHED) rt_fail("unfinished capture", -1);
  if (l == CAP_POSITION) {
    dst->tag = TAG_INT;
    dst->v.i = (int64_t)(ms->capture[i].init - ms->src_init) + 1;
    return;
  }
  *dst = make_str(ms->capture[i].init, (size_t)l);
}

/* push_captures: the captures of a match into out. With s == NULL (find), only the captures are pushed. */
static int pat_push_captures(MatchState *ms, const char *s, const char *e, LV *out) {
  int nlevels = (ms->level == 0 && s != NULL) ? 1 : ms->level;
  for (int i = 0; i < nlevels; ++i) pat_one_capture(ms, i, s, e, &out[i]);
  return nlevels;
}

/* lmemfind: the first occurrence of s2 in s1, or NULL. */
static const char *pat_memfind(const char *s1, size_t l1, const char *s2, size_t l2) {
  if (l2 == 0) return s1;
  if (l2 > l1) return NULL;
  for (size_t k = 0; k + l2 <= l1; ++k)
    if (memcmp(s1 + k, s2, l2) == 0) return s1 + k;
  return NULL;
}

/* nospecials: the pattern has no magic character, so find may search for it as plain text. */
static int pat_no_specials(const char *p, size_t l) {
  for (size_t k = 0; k < l; ++k)
    if (p[k] != '\0' && strchr(SPECIALS, p[k]) != NULL) return 0;
  return 1;
}

/* posrelatI: an initial position, negative from the end, clipped to [1, inf). */
static size_t pat_posrelat(int64_t pos, size_t len) {
  if (pos > 0) return (size_t)pos;
  if (pos == 0) return 1;
  if (pos < -(int64_t)len) return 1;
  return len + (size_t)pos + 1;
}

/* str_find_aux: string.find (find != 0) and string.match. */
static int pat_find_aux(LV *out, LV *args, int nargs, int find, const char *fname) {
  LV sv = arg_str(args, nargs, 1, fname);
  LV pv = arg_str(args, nargs, 2, fname);
  const LString *S = (const LString *)sv.v.p, *P = (const LString *)pv.v.p;
  size_t ls = S->len, lp = P->len;
  size_t init = pat_posrelat(opt_int(args, nargs, 3, fname, 1), ls) - 1;
  if (init > ls) {  /* start after string's end? */
    out[0].tag = TAG_NIL;
    return 1;
  }
  if (find && ((nargs >= 4 && truthy(&args[3])) || pat_no_specials(P->bytes, lp))) {
    const char *s2 = pat_memfind(S->bytes + init, ls - init, P->bytes, lp);
    if (s2 != NULL) {
      out[0].tag = TAG_INT;
      out[0].v.i = (int64_t)(s2 - S->bytes) + 1;
      out[1].tag = TAG_INT;
      out[1].v.i = (int64_t)(s2 - S->bytes) + (int64_t)lp;
      keep_alive(S);
      return 2;
    }
  } else {
    MatchState ms;
    const char *s1 = S->bytes + init;
    const char *p = P->bytes;
    size_t plen = lp;
    int anchor = (*p == '^');
    if (anchor) {
      p++;
      plen--;  /* skip anchor character */
    }
    pat_prepstate(&ms, S->bytes, ls, p, plen);
    do {
      pat_reprepstate(&ms);
      const char *res = pat_match(&ms, s1, p);
      if (res != NULL) {
        int n;
        if (find) {
          out[0].tag = TAG_INT;
          out[0].v.i = (int64_t)(s1 - S->bytes) + 1;  /* start */
          out[1].tag = TAG_INT;
          out[1].v.i = (int64_t)(res - S->bytes);  /* end */
          n = pat_push_captures(&ms, NULL, NULL, out + 2) + 2;
        } else {
          n = pat_push_captures(&ms, s1, res, out);
        }
        keep_alive(S);
        return n;
      }
    } while (s1++ < ms.src_end && !anchor);
    keep_alive(S);
  }
  out[0].tag = TAG_NIL;  /* not found */
  return 1;
}

static int host_sfind(LV *out, LV *args, int nargs) { return pat_find_aux(out, args, nargs, 1, "find"); }

static int host_smatch(LV *out, LV *args, int nargs) { return pat_find_aux(out, args, nargs, 0, "match"); }

/* The iterator of gmatch (gmatch_aux). Its state is the host closure's up[0] (subject), up[1] (pattern), up[2] (the
 * position to search from) and up[3] (the end of the last match, -1 for none). */
static int pat_gmatch_iter(LV *out, LV *args, int nargs) {
  (void)args;
  (void)nargs;
  HostFn *self = cur_host;
  const LString *S = (const LString *)self->up[0].v.p, *P = (const LString *)self->up[1].v.p;
  MatchState ms;
  pat_prepstate(&ms, S->bytes, S->len, P->bytes, P->len);
  for (size_t src = (size_t)self->up[2].v.i; src <= S->len; ++src) {
    pat_reprepstate(&ms);
    const char *e = pat_match(&ms, S->bytes + src, P->bytes);
    if (e != NULL && (int64_t)(e - S->bytes) != self->up[3].v.i) {
      self->up[2].v.i = (int64_t)(e - S->bytes);
      self->up[3].v.i = (int64_t)(e - S->bytes);
      return pat_push_captures(&ms, S->bytes + src, e, out);
    }
  }
  return 0;  /* not found */
}

static int host_sgmatch(LV *out, LV *args, int nargs) {
  LV sv = arg_str(args, nargs, 1, "gmatch");
  LV pv = arg_str(args, nargs, 2, "gmatch");
  size_t ls = ((LString *)sv.v.p)->len;
  size_t init = pat_posrelat(opt_int(args, nargs, 3, "gmatch", 1), ls) - 1;
  if (init > ls) init = ls + 1;  /* start after string's end: no match */
  make_host_nup(&out[0], pat_gmatch_iter, 4);
  HostFn *h = (HostFn *)out[0].v.p;
  h->up[0] = sv;
  h->up[1] = pv;
  h->up[2].tag = TAG_INT;
  h->up[2].v.i = (int64_t)init;
  h->up[3].tag = TAG_INT;
  h->up[3].v.i = -1;  /* no match yet */
  return 1;
}

/* add_s: the replacement string news, with %0-%9 and %%, for the match s..e. */
static void pat_add_s(MatchState *ms, Buf *b, const char *s, const char *e, const LString *news) {
  const char *p = news->bytes;
  size_t l = news->len;
  const char *q;
  while ((q = (const char *)memchr(p, L_ESC, l)) != NULL) {
    buf_add(b, p, (size_t)(q - p));
    q++;  /* skip ESC */
    if (*q == L_ESC) {  /* '%%' */
      buf_add(b, q, 1);
    } else if (*q == '0') {  /* '%0' */
      buf_add(b, s, (size_t)(e - s));
    } else if (*q >= '1' && *q <= '9') {  /* '%n' */
      LV cap;
      pat_one_capture(ms, *q - '1', s, e, &cap);
      if (cap.tag == TAG_STR) {
        buf_add(b, ((LString *)cap.v.p)->bytes, ((LString *)cap.v.p)->len);
      } else {
        char num[64];
        size_t n = number_text(&cap, num, sizeof num);
        buf_add(b, num, n);
      }
    } else {
      rt_fail("invalid use of '%' in replacement string", -1);
    }
    l -= (size_t)(q + 1 - p);
    p = q + 1;
  }
  buf_add(b, p, l);
}

/* add_value: the replacement of the match s..e by a string, a table (indexed by the first capture) or a function (called
 * with the captures). A false or nil result keeps the match. Returns 1 when the text changed. */
static int pat_add_value(MatchState *ms, Buf *b, const char *s, const char *e, LV *repl) {
  LV res[256];
  if (repl->tag == TAG_LCL || repl->tag == TAG_LCF) {
    LV frame[1024];
    LV fn = *repl;
    int n = pat_push_captures(ms, s, e, frame);
    lua54rt_call(&fn, n, frame, res, 1, 0);
  } else if (repl->tag == TAG_TABLE) {
    LV key, t = *repl;
    pat_one_capture(ms, 0, s, e, &key);
    lua54rt_gettable(&res[0], &t, &key);
  } else {
    pat_add_s(ms, b, s, e, (const LString *)repl->v.p);
    return 1;
  }
  if (!truthy(&res[0])) {
    buf_add(b, s, (size_t)(e - s));  /* keep original text */
    return 0;
  }
  if (res[0].tag == TAG_STR) {
    buf_add(b, ((LString *)res[0].v.p)->bytes, ((LString *)res[0].v.p)->len);
  } else if (is_number(&res[0])) {
    char num[64];
    size_t n = number_text(&res[0], num, sizeof num);
    buf_add(b, num, n);
  } else {
    char buf[64];
    snprintf(buf, sizeof buf, "invalid replacement value (a %s)", type_name(res[0].tag));
    rt_fail(buf, -1);
  }
  return 1;
}

static int host_sgsub(LV *out, LV *args, int nargs) {
  LV sv = arg_str(args, nargs, 1, "gsub");
  LV pv = arg_str(args, nargs, 2, "gsub");
  const LString *S = (const LString *)sv.v.p, *P = (const LString *)pv.v.p;
  int64_t max_s = opt_int(args, nargs, 4, "gsub", (int64_t)S->len + 1);
  LV repl;
  int tr = nargs >= 3 ? args[2].tag : TAG_NIL;
  if (tr == TAG_STR || tr == TAG_INT || tr == TAG_FLOAT) repl = arg_str(args, nargs, 3, "gsub");
  else if (tr == TAG_TABLE || tr == TAG_LCL || tr == TAG_LCF) repl = args[2];
  else lib_arg_error(3, "gsub", "string/function/table", arg_typename(args, nargs, 3));

  const char *src = S->bytes;
  const char *p = P->bytes;
  size_t lp = P->len;
  const char *lastmatch = NULL;  /* end of last match */
  int64_t n = 0;                 /* replacement count */
  int changed = 0;
  int anchor = (*p == '^');
  if (anchor) {
    p++;
    lp--;  /* skip anchor character */
  }
  MatchState ms;
  Buf b = {NULL, 0, 0};
  pat_prepstate(&ms, S->bytes, S->len, p, lp);
  while (n < max_s) {
    pat_reprepstate(&ms);  /* (re)prepare state for new match */
    const char *e = pat_match(&ms, src, p);
    if (e != NULL && e != lastmatch) {  /* match? */
      n++;
      changed = pat_add_value(&ms, &b, src, e, &repl) | changed;
      src = lastmatch = e;
    } else if (src < ms.src_end) {  /* otherwise, skip one character */
      buf_add(&b, src, 1);
      src++;
    } else {
      break;  /* end of subject */
    }
    if (anchor) break;
  }
  if (!changed) {  /* no changes? */
    out[0] = sv;
  } else {  /* something changed */
    buf_add(&b, src, (size_t)(ms.src_end - src));
    out[0] = make_str(b.p != NULL ? b.p : "", b.len);
    free(b.p);
  }
  out[1].tag = TAG_INT;
  out[1].v.i = n;
  keep_alive(S);
  return 2;
}

/* ---- table: pack, move, sort (ltablib.c) ---- */

/* t[i] and t[i] = v with the metamethods, as lua_geti and lua_seti. */
static LV tget(LV *t, int64_t i) {
  LV k, v;
  k.tag = TAG_INT;
  k.v.i = i;
  lua54rt_gettable(&v, t, &k);
  return v;
}

static void tset(LV *t, int64_t i, LV *v) {
  LV k;
  k.tag = TAG_INT;
  k.v.i = i;
  lua54rt_settable(t, &k, v);
}

static int host_tpack(LV *out, LV *args, int nargs) {
  LV t;
  lua54rt_newtable(&t);
  for (int k = 0; k < nargs; ++k) {
    LV key;
    key.tag = TAG_INT;
    key.v.i = k + 1;
    raw_set((Table *)t.v.p, &key, &args[k]);
  }
  LV key = make_str("n", 1), n;
  n.tag = TAG_INT;
  n.v.i = nargs;
  raw_set((Table *)t.v.p, &key, &n);
  out[0] = t;
  return 1;
}

/* table.move(a1, f, e, t [, a2]): the elements f..e of a1 go to a2 at t, in the order that does not overwrite them. */
static int host_tmove(LV *out, LV *args, int nargs) {
  arg_table(args, nargs, 1, "move");
  int64_t f = arg_int(args, nargs, 2, "move");
  int64_t e = arg_int(args, nargs, 3, "move");
  int64_t t = arg_int(args, nargs, 4, "move");
  int tt = nargs >= 5 && args[4].tag != TAG_NIL ? 5 : 1;
  if (tt == 5) arg_table(args, nargs, 5, "move");
  LV *dst = &args[tt - 1];
  if (e >= f) {
    if (!(f > 0 || e < INT64_MAX + f)) arg_fail(3, "move", "too many elements to move");
    int64_t n = e - f + 1;
    if (!(t <= INT64_MAX - n + 1)) arg_fail(4, "move", "destination wrap around");
    if (t > e || t <= f || (tt != 1 && !equal_values(&args[0], dst))) {
      for (int64_t i = 0; i < n; ++i) {
        LV v = tget(&args[0], f + i);
        tset(dst, t + i, &v);
      }
    } else {
      for (int64_t i = n - 1; i >= 0; --i) {
        LV v = tget(&args[0], f + i);
        tset(dst, t + i, &v);
      }
    }
  }
  out[0] = *dst;
  return 1;
}

/* The quicksort of ltablib.c, with the same comparisons and the same swaps: the values it holds are kept in locals,
 * and the table is read and written with tget and tset. The pivot is the middle element; a randomized pivot is used only
 * after a badly unbalanced partition, as in Lua (its seed here is fixed). */
typedef struct SortCtx {
  LV *t;
  LV *cmp;   /* the order function, or NULL for <. */
} SortCtx;

static int sort_lt(SortCtx *c, const LV *a, const LV *b) {
  if (c->cmp == NULL) return lua54rt_cmp(0, (LV *)a, (LV *)b);
  LV frame[1024], ret[256], fn = *c->cmp;
  frame[0] = *a;
  frame[1] = *b;
  lua54rt_call(&fn, 2, frame, ret, 1, 0);
  return truthy(&ret[0]);
}

#define SORT_RANLIMIT 100u

static int64_t partition(SortCtx *c, int64_t lo, int64_t up, LV *pivot) {
  int64_t i = lo, j = up - 1;
  LV ai, aj;
  for (;;) {
    for (;;) {
      ai = tget(c->t, ++i);
      if (!sort_lt(c, &ai, pivot)) break;
      if (i == up - 1) rt_fail("invalid order function for sorting", -1);
    }
    for (;;) {
      aj = tget(c->t, --j);
      if (!sort_lt(c, pivot, &aj)) break;
      if (j < i) rt_fail("invalid order function for sorting", -1);
    }
    if (j < i) {
      tset(c->t, up - 1, &ai);
      tset(c->t, i, pivot);
      return i;
    }
    tset(c->t, i, &aj);
    tset(c->t, j, &ai);
  }
}

static void auxsort(SortCtx *c, int64_t lo, int64_t up, unsigned rnd) {
  while (lo < up) {
    LV alo = tget(c->t, lo), aup = tget(c->t, up);
    if (sort_lt(c, &aup, &alo)) {
      tset(c->t, lo, &aup);
      tset(c->t, up, &alo);
    }
    if (up - lo == 1) return;
    int64_t p;
    if (up - lo < (int64_t)SORT_RANLIMIT || rnd == 0) p = (lo + up) / 2;
    else {
      uint64_t r4 = (uint64_t)(up - lo) / 4;
      p = (int64_t)(rnd % (r4 * 2)) + lo + (int64_t)r4;
    }
    LV ap = tget(c->t, p), alo2 = tget(c->t, lo);
    if (sort_lt(c, &ap, &alo2)) {
      tset(c->t, p, &alo2);
      tset(c->t, lo, &ap);
    } else {
      LV aup2 = tget(c->t, up);
      if (sort_lt(c, &aup2, &ap)) {
        tset(c->t, p, &aup2);
        tset(c->t, up, &ap);
      }
    }
    if (up - lo == 2) return;
    LV pivot = tget(c->t, p), aup1 = tget(c->t, up - 1);
    tset(c->t, p, &aup1);
    tset(c->t, up - 1, &pivot);
    p = partition(c, lo, up, &pivot);
    int64_t n;
    if (p - lo < up - p) {
      auxsort(c, lo, p - 1, rnd);
      n = p - lo;
      lo = p + 1;
    } else {
      auxsort(c, p + 1, up, rnd);
      n = up - p;
      up = p - 1;
    }
    if ((up - lo) / 128 > n) rnd = 0x5bd1e995u;
  }
}

static int host_tsort(LV *out, LV *args, int nargs) {
  (void)out;
  arg_table(args, nargs, 1, "sort");
  int64_t n = table_border((const Table *)args[0].v.p);
  if (n > 1) {
    if (n >= INT32_MAX) arg_fail(1, "sort", "array too big");
    if (nargs >= 2 && args[1].tag != TAG_NIL && args[1].tag != TAG_LCL && args[1].tag != TAG_LCF)
      lib_arg_error(2, "sort", "function", arg_typename(args, nargs, 2));
    SortCtx c;
    c.t = &args[0];
    c.cmp = nargs >= 2 && args[1].tag != TAG_NIL ? &args[1] : NULL;
    auxsort(&c, 1, n, 0);
  }
  return 0;
}

/* ---- math: the rest of lmathlib.c ---- */

#define MATH_F1(name, expr)                                          \
  static int host_m_##name(LV *out, LV *args, int nargs) {           \
    double x = arg_float(args, nargs, 1, #name);                     \
    out[0].tag = TAG_FLOAT;                                          \
    out[0].v.n = (expr);                                             \
    return 1;                                                        \
  }

static double arg_float(const LV *args, int nargs, int k, const char *fname) {
  LV n;
  if (k <= nargs && to_number(&args[k - 1], &n)) return as_float(&n);
  lib_arg_error(k, fname, "number", arg_typename(args, nargs, k));
  return 0;
}

MATH_F1(exp, exp(x))
MATH_F1(sin, sin(x))
MATH_F1(cos, cos(x))
MATH_F1(tan, tan(x))
MATH_F1(asin, asin(x))
MATH_F1(acos, acos(x))

static int host_m_atan(LV *out, LV *args, int nargs) {
  double y = arg_float(args, nargs, 1, "atan");
  double x = nargs >= 2 && args[1].tag != TAG_NIL ? arg_float(args, nargs, 2, "atan") : 1.0;
  out[0].tag = TAG_FLOAT;
  out[0].v.n = atan2(y, x);
  return 1;
}

static int host_m_log(LV *out, LV *args, int nargs) {
  double x = arg_float(args, nargs, 1, "log"), res;
  if (nargs < 2 || args[1].tag == TAG_NIL) res = log(x);
  else {
    double base = arg_float(args, nargs, 2, "log");
    if (base == 2.0) res = log2(x);
    else if (base == 10.0) res = log10(x);
    else res = log(x) / log(base);
  }
  out[0].tag = TAG_FLOAT;
  out[0].v.n = res;
  return 1;
}

static int host_m_fmod(LV *out, LV *args, int nargs) {
  if (nargs >= 2 && args[0].tag == TAG_INT && args[1].tag == TAG_INT) {
    int64_t d = args[1].v.i;
    if ((uint64_t)d + 1u <= 1u) {   /* 0 or -1: no overflow in the division */
      if (d == 0) arg_fail(2, "fmod", "zero");
      out[0].tag = TAG_INT;
      out[0].v.i = 0;
    } else {
      out[0].tag = TAG_INT;
      out[0].v.i = args[0].v.i % d;
    }
    return 1;
  }
  double a = arg_float(args, nargs, 1, "fmod"), b = arg_float(args, nargs, 2, "fmod");
  out[0].tag = TAG_FLOAT;
  out[0].v.n = fmod(a, b);
  return 1;
}

static int host_m_modf(LV *out, LV *args, int nargs) {
  if (nargs >= 1 && args[0].tag == TAG_INT) {
    out[0] = args[0];
    out[1].tag = TAG_FLOAT;
    out[1].v.n = 0.0;
    return 2;
  }
  double n = arg_float(args, nargs, 1, "modf");
  double ip = n < 0 ? ceil(n) : floor(n);
  out[0].tag = TAG_FLOAT;
  out[0].v.n = ip;
  if (ip >= -9223372036854775808.0 && ip < 9223372036854775808.0) {   /* pushnumint: an integer when it fits */
    out[0].tag = TAG_INT;
    out[0].v.i = (int64_t)ip;
  }
  out[1].tag = TAG_FLOAT;
  out[1].v.n = n == ip ? 0.0 : n - ip;
  return 2;
}

static int host_m_ult(LV *out, LV *args, int nargs) {
  uint64_t a = (uint64_t)arg_int(args, nargs, 1, "ult");
  uint64_t b = (uint64_t)arg_int(args, nargs, 2, "ult");
  out[0].tag = a < b ? TAG_TRUE : TAG_FALSE;
  return 1;
}

static int host_m_type(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "type", "value");
  out[0].tag = TAG_NIL;
  if (args[0].tag == TAG_INT) set_string(&out[0], "integer");
  else if (args[0].tag == TAG_FLOAT) set_string(&out[0], "float");
  return 1;
}

/* lmathlib.c's xoshiro256**, with its seeding, so that math.randomseed(n) gives the same numbers as Lua 5.4.9. */
static uint64_t rng[4];

static uint64_t rotl64(uint64_t x, int n) { return (x << n) | (x >> (64 - n)); }

static uint64_t nextrand(void) {
  uint64_t s0 = rng[0], s1 = rng[1], s2 = rng[2] ^ s0, s3 = rng[3] ^ s1;
  uint64_t res = rotl64(s1 * 5, 7) * 9;
  rng[0] = s0 ^ s3;
  rng[1] = s1 ^ s2;
  rng[2] = s2 ^ (s1 << 17);
  rng[3] = rotl64(s3, 45);
  return res;
}

static void setseed(uint64_t n1, uint64_t n2) {
  rng[0] = n1;
  rng[1] = 0xff;
  rng[2] = n2;
  rng[3] = 0;
  for (int i = 0; i < 16; ++i) nextrand();
}

/* lmathlib.c's project: a random integer in [0, n] without bias, from ran and further draws. */
static uint64_t project(uint64_t ran, uint64_t n) {
  if ((n & (n + 1)) == 0) return ran & n;
  uint64_t lim = n;
  lim |= lim >> 1;
  lim |= lim >> 2;
  lim |= lim >> 4;
  lim |= lim >> 8;
  lim |= lim >> 16;
  lim |= lim >> 32;
  while ((ran &= lim) > n) ran = nextrand();
  return ran;
}

static int host_m_random(LV *out, LV *args, int nargs) {
  uint64_t rv = nextrand();
  int64_t low = 0, up = 0;
  switch (nargs) {
    case 0:
      out[0].tag = TAG_FLOAT;
      out[0].v.n = (double)(rv >> 11) * 0x1.0p-53;
      return 1;
    case 1:
      low = 1;
      up = arg_int(args, nargs, 1, "random");
      if (up == 0) {
        out[0].tag = TAG_INT;
        out[0].v.i = (int64_t)rv;
        return 1;
      }
      break;
    case 2:
      low = arg_int(args, nargs, 1, "random");
      up = arg_int(args, nargs, 2, "random");
      break;
    default: rt_fail("wrong number of arguments", -1);
  }
  if (!(low <= up)) arg_fail(1, "random", "interval is empty");
  out[0].tag = TAG_INT;
  out[0].v.i = (int64_t)(project(rv, (uint64_t)up - (uint64_t)low) + (uint64_t)low);
  return 1;
}

static int host_m_randomseed(LV *out, LV *args, int nargs) {
  uint64_t n1, n2;
  if (nargs == 0) {
    n1 = (uint64_t)time(NULL);
    n2 = (uint64_t)(uintptr_t)&out;
  } else {
    n1 = (uint64_t)arg_int(args, nargs, 1, "randomseed");
    n2 = nargs >= 2 && args[1].tag != TAG_NIL ? (uint64_t)arg_int(args, nargs, 2, "randomseed") : 0;
  }
  setseed(n1, n2);
  out[0].tag = TAG_INT;
  out[0].v.i = (int64_t)n1;
  out[1].tag = TAG_INT;
  out[1].v.i = (int64_t)n2;
  return 2;
}

/* ---- os and io: what a test program prints with and reads the clock with ---- */
static int host_oclock(LV *out, LV *args, int nargs) {
  (void)args;
  (void)nargs;
  out[0].tag = TAG_FLOAT;
  out[0].v.n = (double)clock() / CLOCKS_PER_SEC;
  return 1;
}

static int host_otime(LV *out, LV *args, int nargs) {
  (void)args;
  (void)nargs;
  out[0].tag = TAG_INT;
  out[0].v.i = (int64_t)time(NULL);
  return 1;
}

static int host_ogetenv(LV *out, LV *args, int nargs) {
  LV name = arg_str(args, nargs, 1, "getenv");
  const char *v = getenv(((LString *)name.v.p)->bytes);
  if (v == NULL) out[0].tag = TAG_NIL;
  else out[0] = make_str(v, strlen(v));
  return 1;
}

static int host_oexit(LV *out, LV *args, int nargs) {
  (void)out;
  int code = 0;
  if (nargs >= 1 && args[0].tag == TAG_FALSE) code = 1;
  else if (nargs >= 1 && args[0].tag == TAG_INT) code = (int)args[0].v.i;
  fflush(stdout);
  exit(code);
}

/* io.write(...): the values go to stdout; the result is the stdout table, as in Lua (a file with a write method). */
static LV io_stdout;

static void write_args(const LV *args, int nargs, const char *fname) {
  for (int k = 1; k <= nargs; ++k) {
    const LV *v = &args[k - 1];
    if (v->tag == TAG_STR) fwrite(((LString *)v->v.p)->bytes, 1, ((LString *)v->v.p)->len, stdout);
    else if (is_number(v)) {
      char buf[64];
      size_t n = number_text(v, buf, sizeof buf);
      fwrite(buf, 1, n, stdout);
    } else lib_arg_error(k, fname, "string", arg_typename(args, nargs, k));
  }
}

static int host_iowrite(LV *out, LV *args, int nargs) {
  write_args(args, nargs, "write");
  out[0] = io_stdout;
  return 1;
}

/* io.stdout:write(...): the first argument is the file itself. */
static int host_fwrite(LV *out, LV *args, int nargs) {
  write_args(args + 1, nargs - 1, "write");
  out[0] = args[0];
  return 1;
}

/* The tables of the libraries; the string metatable is created in install_more. */

static void register_table(LV *env, const char *name, LV *tbl) { set_global(env, name, tbl); }

static void add_fn(LV *tbl, const char *name, lua_cfn fn) {
  LV f;
  make_host(&f, fn);
  LV key = make_str(name, strlen(name));
  raw_set((Table *)tbl->v.p, &key, &f);
}

static void install_more(LV *env) {
  LV f;
  make_host(&f, host_error);
  set_global(env, "error", &f);
  make_host(&f, host_assert);
  set_global(env, "assert", &f);
  make_host(&f, host_pcall);
  set_global(env, "pcall", &f);
  make_host(&f, host_xpcall);
  set_global(env, "xpcall", &f);
  make_host(&f, host_tonumber);
  set_global(env, "tonumber", &f);
  make_host(&f, host_rawget);
  set_global(env, "rawget", &f);
  make_host(&f, host_rawset);
  set_global(env, "rawset", &f);
  make_host(&f, host_rawequal);
  set_global(env, "rawequal", &f);
  make_host(&f, host_rawlen);
  set_global(env, "rawlen", &f);
  make_host(&f, host_collectgarbage);
  set_global(env, "collectgarbage", &f);

  LV tbl;
  lua54rt_newtable(&tbl);
  add_fn(&tbl, "insert", host_tinsert);
  add_fn(&tbl, "remove", host_tremove);
  add_fn(&tbl, "concat", host_tconcat);
  add_fn(&tbl, "unpack", host_tunpack);
  add_fn(&tbl, "pack", host_tpack);
  add_fn(&tbl, "move", host_tmove);
  add_fn(&tbl, "sort", host_tsort);
  register_table(env, "table", &tbl);

  LV math;
  lua54rt_newtable(&math);
  add_fn(&math, "floor", host_mfloor);
  add_fn(&math, "ceil", host_mceil);
  add_fn(&math, "abs", host_mabs);
  add_fn(&math, "max", host_mmax);
  add_fn(&math, "min", host_mmin);
  add_fn(&math, "sqrt", host_msqrt);
  add_fn(&math, "tointeger", host_mtointeger);
  add_fn(&math, "exp", host_m_exp);
  add_fn(&math, "sin", host_m_sin);
  add_fn(&math, "cos", host_m_cos);
  add_fn(&math, "tan", host_m_tan);
  add_fn(&math, "asin", host_m_asin);
  add_fn(&math, "acos", host_m_acos);
  add_fn(&math, "atan", host_m_atan);
  add_fn(&math, "log", host_m_log);
  add_fn(&math, "fmod", host_m_fmod);
  add_fn(&math, "modf", host_m_modf);
  add_fn(&math, "ult", host_m_ult);
  add_fn(&math, "type", host_m_type);
  add_fn(&math, "random", host_m_random);
  add_fn(&math, "randomseed", host_m_randomseed);
  {
    LV seeds[2];
    host_m_randomseed(seeds, NULL, 0);   /* the generator starts from a time-based seed, as in Lua */
  }
  LV v;
  v.tag = TAG_FLOAT;
  v.v.n = HUGE_VAL;
  LV key = make_str("huge", 4);
  raw_set((Table *)math.v.p, &key, &v);
  v.tag = TAG_FLOAT;
  v.v.n = 3.141592653589793238462643383279502884;
  key = make_str("pi", 2);
  raw_set((Table *)math.v.p, &key, &v);
  v.tag = TAG_INT;
  v.v.i = INT64_MAX;
  key = make_str("maxinteger", 10);
  raw_set((Table *)math.v.p, &key, &v);
  v.v.i = INT64_MIN;
  key = make_str("mininteger", 10);
  raw_set((Table *)math.v.p, &key, &v);
  register_table(env, "math", &math);

  LV str;
  lua54rt_newtable(&str);
  add_fn(&str, "len", host_slen);
  add_fn(&str, "sub", host_ssub);
  add_fn(&str, "upper", host_supper);
  add_fn(&str, "lower", host_slower);
  add_fn(&str, "rep", host_srep);
  add_fn(&str, "reverse", host_sreverse);
  add_fn(&str, "byte", host_sbyte);
  add_fn(&str, "char", host_schar);
  add_fn(&str, "format", host_sformat);
  add_fn(&str, "find", host_sfind);
  add_fn(&str, "match", host_smatch);
  add_fn(&str, "gmatch", host_sgmatch);
  add_fn(&str, "gsub", host_sgsub);
  register_table(env, "string", &str);

  LV os_tbl;
  lua54rt_newtable(&os_tbl);
  add_fn(&os_tbl, "clock", host_oclock);
  add_fn(&os_tbl, "time", host_otime);
  add_fn(&os_tbl, "getenv", host_ogetenv);
  add_fn(&os_tbl, "exit", host_oexit);
  register_table(env, "os", &os_tbl);

  LV io_tbl;
  lua54rt_newtable(&io_tbl);
  lua54rt_newtable(&io_stdout);
  add_fn(&io_stdout, "write", host_fwrite);
  add_fn(&io_tbl, "write", host_iowrite);
  key = make_str("stdout", 6);
  raw_set((Table *)io_tbl.v.p, &key, &io_stdout);
  register_table(env, "io", &io_tbl);

  set_global(env, "_G", env);
  LV version = make_str("Lua 5.4", 7);
  set_global(env, "_VERSION", &version);
  string_meta = (Table *)gc_alloc(GC_TABLE, sizeof(Table));
  if (string_meta == NULL) die("out of memory");
  key = make_str("__index", 7);
  raw_set(string_meta, &key, &str);
}

/* ---- the garbage collector: mark and sweep (docs/notes/lua54-pathb.md, "Garbage collection") ----
 * Every object (strings, tables, closures, upvalues, host functions, saved varargs) starts with a GCObj header and is
 * linked into one list and into a set of addresses. A collection marks from the roots: the Lua stack, the open upvalues,
 * the string metatable, the two library iterators and the running main closure. The C stack is scanned conservatively,
 * because the helpers keep values in their locals: a word counts only if it is the address of an object in the set, so a
 * stale word can only keep an object one cycle longer. The sweep frees the objects that are not marked.
 * The collector is off until the main function starts (stack_base is set by lua54rt_run_main). */
#define GC_MIN_THRESHOLD ((size_t)4 << 20)
#define LUA54RT_STACK 65536
#define GC_TOMB ((void *)1)

static LV lua_stack[LUA54RT_STACK];
static GCObj *all_objects = NULL;
static size_t gc_allocated = 0;             /* bytes allocated since the last collection */
static size_t gc_live = 0;                  /* bytes live after the last collection */
static size_t gc_min_threshold = GC_MIN_THRESHOLD;   /* LUA54RT_GC_THRESHOLD overrides it, for the tests */
static size_t gc_threshold = GC_MIN_THRESHOLD;
static void *stack_base = NULL;             /* the top of the C stack that the collector scans */
static void *running_main = NULL;           /* the closure of the main function, while it runs */

/* The set of object addresses: linear probing; a removed slot holds GC_TOMB. */
static void **obj_set = NULL;
static size_t obj_cap = 0, obj_used = 0;

static size_t set_hash(const void *p) { return (size_t)mix((uint64_t)(uintptr_t)p); }

static int set_has(const void *p) {
  if (obj_cap == 0) return 0;
  size_t mask = obj_cap - 1;
  for (size_t i = set_hash(p) & mask;; i = (i + 1) & mask) {
    void *q = obj_set[i];
    if (q == NULL) return 0;
    if (q == p && q != GC_TOMB) return 1;   /* a removed slot is not a member, even for the tombstone's own value */
  }
}

static void set_insert_raw(void *p) {
  size_t mask = obj_cap - 1;
  size_t i = set_hash(p) & mask;
  while (obj_set[i] != NULL && obj_set[i] != GC_TOMB) i = (i + 1) & mask;
  if (obj_set[i] == NULL) obj_used++;
  obj_set[i] = p;
}

static void set_rehash(size_t cap) {
  void **old = obj_set;
  size_t oldcap = obj_cap;
  obj_set = (void **)calloc(cap, sizeof(void *));
  if (obj_set == NULL) die("out of memory");
  obj_cap = cap;
  obj_used = 0;
  for (size_t i = 0; i < oldcap; ++i) {
    if (old[i] != NULL && old[i] != GC_TOMB) set_insert_raw(old[i]);
  }
  free(old);
}

static void set_insert(void *p) {
  if ((obj_used + 1) * 2 > obj_cap) set_rehash(obj_cap == 0 ? 256 : obj_cap * 2);
  set_insert_raw(p);
}

static void set_remove(void *p) {
  if (obj_cap == 0) return;
  size_t mask = obj_cap - 1;
  for (size_t i = set_hash(p) & mask;; i = (i + 1) & mask) {
    void *q = obj_set[i];
    if (q == NULL) return;
    if (q == p) {
      obj_set[i] = GC_TOMB;
      return;
    }
  }
}

static void gc_collect(void);

/* Allocates an object of kind with size bytes, zeroed. A collection runs first when enough has been allocated. */
static void *gc_alloc(uint8_t kind, size_t size) {
  if (stack_base != NULL && gc_allocated >= gc_threshold) gc_collect();
  GCObj *o = (GCObj *)calloc(1, size);
  if (o == NULL) die("out of memory");
  o->kind = kind;
  o->size = size;
  o->next = all_objects;
  all_objects = o;
  set_insert(o);
  gc_allocated += size;
  return o;
}

/* The gray objects, to traverse after the roots. */
static GCObj **gray = NULL;
static size_t gray_n = 0, gray_cap = 0;

static void mark_obj(const void *p) {
  if (p == NULL || !set_has(p)) return;
  GCObj *o = (GCObj *)p;
  if (o->marked) return;
  o->marked = 1;
  if (gray_n == gray_cap) {
    gray_cap = gray_cap == 0 ? 256 : gray_cap * 2;
    gray = (GCObj **)realloc(gray, gray_cap * sizeof(GCObj *));
    if (gray == NULL) die("out of memory");
  }
  gray[gray_n++] = o;
}

static void mark_value(const LV *v) {
  if (v->tag == TAG_STR || v->tag == TAG_TABLE || v->tag == TAG_LCL || v->tag == TAG_LCF) mark_obj(v->v.p);
}

static void traverse(GCObj *o) {
  switch (o->kind) {
    case GC_TABLE: {
      Table *t = (Table *)o;
      for (size_t i = 0; i < t->cap; ++i) {
        if (t->nodes[i].used) {
          mark_value(&t->nodes[i].key);
          mark_value(&t->nodes[i].val);
        }
      }
      mark_obj(t->meta);
      break;
    }
    case GC_LCL: {
      LClosure *c = (LClosure *)o;
      for (int k = 0; k < c->nupvals; ++k) mark_obj(c->upvals[k]);
      break;
    }
    case GC_UPVAL: {
      UpVal *u = (UpVal *)o;
      if (u->v != NULL) mark_value(u->v);
      break;
    }
    case GC_VARARGS: {
      VarArgs *va = (VarArgs *)o;
      for (int k = 0; k < va->count; ++k) mark_value(&va->vals[k]);
      break;
    }
    case GC_LCF: {
      HostFn *h = (HostFn *)o;
      for (int k = 0; k < h->nup; ++k) mark_value(&h->up[k]);
      break;
    }
    default: break;
  }
}

static void propagate(void) {
  while (gray_n > 0) {
    GCObj *o = gray[--gray_n];
    traverse(o);
  }
}

/* The C stack, from here up to the main function's frame: the registers are spilled into a jmp_buf first. */
static void scan_c_stack(void) {
  jmp_buf regs;
  volatile int here = 0;
  __builtin_unwind_init();   /* every callee-saved register goes to the stack */
  setjmp(regs);
  uintptr_t lo = (uintptr_t)&here;
  uintptr_t lo2 = (uintptr_t)&regs;
  if (lo2 < lo) lo = lo2;
  uintptr_t hi = (uintptr_t)stack_base;
  for (uintptr_t p = lo & ~(uintptr_t)(sizeof(uintptr_t) - 1); p + sizeof(uintptr_t) <= hi; p += sizeof(uintptr_t)) {
    uintptr_t w = *(volatile uintptr_t *)p;
    if (w != 0 && set_has((const void *)w)) mark_obj((const void *)w);
  }
  (void)here;
}

static void free_object(GCObj *o) {
  set_remove(o);
  switch (o->kind) {
    case GC_TABLE: free(((Table *)o)->nodes); break;
    case GC_VARARGS: free(((VarArgs *)o)->vals); break;
    default: break;
  }
  free(o);
}

static void sweep(void) {
  GCObj **pp = &all_objects;
  size_t live = 0;
  while (*pp != NULL) {
    GCObj *o = *pp;
    if (o->marked) {
      o->marked = 0;
      live += o->size;
      pp = &o->next;
    } else {
      *pp = o->next;
      free_object(o);
    }
  }
  gc_live = live;
}

static void gc_collect(void) {
  if (stack_base == NULL) return;
  gray_n = 0;
  for (size_t i = 0; i < LUA54RT_STACK; ++i) mark_value(&lua_stack[i]);
  scan_c_stack();
  for (UpVal *u = open_upvals; u != NULL; u = u->open_next) mark_obj(u);
  mark_obj(string_meta);
  mark_value(&next_fn);
  mark_value(&ipairs_iter_fn);
  mark_obj(running_main);
  propagate();
  sweep();
  gc_threshold = gc_live * 2 > gc_min_threshold ? gc_live * 2 : gc_min_threshold;
  gc_allocated = 0;
}

/* collectgarbage(opt): "collect" (the default), "step", "count" (in KB), "isrunning", "stop", "restart". */
static int host_collectgarbage(LV *out, LV *args, int nargs) {
  const char *opt = "collect";
  if (nargs >= 1 && args[0].tag != TAG_NIL) {
    if (args[0].tag != TAG_STR) lib_arg_error(1, "collectgarbage", "string", arg_typename(args, nargs, 1));
    opt = ((LString *)args[0].v.p)->bytes;
  }
  if (strcmp(opt, "collect") == 0) {
    gc_collect();
    out[0].tag = TAG_INT;
    out[0].v.i = 0;
    return 1;
  }
  if (strcmp(opt, "step") == 0) {
    gc_collect();
    out[0].tag = TAG_TRUE;
    return 1;
  }
  if (strcmp(opt, "count") == 0) {
    out[0].tag = TAG_FLOAT;
    out[0].v.n = (double)(gc_live + gc_allocated) / 1024.0;
    return 1;
  }
  if (strcmp(opt, "isrunning") == 0) {
    out[0].tag = TAG_TRUE;
    return 1;
  }
  if (strcmp(opt, "stop") == 0 || strcmp(opt, "restart") == 0) {
    out[0].tag = TAG_INT;
    out[0].v.i = 0;
    return 1;
  }
  char msg[160];
  snprintf(msg, sizeof msg, "bad argument #1 to 'collectgarbage' (invalid option '%s')", opt);
  rt_fail(msg, -1);
  return 0;
}

/* Runs the main function of a chunk on a stack the runtime owns. The results are copied to out (at most outsize of
 * them); the number of results is returned. */
int lua54rt_run_main(void *cl, LV *out, int outsize) {
  LV ret[256];
  lua54rt_nargs = 0;
  lua54rt_top = 0;
  const char *gcenv = getenv("LUA54RT_GC_THRESHOLD");
  if (gcenv != NULL) gc_min_threshold = gc_threshold = (size_t)strtoul(gcenv, NULL, 10);
  stack_base = __builtin_frame_address(0);
  running_main = cl;
  ((LClosure *)cl)->fn(ret, lua_stack, cl);
  running_main = NULL;
  int n = lua54rt_nret < outsize ? lua54rt_nret : outsize;
  for (int k = 0; k < n; ++k) out[k] = ret[k];
  return n;
}
