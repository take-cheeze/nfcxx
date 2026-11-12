/* ptxi: a CPU interpreter for the PTX subset that tools/pathb-ptx-emit emits.
 *
 * Usage: ptxi FILE.ptx KERNEL [--grid X[,Y[,Z]]] [--block X[,Y[,Z]]] ARG... [--dump K]...
 *                             [--random N [--seed S]] [--explore [--max-schedules M]] [--max-steps S]
 *   ARG is one kernel parameter, in order:
 *     ptr:COUNT[:iota=START]   a global buffer of COUNT int32 (zeroed, or START+i in element i)
 *     s32:VALUE                a 32-bit scalar
 *     bytes:HEX                a byte array parameter (.param .align A .b8 NAME[N]), given as N bytes of hex; every
 *                              thread gets its own copy
 *   --dump K                   print argument K (a ptr) as COUNT lines of int32 values
 *
 * Scheduling. Each thread is a resumable state machine (pc, registers, call stack). The instructions that
 * touch shared state (global or generic ld/st, atom, red, bar.sync) are the scheduling points; the others
 * are thread-local and run without a choice. Three modes choose which poised thread steps next:
 *   default      the lowest-numbered poised thread, so each thread runs until it blocks or exits (the order the
 *                emitter's tests were written against); prints the buffers named by --dump, as before.
 *   --random N   N runs, each choosing uniformly among the poised threads (seeded by --seed, default 1).
 *   --explore    every schedule, by depth-first search with replay (stateless model checking). It stops with
 *                exit 5 if more than --max-schedules (default 100000) complete schedules exist.
 * The last two print one line per distinct outcome: "outcome COUNT: VALUES", where VALUES are the --dump
 * buffers in order, separated by " | ", and then "schedules N (exhaustive)" or "(random)".
 * The interleavings are sequentially consistent: a load returns the latest store in the schedule. That is
 * stronger than the PTX memory model, which also allows other outcomes; a kernel that passes here may still
 * fail on hardware. Relaxed, acquire and release qualifiers are accepted and change nothing.
 *
 * Synchronization. atom.global.{add,exch} and red.global.add are one indivisible step. bar.sync ID (ID 0..15,
 * full block only, no count) waits until every live thread of the block has arrived at the same ID; a thread
 * that has exited no longer counts. A schedule in which every live thread waits and none can be released is a
 * deadlock (exit 4).
 *
 * Memory is one flat arena: the buffers from ARENA_BASE up, then one local frame per thread. An access of n bytes
 * must lie inside one buffer or inside the accessing thread's own frame; anything else is a fault, so a missing
 * bounds check shows up as an error or as a write into a guard buffer, not as silent corruption. Shared memory is
 * refused.
 *
 * Accepted: .version, .target, .address_size (ignored), .visible .entry and .func with .param, call (of a
 * .func of the module, no recursion), st.param (call arguments), .reg (ignored:
 * registers are created on first use), .local, labels, ld (param, generic, global, local), st,
 * byte-array parameters (.param .align A .b8 NAME[N], in a function's header, a call's block, or a result
 * "(.param .align A .b8 func_retval0[N])": their bytes live in the thread's frame, ld.param and st.param of
 * [NAME+OFF] move them, and call copies them by value, as nvcc's struct parameters),
 * mov, cvta, add, sub, mul.lo / mul.wide, mad.lo, shl, and, or, setp, bra, ret, predicates
 * (@%p, @!%p), atom, red, bar.sync, and the special registers %tid, %ntid, %ctaid, %nctaid (x, y, z).
 *
 * Exit: 0 ran, 2 usage or malformed input, 3 unsupported PTX (refused before running), 4 memory fault, deadlock,
 * or step limit, 5 exploration incomplete (--max-schedules reached).
 * Limits: 8192 instructions, 1024 registers, 64 parameters, 64 local symbols, 1024 labels, 32 functions,
 * 4096 threads, 256 distinct outcomes.
 * Only the kernel and the functions it reaches are parsed, so an unreached .func is not checked.
 */
#include <ctype.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ARENA_BASE 0x1000ULL
#define EXIT_BAD 2
#define EXIT_UNSUPPORTED 3
#define EXIT_FAULT 4

#define MAXINST 8192
#define MAXREG 1024
#define MAXPARAM 256
#define MAXLOCAL 64
#define MAXLABEL 1024
#define MAXNAME 64
#define MAXTEXT 96
#define MAXFUNC 32
#define MAXFPARAM 8

static void fail(int code, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "ptxi: ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
  exit(code);
}

/* ---- types: s8..s64, u8..u64, b8..b64 ---- */

typedef struct {
  int bits; /* 0: no type */
  int sign;
} Ty;

static int parse_ty(const char *s, Ty *t) {
  const char *d = s + 1;
  if (s[0] != 's' && s[0] != 'u' && s[0] != 'b') return 0;
  if (!*d) return 0;
  for (const char *p = d; *p; p++)
    if (!isdigit((unsigned char)*p)) return 0;
  int bits = atoi(d);
  if (bits != 8 && bits != 16 && bits != 32 && bits != 64) return 0;
  t->bits = bits;
  t->sign = s[0] == 's';
  return 1;
}

/* Sign- or zero-extend the low t.bits bits of v to 64 bits: the canonical register value. */
static uint64_t canon(Ty t, uint64_t v) {
  if (t.bits == 64) return v;
  uint64_t mask = (1ULL << t.bits) - 1;
  v &= mask;
  if (t.sign && ((v >> (t.bits - 1)) & 1)) v |= ~mask;
  return v;
}

/* ---- operands and instructions ---- */

enum { K_NONE, K_REG, K_IMM, K_SPECIAL, K_SYM, K_MEM, K_PARAM, K_PARR };
enum {
  SP_TIDX, SP_TIDY, SP_TIDZ, SP_NTIDX, SP_NTIDY, SP_NTIDZ,
  SP_CTAIDX, SP_CTAIDY, SP_CTAIDZ, SP_NCTAIDX, SP_NCTAIDY, SP_NCTAIDZ
};
enum {
  OP_LD, OP_ST, OP_MOV, OP_CVTA, OP_ADD, OP_SUB, OP_MUL, OP_MAD,
  OP_SHL, OP_SHR, OP_AND, OP_OR, OP_SETP, OP_BRA, OP_RET, OP_CALL, OP_CVT,
  OP_ATOM, OP_RED, OP_BAR
};
enum { AOP_NONE, AOP_ADD, AOP_EXCH };
enum { SPACE_NONE, SPACE_PARAM, SPACE_GLOBAL, SPACE_LOCAL };
enum { CMP_NONE, CMP_EQ, CMP_NE, CMP_LT, CMP_LE, CMP_GT, CMP_GE };

typedef struct {
  int kind;
  int idx;     /* register, special, local symbol, parameter; for K_MEM the base register */
  int64_t imm; /* immediate; for K_MEM the byte offset */
} Operand;

typedef struct {
  int op;
  Ty ty;
  int space;
  int cmp;
  int wide;
  int pred; /* predicate register, -1 if none */
  int pred_neg;
  Operand a[4];
  int n;
  int target; /* bra: instruction index */
  int callee; /* call: index into funcs, -1 until resolved */
  int ret;    /* call: register that receives the result, -1 for none */
  int nargs;  /* call: number of arguments */
  int argp[4]; /* call: parameter index of each argument */
  int ret_param; /* call: the array parameter that receives the result, -1 for none */
  Ty src;        /* cvt: the source type (ty is the destination type) */
  int aop;       /* atom, red: AOP_ADD or AOP_EXCH */
  char label[MAXNAME];
  char text[MAXTEXT];
} Inst;

typedef struct {
  char name[MAXNAME];
  Ty ty;
  int is_array;   /* a byte array (.b8 NAME[N]): its bytes are in the thread's frame at off */
  uint64_t size;  /* the array's size in bytes */
  uint64_t off;   /* the array's offset in the thread's frame */
} Param;

typedef struct {
  char name[MAXNAME];
  uint64_t off;
  uint64_t size;
} LocalSym;

typedef struct {
  char name[MAXNAME];
  int index;
} Label;

static Inst insts[MAXINST];
static int ninst;
static char regs[MAXREG][MAXNAME];
static int nregs;
static Param params[MAXPARAM];
static int nparams;
static LocalSym locals[MAXLOCAL];
static int nlocals;
static Label labels[MAXLABEL];
static int nlabels;
static uint64_t frame_bytes; /* per-thread local bytes used by the .local declarations */

/* A .entry or .func. Its instructions are [start, end); its parameters are params[param[k]]. */
typedef struct {
  char name[MAXNAME];
  int is_entry;
  int start, end;
  int rv;     /* register holding the result of a .func, -1 for none */
  int rv_param; /* the array parameter holding the result of a .func (func_retval0[N]), -1 for none */
  int nparam;
  int param[MAXFPARAM];
} Func;
static Func funcs[MAXFUNC];
static int nfuncs;
/* The function being parsed, "name/": registers, labels and parameters are scoped by it, so the same
 * names in two functions (%r1, $L0, $call1_p0) are different objects. */
