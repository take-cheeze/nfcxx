/* The runtime helpers that lowered Lua 5.4 IR calls (docs/notes/lua54-pathb.md, "Runtime helpers").
 * Numbers only: arithmetic, bitwise, unary and numeric for loops, with lvm.c's rules (luaV_idiv, luaV_mod, luaV_modf,
 * luaV_shiftl, forprep, forlimit, floatforloop). Strings, tables, calls and metamethods are not here yet; a non-number
 * operand stops the program. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct LV {
  uint8_t tag;
  uint8_t pad[7];
  union {
    int64_t i;
    double n;
    void *p;
  } v;
} LV;

enum { TAG_NIL = 0x00, TAG_INT = 0x03, TAG_FLOAT = 0x13, TAG_LCL = 0x06 };
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

/* A Lua function value made from a lowered prototype. A function with upvalues is not lowered yet, so there are none. */
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

/* OP_CALL with one result: the callee's base is args, its result goes to ret. Missing parameters are nil. */
void lua54rt_call(LV *fn, int nargs, LV *args, LV *ret) {
  if (fn->tag != TAG_LCL) die("attempt to call a value that is not a lowered function");
  LClosure *c = (LClosure *)fn->v.p;
  for (int k = nargs; k < c->numparams; ++k) args[k].tag = TAG_NIL;
  c->fn(ret, args, c);
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

/* kind 0: a < b, 1: a <= b, 2: a == b */
int lua54rt_cmp(int kind, LV *a, LV *b) {
  if (!is_number(a) || !is_number(b)) die("comparison of a non-number");
  if (a->tag == TAG_INT && b->tag == TAG_INT) {
    if (kind == 0) return a->v.i < b->v.i;
    if (kind == 1) return a->v.i <= b->v.i;
    return a->v.i == b->v.i;
  }
  double x = as_float(a), y = as_float(b);
  if (kind == 0) return x < y;
  if (kind == 1) return x <= y;
  return x == y;
}
