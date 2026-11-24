/* The runtime helpers that lowered Lua 5.4 IR calls (docs/notes/lua54-pathb.md, "Runtime helpers").
 * Numbers only: arithmetic, bitwise, unary and numeric for loops, with lvm.c's rules (luaV_idiv, luaV_mod, luaV_modf,
 * luaV_shiftl, forprep, forlimit, floatforloop). Strings, tables, calls and metamethods are not here yet; a non-number
 * operand stops the program. */
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

enum {
  TAG_NIL = 0x00, TAG_FALSE = 0x01, TAG_TRUE = 0x11, TAG_INT = 0x03, TAG_FLOAT = 0x13, TAG_STR = 0x04,
  TAG_TABLE = 0x05, TAG_LCL = 0x06, TAG_LCF = 0x16
};
/* lopcodes.h opcode numbers of the binary ops (the helper takes the base op, not the K or I form). */
enum {
  OP_ADD = 34, OP_SUB = 35, OP_MUL = 36, OP_MOD = 37, OP_POW = 38, OP_DIV = 39, OP_IDIV = 40,
  OP_BAND = 41, OP_BOR = 42, OP_BXOR = 43, OP_SHL = 44, OP_SHR = 45
};
enum { OP_UNM = 49, OP_BNOT = 50 };