static char scope[MAXNAME];

static void scoped(char *out, size_t n, const char *name) {
  if (snprintf(out, n, "%s%s", scope, name) >= (int)n) fail(EXIT_UNSUPPORTED, "name too long: %s", name);
}

static int reg_index(const char *name) {
  char key[MAXNAME];
  scoped(key, sizeof key, name);
  for (int i = 0; i < nregs; i++)
    if (!strcmp(regs[i], key)) return i;
  if (nregs == MAXREG) fail(EXIT_UNSUPPORTED, "too many registers");
  snprintf(regs[nregs], MAXNAME, "%s", key);
  return nregs++;
}

static int special_index(const char *name) {
  static const char *names[] = {
    "%tid.x", "%tid.y", "%tid.z", "%ntid.x", "%ntid.y", "%ntid.z",
    "%ctaid.x", "%ctaid.y", "%ctaid.z", "%nctaid.x", "%nctaid.y", "%nctaid.z"};
  for (int i = 0; i < 12; i++)
    if (!strcmp(names[i], name)) return i;
  return -1;
}

static int param_index(const char *name) {
  for (int i = 0; i < nparams; i++)
    if (!strcmp(params[i].name, name)) return i;
  return -1;
}

static int local_index(const char *name) {
  for (int i = 0; i < nlocals; i++)
    if (!strcmp(locals[i].name, name)) return i;
  return -1;
}

static Operand parse_operand(const char *tok) {
  Operand o = {K_NONE, 0, 0};
  if (tok[0] == '[') {
    size_t n = strcspn(tok + 1, "]");
    if (tok[1 + n] != ']') fail(EXIT_BAD, "unclosed memory operand '%s'", tok);
    char inner[MAXNAME];
    if (n >= sizeof inner) fail(EXIT_BAD, "memory operand too long '%s'", tok);
    memcpy(inner, tok + 1, n);
    inner[n] = 0;
    if (inner[0] == '%') {
      char *plus = strchr(inner, '+');
      if (plus) {
        *plus = 0;
        o.imm = strtoll(plus + 1, NULL, 0);
      }
      o.kind = K_MEM;
      o.idx = reg_index(inner);
    } else {
      /* [NAME] or [NAME+OFF]: a scalar parameter, or an offset in a byte array parameter */
      int64_t off = 0;
      char *plus = strchr(inner, '+');
      if (plus) {
        *plus = 0;
        off = strtoll(plus + 1, NULL, 0);
      }
      char key[MAXNAME];
      scoped(key, sizeof key, inner);
      int p = param_index(key);
      if (p < 0) fail(EXIT_BAD, "unknown parameter in '%s'", tok);
      if (params[p].is_array) {
        if (off < 0 || (uint64_t)off > params[p].size) fail(EXIT_BAD, "offset past the parameter in '%s'", tok);
        o.kind = K_PARR;
        o.idx = p;
        o.imm = off;
      } else {
        if (off != 0) fail(EXIT_UNSUPPORTED, "offset into a scalar parameter in '%s'", tok);
        o.kind = K_PARAM;
        o.idx = p;
      }
    }
    return o;
  }
  if (tok[0] == '%') {
    int sp = special_index(tok);
    if (sp >= 0) {
      o.kind = K_SPECIAL;
      o.idx = sp;
    } else {
      o.kind = K_REG;
      o.idx = reg_index(tok);
    }
    return o;
  }
  if (isdigit((unsigned char)tok[0]) || tok[0] == '-') {
    o.kind = K_IMM;
    o.imm = strtoll(tok, NULL, 0);
    return o;
  }
  int s = local_index(tok);
  if (s < 0) fail(EXIT_BAD, "unknown symbol '%s'", tok);
  o.kind = K_SYM;
  o.idx = s;
  return o;
}

/* ---- parsing ---- */

static char *trim(char *s) {
  while (isspace((unsigned char)*s)) s++;
  char *e = s + strlen(s);
  while (e > s && isspace((unsigned char)e[-1])) *--e = 0;
  return s;
}

/* Split on whitespace and commas, in place. */
static int split_tokens(char *s, char **tok, int max) {
  int n = 0;
  for (char *p = s; *p;) {
    while (*p && (isspace((unsigned char)*p) || *p == ',')) p++;
    if (!*p) break;
    if (n == max) fail(EXIT_BAD, "too many tokens");
    tok[n++] = p;
    while (*p && !isspace((unsigned char)*p) && *p != ',') p++;
    if (*p) *p++ = 0;
  }
  return n;
}

/* Split a dotted opcode such as "ld.param.s32" into its parts, in place. */
static int split_dots(char *s, char **parts, int max) {
  int n = 0;
  char *p = s;
  for (;;) {
    if (n == max) fail(EXIT_BAD, "too many modifiers");
    parts[n++] = p;
    char *dot = strchr(p, '.');
    if (!dot) break;
    *dot = 0;
    p = dot + 1;
  }
  return n;
}

static int cmp_index(const char *m) {
  static const char *names[] = {"eq", "ne", "lt", "le", "gt", "ge"};
  for (int i = 0; i < 6; i++)
    if (!strcmp(m, names[i])) return i + 1;
  return CMP_NONE;
}

static void add_label(const char *name) {
  char key[MAXNAME];
  scoped(key, sizeof key, name);
  if (nlabels == MAXLABEL) fail(EXIT_UNSUPPORTED, "too many labels");
  for (int i = 0; i < nlabels; i++)
    if (!strcmp(labels[i].name, key)) fail(EXIT_BAD, "duplicate label '%s'", name);
  snprintf(labels[nlabels].name, MAXNAME, "%s", key);
  labels[nlabels].index = ninst;
  nlabels++;
}

static void parse_local(char *s) {
  char *tok[8];
  char buf[MAXTEXT * 2];
  snprintf(buf, sizeof buf, "%s", s);
  int nt = split_tokens(buf, tok, 8);
  uint64_t align = 1;
  char *decl = NULL;
  for (int i = 1; i < nt; i++) {
    if (!strcmp(tok[i], ".align") && i + 1 < nt) align = strtoull(tok[++i], NULL, 0);
    else if (strchr(tok[i], '[')) decl = tok[i];
  }
  if (!decl) fail(EXIT_UNSUPPORTED, "unsupported .local declaration: %s", s);
  if (nlocals == MAXLOCAL) fail(EXIT_UNSUPPORTED, "too many local symbols");
  char *br = strchr(decl, '[');
  *br = 0;
  LocalSym *ls = &locals[nlocals++];
  snprintf(ls->name, MAXNAME, "%s", decl);
  ls->size = strtoull(br + 1, NULL, 0);
  if (align == 0) align = 1;
  ls->off = (frame_bytes + align - 1) / align * align;
  frame_bytes = ls->off + ls->size;
}

