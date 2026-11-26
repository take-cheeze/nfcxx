#define _GNU_SOURCE
/* The runtime helpers that lowered Lua 5.4 IR calls (docs/notes/lua54-pathb.md, "Runtime helpers").
 * Values, numbers with lvm.c's rules, strings, tables with metatables, closures and upvalues, the calling protocol,
 * the operators with their metamethods, the host library, and the errors of ldebug.c with their variable names. */
#include <ctype.h>
#include <limits.h>
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
  TAG_STR = 0x04, TAG_TABLE = 0x05, TAG_LCL = 0x06, TAG_LCF = 0x16,
  TAG_DEADKEY = 0x7f   /* a key of a weak table whose object was collected: it matches no key (lgc.c's dead keys) */
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
void lua54rt_close_state(void);
static void scrub_stack(void);

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
static struct Table *arg_table(const LV *args, int nargs, int k, const char *fname);
static const char *arg_typename(const LV *args, int nargs, int k);

/* An internal inconsistency of the runtime, not a Lua error. */
static void die(const char *what) {
  fprintf(stderr, "lua54rt: internal error: %s\n", what);
  exit(4);
}

/* A copy of a string, malloc'ed (the report of an error is built in such strings). */
static char *dupstr(const char *s) {
  size_t n = strlen(s) + 1;
  char *p = (char *)malloc(n);
  if (p == NULL) die("out of memory");
  memcpy(p, s, n);
  return p;
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

static char *uncaught_message(const LV *err);

static void raise_value(LV err) {
  if (pcall_top != NULL) {
    pcall_top->err = err;
    longjmp(pcall_top->jb, 1);
  }
  /* lua.c's msghandler runs before the unwinding, so the traceback is that of the error's frames */
  char *report = uncaught_message(&err);
  close_to(NULL, &err);   /* lua.c's protected call closes the to-be-closed variables before it reports the error */
  fprintf(stderr, "lua: %s\n", report);
  free(report);
  lua54rt_close_state();  /* lua.c's lua_close runs the finalizers after the report */
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

static int get_mt(const LV *o, const char *event, LV *out);

/* ldebug.c's luaT_objtypename: the __name of a table's metatable when that is a string, else the type name. The string
 * lives in the metatable, which the value keeps alive while the message is built. */
static const char *objtypename(const LV *v) {
  LV n;
  if (v->tag == TAG_TABLE && get_mt(v, "__name", &n) && n.tag == TAG_STR) return ((LString *)n.v.p)->bytes;
  return type_name(v->tag);
}

/* lauxlib.c's luaL_typeerror: the same, for any value that has a metatable (a string has the string one). */
static const char *argtypename(const LV *v) {
  LV n;
  if (get_mt(v, "__name", &n) && n.tag == TAG_STR) return ((LString *)n.v.p)->bytes;
  return type_name(v->tag);
}

/* luaG_typeerror: "attempt to <op> a <type> value" with the info of the operand. */
static void type_fail(const char *op, const LV *v, int operand) {
  char buf[300];
  snprintf(buf, sizeof buf, "attempt to %s a %s value", op, objtypename(v));
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

/* ---- tables: ltable.c (Lua 5.4.9). An array part (array, alimit) and a hash part of 2^lsizenode nodes with chains
 * (next offsets), main positions and free positions as ltable.c has them. So the border of '#' (luaH_getn), the order of
 * next/pairs and the moment of a rehash are Lua's for integer, float and boolean keys. The hash of a string or a pointer
 * differs from Lua's (Lua seeds its string hash randomly), so their positions do too. ---- */
typedef struct Node {
  LV key;     /* TAG_NIL: a node whose key was never set; TAG_DEADKEY: a weak key that was collected */
  LV val;     /* TAG_NIL: an empty entry; its key stays until the next resize */
  int next;   /* offset to the next node of the chain, 0 at the end */
} Node;

typedef struct Table {
  GCObj gc;
  LV *array;                  /* the array part: realasize entries */
  unsigned int alimit;        /* ltable.c's alimit: the array size, or a hint for '#' when norealasize is set */
  unsigned char norealasize;  /* ltable.c's BITRAS: alimit is not the real size of the array */
  unsigned char tofin;        /* marked for finalization (lgc.c's FINALIZEDBIT): in fin_objs or tbf */
  Node *node;                 /* the hash part: 2^lsizenode nodes; &dummy_node when it is empty */
  unsigned char lsizenode;
  Node *lastfree;             /* the search for a free node goes down from here; NULL when the hash part is dummy_node */
  struct Table *meta;         /* the metatable, or NULL */
} Table;

static Node dummy_node;               /* all zero: nil key, empty value, no chain */
static LV absent_slot;                /* all zero: the nil that 'absent' lookups return; never written */

#define MAXABITS 31
#define MAXASIZE (1u << MAXABITS)
#define MAXHBITS 30

static uint64_t mix(uint64_t x) {
  x ^= x >> 33;
  x *= 0xff51afd7ed558ccdULL;
  x ^= x >> 33;
  return x;
}

static uint64_t hash_key(const LV *k) {
  switch (k->tag) {
    case TAG_STR: {
      const LString *s = (const LString *)k->v.p;
      uint64_t h = 1469598103934665603ULL;
      for (size_t i = 0; i < s->len; ++i) h = (h ^ (unsigned char)s->bytes[i]) * 1099511628211ULL;
      return h;
    }
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

/* The key as lvm.c stores it: a float with an exact integer value is that integer. Only valid for a key that is not nil
 * or NaN. */
static LV normal_key(const LV *k) {
  LV r = *k;
  if (k->tag == TAG_FLOAT && floor(k->v.n) == k->v.n && k->v.n >= -9223372036854775808.0 &&
      k->v.n < 9223372036854775808.0) {
    r.tag = TAG_INT;
    r.v.i = (int64_t)k->v.n;
  }
  return r;
}

/* ltable.c's l_hashfloat. */
static int l_hashfloat(double n) {
  int i;
  n = frexp(n, &i) * -(double)INT_MIN;
  if (!(n >= -9223372036854775808.0 && n < 9223372036854775808.0)) return 0;   /* inf or NaN */
  int64_t ni = (int64_t)n;
  unsigned int u = (unsigned int)i + (unsigned int)ni;
  return (int)(u <= (unsigned int)INT_MAX ? u : ~u);
}

static int table_isdummy(const Table *t) { return t->lastfree == NULL; }
static size_t node_count(const Table *t) { return (size_t)1 << t->lsizenode; }

/* The main position of a key (ltable.c's mainpositionTV). */
static Node *mainposition(const Table *t, const LV *key) {
  size_t size = node_count(t);
  uint64_t mod = (uint64_t)((size - 1) | 1);
  switch (key->tag) {
    case TAG_INT: return &t->node[(uint64_t)key->v.i % mod];
    case TAG_FLOAT: return &t->node[(uint64_t)(unsigned int)l_hashfloat(key->v.n) % mod];
    case TAG_STR: return &t->node[hash_key(key) & (size - 1)];
    case TAG_FALSE: return &t->node[0];
    case TAG_TRUE: return &t->node[1 & (size - 1)];
    default: return &t->node[(uint64_t)(uint32_t)(uintptr_t)key->v.p % mod];
  }
}

/* The node that holds 'key' (not normalized is fine: the float and integer keys do not match), or NULL. */
static Node *find_node(const Table *t, const LV *key) {
  Node *n = mainposition(t, key);
  for (;;) {
    if (same_key(&n->key, key)) return n;
    if (n->next == 0) return NULL;
    n += n->next;
  }
}

/* ltable.c's arrayindex: the array index of k, or 0 when k is not one. */
static unsigned int arrayindex(int64_t k) {
  if ((uint64_t)k - 1u < (uint64_t)MAXASIZE) return (unsigned int)k;
  return 0;
}

/* luaO_ceillog2 for x >= 1. */
static int ceillog2(unsigned int x) {
  int l = 0;
  x--;
  while (x > 0) {
    l++;
    x >>= 1;
  }
  return l;
}

/* ltable.c's luaH_realasize: the size of the array part. */
static unsigned int realasize(const Table *t) {
  unsigned int limit = t->alimit;
  if (!t->norealasize || (limit & (limit - 1)) == 0) return limit;
  unsigned int size = limit;
  size |= (size >> 1);
  size |= (size >> 2);
  size |= (size >> 4);
  size |= (size >> 8);
  size |= (size >> 16);
  return size + 1;
}

static int ispow2realasize(const Table *t) { return t->norealasize || (t->alimit & (t->alimit - 1)) == 0; }

static int limitequalsasize(const Table *t) { return !t->norealasize || (t->alimit & (t->alimit - 1)) == 0; }

static unsigned int setlimittosize(Table *t) {
  t->alimit = realasize(t);
  t->norealasize = 0;
  return t->alimit;
}

/* luaH_getint: the value slot of integer key, or &absent_slot. As in ltable.c, a read may move alimit (the hint). */
static LV *table_getint(Table *t, int64_t key) {
  uint64_t alimit = t->alimit;
  if ((uint64_t)key - 1u < alimit) return &t->array[key - 1];
  if (t->norealasize && (((uint64_t)key - 1u) & ~(alimit - 1u)) < alimit) {
    t->alimit = (unsigned int)key;   /* probably '#t' is here now */
    return &t->array[key - 1];
  }
  Node *n = &t->node[(uint64_t)key % (uint64_t)((node_count(t) - 1) | 1)];
  for (;;) {
    if (n->key.tag == TAG_INT && n->key.v.i == key) return &n->val;
    if (n->next == 0) return &absent_slot;
    n += n->next;
  }
}

/* luaH_get: the value slot of a key (normalized or not), or &absent_slot. */
static LV *table_get(Table *t, const LV *key) {
  switch (key->tag) {
    case TAG_INT: return table_getint(t, key->v.i);
    case TAG_NIL: return &absent_slot;
    case TAG_FLOAT: {
      if (floor(key->v.n) == key->v.n && key->v.n >= -9223372036854775808.0 && key->v.n < 9223372036854775808.0)
        return table_getint(t, (int64_t)key->v.n);
      break;
    }
    default: break;
  }
  Node *n = find_node(t, key);
  return n != NULL ? &n->val : &absent_slot;
}

/* lua_rawget: nil for a nil or NaN key, as Lua reads them. */
static LV raw_get(Table *t, const LV *key) {
  if (key->tag == TAG_NIL) return absent_slot;
  if (key->tag == TAG_FLOAT && key->v.n != key->v.n) return absent_slot;
  return *table_get(t, key);
}

static void table_setnodevector(Table *t, unsigned int size) {
  if (size == 0) {
    t->node = &dummy_node;
    t->lsizenode = 0;
    t->lastfree = NULL;
    return;
  }
  int lsize = ceillog2(size);
  if (lsize > MAXHBITS) die("table overflow");
  size = 1u << lsize;
  t->node = (Node *)calloc(size, sizeof(Node));
  if (t->node == NULL) die("out of memory");
  t->lsizenode = (unsigned char)lsize;
  t->lastfree = t->node + size;
}

static Node *getfreepos(Table *t) {
  if (!table_isdummy(t)) {
    while (t->lastfree > t->node) {
      t->lastfree--;
      if (t->lastfree->key.tag == TAG_NIL) return t->lastfree;
    }
  }
  return NULL;
}

static void table_setint(Table *t, int64_t key, const LV *val);
static void raw_set(Table *t, const LV *key, const LV *val);

/* ltable.c's rehash: count the integer keys, choose the array size and resize. */
static int countint(int64_t key, unsigned int *nums) {
  unsigned int k = arrayindex(key);
  if (k != 0) {
    nums[ceillog2(k)]++;
    return 1;
  }
  return 0;
}

static unsigned int numusearray(const Table *t, unsigned int *nums) {
  unsigned int ause = 0, i = 1, asize = t->alimit;
  unsigned int ttlg = 1;
  for (int lg = 0; lg <= MAXABITS; lg++, ttlg *= 2) {
    unsigned int lc = 0, lim = ttlg;
    if (lim > asize) {
      lim = asize;
      if (i > lim) break;
    }
    for (; i <= lim; i++) {
      if (t->array[i - 1].tag != TAG_NIL) lc++;
    }
    nums[lg] += lc;
    ause += lc;
  }
  return ause;
}

static int numusehash(const Table *t, unsigned int *nums, unsigned int *pna) {
  int totaluse = 0, ause = 0;
  int i = (int)node_count(t);
  while (i--) {
    const Node *n = &t->node[i];
    if (n->val.tag != TAG_NIL) {
      if (n->key.tag == TAG_INT) ause += countint(n->key.v.i, nums);
      totaluse++;
    }
  }
  *pna += (unsigned int)ause;
  return totaluse;
}

static unsigned int computesizes(unsigned int nums[], unsigned int *pna) {
  int i;
  unsigned int twotoi, a = 0, na = 0, optimal = 0;
  for (i = 0, twotoi = 1; twotoi > 0 && *pna > twotoi / 2; i++, twotoi *= 2) {
    a += nums[i];
    if (a > twotoi / 2) {
      optimal = twotoi;
      na = a;
    }
  }
  *pna = na;
  return optimal;
}

static void exchange_hash(Table *a, Table *b) {
  Node *node = a->node;
  unsigned char lsizenode = a->lsizenode;
  Node *lastfree = a->lastfree;
  a->node = b->node;
  a->lsizenode = b->lsizenode;
  a->lastfree = b->lastfree;
  b->node = node;
  b->lsizenode = lsizenode;
  b->lastfree = lastfree;
}

/* ltable.c's luaH_resize: the array gets newasize entries and the hash part gets room for nhsize keys. */
static void table_resize(Table *t, unsigned int newasize, unsigned int nhsize) {
  unsigned int i;
  Table newt;
  unsigned int oldasize = setlimittosize(t);
  table_setnodevector(&newt, nhsize);
  if (newasize < oldasize) {
    t->alimit = newasize;
    exchange_hash(t, &newt);
    for (i = newasize; i < oldasize; i++) {
      if (t->array[i].tag != TAG_NIL) table_setint(t, (int64_t)i + 1, &t->array[i]);
    }
    t->alimit = oldasize;
    exchange_hash(t, &newt);
  }
  LV *newarray;
  if (newasize == 0) {
    free(t->array);
    newarray = NULL;
  } else {
    newarray = (LV *)realloc(t->array, sizeof(LV) * (size_t)newasize);
    if (newarray == NULL) die("out of memory");
  }
  exchange_hash(t, &newt);   /* t has the new hash part, newt the old one */
  t->array = newarray;
  t->alimit = newasize;
  for (i = oldasize; i < newasize; i++) t->array[i].tag = TAG_NIL;
  for (size_t j = 0; j < node_count(&newt); ++j) {
    Node *old = &newt.node[j];
    if (old->val.tag != TAG_NIL) raw_set(t, &old->key, &old->val);
  }
  if (!table_isdummy(&newt)) free(newt.node);
}

static void table_rehash(Table *t, const LV *ek) {
  unsigned int nums[MAXABITS + 1];
  unsigned int na, asize, totaluse;
  for (int i = 0; i <= MAXABITS; i++) nums[i] = 0;
  setlimittosize(t);
  na = numusearray(t, nums);
  totaluse = na;
  totaluse += (unsigned int)numusehash(t, nums, &na);
  if (ek->tag == TAG_INT) na += (unsigned int)countint(ek->v.i, nums);
  totaluse++;
  asize = computesizes(nums, &na);
  table_resize(t, asize, totaluse - na);
}

/* ltable.c's luaH_newkey: key is normalized, not nil and not NaN. Nothing is inserted for a nil value. */
static void table_newkey(Table *t, const LV *key, const LV *val) {
  Node *mp;
  if (val->tag == TAG_NIL) return;
  mp = mainposition(t, key);
  if (mp->val.tag != TAG_NIL || table_isdummy(t)) {   /* main position is taken? */
    Node *f = getfreepos(t);
    if (f == NULL) {
      table_rehash(t, key);
      raw_set(t, key, val);
      return;
    }
    Node *othern = mainposition(t, &mp->key);
    if (othern != mp) {   /* the colliding node is out of its main position: move it to the free node */
      while (othern + othern->next != mp) othern += othern->next;
      othern->next = (int)(f - othern);
      *f = *mp;
      if (mp->next != 0) {
        f->next += (int)(mp - f);
        mp->next = 0;
      }
      mp->val.tag = TAG_NIL;
    } else {   /* the colliding node is in its main position: the new key goes to the free node */
      if (mp->next != 0) f->next = (int)((mp + mp->next) - f);
      mp->next = (int)(f - mp);
      mp = f;
    }
  }
  mp->key = *key;
  mp->val = *val;
}

/* lua_rawset: nil and NaN keys are errors. */
static void raw_set(Table *t, const LV *key, const LV *val) {
  if (key->tag == TAG_NIL) rt_fail("table index is nil", -1);
  if (key->tag == TAG_FLOAT && key->v.n != key->v.n) rt_fail("table index is NaN", -1);
  LV k = normal_key(key);
  LV *slot = table_get(t, &k);
  if (slot != &absent_slot) {
    *slot = *val;
    return;
  }
  table_newkey(t, &k, val);
}

/* luaH_setint. */
static void table_setint(Table *t, int64_t key, const LV *val) {
  LV *p = table_getint(t, key);
  if (p != &absent_slot) {
    *p = *val;
    return;
  }
  LV k;
  k.tag = TAG_INT;
  k.v.i = key;
  table_newkey(t, &k, val);
}

void lua54rt_newtable(LV *dst, unsigned int hsize, unsigned int asize) {
  Table *t = (Table *)gc_alloc(GC_TABLE, sizeof *t);
  if (t == NULL) die("out of memory");
  t->array = NULL;
  t->alimit = 0;
  t->norealasize = 0;
  table_setnodevector(t, 0);
  if (hsize != 0 || asize != 0) table_resize(t, asize, hsize);
  dst->tag = TAG_TABLE;
  dst->v.p = t;
}

/* ltable.c's hash_search: the border beyond the array part, from j (zero or present) with j + 1 present. */
static uint64_t hash_search(Table *t, uint64_t j) {
  uint64_t i;
  if (j == 0) j++;
  do {
    i = j;
    if (j <= (uint64_t)INT64_MAX / 2) {
      j *= 2;
    } else {
      j = (uint64_t)INT64_MAX;
      if (table_getint(t, (int64_t)j)->tag == TAG_NIL) break;
      return j;
    }
  } while (table_getint(t, (int64_t)j)->tag != TAG_NIL);
  while (j - i > 1u) {
    uint64_t m = (i + j) / 2;
    if (table_getint(t, (int64_t)m)->tag == TAG_NIL) j = m;
    else i = m;
  }
  return i;
}

static unsigned int binsearch(const LV *array, unsigned int i, unsigned int j) {
  while (j - i > 1u) {
    unsigned int m = (i + j) / 2;
    if (array[m - 1].tag == TAG_NIL) j = m;
    else i = m;
  }
  return i;
}

/* ltable.c's luaH_getn: a border of t, found as Lua finds it (and it may move alimit, as a hint). */
static uint64_t table_getn(Table *t) {
  unsigned int limit = t->alimit;
  if (limit > 0 && t->array[limit - 1].tag == TAG_NIL) {   /* (1) */
    if (limit >= 2 && t->array[limit - 2].tag != TAG_NIL) {
      if (ispow2realasize(t) && !(((limit - 1) & (limit - 2)) == 0)) {
        t->alimit = limit - 1;
        t->norealasize = 1;
      }
      return limit - 1;
    } else {
      unsigned int boundary = binsearch(t->array, 0, limit);
      if (ispow2realasize(t) && boundary > realasize(t) / 2) {
        t->alimit = boundary;
        t->norealasize = 1;
      }
      return boundary;
    }
  }
  if (!limitequalsasize(t)) {   /* (2) */
    if (t->array[limit].tag == TAG_NIL) return limit;
    limit = realasize(t);
    if (t->array[limit - 1].tag == TAG_NIL) {
      unsigned int boundary = binsearch(t->array, t->alimit, limit);
      t->alimit = boundary;
      return boundary;
    }
  }
  /* (3) */
  if (table_isdummy(t) || table_getint(t, (int64_t)limit + 1)->tag == TAG_NIL) return limit;
  return hash_search(t, limit);
}

/* ltable.c's luaH_next: the entry after key (nil for the first), in the array part and then in the nodes. Returns 0 at
 * the end. */
static int table_next(Table *t, const LV *key, LV *kout, LV *vout) {
  unsigned int asize = realasize(t);
  unsigned int i;
  if (key->tag == TAG_NIL) {
    i = 0;
  } else {
    unsigned int ai = key->tag == TAG_INT ? arrayindex(key->v.i) : 0;
    if (ai - 1u < asize) {
      i = ai;
    } else {
      Node *n = find_node(t, key);
      if (n == NULL) {
        /* luaG_runerror from next, a C function: no position */
        raise_value(make_str("invalid key to 'next'", 22));
      }
      i = (unsigned int)(n - t->node) + 1 + asize;
    }
  }
  for (; i < asize; i++) {
    if (t->array[i].tag != TAG_NIL) {
      kout->tag = TAG_INT;
      kout->v.i = (int64_t)i + 1;
      *vout = t->array[i];
      return 1;
    }
  }
  for (i -= asize; i < node_count(t); i++) {
    Node *n = &t->node[i];
    if (n->val.tag != TAG_NIL) {
      *kout = n->key;
      *vout = n->val;
      return 1;
    }
  }
  return 0;
}

/* The border of t (the '#' of Lua 5.4.9). */
static int64_t table_border(Table *t) { return (int64_t)table_getn(t); }

/* ---- metamethods (ltm.c): looked up in the metatable of a table; only tables have metatables here ---- */
static Table *string_meta = NULL;   /* the metatable of every string; its __index is the string library */

static int get_mt(const LV *o, const char *event, LV *out) {
  Table *mt;
  if (o->tag == TAG_TABLE) mt = ((Table *)o->v.p)->meta;
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

/* A generic 'for' calls its iterator through lua54rt_tforcall, so the iterator's argument errors name it "for iterator"
 * as luaL_argerror does. host_from_tfor is set while such a host function runs. */
static LV global_env;   /* the table of the globals: pushglobalfuncname looks function names up in it */
static int call_is_tfor = 0;
static int call_is_tail = 0;   /* set by lua54rt_tailcall for the next call, as call_is_tfor is */
static int host_from_tfor = 0;
static const char *host_name(const char *name) { return host_from_tfor ? "for iterator" : name; }
static void install_more(LV *env);
void lua54rt_install_library(LV *env);

/* Calls a metamethod with nargs values and returns its first result (luaT_callTMres). event is the name of the event
 * without its underscores ("index"), which the traceback gives the frame: "in metamethod 'index'". */
static const char *call_mm_event = NULL;   /* set for the next call, by call_mmv */
static LV call_mmv(const LV *fn, const LV *args, int nargs, const char *event) {
  LV frame[1024], ret[64];
  for (int k = 0; k < nargs; ++k) frame[k] = args[k];
  call_mm_event = event;
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
  const char *where;  /* "source:linedefined", for a traceback's "in function <source:line>" */
  UpVal *upvals[1];   /* nupvals entries; the closure is allocated with room for them */
} LClosure;

static UpVal *open_upvals = NULL;

void lua54rt_closure(LV *dst, void *fn, int numparams, int nupvals, const char *where) {
  size_t size = sizeof(LClosure) + sizeof(UpVal *) * (size_t)(nupvals > 0 ? nupvals - 1 : 0);
  LClosure *c = (LClosure *)gc_alloc(GC_LCL, size);
  if (c == NULL) die("out of memory");
  c->fn = (lua_fn)fn;
  c->numparams = numparams;
  c->nupvals = nupvals;
  c->where = where;
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

/* The call stack: one record per call, with the site of the call (its position in the caller and the variable info of
 * the callee, NULL when the caller is not a Lua function, e.g. pcall), the callee and whether it was a tail call. The top
 * record is the call of the running function, so level 1 (the caller of error) is the top, and level 2 is the record
 * below it. It serves error levels and the traceback of an uncaught error. Records past CALLSTACK_MAX are not kept. */
#define CALLSTACK_MAX 4096
typedef struct CallRec {
  const char *site;
  LV callee;
  int tail;          /* a Lua function entered by a tail call: its caller's frame is gone, as in Lua */
  const char *mm;    /* a metamethod: its event, as "index" */
} CallRec;
static CallRec callrec[CALLSTACK_MAX];
static int call_depth = 0;

static void push_callsite(const char *s, const LV *callee, int tail, const char *mm) {
  if (call_depth < CALLSTACK_MAX) {
    callrec[call_depth].site = s;
    callrec[call_depth].callee = *callee;
    callrec[call_depth].tail = tail;
    callrec[call_depth].mm = mm;
  }
  call_depth++;
}

/* The position of the caller of a call made now: NULL when the caller is a host function, whose calls have no position
 * (as in Lua, where the caller is a C function). */
static const char *caller_site(void) {
  if (call_depth > 0 && call_depth <= CALLSTACK_MAX && callrec[call_depth - 1].callee.tag == TAG_LCF) return NULL;
  return site;
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
  int from_tfor = call_is_tfor;   /* this call is the iterator of a generic 'for' (lua54rt_tforcall) */
  call_is_tfor = 0;
  int from_tail = call_is_tail && fn->tag == TAG_LCL;   /* a Lua function called by a return (lua54rt_tailcall) */
  call_is_tail = 0;
  const char *mm = call_mm_event;   /* a metamethod call (call_mmv) */
  call_mm_event = NULL;
  if (fn->tag == TAG_LCF) {
    LV out[64];
    /* zeroed: the collector scans the C stack, and a stale address left here by an earlier call would keep its object */
    memset(out, 0, sizeof out);
    const char *saved = site;
    HostFn *saved_host = cur_host;
    int saved_tfor = host_from_tfor;
    push_callsite(caller_site(), fn, 0, mm);
    cur_host = (HostFn *)fn->v.p;
    host_from_tfor = from_tfor;
    if (cur_host->fn == host_collectgarbage) scrub_stack();
    int n = cur_host->fn(out, args, nargs);
    host_from_tfor = saved_tfor;
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
    push_callsite(caller_site(), fn, from_tail, mm);
    c->fn(ret, args, c);
    pop_callsite();
    site = saved;
    finish_call(ret, wanted, a);
    return;
  }
  LV h;
  if (!get_mt(fn, "__call", &h)) type_fail("call", fn, 0);
  for (int k = nargs; k > 0; --k) args[k] = args[k - 1];
  args[0] = *fn;
  lua54rt_call(&h, nargs + 1, args, ret, wanted, a);
}

/* TFORCALL: the iterator call of a generic 'for'. */
void lua54rt_tforcall(LV *fn, int nargs, LV *args, LV *ret, int wanted, int a) {
  call_is_tfor = 1;
  lua54rt_call(fn, nargs, args, ret, wanted, a);
}

/* TAILCALL: `return f(...)`. A Lua function called this way replaces the caller's frame. */
void lua54rt_tailcall(LV *fn, int nargs, LV *args, LV *ret, int wanted, int a) {
  call_is_tail = 1;
  lua54rt_call(fn, nargs, args, ret, wanted, a);
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
      *dst = call_mmv(&h, args, 2, ev + 2);
      return;
    }
    if (y.tag != TAG_STR && get_mt(&y, ev, &h)) {
      LV args[2] = {x, y};
      *dst = call_mmv(&h, args, 2, ev + 2);
      return;
    }
    string_arith_fail(ev, &x, &y);
  }
  if (get_mt(&x, ev, &h) || get_mt(&y, ev, &h)) {
    LV args[2] = {x, y};
    *dst = call_mmv(&h, args, 2, ev + 2);
    return;
  }
  if (bitwise) {
    int culprit = is_number(&x) ? 1 : 0;
    type_fail("perform bitwise operation on", culprit ? &y : &x, culprit);
  }
  int culprit = to_number(&x, &nx) ? 1 : 0;   /* luaG_opinterror: the first operand unless it is a number */
  type_fail("perform arithmetic on", culprit ? &y : &x, culprit);
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
      *dst = call_mmv(&h, args, 2, "unm");
      return;
    }
    type_fail("perform arithmetic on", &x, 0);
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
    *dst = call_mmv(&h, args, 2, "bnot");
    return;
  }
  type_fail("perform bitwise operation on", &x, 0);
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
  const char *t1 = objtypename(a), *t2 = objtypename(b);
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
      LV r = call_mmv(&h, args, 2, "eq");
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
    LV r = call_mmv(&h, args, 2, ev + 2);
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
      *dst = call_mmv(&h, args, 2, "len");
      return;
    }
    n = table_border((Table *)x.v.p);
  } else {
    type_fail("get length of", &x, 0);
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
      acc = call_mmv(&h, args, 2, "concat");
      continue;
    }
    /* the culprit: l, unless l is fine; then acc, which is operand i+1 only while it is still the original value */
    if (!l_ok) type_fail("concatenate", &l, i);
    type_fail("concatenate", &acc, i + 1 == n - 1 ? i + 1 : -1);
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
      LV v = raw_get((Table *)obj.v.p, &k);
      if (v.tag != TAG_NIL) {
        *dst = v;
        return;
      }
      if (!get_mt(&obj, "__index", &h)) {
        dst->tag = TAG_NIL;
        return;
      }
    } else if (!get_mt(&obj, "__index", &h)) {
      type_fail("index", &obj, operand);
    }
    if (h.tag == TAG_LCL || h.tag == TAG_LCF) {
      LV args[2] = {obj, k};
      *dst = call_mmv(&h, args, 2, "index");
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
      LV cur = raw_get((Table *)obj.v.p, &k);
      if (cur.tag != TAG_NIL || !get_mt(&obj, "__newindex", &h)) {
        raw_set((Table *)obj.v.p, &k, &v);
        return;
      }
    } else if (!get_mt(&obj, "__newindex", &h)) {
      type_fail("index", &obj, operand);
    }
    if (h.tag == TAG_LCL || h.tag == TAG_LCF) {
      LV args[3] = {obj, k, v};
      call_mmv(&h, args, 3, "newindex");
      return;
    }
    obj = h;
  }
  rt_fail("'__newindex' chain too long; possible loop", -1);
}