static void die(const char *what) {
  fprintf(stderr, "lua54rt: %s\n", what);
  exit(4);
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

/* The calling protocol (docs/notes/lua54-pathb.md, "Calls"). A callee writes its results to ret[0..n-1] and records n in
 * lua54rt_nret. The stack top, lua54rt_top, is the index after the last value of a multi-result op; the next op that
 * takes "up to top" reads it at once. The callee's arguments are the caller's registers. A vararg function saves its
 * extra arguments at entry (lua54rt_varargprep), while their count is still in lua54rt_nargs. */
static int lua54rt_nret = 0;
static int lua54rt_top = 0;
static int lua54rt_nargs = 0;

int lua54rt_gettop(void) { return lua54rt_top; }

/* RETURN: copy n values from src to ret. ret lies below src (it is the caller's register A), so a forward copy is safe. */
void lua54rt_setret(LV *ret, LV *src, int n) {
  for (int k = 0; k < n; ++k) ret[k] = src[k];
  lua54rt_nret = n;
}

/* OP_CALL: the callee's base is args; its results go to ret. wanted is the number of results the caller takes, or -1
 * for all of them, which sets the stack top to a + n (a is the caller's register index of the call). */
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

void lua54rt_call(LV *fn, int nargs, LV *args, LV *ret, int wanted, int a) {
  if (fn->tag == TAG_LCF) {
    LV out[64];
    int n = ((HostFn *)fn->v.p)->fn(out, args, nargs);
    lua54rt_nret = n;
    for (int k = 0; k < n; ++k) ret[k] = out[k];
    finish_call(ret, wanted, a);
    return;
  }
  if (fn->tag != TAG_LCL) die("attempt to call a value that is not a function");
  LClosure *c = (LClosure *)fn->v.p;
  for (int k = nargs; k < c->numparams; ++k) args[k].tag = TAG_NIL;
  lua54rt_nargs = nargs;
  lua54rt_nret = 0;
  c->fn(ret, args, c);
  finish_call(ret, wanted, a);
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

/* luaV_tointeger with F2Ifloor or F2Iceil (mode 0 is floor, 1 is ceil). */
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

/* luaV_idiv: floor division of integers. */
static int64_t int_idiv(int64_t m, int64_t n) {
  if ((uint64_t)n + 1u <= 1u) {
    if (n == 0) die("attempt to perform 'n//0'");
    return (int64_t)(0u - (uint64_t)m); /* n == -1 */
  }
  int64_t q = m / n;
  if ((m ^ n) < 0 && m % n != 0) q -= 1;
  return q;
}

/* luaV_mod: modulo of integers, the result has the sign of the divisor. */
static int64_t int_mod(int64_t m, int64_t n) {
  if ((uint64_t)n + 1u <= 1u) {
    if (n == 0) die("attempt to perform 'n%%0'");
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

void lua54rt_arith(int op, LV *dst, LV *a, LV *b) {
  if (!is_number(a) || !is_number(b)) die("arithmetic on a non-number");
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
  /* bitwise: both operands need an exact integer value */
  int64_t x, y;
  if (!to_int_exact(a, &x) || !to_int_exact(b, &y)) die("number has no integer representation");
  int64_t r;
  if (op == OP_BAND) r = x & y;
  else if (op == OP_BOR) r = x | y;
  else if (op == OP_BXOR) r = x ^ y;
  else if (op == OP_SHL) r = shift_l(x, y);
  else r = shift_l(x, (int64_t)(0u - (uint64_t)y)); /* OP_SHR: shiftl by -y */
  dst->tag = TAG_INT;
  dst->v.i = r;
}

void lua54rt_unary(int op, LV *dst, LV *a) {
  if (op == OP_UNM) {
    if (a->tag == TAG_INT) {
      dst->tag = TAG_INT;
      dst->v.i = (int64_t)(0u - (uint64_t)a->v.i);
      return;
    }
    if (a->tag != TAG_FLOAT) die("arithmetic on a non-number");
    dst->tag = TAG_FLOAT;
    dst->v.n = -a->v.n;
    return;
  }
  /* OP_BNOT */
  int64_t x;
  if (!to_int_exact(a, &x)) die("number has no integer representation");
  dst->tag = TAG_INT;
  dst->v.i = (int64_t)~(uint64_t)x;
}

/* lvm.c forprep. ra: ra[0] init, ra[1] limit, ra[2] step, ra[3] control. Returns 1 to skip the loop. */
int lua54rt_forprep(LV *ra) {
  LV *pinit = &ra[0], *plimit = &ra[1], *pstep = &ra[2];
  if (pinit->tag == TAG_INT && pstep->tag == TAG_INT) {
    int64_t init = pinit->v.i, step = pstep->v.i, limit;
    if (step == 0) die("'for' step is zero");
    ra[3].tag = TAG_INT;
    ra[3].v.i = init;
    /* forlimit */
    if (!to_int_round(plimit, &limit, step < 0)) {
      if (!is_number(plimit)) die("'for' limit must be a number");
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
  if (!is_number(plimit)) die("'for' limit must be a number");
  if (!is_number(pstep)) die("'for' step must be a number");
  if (!is_number(pinit)) die("'for' initial value must be a number");
  double limit = as_float(plimit), step = as_float(pstep), init = as_float(pinit);
  if (step == 0) die("'for' step is zero");
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


/* Strings: immutable, compared by content. No interning: each lowered string constant or result is a new object. */
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

/* Tables: a hash of key/value nodes with linear probing. Keys are normalized as lvm.c does: a float with an integer
 * value is the integer key. Setting nil keeps the node until the next resize. No array part yet. */
typedef struct Node {
  LV key;
  LV val;
  int used;
} Node;

typedef struct Table {
  Node *nodes;
  size_t cap;    /* a power of two, or 0 */
  size_t count;  /* used nodes, including those with a nil value */
} Table;

static const char *type_name(uint8_t tag) {
  switch (tag) {
    case TAG_NIL: return "nil";
    case TAG_FALSE:
    case TAG_TRUE: return "boolean";
    case TAG_INT:
    case TAG_FLOAT: return "number";
    case TAG_STR: return "string";
    case TAG_TABLE: return "table";
    case TAG_LCL: return "function";
    default: return "?";
  }
}

static void die_type(const char *what, uint8_t tag) {
  char buf[128];
  snprintf(buf, sizeof buf, "attempt to %s a %s value", what, type_name(tag));
  die(buf);
}

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

/* The key as lvm.c stores it: nil and NaN are errors; a float with an exact integer value is an integer. */
static LV normal_key(const LV *k) {
  LV r = *k;
  if (k->tag == TAG_NIL) die("table index is nil");
  if (k->tag == TAG_FLOAT) {
    double f = k->v.n;
    if (f != f) die("table index is NaN");
    if (floor(f) == f && f >= -9223372036854775808.0 && f < 9223372036854775808.0) {
      r.tag = TAG_INT;
      r.v.i = (int64_t)f;
    }
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

void lua54rt_newtable(LV *dst) {
  Table *t = (Table *)calloc(1, sizeof *t);
  if (t == NULL) die("out of memory");
  dst->tag = TAG_TABLE;
  dst->v.p = t;
}

static Table *as_table(const LV *t, const char *what) {
  if (t->tag != TAG_TABLE) die_type(what, t->tag);
  return (Table *)t->v.p;
}

void lua54rt_gettable(LV *dst, LV *t, LV *key) {
  Table *tb = as_table(t, "index");
  LV k = normal_key(key);
  Node *n = table_find(tb, &k);
  if (n != NULL) *dst = n->val;
  else dst->tag = TAG_NIL;
}

void lua54rt_settable(LV *t, LV *key, LV *val) {
  Table *tb = as_table(t, "index");
  LV k = normal_key(key);
  if (val->tag == TAG_NIL) {
    Node *n = table_find(tb, &k);
    if (n != NULL) n->val.tag = TAG_NIL;
    return;
  }
  Node *n = table_slot(tb, &k);
  n->val = *val;
}

/* The border: the largest n with t[1..n] all non-nil, found by counting from 1. */
static int64_t table_border(const Table *t) {
  int64_t n = 0;
  for (;;) {
    LV k;
    k.tag = TAG_INT;
    k.v.i = n + 1;
    Node *node = table_find(t, &k);
    if (node == NULL || node->val.tag == TAG_NIL) return n;
    n++;
  }
}

void lua54rt_len(LV *dst, LV *src) {
  /* read the source before the destination is written: they may be the same register */
  int64_t n;
  if (src->tag == TAG_STR) n = (int64_t)((LString *)src->v.p)->len;
  else n = table_border(as_table(src, "get the length of"));
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

/* OP_CONCAT: R[dst] := the n values from base, concatenated; strings and numbers only. */
void lua54rt_concat(LV *dst, LV *base, int n) {
  size_t total = 0;
  char numbuf[64];
  for (int i = 0; i < n; ++i) {
    if (base[i].tag == TAG_STR) total += ((LString *)base[i].v.p)->len;
    else if (is_number(&base[i])) total += number_text(&base[i], numbuf, sizeof numbuf);
    else die_type("concatenate", base[i].tag);
  }
  char *buf = (char *)malloc(total + 1);
  if (buf == NULL) die("out of memory");
  size_t pos = 0;
  for (int i = 0; i < n; ++i) {
    if (base[i].tag == TAG_STR) {
      LString *s = (LString *)base[i].v.p;
      memcpy(buf + pos, s->bytes, s->len);
      pos += s->len;
    } else {
      pos += number_text(&base[i], buf + pos, total + 1 - pos);
    }
  }
  *dst = make_str(buf, total);
  free(buf);
}

/* OP_SETLIST: t[offset + j] := vals[j - 1] for j = 1..count. */
void lua54rt_setlist(LV *t, long offset, LV *vals, int count) {
  Table *tb = as_table(t, "index");
  for (int j = 1; j <= count; ++j) {
    LV k;
    k.tag = TAG_INT;
    k.v.i = offset + j;
    if (vals[j - 1].tag == TAG_NIL) continue;
    Node *n = table_slot(tb, &k);
    n->val = vals[j - 1];
  }
}

/* A closure for the main function of a chunk: upvalue 0 is _ENV, a fresh table; the others are nil. */
void lua54rt_install_library(LV *env);

static void set_global(LV *env, const char *name, LV *value) {
  LV key = make_str(name, strlen(name));
  lua54rt_settable(env, &key, value);
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

/* Equality as lvm.c's luaV_equalobj without metamethods: numbers by value, other types by tag, then content (strings)
 * or identity (tables and functions); nil and booleans are equal to themselves. */
static int equal_values(const LV *a, const LV *b) {
  if (is_number(a) && is_number(b)) {
    if (a->tag == TAG_INT && b->tag == TAG_INT) return a->v.i == b->v.i;
    return as_float(a) == as_float(b);
  }
  if (a->tag != b->tag) return 0;
  return same_key(a, b);
}

/* kind 0: a < b, 1: a <= b, 2: a == b. Returns 0 or 1. Numbers compare as doubles when they differ in type; strings by
 * bytes (the C locale's collation, as strcoll gives there). */
int lua54rt_cmp(int kind, LV *a, LV *b) {
  if (kind == 2) return equal_values(a, b);
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
  die("attempt to compare two incompatible values");
  return 0;
}

/* The host library: print, type, tostring, pairs, next, ipairs, select. The rest of the base library is not here. */
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

static int host_print(LV *out, LV *args, int nargs) {
  (void)out;
  for (int k = 0; k < nargs; ++k) {
    if (k > 0) fputc('\t', stdout);
    write_value(stdout, &args[k]);
  }
  fputc('\n', stdout);
  return 0;
}

static void set_string(LV *dst, const char *s) { *dst = make_str(s, strlen(s)); }

static int host_type(LV *out, LV *args, int nargs) {
  if (nargs < 1) die("bad argument #1 to 'type' (value expected)");
  const char *name = type_name(args[0].tag);
  if (args[0].tag == TAG_LCF) name = "function";
  set_string(&out[0], name);
  return 1;
}

static int host_tostring(LV *out, LV *args, int nargs) {
  if (nargs < 1) die("bad argument #1 to 'tostring' (value expected)");
  if (args[0].tag == TAG_STR) {
    out[0] = args[0];
    return 1;
  }
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
  Table *t = as_table(&args[0], "traverse");
  size_t start = 0;
  if (nargs >= 2 && args[1].tag != TAG_NIL) {
    LV k = normal_key(&args[1]);
    Node *nd = table_find(t, &k);
    if (nd == NULL) die("invalid key to 'next'");
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
  if (nargs < 1) die("bad argument #1 to 'pairs' (table expected)");
  as_table(&args[0], "traverse");
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
  if (nargs < 1) die("bad argument #1 to 'ipairs' (table expected)");
  out[0] = ipairs_iter_fn;
  out[1] = args[0];
  out[2].tag = TAG_INT;
  out[2].v.i = 0;
  return 3;
}

/* select('#', ...) or select(n, ...): the values from the n-th on. */
static int host_select(LV *out, LV *args, int nargs) {
  if (nargs < 1) die("bad argument #1 to 'select' (number expected)");
  int count = nargs - 1;
  if (args[0].tag == TAG_STR && ((LString *)args[0].v.p)->len == 1 && ((LString *)args[0].v.p)->bytes[0] == '#') {
    out[0].tag = TAG_INT;
    out[0].v.i = count;
    return 1;
  }
  if (args[0].tag != TAG_INT) die("bad argument #1 to 'select' (number expected)");
  int64_t n = args[0].v.i;
  if (n < 1) die("bad argument #1 to 'select' (index out of range)");
  int produced = 0;
  for (int64_t k = n; k <= count; ++k) out[produced++] = args[k];
  return produced;
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