static void add_inst(char *stmt) {
  Inst in;
  memset(&in, 0, sizeof in);
  in.pred = -1;
  snprintf(in.text, sizeof in.text, "%s", stmt);
  char buf[MAXTEXT * 2];
  snprintf(buf, sizeof buf, "%s", stmt);
  char *tok[16];
  int nt = split_tokens(buf, tok, 16);
  int i = 0;
  if (nt == 0) return;
  if (tok[0][0] == '@') {
    char *r = tok[0] + 1;
    if (*r == '!') {
      in.pred_neg = 1;
      r++;
    }
    if (*r != '%') fail(EXIT_BAD, "bad predicate in '%s'", stmt);
    in.pred = reg_index(r);
    i = 1;
  }
  if (i >= nt) fail(EXIT_BAD, "no opcode in '%s'", stmt);

  char opbuf[64];
  snprintf(opbuf, sizeof opbuf, "%s", tok[i++]);
  char *parts[8];
  int np = split_dots(opbuf, parts, 8);
  const char *op = parts[0];
  if (!strcmp(op, "call")) {
    /* call (%rv), NAME, (ARG, ...): the result register is optional; each argument is a parameter. */
    in.op = OP_CALL;
    in.callee = -1;
    in.ret = -1;
    in.ret_param = -1;
    if (nt - i < 1) fail(EXIT_BAD, "call needs a function name: '%s'", stmt);
    if (tok[i][0] == '(') {
      size_t l = strlen(tok[i]);
      if (l < 3 || tok[i][l - 1] != ')') fail(EXIT_BAD, "bad call result: '%s'", stmt);
      tok[i][l - 1] = 0;
      char rkey[MAXNAME];
      scoped(rkey, sizeof rkey, tok[i] + 1);
      int rp = param_index(rkey);
      if (rp >= 0 && params[rp].is_array) in.ret_param = rp;
      else in.ret = reg_index(tok[i] + 1);
      i++;
    }
    if (nt - i < 1) fail(EXIT_BAD, "call needs a function name: '%s'", stmt);
    snprintf(in.label, sizeof in.label, "%s", tok[i++]);
    /* the argument list: (A, B, ...), split at the commas, so the first token has the '(' and the last the ')' */
    for (; i < nt; i++) {
      char *a = tok[i];
      if (a[0] == '(') a++;
      size_t l = strlen(a);
      if (l && a[l - 1] == ')') a[--l] = 0;
      if (!l) continue;
      if (in.nargs == 4) fail(EXIT_UNSUPPORTED, "call with more than 4 arguments: '%s'", stmt);
      char key[MAXNAME];
      scoped(key, sizeof key, a);
      int p = param_index(key);
      if (p < 0) fail(EXIT_BAD, "unknown call argument '%s'", a);
      in.argp[in.nargs++] = p;
    }
    if (ninst == MAXINST) fail(EXIT_UNSUPPORTED, "too many instructions");
    insts[ninst++] = in;
    return;
  }
  static const char *known[] = {"ld", "st", "mov", "cvta", "add", "sub", "mul", "mad",
                                "shl", "shr", "and", "or", "setp", "bra", "ret", "cvt", "atom", "red", "bar"};
  int is_known = 0;
  for (int k = 0; k < (int)(sizeof known / sizeof known[0]); k++)
    if (!strcmp(op, known[k])) is_known = 1;
  if (!is_known) fail(EXIT_UNSUPPORTED, "unsupported instruction '%s'", stmt);
  int have_ty = 0;
  for (int k = 1; k < np; k++) {
    const char *m = parts[k];
    Ty t;
    if (!strcmp(m, "param")) in.space = SPACE_PARAM;
    else if (!strcmp(m, "global")) in.space = SPACE_GLOBAL;
    else if (!strcmp(m, "local")) in.space = SPACE_LOCAL;
    else if (!strcmp(m, "lo")) ;
    else if (!strcmp(m, "wide")) in.wide = 1;
    else if (!strcmp(op, "cvta") && !strcmp(m, "to")) ;
    else if (!strcmp(m, "add")) in.aop = AOP_ADD;   /* atom.add, red.add */
    else if (!strcmp(m, "exch")) in.aop = AOP_EXCH; /* atom.exch */
    else if (!strcmp(m, "sync")) ;                  /* bar.sync */
    else if (!strcmp(m, "relaxed") || !strcmp(m, "acquire") || !strcmp(m, "release") || !strcmp(m, "acq_rel") ||
             !strcmp(m, "gpu") || !strcmp(m, "cta") || !strcmp(m, "sys")) ; /* memory semantics: SC here, no effect */
    else if (cmp_index(m)) in.cmp = cmp_index(m);
    else if (parse_ty(m, &t)) {
      in.ty = t;
      have_ty = 1;
    } else fail(EXIT_UNSUPPORTED, "unsupported modifier '.%s' in '%s'", m, stmt);
  }

  int want = -1;
  if (!strcmp(op, "ld")) {
    in.op = OP_LD;
    want = 2;
  } else if (!strcmp(op, "st")) {
    in.op = OP_ST;
    want = 2;
  } else if (!strcmp(op, "mov")) {
    in.op = OP_MOV;
    want = 2;
  } else if (!strcmp(op, "cvta")) {
    in.op = OP_CVTA;
    want = 2;
  } else if (!strcmp(op, "add")) {
    in.op = OP_ADD;
    want = 3;
  } else if (!strcmp(op, "sub")) {
    in.op = OP_SUB;
    want = 3;
  } else if (!strcmp(op, "mul")) {
    in.op = OP_MUL;
    want = 3;
    if (in.wide && in.ty.bits != 32) fail(EXIT_UNSUPPORTED, "mul.wide is only for 32-bit types: '%s'", stmt);
    if (!in.wide && !strstr(stmt, "mul.lo")) fail(EXIT_UNSUPPORTED, "mul needs .lo or .wide: '%s'", stmt);
  } else if (!strcmp(op, "mad")) {
    in.op = OP_MAD;
    want = 4;
    if (!strstr(stmt, "mad.lo")) fail(EXIT_UNSUPPORTED, "mad needs .lo: '%s'", stmt);
  } else if (!strcmp(op, "shl")) {
    in.op = OP_SHL;
    want = 3;
  } else if (!strcmp(op, "shr")) {
    in.op = OP_SHR;
    want = 3;
  } else if (!strcmp(op, "cvt")) {
    /* integer to integer only: cvt.DST.SRC (the value is canonical for DST); no floating point */
    in.op = OP_CVT;
    want = 2;
    if (np != 3 || !parse_ty(parts[1], &in.ty) || !parse_ty(parts[2], &in.src) || in.ty.bits == 0 || in.src.bits == 0)
      fail(EXIT_UNSUPPORTED, "unsupported conversion '%s'", stmt);
    have_ty = 1;
  } else if (!strcmp(op, "and")) {
    in.op = OP_AND;
    want = 3;
  } else if (!strcmp(op, "or")) {
    in.op = OP_OR;
    want = 3;
  } else if (!strcmp(op, "setp")) {
    in.op = OP_SETP;
    want = 3;
    if (!in.cmp) fail(EXIT_BAD, "setp without a comparison: '%s'", stmt);
  } else if (!strcmp(op, "bra")) {
    in.op = OP_BRA;
    want = 1; /* the label, not an operand */
  } else if (!strcmp(op, "ret")) {
    in.op = OP_RET;
    want = 0;
  } else if (!strcmp(op, "atom") || !strcmp(op, "red")) {
    in.op = op[0] == 'a' ? OP_ATOM : OP_RED;
    want = in.op == OP_ATOM ? 3 : 2;
    if (in.aop == AOP_NONE) fail(EXIT_UNSUPPORTED, "unsupported atomic operation: '%s'", stmt);
    if (in.space != SPACE_GLOBAL && in.space != SPACE_NONE) fail(EXIT_UNSUPPORTED, "atomic on a non-global space: '%s'", stmt);
  } else if (!strcmp(op, "bar")) {
    in.op = OP_BAR;
    want = 1; /* the barrier ID */
    if (np != 2 || strcmp(parts[1], "sync")) fail(EXIT_UNSUPPORTED, "only bar.sync is supported: '%s'", stmt);
    if (nt - i == 2) fail(EXIT_UNSUPPORTED, "named barrier with a thread count is not supported: '%s'", stmt);
  } else {
    fail(EXIT_UNSUPPORTED, "unsupported instruction '%s'", stmt);
  }
  if (in.op != OP_BRA && in.op != OP_RET && in.op != OP_BAR && !have_ty)
    fail(EXIT_UNSUPPORTED, "no type on '%s'", stmt);
  if (in.op == OP_LD && in.space != SPACE_PARAM && in.space != SPACE_GLOBAL && in.space != SPACE_LOCAL && in.space != SPACE_NONE)
    fail(EXIT_UNSUPPORTED, "unsupported state space in '%s'", stmt);

  if (in.op == OP_BRA) {
    if (nt - i != 1) fail(EXIT_BAD, "bra takes one label: '%s'", stmt);
    scoped(in.label, sizeof in.label, tok[i]);
    i = nt;
  } else {
    if (nt - i != want) fail(EXIT_BAD, "expected %d operands: '%s'", want, stmt);
    for (; i < nt; i++) in.a[in.n++] = parse_operand(tok[i]);
  }

  /* Operand kinds the emitter's code shapes use. */
  if (in.op == OP_LD) {
    if (in.a[0].kind != K_REG) fail(EXIT_BAD, "ld destination must be a register: '%s'", stmt);
    if (in.space == SPACE_PARAM ? (in.a[1].kind != K_PARAM && in.a[1].kind != K_PARR) : in.a[1].kind != K_MEM)
      fail(EXIT_BAD, "bad ld source: '%s'", stmt);
  } else if (in.op == OP_ST) {
    if (in.a[0].kind != K_MEM && !(in.space == SPACE_PARAM && (in.a[0].kind == K_PARAM || in.a[0].kind == K_PARR)))
      fail(EXIT_BAD, "st destination must be a memory or parameter operand: '%s'", stmt);
  } else if (in.op == OP_ATOM) {
    if (in.a[0].kind != K_REG || in.a[1].kind != K_MEM || (in.a[2].kind != K_REG && in.a[2].kind != K_IMM))
      fail(EXIT_BAD, "atom needs a register, a [register] operand and a value: '%s'", stmt);
  } else if (in.op == OP_RED) {
    if (in.a[0].kind != K_MEM || (in.a[1].kind != K_REG && in.a[1].kind != K_IMM))
      fail(EXIT_BAD, "red needs a [register] operand and a value: '%s'", stmt);
  } else if (in.op == OP_BAR) {
    if (in.a[0].kind != K_IMM || in.a[0].imm < 0 || in.a[0].imm > 15)
      fail(EXIT_UNSUPPORTED, "barrier ID must be 0..15: '%s'", stmt);
  } else if (in.op != OP_BRA && in.op != OP_RET) {
    if (in.a[0].kind != K_REG) fail(EXIT_BAD, "destination must be a register: '%s'", stmt);
  }
  if (ninst == MAXINST) fail(EXIT_UNSUPPORTED, "too many instructions");
  insts[ninst++] = in;
}