/* OP_SETLIST: t[offset + j] := vals[j - 1] for j = 1..count. */
void lua54rt_setlist(LV *t, long offset, LV *vals, int count) {
  if (t->tag != TAG_TABLE) type_fail("index", t, 0);
  Table *h = (Table *)t->v.p;
  /* lvm.c's OP_SETLIST: the array part is made large enough at once, and the values go straight into it */
  uint64_t last = (uint64_t)offset + (uint64_t)count;
  if (last > realasize(h)) table_resize(h, (unsigned int)last, table_isdummy(h) ? 0 : (unsigned int)node_count(h));
  for (int j = 1; j <= count; ++j) h->array[offset + j - 1] = vals[j - 1];
}

/* A closure for the main function of a chunk: upvalue 0 is _ENV, a fresh table; the others are nil. */
static void set_global(LV *env, const char *name, LV *value) {
  LV key = make_str(name, strlen(name));
  raw_set((Table *)env->v.p, &key, value);
}

void *lua54rt_make_main(void *fn, int nupvals) {
  LV cl;
  lua54rt_closure(&cl, fn, 0, nupvals, NULL);
  LClosure *c = (LClosure *)cl.v.p;
  for (int k = 0; k < nupvals; ++k) {
    UpVal *uv = (UpVal *)gc_alloc(GC_UPVAL, sizeof *uv);
    if (uv == NULL) die("out of memory");
    uv->open_next = NULL;
    if (k == 0) lua54rt_newtable(&uv->closed, 0, 0);
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
    case TAG_TABLE: {
      /* luaL_tolstring: the __name of the metatable, when it is a string, in place of "table" */
      LV n;
      if (get_mt(v, "__name", &n) && n.tag == TAG_STR) fprintf(f, "%s: %p", ((LString *)n.v.p)->bytes, v->v.p);
      else fprintf(f, "table: %p", v->v.p);
      break;
    }
    case TAG_LCL:
    case TAG_LCF: fprintf(f, "function: %p", v->v.p); break;
    default: fprintf(f, "?"); break;
  }
}

