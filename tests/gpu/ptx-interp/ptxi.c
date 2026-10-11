/* ptxi: a CPU interpreter for the PTX subset that scripts/pathb-ptx-emit.rb emits.
 *
 * Usage: ptxi FILE.ptx KERNEL [--grid X[,Y[,Z]]] [--block X[,Y[,Z]]] ARG... [--dump K]...
 *   ARG is one kernel parameter, in order:
 *     ptr:COUNT[:iota=START]   a global buffer of COUNT int32 (zeroed, or START+i in element i)
 *     s32:VALUE                a 32-bit scalar
 *   --dump K                   print argument K (a ptr) as COUNT lines of int32 values
 *
 * Every thread of the grid runs to completion, one after another, on the host; threads do not
 * interleave, so barriers, shared memory and atomics are refused. Memory is one flat arena: the
 * buffers from ARENA_BASE up, then one local frame per thread. An access of n bytes must lie inside
 * one buffer or inside the accessing thread's own frame; anything else is a fault, so a missing
 * bounds check shows up as an error or as a write into a guard buffer, not as silent corruption.
 *
 * Accepted: .version, .target, .address_size (ignored), .visible .entry with .param, .reg (ignored:
 * registers are created on first use), .local, labels, ld (param, generic, global, local), st,
 * mov, cvta, add, sub, mul.lo / mul.wide, mad.lo, shl, and, or, setp, bra, ret, predicates
 * (@%p, @!%p), and the special registers %tid, %ntid, %ctaid, %nctaid (x, y, z).
 *
 * Exit: 0 ran, 2 usage or malformed input, 3 unsupported PTX (refused before running), 4 memory fault.
 * Limits: 8192 instructions, 1024 registers, 64 parameters, 64 local symbols, 1024 labels.
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
#define MAXPARAM 64
#define MAXLOCAL 64
#define MAXLABEL 1024
#define MAXNAME 64
#define MAXTEXT 96

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

enum { K_NONE, K_REG, K_IMM, K_SPECIAL, K_SYM, K_MEM, K_PARAM };
enum {
  SP_TIDX, SP_TIDY, SP_TIDZ, SP_NTIDX, SP_NTIDY, SP_NTIDZ,
  SP_CTAIDX, SP_CTAIDY, SP_CTAIDZ, SP_NCTAIDX, SP_NCTAIDY, SP_NCTAIDZ
};
enum {
  OP_LD, OP_ST, OP_MOV, OP_CVTA, OP_ADD, OP_SUB, OP_MUL, OP_MAD,
  OP_SHL, OP_AND, OP_OR, OP_SETP, OP_BRA, OP_RET
};
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
  char label[MAXNAME];
  char text[MAXTEXT];
} Inst;

typedef struct {
  char name[MAXNAME];
  Ty ty;
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

static int reg_index(const char *name) {
  for (int i = 0; i < nregs; i++)
    if (!strcmp(regs[i], name)) return i;
  if (nregs == MAXREG) fail(EXIT_UNSUPPORTED, "too many registers");
  snprintf(regs[nregs], MAXNAME, "%s", name);
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
      int p = param_index(inner);
      if (p < 0) fail(EXIT_BAD, "unknown parameter in '%s'", tok);
      o.kind = K_PARAM;
      o.idx = p;
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
  if (nlabels == MAXLABEL) fail(EXIT_UNSUPPORTED, "too many labels");
  for (int i = 0; i < nlabels; i++)
    if (!strcmp(labels[i].name, name)) fail(EXIT_BAD, "duplicate label '%s'", name);
  snprintf(labels[nlabels].name, MAXNAME, "%s", name);
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
  static const char *known[] = {"ld", "st", "mov", "cvta", "add", "sub", "mul", "mad",
                                "shl", "and", "or", "setp", "bra", "ret"};
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
  } else {
    fail(EXIT_UNSUPPORTED, "unsupported instruction '%s'", stmt);
  }
  if (in.op != OP_BRA && in.op != OP_RET && !have_ty)
    fail(EXIT_UNSUPPORTED, "no type on '%s'", stmt);
  if (in.op == OP_LD && in.space != SPACE_PARAM && in.space != SPACE_GLOBAL && in.space != SPACE_LOCAL && in.space != SPACE_NONE)
    fail(EXIT_UNSUPPORTED, "unsupported state space in '%s'", stmt);

  if (in.op == OP_BRA) {
    if (nt - i != 1) fail(EXIT_BAD, "bra takes one label: '%s'", stmt);
    snprintf(in.label, sizeof in.label, "%s", tok[i]);
    i = nt;
  } else {
    if (nt - i != want) fail(EXIT_BAD, "expected %d operands: '%s'", want, stmt);
    for (; i < nt; i++) in.a[in.n++] = parse_operand(tok[i]);
  }

  /* Operand kinds the emitter's code shapes use. */
  if (in.op == OP_LD) {
    if (in.a[0].kind != K_REG) fail(EXIT_BAD, "ld destination must be a register: '%s'", stmt);
    if (in.space == SPACE_PARAM ? in.a[1].kind != K_PARAM : in.a[1].kind != K_MEM)
      fail(EXIT_BAD, "bad ld source: '%s'", stmt);
  } else if (in.op == OP_ST) {
    if (in.a[0].kind != K_MEM) fail(EXIT_BAD, "st destination must be a memory operand: '%s'", stmt);
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
    if (*s == '.') {
      if (!strncmp(s, ".reg", 4)) {
        /* registers are created on first use */
      } else if (!strncmp(s, ".local", 6)) {
        parse_local(s);
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
      snprintf(pr->name, MAXNAME, "%s", tok[nt - 1]);
      int found = 0;
      for (int i = 0; i < nt - 1; i++) {
        if (tok[i][0] == '.' && strcmp(tok[i], ".param") && parse_ty(tok[i] + 1, &pr->ty)) found = 1;
      }
      if (!found) fail(EXIT_UNSUPPORTED, "unsupported parameter '%s'", p);
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

static char *match_close(char *open, char oc, char cc) {
  int depth = 0;
  for (char *p = open; *p; p++) {
    if (*p == oc) depth++;
    else if (*p == cc && --depth == 0) return p;
  }
  fail(EXIT_BAD, "unbalanced '%c'", oc);
  return NULL;
}

/* Find the .entry called kernel, parse its parameters and body. */
static void parse_kernel(char *text, const char *kernel) {
  char *p = text;
  for (;;) {
    p = strstr(p, ".entry");
    if (!p) fail(EXIT_BAD, "kernel '%s' not found", kernel);
    char *q = p + 6;
    if (!isspace((unsigned char)*q)) {
      p = q;
      continue;
    }
    while (isspace((unsigned char)*q)) q++;
    char *name_end = q;
    while (isalnum((unsigned char)*name_end) || *name_end == '_' || *name_end == '$') name_end++;
    char name[MAXNAME];
    size_t nl = (size_t)(name_end - q);
    if (nl == 0 || nl >= sizeof name) fail(EXIT_BAD, "bad .entry name");
    memcpy(name, q, nl);
    name[nl] = 0;
    char *open = strchr(name_end, '(');
    if (!open) fail(EXIT_BAD, "no parameter list for '%s'", name);
    char *close = match_close(open, '(', ')');
    char *brace = strchr(close, '{');
    if (!brace) fail(EXIT_BAD, "no body for '%s'", name);
    char *body_end = match_close(brace, '{', '}');
    if (!strcmp(name, kernel)) {
      *close = 0;
      parse_params(open + 1);
      *body_end = 0;
      parse_body(brace + 1);
      for (int i = 0; i < ninst; i++) {
        Inst *in = &insts[i];
        if (in->op != OP_BRA) continue;
        in->target = -1;
        for (int k = 0; k < nlabels; k++)
          if (!strcmp(labels[k].name, in->label)) in->target = labels[k].index;
        if (in->target < 0) fail(EXIT_BAD, "unknown label '%s'", in->label);
      }
      return;
    }
    p = body_end + 1;
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

static void run_thread(const Launch *l, uint64_t *r, const uint64_t *tid, const uint64_t *ctaid,
                       uint64_t local_base, uint64_t frame) {
  int pc = 0;
  while (pc < ninst) {
    const Inst *in = &insts[pc];
    if (in->pred >= 0) {
      int v = r[in->pred] != 0;
      if (in->pred_neg) v = !v;
      if (!v) {
        pc++;
        continue;
      }
    }
    int next = pc + 1;
    uint64_t a = 0, b = 0, c = 0;
    if (in->op != OP_RET && in->op != OP_BRA && in->op != OP_LD) {
      a = value(l, r, tid, ctaid, local_base, in->a[1]);
      if (in->n > 2) b = value(l, r, tid, ctaid, local_base, in->a[2]);
      if (in->n > 3) c = value(l, r, tid, ctaid, local_base, in->a[3]);
    }
    int nbytes = in->ty.bits / 8;
    switch (in->op) {
      case OP_RET:
        return;
      case OP_BRA:
        next = in->target;
        break;
      case OP_LD: {
        uint64_t v;
        if (in->space == SPACE_PARAM) {
          v = l->params[in->a[1].idx];
        } else {
          uint64_t addr = r[in->a[1].idx] + (uint64_t)in->a[1].imm;
          v = load_bytes(mem_at(l, local_base, frame, addr, nbytes, in), nbytes);
        }
        r[in->a[0].idx] = canon(in->ty, v);
        break;
      }
      case OP_ST: {
        uint64_t addr = r[in->a[0].idx] + (uint64_t)in->a[0].imm;
        store_bytes(mem_at(l, local_base, frame, addr, nbytes, in), nbytes, a);
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
    pc = next;
  }
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

static void put_le32(uint8_t *m, uint32_t v) {
  for (int i = 0; i < 4; i++) m[i] = (uint8_t)(v >> (8 * i));
}

static uint32_t get_le32(const uint8_t *m) {
  return (uint32_t)m[0] | ((uint32_t)m[1] << 8) | ((uint32_t)m[2] << 16) | ((uint32_t)m[3] << 24);
}

static uint64_t align16(uint64_t v) { return (v + 15) / 16 * 16; }

static void usage(void) {
  fprintf(stderr,
          "usage: ptxi FILE.ptx KERNEL [--grid X[,Y[,Z]]] [--block X[,Y[,Z]]] "
          "ARG... [--dump K]...\n"
          "  ARG: ptr:COUNT[:iota=START] | s32:VALUE\n");
  exit(EXIT_BAD);
}

int main(int argc, char **argv) {
  if (argc < 3) usage();
  const char *file = argv[1];
  const char *kernel = argv[2];
  uint64_t grid[3] = {1, 1, 1}, block[3] = {1, 1, 1};

  int nargs = 0;
  int akind[MAXPARAM];  /* 0 ptr, 1 s32 */
  uint64_t acount[MAXPARAM], abuf[MAXPARAM];
  int has_iota[MAXPARAM];
  int64_t aval[MAXPARAM];
  int dumps[MAXPARAM], ndump = 0;

  for (int i = 3; i < argc; i++) {
    if (!strcmp(argv[i], "--grid") || !strcmp(argv[i], "--block")) {
      if (i + 1 >= argc) usage();
      uint64_t *dims = !strcmp(argv[i], "--grid") ? grid : block;
      parse_dims(argv[++i], dims);
    } else if (!strcmp(argv[i], "--dump")) {
      if (i + 1 >= argc || ndump == MAXPARAM) usage();
      dumps[ndump++] = atoi(argv[++i]);
    } else if (!strncmp(argv[i], "--", 2)) {
      usage();
    } else {
      if (nargs == MAXPARAM) usage();
      const char *a = argv[i];
      if (!strncmp(a, "ptr:", 4)) {
        akind[nargs] = 0;
        char *end;
        acount[nargs] = strtoull(a + 4, &end, 10);
        has_iota[nargs] = 0;
        if (*end == ':' && !strncmp(end, ":iota=", 6)) {
          has_iota[nargs] = 1;
          aval[nargs] = strtoll(end + 6, NULL, 10);
        } else if (*end) {
          usage();
        }
      } else if (!strncmp(a, "s32:", 4)) {
        akind[nargs] = 1;
        aval[nargs] = strtoll(a + 4, NULL, 0);
      } else usage();
      nargs++;
    }
  }

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
  parse_kernel(text, kernel);
  if (nparams != nargs) fail(EXIT_BAD, "kernel takes %d parameters, got %d arguments", nparams, nargs);

  /* Arena: the buffers, then one local frame per thread. */
  uint64_t cursor = 0;
  for (int i = 0; i < nargs; i++) {
    if (akind[i] == 0) {
      if (params[i].ty.bits != 64) fail(EXIT_BAD, "parameter %d is not a pointer", i);
      abuf[i] = cursor;
      cursor = align16(cursor + acount[i] * 4);
    } else {
      if (params[i].ty.bits != 32) fail(EXIT_BAD, "parameter %d is not a 32-bit scalar", i);
    }
  }
  uint64_t local_start = cursor;
  uint64_t frame = align16(frame_bytes);
  uint64_t nthreads = grid[0] * grid[1] * grid[2] * block[0] * block[1] * block[2];
  Launch L;
  memset(&L, 0, sizeof L);
  L.arena_size = local_start + frame * nthreads;
  L.arena = calloc(1, L.arena_size ? L.arena_size : 1);
  if (!L.arena) fail(EXIT_FAULT, "out of memory for %llu bytes", (unsigned long long)L.arena_size);
  for (int i = 0; i < 3; i++) {
    L.ntid[i] = block[i];
    L.nctaid[i] = grid[i];
  }
  for (int i = 0; i < nargs; i++) {
    if (akind[i] == 0) {
      L.params[i] = ARENA_BASE + abuf[i];
      L.bufaddr[L.nbuf] = ARENA_BASE + abuf[i];
      L.bufsize[L.nbuf] = acount[i] * 4;
      L.nbuf++;
      if (has_iota[i])
        for (uint64_t k = 0; k < acount[i]; k++) put_le32(L.arena + abuf[i] + 4 * k, (uint32_t)(aval[i] + (int64_t)k));
    } else {
      L.params[i] = (uint64_t)aval[i];
    }
  }

  /* Run every thread. Blocks in x-major order, threads within a block in x-major order. */
  uint64_t *r = calloc(nregs ? nregs : 1, sizeof *r);
  if (!r) fail(EXIT_FAULT, "out of memory");
  uint64_t tid[3], ctaid[3];
  uint64_t gid = 0;
  for (uint64_t cz = 0; cz < grid[2]; cz++)
    for (uint64_t cy = 0; cy < grid[1]; cy++)
      for (uint64_t cx = 0; cx < grid[0]; cx++)
        for (uint64_t tz = 0; tz < block[2]; tz++)
          for (uint64_t ty = 0; ty < block[1]; ty++)
            for (uint64_t tx = 0; tx < block[0]; tx++, gid++) {
              tid[0] = tx; tid[1] = ty; tid[2] = tz;
              ctaid[0] = cx; ctaid[1] = cy; ctaid[2] = cz;
              memset(r, 0, (nregs ? nregs : 1) * sizeof *r);
              uint64_t local_base = ARENA_BASE + local_start + gid * frame;
              run_thread(&L, r, tid, ctaid, local_base, frame);
            }

  for (int d = 0; d < ndump; d++) {
    int k = dumps[d];
    if (k < 0 || k >= nargs || akind[k] != 0) usage();
    for (uint64_t e = 0; e < acount[k]; e++) printf("%d\n", (int32_t)get_le32(L.arena + abuf[k] + 4 * e));
  }
  free(r);
  free(L.arena);
  free(text);
  return 0;
}