static int is_label(const char *s, const char *end) {
  if (end == s) return 0;
  for (const char *p = s; p < end; p++)
    if (!(isalnum((unsigned char)*p) || *p == '_' || *p == '$')) return 0;
  return 1;
}

static void parse_params(char *text);

/* The body between the braces of one .entry. Statements end at ';'; labels may precede one. */
static void parse_body(char *body) {
  char *start = body;
  for (;;) {
    char *semi = strchr(start, ';');
    if (semi) *semi = 0;
    char *s = trim(start);
    for (;;) {
      char *colon = strchr(s, ':');
      if (!colon || !is_label(s, colon)) break;
      *colon = 0;
      add_label(s);
      s = trim(colon + 1);
    }
    while (*s == '{' || *s == '}') s = trim(s + 1); /* the braces of a call's parameter block */
    if (*s == '.') {
      if (!strncmp(s, ".reg", 4)) {
        /* registers are created on first use */
      } else if (!strncmp(s, ".local", 6)) {
        parse_local(s);
      } else if (!strncmp(s, ".param", 6)) {
        parse_params(s); /* a call's parameter, declared in its block */
      } else {
        fail(EXIT_UNSUPPORTED, "unsupported directive '%s'", s);
      }
    } else if (*s) {
      add_inst(s);
    }
    if (!semi) break;
    start = semi + 1;
  }
}

static void parse_params(char *text) {
  char *p = text;
  for (;;) {
    char *comma = strchr(p, ',');
    if (comma) *comma = 0;
    char *tok[8];
    char buf[MAXTEXT];
    snprintf(buf, sizeof buf, "%s", p);
    int nt = split_tokens(buf, tok, 8);
    if (nt) {
      if (nparams == MAXPARAM) fail(EXIT_UNSUPPORTED, "too many parameters");
      Param *pr = &params[nparams++];
      memset(pr, 0, sizeof *pr);
      char *br = strchr(tok[nt - 1], '[');
      int found = 0;
      if (br) {
        /* NAME[N] of .b8: a byte array, with the alignment of its .align (default 1) */
        char *close = strchr(br, ']');
        if (!close || close[1]) fail(EXIT_UNSUPPORTED, "unsupported parameter '%s'", p);
        *br = 0;
        pr->is_array = 1;
        pr->size = strtoull(br + 1, NULL, 10);
      }
      scoped(pr->name, MAXNAME, tok[nt - 1]);
      uint64_t align = 1;
      for (int i = 0; i < nt - 1; i++) {
        if (tok[i][0] == '.' && strcmp(tok[i], ".param") && parse_ty(tok[i] + 1, &pr->ty)) found = 1;
        if (!strcmp(tok[i], ".align") && i + 1 < nt - 1) align = strtoull(tok[i + 1], NULL, 10);
      }
      if (!found || (pr->is_array && pr->ty.bits != 8)) fail(EXIT_UNSUPPORTED, "unsupported parameter '%s'", p);
      if (pr->is_array) {
        if (align < 1) align = 1;
        frame_bytes = (frame_bytes + align - 1) / align * align;
        pr->off = frame_bytes;
        frame_bytes += pr->size;
      }
    }
    if (!comma) break;
    p = comma + 1;
  }
}

static void strip_comments(char *s) {
  char *p = s;
  while (*p) {
    if (p[0] == '/' && p[1] == '/') {
      while (*p && *p != '\n') *p++ = ' ';
    } else if (p[0] == '/' && p[1] == '*') {
      char *e = strstr(p + 2, "*/");
      if (!e) fail(EXIT_BAD, "unterminated comment");
      while (p < e + 2) *p++ = ' ';
    } else {
      p++;
    }
  }
}

static const char *match_close(const char *open, char oc, char cc) {
  int depth = 0;
  for (const char *p = open; *p; p++) {
    if (*p == oc) depth++;
    else if (*p == cc && --depth == 0) return p;
  }
  fail(EXIT_BAD, "unbalanced '%c'", oc);
  return NULL;
}

/* ---- definitions and functions ---- */

static char *dup_range(const char *s, size_t n) {
  char *d = malloc(n + 1);
  if (!d) fail(EXIT_FAULT, "out of memory");
  memcpy(d, s, n);
  d[n] = 0;
  return d;
}

/* An .entry or .func in the text. The pointers point into the text, which is not changed. */
typedef struct {
  char name[MAXNAME];
  char rv[MAXNAME];          /* the result register of a .func: "%rv" in .func (.reg .b32 %rv) f(...); "" if none */
  const char *open, *close;  /* the parameter list, between the parentheses */
  const char *brace, *body_end;
  int is_entry;
} Def;

/* Find the .entry or .func called name. Returns 0 when the text has no such definition. */
static int find_def(const char *text, const char *name, Def *d) {
  const char *p = text;
  for (;;) {
    const char *e = strstr(p, ".entry");
    const char *f = strstr(p, ".func");
    const char *k = (e && (!f || e < f)) ? e : f;
    if (!k) return 0;
    int is_entry = k == e;
    p = k + (is_entry ? 6 : 5);
    if (!isspace((unsigned char)*p) && *p != '(') continue;
    const char *q = p;
    while (isspace((unsigned char)*q)) q++;
    char rv[MAXNAME] = "";
    if (*q == '(') {
      const char *rc = strchr(q, ')');
      if (!rc) fail(EXIT_BAD, "unbalanced result list");
      size_t n = (size_t)(rc - q - 1);
      if (n >= MAXTEXT) fail(EXIT_UNSUPPORTED, "result list too long");
      char tmp[MAXTEXT];
      memcpy(tmp, q + 1, n);
      tmp[n] = 0;
      char *tok[8];
      int nt = split_tokens(tmp, tok, 8);
      if (nt) snprintf(rv, sizeof rv, "%s", tok[nt - 1]);
      q = rc + 1;
      while (isspace((unsigned char)*q)) q++;
    }
    const char *ne = q;
    while (isalnum((unsigned char)*ne) || *ne == '_' || *ne == '$') ne++;
    size_t nl = (size_t)(ne - q);
    if (nl == 0 || nl >= MAXNAME) {
      p = ne;
      continue;
    }
    char dn[MAXNAME];
    memcpy(dn, q, nl);
    dn[nl] = 0;
    while (isspace((unsigned char)*ne)) ne++;
    if (*ne != '(') {
      p = ne;
      continue;
    }
    const char *cl = match_close(ne, '(', ')');
    const char *brace = strchr(cl, '{');
    if (!brace) fail(EXIT_BAD, "no body for '%s'", dn);
    const char *be = match_close(brace, '{', '}');
    if (!strcmp(dn, name)) {
      snprintf(d->name, MAXNAME, "%s", dn);
      snprintf(d->rv, MAXNAME, "%s", rv);
      d->open = ne;
      d->close = cl;
      d->brace = brace;
      d->body_end = be;
      d->is_entry = is_entry;
      return 1;
    }
    p = be + 1;
  }
}

static int func_index(const char *name) {
  for (int i = 0; i < nfuncs; i++)
    if (!strcmp(funcs[i].name, name)) return i;
  return -1;
}