/* lauxlib.c's luaL_checkany: the argument must be given, whatever its value. */
static void check_any(int nargs, int k, const char *fname) {
  if (nargs < k) arg_fail(k, fname, "value expected");
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
    char buf[300];
    snprintf(buf, sizeof buf, "bad argument #%d to '%s' (table expected, got %s)", k, fname, argtypename(v));
    rt_fail(buf, -1);
  }
  return (Table *)v->v.p;
}

/* luaL_tolstring's __tostring: the string the metamethod returns, when the value has one. */
static int tostring_mm(const LV *v, LV *out) {
  LV h;
  if (!get_mt(v, "__tostring", &h)) return 0;
  LV args[1] = {*v};
  LV r = call_mmv(&h, args, 1, NULL);
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
  check_any(nargs, 1, "type");
  set_string(&out[0], type_name(args[0].tag));
  return 1;
}

static int host_tostring(LV *out, LV *args, int nargs) {
  check_any(nargs, 1, "tostring");
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
  Table *t = expect_table(&args[0], 1, host_name("next"));
  LV key;
  key.tag = TAG_NIL;
  if (nargs >= 2) key = args[1];
  if (!table_next(t, &key, &out[0], &out[1])) {
    out[0].tag = TAG_NIL;
    return 1;
  }
  return 2;
}

