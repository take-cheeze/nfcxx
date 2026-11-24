#define _GNU_SOURCE
/* The runtime helpers that lowered Lua 5.4 IR calls (docs/notes/lua54-pathb.md, "Runtime helpers").
 * Values, numbers with lvm.c's rules, strings, tables with metatables, closures and upvalues, the calling protocol,
 * the operators with their metamethods, the host library, and the errors of ldebug.c with their variable names. */
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

/* luaG_runerror with the info of operand (or none when operand < 0): before + info + after. */
static void rt_fail3(const char *before, int operand, const char *after) {
  char where[512], info[512];
  info[0] = '\0';
  site_line(0, where, sizeof where);
  if (operand >= 0) site_line(1 + operand, info, sizeof info);
  if (where[0] != '\0') fprintf(stderr, "lua: %s %s%s%s\n", where, before, info, after);
  else fprintf(stderr, "lua: %s%s%s\n", before, info, after);
  exit(1);
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
typedef struct LString {
  size_t len;
  char bytes[1];   /* len bytes and a NUL */
} LString;

static LV make_str(const char *p, size_t len) {
  LString *s = (LString *)malloc(sizeof(LString) + len);
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
  Table *t = (Table *)calloc(1, sizeof *t);
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
static int get_mt(const LV *o, const char *event, LV *out) {
  if (o->tag != TAG_TABLE) return 0;
  const Table *mt = ((const Table *)o->v.p)->meta;
  if (mt == NULL) return 0;
  LV key = make_str(event, strlen(event));
  LV v = raw_get(mt, &key);
  if (v.tag == TAG_NIL) return 0;
  *out = v;
  return 1;
}

static int truthy(const LV *v) { return v->tag != TAG_NIL && v->tag != TAG_FALSE; }

void lua54rt_call(LV *fn, int nargs, LV *args, LV *ret, int wanted, int a);
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
  LV *v;
  LV closed;
  UpVal *open_next;   /* the open list, highest address first */
};

typedef void (*lua_fn)(LV *ret, LV *base, void *cl);
typedef struct LClosure {
  lua_fn fn;
  int numparams;
  int nupvals;
  UpVal *upvals[1];   /* nupvals entries; the closure is allocated with room for them */
} LClosure;

static UpVal *open_upvals = NULL;

void lua54rt_closure(LV *dst, void *fn, int numparams, int nupvals) {
  size_t size = sizeof(LClosure) + sizeof(UpVal *) * (size_t)(nupvals > 0 ? nupvals - 1 : 0);
  LClosure *c = (LClosure *)malloc(size);
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
  UpVal *uv = (UpVal *)malloc(sizeof *uv);
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
void lua54rt_close(LV *level) {
  while (open_upvals != NULL && open_upvals->v >= level) {
    UpVal *uv = open_upvals;
    uv->closed = *uv->v;
    uv->v = &uv->closed;
    open_upvals = uv->open_next;
  }
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
typedef struct HostFn {
  lua_cfn fn;
} HostFn;

static void make_host(LV *dst, lua_cfn fn) {
  HostFn *h = (HostFn *)malloc(sizeof *h);
  if (h == NULL) die("out of memory");
  h->fn = fn;
  dst->tag = TAG_LCF;
  dst->v.p = h;
}

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
    int n = ((HostFn *)fn->v.p)->fn(out, args, nargs);
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
    c->fn(ret, args, c);
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
  int count;
  LV *vals;
} VarArgs;

void *lua54rt_varargprep(LV *base, int nfixed) {
  VarArgs *va = (VarArgs *)malloc(sizeof *va);
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
    UpVal *uv = (UpVal *)malloc(sizeof *uv);
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
static int host_select(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "select", "number");
  int count = nargs - 1;
  if (args[0].tag == TAG_STR && ((LString *)args[0].v.p)->len == 1 && ((LString *)args[0].v.p)->bytes[0] == '#') {
    out[0].tag = TAG_INT;
    out[0].v.i = count;
    return 1;
  }
  if (args[0].tag != TAG_INT) rt_fail("bad argument #1 to 'select' (number expected)", -1);
  int64_t n = args[0].v.i;
  if (n < 1) rt_fail("bad argument #1 to 'select' (index out of range)", -1);
  int produced = 0;
  for (int64_t k = n; k <= count; ++k) out[produced++] = args[k];
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
}

/* Runs the main function of a chunk on a stack the runtime owns. The results are copied to out (at most outsize of
 * them); the number of results is returned. */
#define LUA54RT_STACK 65536
int lua54rt_run_main(void *cl, LV *out, int outsize) {
  static LV stack[LUA54RT_STACK];
  LV ret[256];
  lua54rt_nargs = 0;
  lua54rt_top = 0;
  ((LClosure *)cl)->fn(ret, stack, cl);
  int n = lua54rt_nret < outsize ? lua54rt_nret : outsize;
  for (int k = 0; k < n; ++k) out[k] = ret[k];
  return n;
}