/* Parse one definition into the instruction stream: its parameters, registers and labels are scoped by its name. */
static int parse_function(const Def *d) {
  if (nfuncs == MAXFUNC) fail(EXIT_UNSUPPORTED, "too many functions");
  int idx = nfuncs++;
  Func *fn = &funcs[idx];
  memset(fn, 0, sizeof *fn);
  snprintf(fn->name, MAXNAME, "%s", d->name);
  fn->is_entry = d->is_entry;
  fn->rv = -1;
  fn->rv_param = -1;
  size_t sl = strlen(d->name);
  if (sl + 2 > sizeof scope) fail(EXIT_UNSUPPORTED, "function name too long: %s", d->name);
  memcpy(scope, d->name, sl);
  scope[sl] = '/';
  scope[sl + 1] = 0;
  int p0 = nparams;
  char *plist = dup_range(d->open + 1, (size_t)(d->close - d->open - 1));
  parse_params(plist);
  fn->nparam = nparams - p0;
  if (fn->nparam > MAXFPARAM) fail(EXIT_UNSUPPORTED, "too many parameters in '%s'", d->name);
  for (int k = 0; k < fn->nparam; k++) fn->param[k] = p0 + k;
  if (strchr(d->rv, '[')) {
    /* (.param .align A .b8 func_retval0[N]): the result is a byte array of the function */
    char *tokn = dup_range(d->rv, strlen(d->rv));
    char *br = strchr(tokn, '[');
    if (nparams == MAXPARAM) fail(EXIT_UNSUPPORTED, "too many parameters");
    Param *pr = &params[nparams];
    memset(pr, 0, sizeof *pr);
    pr->is_array = 1;
    pr->ty.bits = 8;
    *br = 0;
    pr->size = strtoull(br + 1, NULL, 10);
    scoped(pr->name, MAXNAME, tokn);
    frame_bytes = (frame_bytes + 7) / 8 * 8;
    pr->off = frame_bytes;
    frame_bytes += pr->size;
    fn->rv_param = nparams++;
    free(tokn);
  } else if (d->rv[0]) {
    fn->rv = reg_index(d->rv);
  }
  fn->start = ninst;
  char *body = dup_range(d->brace + 1, (size_t)(d->body_end - d->brace - 1));
  parse_body(body);
  fn->end = ninst;
  return idx;
}

/* Every call names a function of the module. A callee not parsed yet is parsed here, so only the functions a
 * kernel reaches are checked. */
static void resolve_calls(const char *text) {
  for (int i = 0; i < ninst; i++) {
    Inst *in = &insts[i];
    if (in->op != OP_CALL || in->callee >= 0) continue;
    int f = func_index(in->label);
    if (f < 0) {
      Def d;
      if (!find_def(text, in->label, &d) || d.is_entry)
        fail(EXIT_UNSUPPORTED, "call of '%s': not a device function of this module", in->label);
      f = parse_function(&d);
    }
    if (funcs[f].is_entry) fail(EXIT_UNSUPPORTED, "call of the kernel '%s'", in->label);
    if (funcs[f].nparam != in->nargs)
      fail(EXIT_BAD, "call of '%s' with %d arguments; it takes %d", in->label, in->nargs, funcs[f].nparam);
    in->callee = f;
  }
}

static int visit[MAXFUNC]; /* 0 new, 1 on the call path, 2 done */

/* Refuses a call cycle: the interpreter runs calls as nested runs, which need a finite call depth. */
static void check_calls(int f) {
  visit[f] = 1;
  for (int i = funcs[f].start; i < funcs[f].end; i++) {
    if (insts[i].op != OP_CALL) continue;
    int g = insts[i].callee;
    if (visit[g] == 1) fail(EXIT_UNSUPPORTED, "recursive call of '%s'", funcs[g].name);
    if (!visit[g]) check_calls(g);
  }
  visit[f] = 2;
}

static void resolve_labels(void) {
  for (int i = 0; i < ninst; i++) {
    Inst *in = &insts[i];
    if (in->op != OP_BRA) continue;
    in->target = -1;
    for (int k = 0; k < nlabels; k++)
      if (!strcmp(labels[k].name, in->label)) in->target = labels[k].index;
    if (in->target < 0) fail(EXIT_BAD, "unknown label '%s'", in->label);
  }
}


/* ---- launch and execution ---- */

typedef struct {
  uint8_t *arena;
  uint64_t arena_size;
  uint64_t ntid[3], nctaid[3];
  uint64_t params[MAXPARAM];
  int nbuf;                  /* global buffers: an access must lie inside one of them */
  uint64_t bufaddr[MAXPARAM];
  uint64_t bufsize[MAXPARAM];
} Launch;

/* The kernel arguments, as the command line gave them. */
typedef struct {
  int nargs;
  int akind[MAXPARAM];      /* 0 ptr, 1 s32, 2 bytes */
  uint64_t acount[MAXPARAM];
  uint64_t abuf[MAXPARAM];  /* a ptr: its buffer's offset in the arena, from ARENA_BASE */
  uint8_t *abytes[MAXPARAM];
  int has_iota[MAXPARAM];
  int64_t aval[MAXPARAM];
  int dumps[MAXPARAM], ndump;
} Args;

enum { T_RUN, T_BLOCKED, T_EXITED };

/* A call in progress: where the caller continues, and the call instruction (which names the result registers). */
typedef struct {
  int ret_pc;
  int caller_fn;
  int call;
} Frame;

/* One thread: its registers and parameters, its position, and its call stack. Nothing about it lives on the C stack,
 * so the scheduler can stop it between any two instructions. */
typedef struct {
  uint64_t *r;
  uint64_t *pv;
  uint64_t tid[3], ctaid[3];
  uint64_t local_base, frame;
  int block;   /* linear block index */
  int pc, fn;  /* next instruction, and the function it is in */
  int state;
  int bar;     /* while T_BLOCKED: the barrier ID it waits at */
  int depth;
  Frame stack[MAXFUNC];
} Thread;

typedef struct {
  char *key;
  uint64_t count;
} Outcome;

typedef struct {
  int n, c; /* the number of options at a choice point, and the option taken */
} Choice;

#define MAXOUT 256
#define BARRIERS 16
#define MAXTHREADS (1u << 24)

enum { POL_SEQ, POL_RANDOM, POL_EXPLORE };

static Launch L;
static Args A;
static Thread *threads;
static int nthreads, tpb, nblocks, nregs_alloc;
static int *arrived; /* per block and barrier ID: arrivals in the current generation */
static int *live;    /* per block: threads that have not exited */
static int *poised;
static uint64_t steps, max_steps = 10000000ULL;
static int policy = POL_SEQ;
static uint64_t rng_state;
static Choice *trail; /* the choices of the schedule being run */
static int trail_len, trail_cap;
static Choice *prefix; /* the choices to replay before the search goes on */
static int prefix_len;
static Outcome outcomes[MAXOUT];
static int noutcomes;

static uint64_t special_value(const Launch *l, const uint64_t *tid, const uint64_t *ctaid, int sp) {
  if (sp < 3) return tid[sp];
  if (sp < 6) return l->ntid[sp - 3];
  if (sp < 9) return ctaid[sp - 6];
  return l->nctaid[sp - 9];
}

static uint64_t value(const Launch *l, const uint64_t *r, const uint64_t *tid, const uint64_t *ctaid,
                      uint64_t local_base, Operand o) {
  switch (o.kind) {
    case K_REG: return r[o.idx];
    case K_IMM: return (uint64_t)o.imm;
    case K_SPECIAL: return special_value(l, tid, ctaid, o.idx);
    case K_SYM: return local_base + locals[o.idx].off;
    default: fail(EXIT_BAD, "operand has no value");
  }
  return 0;
}

/* An access of n bytes at addr must lie entirely inside one global buffer or inside this
 * thread's own local frame. Anything else is a fault, even when it is inside the arena. */
static uint8_t *mem_at(const Launch *l, uint64_t local_base, uint64_t frame, uint64_t addr, uint64_t n,
                       const Inst *in) {
  for (int i = 0; i < l->nbuf; i++) {
    uint64_t off = addr - l->bufaddr[i];
    if (addr >= l->bufaddr[i] && off <= l->bufsize[i] && n <= l->bufsize[i] - off)
      return l->arena + (addr - ARENA_BASE);
  }
  uint64_t off = addr - local_base;
  if (frame && addr >= local_base && off <= frame && n <= frame - off)
    return l->arena + (addr - ARENA_BASE);
  fail(EXIT_FAULT, "address 0x%llx out of bounds in '%s'", (unsigned long long)addr, in->text);
  return NULL;
}

static uint64_t load_bytes(const uint8_t *m, int n) {
  uint64_t v = 0;
  for (int i = 0; i < n; i++) v |= (uint64_t)m[i] << (8 * i);
  return v;
}

static void store_bytes(uint8_t *m, int n, uint64_t v) {
  for (int i = 0; i < n; i++) m[i] = (uint8_t)(v >> (8 * i));
}

static void put_le32(uint8_t *m, uint32_t v) {
  for (int i = 0; i < 4; i++) m[i] = (uint8_t)(v >> (8 * i));
}

static uint32_t get_le32(const uint8_t *m) {
  return (uint32_t)m[0] | ((uint32_t)m[1] << 8) | ((uint32_t)m[2] << 16) | ((uint32_t)m[3] << 24);
}

static uint64_t align16(uint64_t v) { return (v + 15) / 16 * 16; }

static uint64_t tval(const Thread *t, Operand o) { return value(&L, t->r, t->tid, t->ctaid, t->local_base, o); }

static uint8_t *tmem(const Thread *t, uint64_t addr, uint64_t n, const Inst *in) {
  return mem_at(&L, t->local_base, t->frame, addr, n, in);
}