/* pairs(v): the __pairs metamethod's three results, or next, v, nil (any value: next reports a bad one). */
static int host_pairs(LV *out, LV *args, int nargs) {
  check_any(nargs, 1, "pairs");
  LV h;
  if (get_mt(&args[0], "__pairs", &h)) {
    LV frame[1024], ret[256];
    frame[0] = args[0];
    lua54rt_call(&h, 1, frame, ret, 3, 0);
    out[0] = ret[0];
    out[1] = ret[1];
    out[2] = ret[2];
    return 3;
  }
  out[0] = next_fn;
  out[1] = args[0];
  out[2].tag = TAG_NIL;
  return 3;
}

static int host_ipairs_iter(LV *out, LV *args, int nargs) {
  (void)nargs;
  if (args[0].tag != TAG_TABLE && args[0].tag != TAG_STR) {
    /* lua_geti in a C function: the error has no position and no variable info */
    char buf[300];
    snprintf(buf, sizeof buf, "attempt to index a %s value", objtypename(&args[0]));
    raise_value(make_str(buf, strlen(buf)));
  }
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
  check_any(nargs, 1, "ipairs");
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

static void gc_check_finalizer(Table *t);

/* lbaselib.c's luaB_setmetatable: a metatable with a __metatable field cannot be changed. */
static int host_setmetatable(LV *out, LV *args, int nargs) {
  Table *t = arg_table(args, nargs, 1, "setmetatable");
  if (nargs < 2 || (args[1].tag != TAG_NIL && args[1].tag != TAG_TABLE))
    lib_arg_error(2, "setmetatable", "nil or table", arg_typename(args, nargs, 2));
  LV protected_field;
  if (get_mt(&args[0], "__metatable", &protected_field)) rt_fail("cannot change a protected metatable", -1);
  t->meta = args[1].tag == TAG_TABLE ? (Table *)args[1].v.p : NULL;
  if (t->meta != NULL) gc_check_finalizer(t);
  out[0] = args[0];
  return 1;
}

/* luaB_getmetatable: the __metatable field when there is one (any value), else the metatable, else nil. */
static int host_getmetatable(LV *out, LV *args, int nargs) {
  check_any(nargs, 1, "getmetatable");
  LV field;
  if (get_mt(&args[0], "__metatable", &field)) {
    out[0] = field;
    return 1;
  }
  Table *mt = NULL;
  if (args[0].tag == TAG_TABLE) mt = ((Table *)args[0].v.p)->meta;
  else if (args[0].tag == TAG_STR) mt = string_meta;
  out[0].tag = TAG_NIL;
  if (mt != NULL) {
    out[0].tag = TAG_TABLE;
    out[0].v.p = mt;
  }
  return 1;
}

void lua54rt_install_library(LV *env) {
  global_env = *env;
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
  first_line(callrec[idx].site, buf, size);
}

/* ---- the traceback of an uncaught error: lua.c's msghandler and luaL_traceback (lauxlib.c) ----
 * The frames are the call records, innermost first: a Lua frame's line is the site of the call it makes (or the current
 * site, for the innermost), a host function is "[C]", and the main chunk is the caller of the first record. A frame whose
 * function made a tail call is gone, as in Lua, and a frame entered by a tail call is followed by "(...tail calls...)". */
static int same_function(const LV *a, const LV *b) { return a->tag == b->tag && a->v.p == b->v.p; }

static int is_library_name(const char *s) {
  static const char *libs[] = {"string", "table", "math", "os", "io", "coroutine", "utf8", "debug", "package"};
  for (size_t k = 0; k < sizeof libs / sizeof libs[0]; ++k)
    if (strcmp(s, libs[k]) == 0) return 1;
  return 0;
}

/* lauxlib.c's pushglobalfuncname: fn as a global ("print") or a field of a library table ("string.rep"). */
static int global_func_name(const LV *fn, char *buf, size_t size) {
  if (global_env.tag != TAG_TABLE) return 0;
  Table *g = (Table *)global_env.v.p;
  LV key, k, v;
  key.tag = TAG_NIL;
  while (table_next(g, &key, &k, &v)) {
    if (k.tag == TAG_STR && same_function(&v, fn)) {
      snprintf(buf, size, "%s", ((LString *)k.v.p)->bytes);
      return 1;
    }
    key = k;
  }
  key.tag = TAG_NIL;
  while (table_next(g, &key, &k, &v)) {
    if (k.tag == TAG_STR && v.tag == TAG_TABLE && is_library_name(((LString *)k.v.p)->bytes)) {
      LV ikey, ik, iv;
      ikey.tag = TAG_NIL;
      while (table_next((Table *)v.v.p, &ikey, &ik, &iv)) {
        if (ik.tag == TAG_STR && same_function(&iv, fn)) {
          snprintf(buf, size, "%s.%s", ((LString *)k.v.p)->bytes, ((LString *)ik.v.p)->bytes);
          return 1;
        }
        ikey = ik;
      }
    }
    key = k;
  }
  return 0;
}

/* The namewhat and name of a call from its site's variable info, " (local 'f')" on the line after the position. */
static int site_callee_name(const char *site, char *kind, size_t kcap, char *name, size_t ncap) {
  if (site == NULL) return 0;
  const char *nl = strchr(site, '\n');
  if (nl == NULL) return 0;
  const char *open = strchr(nl, '(');
  if (open == NULL) return 0;
  open++;
  const char *q = strstr(open, " '");
  if (q == NULL) return 0;
  size_t kl = (size_t)(q - open);
  if (kl >= kcap) return 0;
  memcpy(kind, open, kl);
  kind[kl] = '\0';
  q += 2;
  const char *end = strrchr(q, '\'');
  if (end == NULL || end < q) return 0;
  size_t nl2 = (size_t)(end - q);
  if (nl2 >= ncap) return 0;
  memcpy(name, q, nl2);
  name[nl2] = '\0';
  return 1;
}

/* pushfuncname for the function called by record k. */
static void callee_description(int k, char *buf, size_t size) {
  const CallRec *r = &callrec[k];
  char nm[256], kind[64];
  if (global_func_name(&r->callee, nm, sizeof nm)) {
    snprintf(buf, size, "function '%s'", nm);
  } else if (r->mm != NULL) {
    snprintf(buf, size, "metamethod '%s'", r->mm);
  } else if (!r->tail && site_callee_name(r->site, kind, sizeof kind, nm, sizeof nm)) {
    snprintf(buf, size, "%s '%s'", kind, nm);
  } else if (r->callee.tag == TAG_LCL && ((LClosure *)r->callee.v.p)->where != NULL) {
    snprintf(buf, size, "function <%s>", ((LClosure *)r->callee.v.p)->where);
  } else {
    snprintf(buf, size, "?");
  }
}

/* luaL_traceback(L, L, msg, 1) for the running frames, with lauxlib.c's LEVELS1 and LEVELS2 cut. */
static char *traceback_text(void) {
  int depth = call_depth < CALLSTACK_MAX ? call_depth : CALLSTACK_MAX;
  char **items = (char **)malloc(sizeof(char *) * (size_t)(depth + 2));
  if (items == NULL) die("out of memory");
  int n = 0;
  char line[512], desc[512], item[1100];
  for (int k = depth - 1; k >= 0; --k) {
    if (k + 1 < depth && callrec[k + 1].tail) continue;   /* this frame made a tail call: it is gone */
    if (callrec[k].callee.tag == TAG_LCF) {
      snprintf(line, sizeof line, "[C]:");
    } else {
      const char *cur = k + 1 < depth ? callrec[k + 1].site : site;
      first_line(cur, line, sizeof line);
      if (line[0] == '\0') snprintf(line, sizeof line, "?:");
    }
    callee_description(k, desc, sizeof desc);
    snprintf(item, sizeof item, "\n\t%s in %s%s", line, desc, callrec[k].tail ? "\n\t(...tail calls...)" : "");
    items[n++] = dupstr(item);
  }
  if (!(depth > 0 && callrec[0].tail)) {   /* the main chunk, unless it made the tail call */
    first_line(depth > 0 ? callrec[0].site : site, line, sizeof line);
    if (line[0] == '\0') snprintf(line, sizeof line, "?:");
    snprintf(item, sizeof item, "\n\t%s in main chunk", line);
    items[n++] = dupstr(item);
  }
  items[n++] = dupstr("\n\t[C]: in ?");
  size_t total = 32;
  for (int i = 0; i < n; ++i) total += strlen(items[i]) + 40;
  char *out = (char *)malloc(total);
  if (out == NULL) die("out of memory");
  strcpy(out, "stack traceback:");
  for (int i = 0; i < n; ++i) {
    /* levels 1..n: with more than 22, the first 10 and the last 11 are shown, with the skip count of lauxlib.c */
    if (n > 22 && i == 10) {
      char skip[80];
      snprintf(skip, sizeof skip, "\n\t...\t(skipping %d levels)", n - 22);
      strcat(out, skip);
      i = n - 11 - 1;
      continue;
    }
    strcat(out, items[i]);
  }
  for (int i = 0; i < n; ++i) free(items[i]);
  free(items);
  return out;
}

/* lua.c's msghandler: the message of an uncaught error, with the traceback, except that an error object whose __tostring
 * gives a string is the message by itself. */
static char *uncaught_message(const LV *err) {
  char numbuf[64], other[80];
  const char *text;
  if (err->tag == TAG_STR) {
    text = ((LString *)err->v.p)->bytes;
  } else if (err->tag == TAG_INT || err->tag == TAG_FLOAT) {
    number_text(err, numbuf, sizeof numbuf);
    text = numbuf;
  } else {
    LV h;
    if (get_mt(err, "__tostring", &h)) {
      LV args[1];
      args[0] = *err;
      LV r = call_mmv(&h, args, 1, NULL);
      if (r.tag == TAG_STR) return dupstr(((LString *)r.v.p)->bytes);
    }
    snprintf(other, sizeof other, "(error object is a %s value)", type_name(err->tag));
    text = other;
  }
  char *tb = traceback_text();
  size_t n = strlen(text) + strlen(tb) + 2;
  char *out = (char *)malloc(n);
  if (out == NULL) die("out of memory");
  snprintf(out, n, "%s\n%s", text, tb);
  free(tb);
  return out;
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
  check_any(nargs, 1, "assert");
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
  check_any(nargs, 1, "pcall");
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
  return k > nargs ? "no value" : argtypename(&args[k - 1]);
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
    check_any(nargs, 1, "tonumber");
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
  check_any(nargs, 2, "rawget");
  out[0] = raw_get(t, &args[1]);
  return 1;
}

static int host_rawset(LV *out, LV *args, int nargs) {
  Table *t = arg_table(args, nargs, 1, "rawset");
  check_any(nargs, 3, "rawset");
  raw_set(t, &args[1], &args[2]);
  out[0] = args[0];
  return 1;
}

static int host_rawequal(LV *out, LV *args, int nargs) {
  check_any(nargs, 2, "rawequal");
  out[0].tag = equal_values(&args[0], &args[1]) ? TAG_TRUE : TAG_FALSE;
  return 1;
}

static int host_rawlen(LV *out, LV *args, int nargs) {
  expect_arg(nargs, 1, "rawlen", "table or string");
  out[0].tag = TAG_INT;
  if (args[0].tag == TAG_STR) out[0].v.i = (int64_t)((LString *)args[0].v.p)->len;
  else if (args[0].tag == TAG_TABLE) out[0].v.i = table_border((Table *)args[0].v.p);
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
  check_any(nargs, 1, "tointeger");
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

/* ltablib.c's tpack: lua_createtable(L, n, 1), then t[n] down to t[1] (the array part holds them, nils included). */
static int host_tpack(LV *out, LV *args, int nargs) {
  LV t;
  lua54rt_newtable(&t, 1, (unsigned int)nargs);
  for (int k = nargs - 1; k >= 0; --k) {
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
  int64_t n = table_border((Table *)args[0].v.p);
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
  check_any(nargs, 1, "type");
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
  if (nargs >= 2 && truthy(&args[1])) lua54rt_close_state();   /* os.exit(code, true) closes the state, as lua.c's does */
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
  lua54rt_newtable(&tbl, 0, 0);
  add_fn(&tbl, "insert", host_tinsert);
  add_fn(&tbl, "remove", host_tremove);
  add_fn(&tbl, "concat", host_tconcat);
  add_fn(&tbl, "unpack", host_tunpack);
  add_fn(&tbl, "pack", host_tpack);
  add_fn(&tbl, "move", host_tmove);
  add_fn(&tbl, "sort", host_tsort);
  register_table(env, "table", &tbl);

  LV math;
  lua54rt_newtable(&math, 0, 0);
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
  lua54rt_newtable(&str, 0, 0);
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
  lua54rt_newtable(&os_tbl, 0, 0);
  add_fn(&os_tbl, "clock", host_oclock);
  add_fn(&os_tbl, "time", host_otime);
  add_fn(&os_tbl, "getenv", host_ogetenv);
  add_fn(&os_tbl, "exit", host_oexit);
  register_table(env, "os", &os_tbl);

  LV io_tbl;
  lua54rt_newtable(&io_tbl, 0, 0);
  lua54rt_newtable(&io_stdout, 0, 0);
  add_fn(&io_stdout, "write", host_fwrite);
  add_fn(&io_tbl, "write", host_iowrite);
  key = make_str("stdout", 6);
  raw_set((Table *)io_tbl.v.p, &key, &io_stdout);
  register_table(env, "io", &io_tbl);

  set_global(env, "_G", env);
  LV version = make_str("Lua 5.4", 7);
  set_global(env, "_VERSION", &version);
  LV smt;
  lua54rt_newtable(&smt, 0, 0);
  string_meta = (Table *)smt.v.p;
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

static int gc_busy = 0;      /* a collection is running */
static int gc_in_fin = 0;    /* finalizers are running: no collection, and collectgarbage gives nil (as lbaselib's) */
static int gc_stopped = 0;   /* collectgarbage("stop"): no automatic collection; an explicit one still runs */

/* Allocates an object of kind with size bytes, zeroed. A collection runs first when enough has been allocated. */
static void *gc_alloc(uint8_t kind, size_t size) {
  if (stack_base != NULL && !gc_busy && !gc_in_fin && !gc_stopped && gc_allocated >= gc_threshold) gc_collect();
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

/* ---- weak tables and finalizers (lgc.c). A table whose metatable has __mode is weak: its keys (k), its values (v) or
 * both (kv) are not marked by traverse(). Its ephemeron form (k only) marks a value when its key is alive. After the
 * roots, the atomic phase (gc_collect) clears the weak values, resurrects the objects that have finalizers and
 * clears the weak keys, as lgc.c's atomic does. ---- */
#define WEAK_K 1
#define WEAK_V 2

typedef struct WeakTab {
  Table *t;
  int mode;
} WeakTab;
static WeakTab *weak_tabs = NULL;
static size_t weak_n = 0, weak_cap = 0;

/* fin_objs: the tables marked for finalization (lgc.c's finobj), oldest first. tbf: the objects whose finalizers are due
 * (lgc.c's tobefnz), newest first, from tbf_head. */
static Table **fin_objs = NULL;
static size_t fin_n = 0, fin_cap = 0;
static Table **tbf = NULL;
static size_t tbf_n = 0, tbf_cap = 0, tbf_head = 0;

static int gc_closing = 0;   /* the state is closing: no object gets a finalizer any more (GCSTPCLS) */
/* The Lua stack is a root up to this index. A collectgarbage call marks it up to the end of its arguments: the registers
 * above a call are dead (a call is made into a fresh register), as lgc.c marks up to the top of the running function. */
static size_t gc_root_top = LUA54RT_STACK;

/* Strings with the names the collector looks up, in static memory (no allocation during a collection). */
typedef struct StaticStr {
  GCObj gc;
  size_t len;
  char bytes[8];
} StaticStr;
static StaticStr str_mode_key = {{NULL, 0, 0, 0}, 6, "__mode"};
static StaticStr str_gc_key = {{NULL, 0, 0, 0}, 4, "__gc"};

static LV static_key(StaticStr *s) {
  LV v;
  v.tag = TAG_STR;
  v.v.p = s;
  return v;
}

static int iscollectable(const LV *v) { return v->tag == TAG_TABLE || v->tag == TAG_LCL || v->tag == TAG_LCF; }

/* A string or an object that is not marked yet (a string is always an object here, never cleared). */
static int unmarked_obj(const LV *v) {
  return (v->tag == TAG_STR || iscollectable(v)) && !((GCObj *)v->v.p)->marked;
}

/* lgc.c's iscleared: a string is kept (it is marked); an object is cleared when it is not marked. */
static int iscleared(const LV *v) {
  if (v->tag == TAG_STR) {
    mark_obj(v->v.p);
    return 0;
  }
  if (!iscollectable(v)) return 0;
  return !((GCObj *)v->v.p)->marked;
}

static void set_nil(LV *v) { v->tag = TAG_NIL; }

/* The __mode of t's metatable: WEAK_K and WEAK_V bits, 0 for a strong table. */
static int table_weakmode(Table *t) {
  if (t->meta == NULL) return 0;
  LV key = static_key(&str_mode_key);
  LV v = raw_get(t->meta, &key);
  if (v.tag != TAG_STR) return 0;
  const LString *s = (const LString *)v.v.p;
  int mode = 0;
  if (memchr(s->bytes, 'k', s->len) != NULL) mode |= WEAK_K;
  if (memchr(s->bytes, 'v', s->len) != NULL) mode |= WEAK_V;
  return mode;
}

static void push_weak(Table *t, int mode) {
  if (weak_n == weak_cap) {
    weak_cap = weak_cap == 0 ? 64 : weak_cap * 2;
    weak_tabs = (WeakTab *)realloc(weak_tabs, weak_cap * sizeof(WeakTab));
    if (weak_tabs == NULL) die("out of memory");
  }
  weak_tabs[weak_n].t = t;
  weak_tabs[weak_n].mode = mode;
  weak_n++;
}

static void push_tbf(Table *t) {
  if (tbf_n == tbf_cap) {
    tbf_cap = tbf_cap == 0 ? 16 : tbf_cap * 2;
    tbf = (Table **)realloc(tbf, tbf_cap * sizeof(Table *));
    if (tbf == NULL) die("out of memory");
  }
  tbf[tbf_n++] = t;
}

static void traverse(GCObj *o) {
  switch (o->kind) {
    case GC_TABLE: {
      Table *t = (Table *)o;
      int mode = table_weakmode(t);
      unsigned int asize = realasize(t);
      if (mode != 0) push_weak(t, mode);
      if (!(mode & WEAK_V)) {   /* the array part's keys are integers: its values are strong unless they are weak */
        for (unsigned int i = 0; i < asize; ++i) mark_value(&t->array[i]);
      }
      if (!table_isdummy(t)) {
        for (size_t i = 0; i < node_count(t); ++i) {
          Node *n = &t->node[i];
          if (mode == 0) {
            /* the keys of empty entries are marked too: a key that is freed could be reused and match a lookup */
            if (n->key.tag != TAG_NIL) {
              mark_value(&n->key);
              mark_value(&n->val);
            }
            continue;
          }
          /* an empty entry marks nothing: its key is cleared (clear_weak_keys) */
          if (n->val.tag == TAG_NIL) continue;
          if (!(mode & WEAK_K)) mark_value(&n->key);
          if (!(mode & (WEAK_K | WEAK_V))) mark_value(&n->val);
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

/* An ephemeron key is alive when it is not an object, or it is marked. A string key is alive and marked. */
static int key_alive(const LV *k) {
  if (k->tag == TAG_STR) {
    mark_obj(k->v.p);
    return 1;
  }
  if (!iscollectable(k)) return 1;
  return ((GCObj *)k->v.p)->marked;
}

/* lgc.c's convergeephemerons: a value of a weak-key table is marked when its key is alive, until nothing changes. */
static void converge_ephemerons(void) {
  int changed;
  do {
    changed = 0;
    for (size_t w = 0; w < weak_n; ++w) {   /* weak_n may grow as propagate finds more tables */
      if (weak_tabs[w].mode != WEAK_K) continue;
      Table *t = weak_tabs[w].t;
      if (table_isdummy(t)) continue;
      for (size_t i = 0; i < node_count(t); ++i) {
        Node *n = &t->node[i];
        if (n->val.tag == TAG_NIL || !key_alive(&n->key)) continue;
        if (unmarked_obj(&n->val)) {
          mark_value(&n->val);
          propagate();
          changed = 1;
        }
      }
    }
  } while (changed);
}

/* Weak values are cleared: an array or hash value that is not marked goes (a string is kept). */
static void clear_weak_values(void) {
  for (size_t w = 0; w < weak_n; ++w) {
    if (!(weak_tabs[w].mode & WEAK_V)) continue;
    Table *t = weak_tabs[w].t;
    unsigned int asize = realasize(t);
    for (unsigned int i = 0; i < asize; ++i) {
      if (iscleared(&t->array[i])) set_nil(&t->array[i]);
    }
    if (table_isdummy(t)) continue;
    for (size_t i = 0; i < node_count(t); ++i) {
      Node *n = &t->node[i];
      if (n->val.tag != TAG_NIL && iscleared(&n->val)) set_nil(&n->val);
    }
  }
}

/* Weak keys are cleared: an entry whose key is not marked goes, and its key becomes dead (it matches no key again). A
 * string key with a value is kept; a string key without one is dead when it is not marked. */
static void clear_weak_keys(void) {
  for (size_t w = 0; w < weak_n; ++w) {
    Table *t = weak_tabs[w].t;
    if (table_isdummy(t)) continue;
    for (size_t i = 0; i < node_count(t); ++i) {
      Node *n = &t->node[i];
      if (n->key.tag == TAG_NIL || n->key.tag == TAG_DEADKEY) continue;
      if (n->key.tag == TAG_STR && n->val.tag != TAG_NIL) mark_obj(n->key.v.p);
      if (unmarked_obj(&n->key)) {
        set_nil(&n->val);
        n->key.tag = TAG_DEADKEY;
      }
    }
  }
}

/* lgc.c's separatetobefnz: the unmarked objects with finalizers are due, newest first; the marked ones stay in fin_objs. */
static void separate_tobefnz(void) {
  for (size_t i = fin_n; i-- > 0;) {
    if (!fin_objs[i]->gc.marked) push_tbf(fin_objs[i]);
  }
  size_t keep = 0;
  for (size_t i = 0; i < fin_n; ++i) {
    if (fin_objs[i]->gc.marked) fin_objs[keep++] = fin_objs[i];
  }
  fin_n = keep;
}

/* lbaselib's setmetatable and lgc.c's luaC_checkfinalizer: a table whose new metatable has a __gc field is marked for
 * finalization, once. A table marked by an earlier metatable keeps its mark. */
static void gc_check_finalizer(Table *t) {
  if (t->tofin || gc_closing || t->meta == NULL) return;
  LV key = static_key(&str_gc_key);
  if (raw_get(t->meta, &key).tag == TAG_NIL) return;
  t->tofin = 1;
  if (fin_n == fin_cap) {
    fin_cap = fin_cap == 0 ? 16 : fin_cap * 2;
    fin_objs = (Table **)realloc(fin_objs, fin_cap * sizeof(Table *));
    if (fin_objs == NULL) die("out of memory");
  }
  fin_objs[fin_n++] = t;
}

/* Zeroes the stack below the caller's frame. Called just before collectgarbage, so that the frames of the collection are
 * made on zeroed memory: an uninitialized slot of such a frame would otherwise hold the address of an object that an
 * earlier call (setmetatable, say) left there, and the conservative scan would keep the object alive. */
static void __attribute__((noinline)) scrub_stack(void) {
  volatile unsigned char buf[32768];
  for (size_t i = 0; i < sizeof buf; ++i) buf[i] = 0;
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
    case GC_TABLE: {
      Table *t = (Table *)o;
      free(t->array);
      if (!table_isdummy(t)) free(t->node);
      break;
    }
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

/* lgc.c's atomic phase, after the roots: weak values, then the objects with finalizers are resurrected (they are due),
 * then the weak keys are cleared, so a key of a resurrected object stays until the next collection. */
static void gc_collect(void) {
  if (stack_base == NULL || gc_busy || gc_in_fin) return;
  gc_busy = 1;
  gray_n = 0;
  weak_n = 0;
  for (size_t i = 0; i < gc_root_top; ++i) mark_value(&lua_stack[i]);
  scan_c_stack();
  for (UpVal *u = open_upvals; u != NULL; u = u->open_next) mark_obj(u);
  mark_obj(string_meta);
  mark_value(&next_fn);
  mark_value(&ipairs_iter_fn);
  mark_obj(running_main);
  for (size_t i = tbf_head; i < tbf_n; ++i) mark_obj(tbf[i]);
  propagate();
  converge_ephemerons();
  clear_weak_values();
  separate_tobefnz();
  for (size_t i = tbf_head; i < tbf_n; ++i) mark_obj(tbf[i]);
  propagate();
  converge_ephemerons();
  clear_weak_values();
  clear_weak_keys();
  sweep();
  gc_threshold = gc_live * 2 > gc_min_threshold ? gc_live * 2 : gc_min_threshold;
  gc_allocated = 0;
  gc_busy = 0;
}

/* The finalizer of t, called as lgc.c's GCTM does: with t as its argument, and an error in it is dropped (a warning in
 * Lua, which lua.c leaves off). The call is protected like a pcall. */
static void call_finalizer(Table *t) {
  LV obj, fn;
  LV frame[1024], ret[64];
  PCall p;
  if (t->meta == NULL) return;
  LV key = static_key(&str_gc_key);
  fn = raw_get(t->meta, &key);
  if (fn.tag == TAG_NIL) return;
  obj.tag = TAG_TABLE;
  obj.v.p = t;
  const char *saved_site = site;
  int saved_depth = call_depth;
  p.prev = pcall_top;
  p.base = frame;
  pcall_top = &p;
  if (setjmp(p.jb) == 0) {
    frame[0] = obj;
    lua54rt_call(&fn, 1, frame, ret, 0, 0);
    pcall_top = p.prev;
    site = saved_site;
  } else {
    site = saved_site;
    call_depth = saved_depth;
    pcall_top = p.prev;
    close_to(p.base, &p.err);
  }
}

/* GCTM for each due object, newest first. The object is normal again once it is taken (lgc.c's udata2finalize), so a
 * finalizer may give it a finalizer again. */
static void run_finalizers(void) {
  if (gc_in_fin) return;
  gc_in_fin = 1;
  while (tbf_head < tbf_n) {
    Table *t = tbf[tbf_head++];
    t->tofin = 0;
    call_finalizer(t);
  }
  tbf_head = tbf_n = 0;
  gc_in_fin = 0;
}

/* lua_close (luaC_freeallobjects): every object with a finalizer is due, newest first, after the ones already due; no
 * object gets a finalizer from now on. */
void lua54rt_close_state(void) {
  if (stack_base == NULL) return;
  gc_closing = 1;
  for (size_t i = fin_n; i-- > 0;) push_tbf(fin_objs[i]);
  fin_n = 0;
  run_finalizers();
}

/* The index of the Lua stack at the end of a call's arguments (the top of the registers that are live), or the whole
 * stack when the arguments are not on it (a call from a metamethod or a library function). */
static size_t lua_top_index(const LV *args, int nargs) {
  uintptr_t lo = (uintptr_t)lua_stack, hi = (uintptr_t)(lua_stack + LUA54RT_STACK), a = (uintptr_t)args;
  if (a < lo || a >= hi) return LUA54RT_STACK;
  size_t top = (size_t)(args - lua_stack) + (size_t)nargs;
  return top < LUA54RT_STACK ? top : LUA54RT_STACK;
}

/* collectgarbage(opt): "collect" (the default), "step", "count" (in KB), "isrunning", "stop", "restart". A collection
 * calls the finalizers that are due after it, as Lua's full collection does. */
static int host_collectgarbage(LV *out, LV *args, int nargs) {
  const char *opt = "collect";
  if (nargs >= 1 && args[0].tag != TAG_NIL) {
    if (args[0].tag != TAG_STR) lib_arg_error(1, "collectgarbage", "string", arg_typename(args, nargs, 1));
    opt = ((LString *)args[0].v.p)->bytes;
  }
  int known = strcmp(opt, "collect") == 0 || strcmp(opt, "step") == 0 || strcmp(opt, "count") == 0 ||
              strcmp(opt, "isrunning") == 0 || strcmp(opt, "stop") == 0 || strcmp(opt, "restart") == 0;
  if (known && gc_in_fin) {   /* inside a finalizer lua_gc gives -1, and lbaselib pushes a fail */
    out[0].tag = TAG_NIL;
    return 1;
  }
  if (strcmp(opt, "collect") == 0 || strcmp(opt, "step") == 0) {
    gc_root_top = lua_top_index(args, nargs);
    gc_collect();
    gc_root_top = LUA54RT_STACK;
    run_finalizers();
    if (opt[0] == 's') {
      out[0].tag = TAG_TRUE;
    } else {
      out[0].tag = TAG_INT;
      out[0].v.i = 0;
    }
    return 1;
  }
  if (strcmp(opt, "count") == 0) {
    out[0].tag = TAG_FLOAT;
    out[0].v.n = (double)(gc_live + gc_allocated) / 1024.0;
    return 1;
  }
  if (strcmp(opt, "isrunning") == 0) {
    out[0].tag = gc_stopped ? TAG_FALSE : TAG_TRUE;
    return 1;
  }
  if (strcmp(opt, "stop") == 0 || strcmp(opt, "restart") == 0) {
    gc_stopped = opt[0] == 's';
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