/* The scheduler's choice among n poised threads. Sequential: always the first. Random: xorshift. Exploration:
 * replay the prefix, then take option 0 and record the point, so the search can come back to it. */
static int choose(int n) {
  if (policy == POL_SEQ) return 0;
  if (policy == POL_RANDOM) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return (int)(rng_state % (uint64_t)n);
  }
  int c = 0;
  if (trail_len < prefix_len) {
    if (prefix[trail_len].n != n) fail(EXIT_FAULT, "schedule replay diverged: %d options, expected %d", n, prefix[trail_len].n);
    c = prefix[trail_len].c;
  }
  if (trail_len == trail_cap) {
    trail_cap = trail_cap ? 2 * trail_cap : 256;
    trail = realloc(trail, (size_t)trail_cap * sizeof *trail);
    if (!trail) fail(EXIT_FAULT, "out of memory");
  }
  trail[trail_len].n = n;
  trail[trail_len].c = c;
  trail_len++;
  return c;
}

static void release(int block, int id) {
  for (int g = block * tpb; g < (block + 1) * tpb; g++)
    if (threads[g].state == T_BLOCKED && threads[g].bar == id) threads[g].state = T_RUN;
  arrived[block * BARRIERS + id] = 0;
}

/* A barrier generation completes when every live thread of the block has arrived at it. Exited threads are not
 * counted, so they never hold a barrier back. */
static void maybe_release(int block) {
  for (int id = 0; id < BARRIERS; id++) {
    int n = arrived[block * BARRIERS + id];
    if (n > 0 && n == live[block]) release(block, id);
  }
}

static void exit_thread(Thread *t) {
  t->state = T_EXITED;
  live[t->block]--;
  maybe_release(t->block);
}

/* Returns from the current function: the result of the call that entered it goes to the caller. Returning from the
 * kernel ends the thread. */
static void do_return(Thread *t) {
  if (t->depth == 0) {
    exit_thread(t);
    return;
  }
  Frame *f = &t->stack[--t->depth];
  const Inst *call = &insts[f->call];
  const Func *callee = &funcs[t->fn];
  if (call->ret >= 0) {
    if (callee->rv < 0) fail(EXIT_UNSUPPORTED, "'%s' returns no value", callee->name);
    t->r[call->ret] = t->r[callee->rv];
  }
  if (call->ret_param >= 0) {
    if (callee->rv_param < 0) fail(EXIT_UNSUPPORTED, "'%s' returns no array", callee->name);
    const Param *dst = &params[call->ret_param], *src = &params[callee->rv_param];
    if (dst->size != src->size) fail(EXIT_BAD, "result of '%s' does not match its call", callee->name);
    memmove(tmem(t, t->local_base + dst->off, dst->size, call), tmem(t, t->local_base + src->off, src->size, call),
            dst->size);
  }
  t->pc = f->ret_pc;
  t->fn = f->caller_fn;
}

/* Executes one instruction of thread t. */
static void step(Thread *t) {
  if (t->pc == funcs[t->fn].end) {
    do_return(t);
    return;
  }
  if (++steps > max_steps) fail(EXIT_FAULT, "step limit of %llu reached", (unsigned long long)max_steps);
  const Inst *in = &insts[t->pc];
  if (in->pred >= 0) {
    int v = t->r[in->pred] != 0;
    if (in->pred_neg) v = !v;
    if (!v) {
      t->pc++;
      return;
    }
  }
  uint64_t *r = t->r;
  int next = t->pc + 1;
  uint64_t a = 0, b = 0, c = 0;
  if (in->op != OP_RET && in->op != OP_BRA && in->op != OP_LD && in->op != OP_CALL && in->op != OP_ATOM &&
      in->op != OP_RED && in->op != OP_BAR) {
    a = tval(t, in->a[1]);
    if (in->n > 2) b = tval(t, in->a[2]);
    if (in->n > 3) c = tval(t, in->a[3]);
  }
  int nbytes = in->ty.bits / 8;
  switch (in->op) {
    case OP_RET:
      do_return(t);
      return;
    case OP_CALL: {
      const Func *callee = &funcs[in->callee];
      uint64_t args[4];
      for (int k = 0; k < in->nargs; k++) args[k] = t->pv[in->argp[k]];
      for (int k = 0; k < in->nargs; k++) {
        const Param *formal = &params[callee->param[k]];
        if (formal->is_array) {
          /* a byte array argument is copied by value into the callee's array */
          const Param *actual = &params[in->argp[k]];
          if (!actual->is_array || actual->size != formal->size) fail(EXIT_BAD, "array argument of '%s' does not match", callee->name);
          memmove(tmem(t, t->local_base + formal->off, formal->size, in), tmem(t, t->local_base + actual->off, actual->size, in),
                  formal->size);
        } else {
          t->pv[callee->param[k]] = args[k];
        }
      }
      if (t->depth == MAXFUNC) fail(EXIT_UNSUPPORTED, "call depth too large");
      Frame *f = &t->stack[t->depth++];
      f->ret_pc = next;
      f->caller_fn = t->fn;
      f->call = t->pc;
      t->fn = in->callee;
      next = callee->start;
      break;
    }
    case OP_BRA:
      next = in->target;
      break;
    case OP_LD: {
      uint64_t v;
      if (in->space == SPACE_PARAM && in->a[1].kind == K_PARR) {
        uint64_t addr = t->local_base + params[in->a[1].idx].off + (uint64_t)in->a[1].imm;
        v = load_bytes(tmem(t, addr, nbytes, in), nbytes);
      } else if (in->space == SPACE_PARAM) {
        v = t->pv[in->a[1].idx];
      } else {
        uint64_t addr = r[in->a[1].idx] + (uint64_t)in->a[1].imm;
        v = load_bytes(tmem(t, addr, nbytes, in), nbytes);
      }
      r[in->a[0].idx] = canon(in->ty, v);
      break;
    }
    case OP_ST: {
      if (in->space == SPACE_PARAM && in->a[0].kind == K_PARR) {
        uint64_t addr = t->local_base + params[in->a[0].idx].off + (uint64_t)in->a[0].imm;
        store_bytes(tmem(t, addr, nbytes, in), nbytes, a);
        break;
      }
      if (in->space == SPACE_PARAM) {
        t->pv[in->a[0].idx] = a;
        break;
      }
      uint64_t addr = r[in->a[0].idx] + (uint64_t)in->a[0].imm;
      store_bytes(tmem(t, addr, nbytes, in), nbytes, a);
      break;
    }
    case OP_ATOM:
    case OP_RED: {
      /* atom: dst, [addr], value; red: [addr], value. One step, so no other thread's access falls between the
       * read and the write. */
      int mi = in->op == OP_ATOM ? 1 : 0;
      int vi = in->op == OP_ATOM ? 2 : 1;
      uint64_t v = tval(t, in->a[vi]);
      uint64_t addr = r[in->a[mi].idx] + (uint64_t)in->a[mi].imm;
      uint8_t *m = tmem(t, addr, nbytes, in);
      uint64_t old = canon(in->ty, load_bytes(m, nbytes));
      store_bytes(m, nbytes, in->aop == AOP_ADD ? old + v : v);
      if (in->op == OP_ATOM) r[in->a[0].idx] = old;
      break;
    }
    case OP_BAR: {
      int id = (int)in->a[0].imm;
      t->state = T_BLOCKED;
      t->bar = id;
      arrived[t->block * BARRIERS + id]++;
      maybe_release(t->block);
      break;
    }
    case OP_MOV:
      r[in->a[0].idx] = canon(in->ty, a);
      break;
    case OP_CVTA:
      r[in->a[0].idx] = a;
      break;
    case OP_ADD:
      r[in->a[0].idx] = canon(in->ty, a + b);
      break;
    case OP_SUB:
      r[in->a[0].idx] = canon(in->ty, a - b);
      break;
    case OP_MUL:
      if (in->wide) {
        /* 32-bit operands, 64-bit product: the operands are canonical, so they fit */
        r[in->a[0].idx] = in->ty.sign ? (uint64_t)((int64_t)a * (int64_t)b) : a * b;
      } else {
        r[in->a[0].idx] = canon(in->ty, a * b);
      }
      break;
    case OP_MAD:
      r[in->a[0].idx] = canon(in->ty, a * b + c);
      break;
    case OP_SHL:
      r[in->a[0].idx] = b >= (uint64_t)in->ty.bits ? 0 : canon(in->ty, a << b);
      break;
    case OP_CVT:
      r[in->a[0].idx] = canon(in->ty, a);
      break;
    case OP_SHR:
      /* the operand is read at the instruction's width (shr.s32 of a 32-bit register sign-extends it) */
      if (in->ty.sign) {
        int64_t x = (int64_t)canon(in->ty, a);
        r[in->a[0].idx] = canon(in->ty, (uint64_t)(x >> (b >= 63 ? 63 : b)));
      } else {
        r[in->a[0].idx] = b >= (uint64_t)in->ty.bits ? 0 : canon(in->ty, canon(in->ty, a) >> b);
      }
      break;
    case OP_AND:
      r[in->a[0].idx] = canon(in->ty, a & b);
      break;
    case OP_OR:
      r[in->a[0].idx] = canon(in->ty, a | b);
      break;
    case OP_SETP: {
      int res = 0;
      if (in->ty.sign) {
        int64_t x = (int64_t)a, y = (int64_t)b;
        switch (in->cmp) {
          case CMP_EQ: res = x == y; break;
          case CMP_NE: res = x != y; break;
          case CMP_LT: res = x < y; break;
          case CMP_LE: res = x <= y; break;
          case CMP_GT: res = x > y; break;
          case CMP_GE: res = x >= y; break;
        }
      } else {
        switch (in->cmp) {
          case CMP_EQ: res = a == b; break;
          case CMP_NE: res = a != b; break;
          case CMP_LT: res = a < b; break;
          case CMP_LE: res = a <= b; break;
          case CMP_GT: res = a > b; break;
          case CMP_GE: res = a >= b; break;
        }
      }
      r[in->a[0].idx] = (uint64_t)res;
      break;
    }
  }
  t->pc = next;
}

/* Whether an instruction touches state another thread can see: global or generic memory, an atomic, or a barrier.
 * These are the scheduling points. The rest only changes this thread's registers, parameters and local frame, so
 * running it first changes nothing another thread can observe. */
static int is_shared(const Inst *in) {
  switch (in->op) {
    case OP_ATOM:
    case OP_RED:
    case OP_BAR:
      return 1;
    case OP_LD:
    case OP_ST:
      return in->space != SPACE_PARAM && in->space != SPACE_LOCAL;
    default:
      return 0;
  }
}

/* Runs thread t through its thread-local instructions, up to its next scheduling point (or until it blocks or
 * exits). */
static void advance(Thread *t) {
  while (t->state == T_RUN) {
    if (t->pc != funcs[t->fn].end && is_shared(&insts[t->pc])) return;
    step(t);
  }
}

static void setup_threads(const uint64_t grid[3], const uint64_t block[3], uint64_t frame, uint64_t local_start) {
  tpb = (int)(block[0] * block[1] * block[2]);
  nblocks = (int)(grid[0] * grid[1] * grid[2]);
  nthreads = nblocks * tpb;
  threads = calloc((size_t)nthreads, sizeof *threads);
  poised = calloc((size_t)nthreads, sizeof *poised);
  arrived = calloc((size_t)nblocks * BARRIERS, sizeof *arrived);
  live = calloc((size_t)nblocks, sizeof *live);
  if (!threads || !poised || !arrived || !live) fail(EXIT_FAULT, "out of memory");
  nregs_alloc = nregs ? nregs : 1;
  /* Blocks in x-major order, threads within a block in x-major order: thread g is in block g / tpb. */
  int g = 0, bidx = 0;
  for (uint64_t cz = 0; cz < grid[2]; cz++)
    for (uint64_t cy = 0; cy < grid[1]; cy++)
      for (uint64_t cx = 0; cx < grid[0]; cx++, bidx++)
        for (uint64_t tz = 0; tz < block[2]; tz++)
          for (uint64_t ty = 0; ty < block[1]; ty++)
            for (uint64_t tx = 0; tx < block[0]; tx++, g++) {
              Thread *t = &threads[g];
              t->r = calloc((size_t)nregs_alloc, sizeof *t->r);
              t->pv = calloc(MAXPARAM, sizeof *t->pv);
              if (!t->r || !t->pv) fail(EXIT_FAULT, "out of memory");
              t->tid[0] = tx;
              t->tid[1] = ty;
              t->tid[2] = tz;
              t->ctaid[0] = cx;
              t->ctaid[1] = cy;
              t->ctaid[2] = cz;
              t->local_base = ARENA_BASE + local_start + (uint64_t)g * frame;
              t->frame = frame;
              t->block = bidx;
            }
}

/* Fresh state for one schedule: the arena (buffers with their starting values, zeroed frames), then every thread. */
static void init_arena(void) {
  memset(L.arena, 0, (size_t)(L.arena_size ? L.arena_size : 1));
  for (int i = 0; i < A.nargs; i++)
    if (A.akind[i] == 0 && A.has_iota[i])
      for (uint64_t k = 0; k < A.acount[i]; k++)
        put_le32(L.arena + A.abuf[i] + 4 * k, (uint32_t)(A.aval[i] + (int64_t)k));
}

static void reset_threads(void) {
  for (int g = 0; g < nthreads; g++) {
    Thread *t = &threads[g];
    memset(t->r, 0, (size_t)nregs_alloc * sizeof *t->r);
    memset(t->pv, 0, MAXPARAM * sizeof *t->pv);
    memcpy(t->pv, L.params, sizeof(uint64_t) * (size_t)A.nargs);
    for (int i = 0; i < A.nargs; i++)
      if (A.akind[i] == 2) memcpy(L.arena + (t->local_base + params[i].off - ARENA_BASE), A.abytes[i], A.acount[i]);
    t->pc = funcs[0].start;
    t->fn = 0;
    t->depth = 0;
    t->state = T_RUN;
    t->bar = -1;
  }
  memset(arrived, 0, (size_t)nblocks * BARRIERS * sizeof *arrived);
  for (int b = 0; b < nblocks; b++) live[b] = tpb;
  steps = 0;
}

/* Runs one schedule to the end: every thread exited. Each round, the threads that are poised (their next instruction
 * is a scheduling point) are the options; the policy picks one, which takes its scheduling point. */
static void run_schedule(void) {
  reset_threads();
  for (;;) {
    int np = 0;
    for (int g = 0; g < nthreads; g++) {
      advance(&threads[g]);
      if (threads[g].state == T_RUN) poised[np++] = g;
    }
    if (np == 0) {
      for (int g = 0; g < nthreads; g++)
        if (threads[g].state == T_BLOCKED)
          fail(EXIT_FAULT, "deadlock: thread %d waits at barrier %d, which no other thread can release", g, threads[g].bar);
      return;
    }
    Thread *t = &threads[poised[np > 1 ? choose(np) : 0]];
    step(t);
  }
}

/* The outcome of a complete schedule: the --dump buffers, in order, separated by " | ". */
static char *outcome_key(void) {
  size_t cap = 2;
  for (int d = 0; d < A.ndump; d++) cap += A.acount[A.dumps[d]] * 12 + 8;
  char *s = malloc(cap);
  if (!s) fail(EXIT_FAULT, "out of memory");
  if (A.ndump == 0) {
    snprintf(s, cap, "-");
    return s;
  }
  size_t n = 0;
  for (int d = 0; d < A.ndump; d++) {
    int k = A.dumps[d];
    if (d) n += (size_t)snprintf(s + n, cap - n, " | ");
    for (uint64_t e = 0; e < A.acount[k]; e++)
      n += (size_t)snprintf(s + n, cap - n, e ? " %d" : "%d", (int32_t)get_le32(L.arena + A.abuf[k] + 4 * e));
  }
  return s;
}

static void record_outcome(void) {
  char *key = outcome_key();
  for (int i = 0; i < noutcomes; i++)
    if (!strcmp(outcomes[i].key, key)) {
      outcomes[i].count++;
      free(key);
      return;
    }
  if (noutcomes == MAXOUT) fail(EXIT_UNSUPPORTED, "more than %d distinct outcomes", MAXOUT);
  outcomes[noutcomes].key = key;
  outcomes[noutcomes].count = 1;
  noutcomes++;
}

static int cmp_outcome(const void *x, const void *y) {
  return strcmp(((const Outcome *)x)->key, ((const Outcome *)y)->key);
}

static void print_outcomes(void) {
  qsort(outcomes, (size_t)noutcomes, sizeof outcomes[0], cmp_outcome);
  for (int i = 0; i < noutcomes; i++)
    printf("outcome %llu: %s\n", (unsigned long long)outcomes[i].count, outcomes[i].key);
}

/* Depth-first search over the schedules, by replay: the last choice that has an untried option is advanced, and the
 * choices before it are kept. Returns 0 when no untried option is left. */
static int next_prefix(void) {
  int d = trail_len - 1;
  while (d >= 0 && trail[d].c + 1 >= trail[d].n) d--;
  if (d < 0) return 0;
  Choice *p = malloc(((size_t)d + 1) * sizeof *p);
  if (!p) fail(EXIT_FAULT, "out of memory");
  memcpy(p, trail, (size_t)d * sizeof *p);
  p[d].n = trail[d].n;
  p[d].c = trail[d].c + 1;
  free(prefix);
  prefix = p;
  prefix_len = d + 1;
  return 1;
}

static void parse_dims(const char *s, uint64_t d[3]) {
  char buf[64];
  snprintf(buf, sizeof buf, "%s", s);
  char *p = buf;
  for (int i = 0; i < 3; i++) {
    d[i] = 1;
    if (!*p) continue;
    char *comma = strchr(p, ',');
    if (comma) *comma = 0;
    d[i] = strtoull(p, NULL, 0);
    if (d[i] == 0) fail(EXIT_BAD, "dimension must be positive: '%s'", s);
    if (!comma) {
      p = p + strlen(p);
    } else {
      p = comma + 1;
    }
  }
}

static void usage(void) {
  fprintf(stderr,
          "usage: ptxi FILE.ptx KERNEL [--grid X[,Y[,Z]]] [--block X[,Y[,Z]]] ARG... [--dump K]...\n"
          "           [--random N [--seed S]] [--explore [--max-schedules M]] [--max-steps S]\n"
          "  ARG: ptr:COUNT[:iota=START] | s32:VALUE | bytes:HEX\n");
  exit(EXIT_BAD);
}

int main(int argc, char **argv) {
  if (argc < 3) usage();
  const char *file = argv[1];
  const char *kernel = argv[2];
  uint64_t grid[3] = {1, 1, 1}, block[3] = {1, 1, 1};
  uint64_t random_runs = 0, seed = 1, max_schedules = 100000;
  int explore = 0;
  memset(&A, 0, sizeof A);

  for (int i = 3; i < argc; i++) {
    if (!strcmp(argv[i], "--grid") || !strcmp(argv[i], "--block")) {
      if (i + 1 >= argc) usage();
      uint64_t *dims = !strcmp(argv[i], "--grid") ? grid : block;
      parse_dims(argv[++i], dims);
    } else if (!strcmp(argv[i], "--dump")) {
      if (i + 1 >= argc || A.ndump == MAXPARAM) usage();
      A.dumps[A.ndump++] = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--random")) {
      if (i + 1 >= argc) usage();
      random_runs = strtoull(argv[++i], NULL, 10);
      if (random_runs == 0) usage();
    } else if (!strcmp(argv[i], "--seed")) {
      if (i + 1 >= argc) usage();
      seed = strtoull(argv[++i], NULL, 10);
    } else if (!strcmp(argv[i], "--explore")) {
      explore = 1;
    } else if (!strcmp(argv[i], "--max-schedules")) {
      if (i + 1 >= argc) usage();
      max_schedules = strtoull(argv[++i], NULL, 10);
      if (max_schedules == 0) usage();
    } else if (!strcmp(argv[i], "--max-steps")) {
      if (i + 1 >= argc) usage();
      max_steps = strtoull(argv[++i], NULL, 10);
      if (max_steps == 0) usage();
    } else if (!strncmp(argv[i], "--", 2)) {
      usage();
    } else {
      int k = A.nargs;
      if (k == MAXPARAM) usage();
      const char *a = argv[i];
      if (!strncmp(a, "ptr:", 4)) {
        A.akind[k] = 0;
        char *end;
        A.acount[k] = strtoull(a + 4, &end, 10);
        A.has_iota[k] = 0;
        if (*end == ':' && !strncmp(end, ":iota=", 6)) {
          A.has_iota[k] = 1;
          A.aval[k] = strtoll(end + 6, NULL, 10);
        } else if (*end) {
          usage();
        }
      } else if (!strncmp(a, "s32:", 4)) {
        A.akind[k] = 1;
        A.aval[k] = strtoll(a + 4, NULL, 0);
      } else if (!strncmp(a, "bytes:", 6)) {
        size_t hl = strlen(a + 6);
        if (hl % 2) usage();
        A.akind[k] = 2;
        A.acount[k] = hl / 2;
        A.abytes[k] = malloc(hl / 2 + 1);
        if (!A.abytes[k]) fail(EXIT_FAULT, "out of memory");
        for (size_t j = 0; j < hl / 2; j++) {
          unsigned v;
          if (sscanf(a + 6 + 2 * j, "%2x", &v) != 1) usage();
          A.abytes[k][j] = (uint8_t)v;
        }
      } else {
        usage();
      }
      A.nargs++;
    }
  }
  if (explore && random_runs) usage();

  /* Read the file, strip comments, find the kernel. */
  FILE *f = fopen(file, "rb");
  if (!f) fail(EXIT_BAD, "cannot open %s", file);
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *text = malloc((size_t)len + 1);
  if (!text || fread(text, 1, (size_t)len, f) != (size_t)len) fail(EXIT_BAD, "cannot read %s", file);
  text[len] = 0;
  fclose(f);
  strip_comments(text);
  Def kd;
  if (!find_def(text, kernel, &kd) || !kd.is_entry) fail(EXIT_BAD, "kernel '%s' not found", kernel);
  parse_function(&kd);
  resolve_calls(text);
  resolve_labels();
  check_calls(0);
  if (funcs[0].nparam != A.nargs) fail(EXIT_BAD, "kernel takes %d parameters, got %d arguments", funcs[0].nparam, A.nargs);
  for (int d = 0; d < A.ndump; d++) {
    int k = A.dumps[d];
    if (k < 0 || k >= A.nargs || A.akind[k] != 0) usage();
  }

  /* Arena: the buffers, then one local frame per thread. */
  uint64_t cursor = 0;
  for (int i = 0; i < A.nargs; i++) {
    if (A.akind[i] == 0) {
      if (params[i].ty.bits != 64) fail(EXIT_BAD, "parameter %d is not a pointer", i);
      A.abuf[i] = cursor;
      cursor = align16(cursor + A.acount[i] * 4);
    } else if (A.akind[i] == 1) {
      if (params[i].ty.bits != 32) fail(EXIT_BAD, "parameter %d is not a 32-bit scalar", i);
    } else {
      if (!params[i].is_array || params[i].size != A.acount[i])
        fail(EXIT_BAD, "parameter %d is not a byte array of %llu bytes", i, (unsigned long long)A.acount[i]);
    }
  }
  uint64_t local_start = cursor;
  uint64_t frame = align16(frame_bytes);
  uint64_t total = grid[0] * grid[1] * grid[2] * block[0] * block[1] * block[2];
  if (total > MAXTHREADS) fail(EXIT_UNSUPPORTED, "too many threads: %llu", (unsigned long long)total);
  L.arena_size = local_start + frame * total;
  L.arena = calloc(1, L.arena_size ? L.arena_size : 1);
  if (!L.arena) fail(EXIT_FAULT, "out of memory for %llu bytes", (unsigned long long)L.arena_size);
  for (int i = 0; i < 3; i++) {
    L.ntid[i] = block[i];
    L.nctaid[i] = grid[i];
  }
  for (int i = 0; i < A.nargs; i++) {
    if (A.akind[i] == 0) {
      L.params[i] = ARENA_BASE + A.abuf[i];
      L.bufaddr[L.nbuf] = ARENA_BASE + A.abuf[i];
      L.bufsize[L.nbuf] = A.acount[i] * 4;
      L.nbuf++;
    } else {
      L.params[i] = (uint64_t)A.aval[i];
    }
  }
  setup_threads(grid, block, frame, local_start);
  init_arena();

  if (explore) {
    /* Every schedule, until the search runs out of untried choices or --max-schedules complete ones have run. */
    policy = POL_EXPLORE;
    uint64_t count = 0;
    int exhaustive = 0;
    for (;;) {
      trail_len = 0;
      init_arena();
      run_schedule();
      count++;
      record_outcome();
      if (!next_prefix()) {
        exhaustive = 1;
        break;
      }
      if (count >= max_schedules) break;
    }
    print_outcomes();
    if (!exhaustive) {
      printf("schedules %llu (incomplete: --max-schedules reached)\n", (unsigned long long)count);
      exit(5);
    }
    printf("schedules %llu (exhaustive)\n", (unsigned long long)count);
    return 0;
  }

  if (random_runs) {
    policy = POL_RANDOM;
    for (uint64_t i = 0; i < random_runs; i++) {
      rng_state = ((seed + i) * 0x9E3779B97F4A7C15ULL) | 1;
      init_arena();
      run_schedule();
      record_outcome();
    }
    print_outcomes();
    printf("schedules %llu (random, seed %llu)\n", (unsigned long long)random_runs, (unsigned long long)seed);
    return 0;
  }

  /* The default: the lowest-numbered poised thread always goes first, so each thread runs until it blocks or exits. */
  policy = POL_SEQ;
  run_schedule();
  for (int d = 0; d < A.ndump; d++) {
    int k = A.dumps[d];
    for (uint64_t e = 0; e < A.acount[k]; e++) printf("%d\n", (int32_t)get_le32(L.arena + A.abuf[k] + 4 * e));
  }
  return 0;
}
