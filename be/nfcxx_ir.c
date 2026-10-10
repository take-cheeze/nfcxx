/*
nfcxx_ir.c -- Path B stage 2: lowers the lowered EDG IL to the nfcxx mid-level IR and prints it.
The spec is docs/notes/pathb-stage2.md, which also describes the text form.

back_end() (nfcxx_be.c) calls nfcxx_ir_back_end() when NFCXX_PATHB_MODE=ir (scripts/pathb-dump --ir).
The IR is built in one pass from the in-memory lowered IL. Expression lowering prints the instructions
it needs before the statement that uses their results, so the printed order is the evaluation order.

Conventions when reading the output:
  %N          register: declared by (let %N TYPE RVALUE), reassigned by (set %N OPERAND)
  $"x"        address of a stack slot (locals, temporaries, parameter copies)
  @"x"        address of static storage (globals, static locals, string literals)
  &"f"        address of a function
  (const T V) and (null PTR) are constants
A value of aggregate type (struct, class, union, array) is represented by the address of an object that
holds it. Aggregates are never SSA values; they are copied with (copy BYTES DST SRC).
Anything not lowered prints an (unsupported KIND NAME) marker, counted by NFCXX_PATHB_STATS.
*/

#include "basic_hdrs.h"
#include "fe_common.h"
#include "il.h"
#include "types.h"
#include "const_ints.h"
#include "float_pt.h"
#include "il_to_str.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

USING_NAMESPACE_EDG

#include "nfcxx_be_int.h"
#include "nfcxx_names.h"

/* ================================================================ text buffers */

/* A growable text buffer. While it is begun, nf_out points at it. Buffers nest: begin saves the
   previous nf_out and end restores it. */
struct ir_buf {
  FILE *f;
  char *data;
  size_t len;
  FILE *saved;
};

static void ir_buf_open(ir_buf *b)
{
  b->f = open_memstream(&b->data, &b->len);
  if (b->f == NULL) {
    fprintf(stderr, "nfcxx_ir: open_memstream failed\n");
    abort();
  }
  b->saved = NULL;
}

static void ir_buf_begin(ir_buf *b)
{
  b->saved = nf_out;
  nf_out = b->f;
}

static void ir_buf_end(ir_buf *b)
{
  fflush(b->f);
  nf_out = b->saved;
}

/* Write the buffered text to out. */
static void ir_buf_write(ir_buf *b, FILE *out)
{
  fflush(b->f);
  if (b->len > 0) fwrite(b->data, 1, b->len, out);
}

static void ir_buf_close(ir_buf *b)
{
  if (b->f != NULL) fclose(b->f);
  b->f = NULL;
}

static char *ir_dup(const char *s)
{
  size_t n = strlen(s) + 1;
  char *p = (char *)malloc(n);
  if (p == NULL) abort();
  memcpy(p, s, n);
  return p;
}

/* printf into a new string. Strings are not freed: the back end runs once per process. */
static char *ir_fmt(const char *fmt, ...)
{
  char buf[512];
  va_list ap;
  int n;
  char *out;
  va_start(ap, fmt);
  n = vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  if (n < 0) abort();
  if ((size_t)n < sizeof buf) return ir_dup(buf);
  out = (char *)malloc((size_t)n + 1);
  if (out == NULL) abort();
  va_start(ap, fmt);
  (void)vsnprintf(out, (size_t)n + 1, fmt, ap);
  va_end(ap);
  return out;
}

/* ================================================================ type text */

/* IR text of a value type: unqualified, with pointer and aggregate pointees printed as in stage 1. */
static char *ir_capture_type(a_type_ptr t, int unqualified)
{
  ir_buf b;
  ir_buf_open(&b);
  ir_buf_begin(&b);
  if (unqualified) nf_put_unqualified_type(skip_typerefs(t));
  else nf_put_type(t);
  ir_buf_end(&b);
  ir_buf_close(&b);
  return b.data;
}

static char *ir_capture_constant(a_constant_ptr c)
{
  ir_buf b;
  ir_buf_open(&b);
  ir_buf_begin(&b);
  nf_put_constant(c);
  ir_buf_end(&b);
  ir_buf_close(&b);
  return b.data;
}

static int ir_is_aggregate(a_type_ptr t)
{
  a_type_ptr s;
  if (t == NULL) return 0;
  s = skip_typerefs(t);
  return s->kind == tk_class || s->kind == tk_struct || s->kind == tk_union || s->kind == tk_array;
}

static int ir_is_void(a_type_ptr t)
{
  return t != NULL && skip_typerefs(t)->kind == tk_void;
}

static int ir_is_pointer(a_type_ptr t)
{
  return t != NULL && skip_typerefs(t)->kind == tk_pointer;
}

static int ir_is_float(a_type_ptr t)
{
  return t != NULL && skip_typerefs(t)->kind == tk_float;
}

static int ir_is_integer(a_type_ptr t)
{
  return t != NULL && skip_typerefs(t)->kind == tk_integer;
}

static int ir_is_bool(a_type_ptr t)
{
  return ir_is_integer(t) && is_bool_type(skip_typerefs(t));
}

static int ir_is_signed(a_type_ptr t)
{
  return ir_is_integer(t) && !ir_is_bool(t) && is_signed_integral_type(skip_typerefs(t));
}

static int ir_is_volatile(a_type_ptr t)
{
  return t != NULL && (get_type_qualifiers(t) & TQ_VOLATILE) != 0;
}

/* Is the object that a pointer or array type designates volatile? EDG strips cv-qualifiers from the node type of
   an rvalue use (the lvalue-to-rvalue conversion), so a read of `*p` for `volatile int *p` has the type `int`.
   The qualifier has to be taken from the operand's type instead. */
static int ir_pointee_is_volatile(a_type_ptr t)
{
  if (t == NULL) return 0;
  t = skip_typerefs(t);
  if (t->kind == tk_pointer) return ir_is_volatile(t->variant.pointer.type);
  if (t->kind == tk_array) return ir_is_volatile(t->variant.array.element_type);
  return 0;
}

static unsigned long ir_size_of(a_type_ptr t)
{
  return (unsigned long)f_size_of_type(skip_typerefs(t));
}

/* Alignment in bytes of an object type (EDG's layout). Printed next to sizes of slots and globals. */
static unsigned long ir_align_of(a_type_ptr t)
{
  return (unsigned long)f_alignment_of_type(skip_typerefs(t));
}

/* IR text of an object type as a value: unqualified scalar, or the address for aggregates. */
static char *ir_valtext(a_type_ptr t)
{
  if (ir_is_aggregate(t)) return ir_fmt("(ptr %s)", ir_capture_type(t, 0));
  return ir_capture_type(t, 1);
}

/* IR text of the address of an object of type t. */
static char *ir_ptext(a_type_ptr t)
{
  return ir_fmt("(ptr %s)", ir_capture_type(t, 0));
}

/* 1 when signed + - * and unary - trap on overflow. Default 0: they wrap (see docs/notes/pathb-stage2.md).
   NFCXX_IR_OVERFLOW=trap selects the checked forms. */
static int ir_trap_overflow;

/* ================================================================ names and tables */

struct ir_ent {
  const void *key; /* entity pointer; NULL for entries made without one */
  char *raw;       /* name used for uniqueness; NULL for explicit mappings */
  char *op;        /* printed form: sigil"name", or an explicit operand */
};

/* The entries live in a growing array. Two open-addressing hash indexes (by entity, by raw name) make lookups
   O(1): a hosted program has tens of thousands of module-level names. The indexes are built lazily from the
   entries (ir_tab_sync), so code that resets a table with `t.n = 0` or appends an entry directly stays valid. */
struct ir_tab {
  ir_ent *e;
  int n, cap;
  int *hkey, *hraw; /* entry index + 1; 0 is empty */
  int hcap;         /* power of two, at least twice the entries */
  int hn;           /* entries already in the indexes */
};

static unsigned long ir_hash_ptr(const void *p)
{
  unsigned long x = (unsigned long)(size_t)p;
  x ^= x >> 33; x *= 0xff51afd7ed558ccdUL; x ^= x >> 33;
  return x;
}

static unsigned long ir_hash_str(const char *s)
{
  unsigned long h = 1469598103934665603UL;
  for (; *s != '\0'; s++) h = (h ^ (unsigned char)*s) * 1099511628211UL;
  return h;
}

/* Bring the indexes up to date with the entries: clear them when the table was reset, grow them, add the new
   entries. The first entry for a key or a name wins (as the linear scans it replaces). */
static void ir_tab_sync(ir_tab *t)
{
  int i;
  if (t->n < t->hn) {
    if (t->hkey != NULL) memset(t->hkey, 0, (size_t)t->hcap * sizeof(int));
    if (t->hraw != NULL) memset(t->hraw, 0, (size_t)t->hcap * sizeof(int));
    t->hn = 0;
  }
  if (t->hcap < 2 * (t->n + 1)) {
    int cap = t->hcap > 0 ? t->hcap : 1024;
    while (cap < 2 * (t->n + 1)) cap *= 2;
    free(t->hkey); free(t->hraw);
    t->hkey = (int *)calloc((size_t)cap, sizeof(int));
    t->hraw = (int *)calloc((size_t)cap, sizeof(int));
    if (t->hkey == NULL || t->hraw == NULL) abort();
    t->hcap = cap;
    t->hn = 0;
  }
  for (i = t->hn; i < t->n; i++) {
    unsigned long m = (unsigned long)t->hcap - 1, h;
    if (t->e[i].key != NULL) {
      for (h = ir_hash_ptr(t->e[i].key) & m; t->hkey[h] != 0 && t->e[t->hkey[h] - 1].key != t->e[i].key; h = (h + 1) & m) {}
      if (t->hkey[h] == 0) t->hkey[h] = i + 1;
    }
    if (t->e[i].raw != NULL) {
      for (h = ir_hash_str(t->e[i].raw) & m; t->hraw[h] != 0 && strcmp(t->e[t->hraw[h] - 1].raw, t->e[i].raw) != 0; h = (h + 1) & m) {}
      if (t->hraw[h] == 0) t->hraw[h] = i + 1;
    }
  }
  t->hn = t->n;
}

static ir_ent *ir_tab_push(ir_tab *t)
{
  ir_tab_sync(t); /* notices a reset (n = 0) before an entry is added over the old ones */
  if (t->n >= t->cap) {
    t->cap = t->cap > 0 ? 2 * t->cap : 1024;
    t->e = (ir_ent *)realloc(t->e, (size_t)t->cap * sizeof(ir_ent));
    if (t->e == NULL) abort();
  }
  return &t->e[t->n++];
}

/* Per function: stack slots and labels. Per module: globals, static objects and string data. */
static ir_tab ir_slots;
static ir_tab ir_labels;
static ir_tab ir_mod;

static int ir_raw_used(ir_tab *t, const char *raw)
{
  unsigned long m, h;
  ir_tab_sync(t);
  m = (unsigned long)t->hcap - 1;
  for (h = ir_hash_str(raw) & m; t->hraw[h] != 0; h = (h + 1) & m) {
    if (strcmp(t->e[t->hraw[h] - 1].raw, raw) == 0) return 1;
  }
  return 0;
}

/* Add an entry with a new name. Names are unique within the table: a clash gets a .N suffix. */
static const char *ir_tab_add(ir_tab *t, const void *key, const char *base, const char *sigil)
{
  char cand[300];
  int k = 0;
  ir_ent *en;
  if (base == NULL || base[0] == '\0') base = "tmp";
  (void)snprintf(cand, sizeof cand, "%s", base);
  while (ir_raw_used(t, cand)) {
    k++;
    (void)snprintf(cand, sizeof cand, "%s.%d", base, k);
  }
  en = ir_tab_push(t);
  en->key = key;
  en->raw = ir_dup(cand);
  en->op = ir_fmt("%s\"%s\"", sigil, cand);
  return en->op;
}

static const char *ir_tab_find(ir_tab *t, const void *key)
{
  unsigned long m, h;
  if (key == NULL) {
    int i;
    for (i = 0; i < t->n; i++) if (t->e[i].key == NULL) return t->e[i].op;
    return NULL;
  }
  ir_tab_sync(t);
  m = (unsigned long)t->hcap - 1;
  for (h = ir_hash_ptr(key) & m; t->hkey[h] != 0; h = (h + 1) & m) {
    if (t->e[t->hkey[h] - 1].key == key) return t->e[t->hkey[h] - 1].op;
  }
  return NULL;
}

/* The operand for an entity, created on first use. */
static const char *ir_tab_get(ir_tab *t, const void *key, const char *base, const char *sigil)
{
  const char *op = ir_tab_find(t, key);
  if (op != NULL) return op;
  return ir_tab_add(t, key, base, sigil);
}

/* An explicit operand for an entity (a parameter used in place). */
static void ir_tab_put(ir_tab *t, const void *key, const char *op)
{
  ir_ent *en = ir_tab_push(t);
  en->key = key;
  en->raw = NULL;
  en->op = ir_dup(op);
}

static const char *ir_name_or(const char *name, const char *fallback)
{
  return (name != NULL && name[0] != '\0') ? name : fallback;
}

/* Routine names. A routine's symbol is its name; the lowering also makes routines that have none (the helper that
   destroys an array with static storage, registered with __cxa_atexit). Those get a unique module-level name on first
   use, and every named routine's name is reserved up front (ir_reserve_routine_names), so that no static object or
   unnamed routine takes it. */
static void ir_reserve_name(const char *name)
{
  ir_ent *en;
  if (name == NULL || name[0] == '\0' || ir_raw_used(&ir_mod, name)) return;
  en = ir_tab_push(&ir_mod);
  en->key = NULL;
  en->raw = ir_dup(name);
  en->op = ir_fmt("&\"%s\"", name);
}

/* The symbol of a routine: its GNU asm label (`int f() __asm__("g")`, which glibc's string.h gives the C++ overloads
   of strchr and friends so that they are the C functions) if it has one, else its name. */
static const char *ir_rout_sym(a_routine_ptr r)
{
  if (has_gnu_routine_supp(r) && gnu_routine_supp(r)->asm_name != NULL && gnu_routine_supp(r)->asm_name[0] != '\0')
    return gnu_routine_supp(r)->asm_name;
  return r->source_corresp.name;
}

static void ir_weak_decl(a_routine_ptr r);

static const char *ir_rout_name(a_routine_ptr r)
{
  const char *n = ir_rout_sym(r);
  const char *op;
  char *s;
  if (n != NULL && n[0] != '\0') {
    if (r->is_weak) ir_weak_decl(r);
    return n;
  }
  op = ir_tab_get(&ir_mod, r, "__unnamed_fn", "&");
  s = ir_dup(op + 2);
  s[strlen(s) - 1] = '\0';
  return s;
}

/* ================================================================ statistics */

/* Node occurrences that were lowered (ok) and that were not (gap), per node class:
   0 operator, 1 statement, 2 expression node, 3 constant, 4 dynamic init. NFCXX_PATHB_STATS=1 prints them. */
#define IR_STAT_N 512
static unsigned long ir_stat_ok[5][IR_STAT_N];
static unsigned long ir_stat_gap[5][IR_STAT_N];

static void ir_note(int cls, int kind, int ok)
{
  if (cls < 0 || cls > 4 || kind < 0 || kind >= IR_STAT_N) return;
  if (ok) ir_stat_ok[cls][kind]++;
  else ir_stat_gap[cls][kind]++;
}

static const char *ir_kind_name(int cls, int kind)
{
  switch (cls) {
    case 0: return kind < (int)eok_last ? nfcxx_eok_name((an_expr_operator_kind)kind) : NULL;
    case 1: return nfcxx_stmk_name((a_statement_kind)kind);
    case 2: return nfcxx_enk_name((an_expr_node_kind)kind);
    case 3: return nfcxx_ck_name((a_constant_repr_kind)kind);
    case 4: return nfcxx_dik_name((a_dynamic_init_kind)kind);
    default: return NULL;
  }
}

static void ir_print_stats(void)
{
  static const char *cls_name[5] = { "op", "stmt", "node", "const", "init" };
  unsigned long ok_total = 0, gap_total = 0;
  int cls, k;
  for (cls = 0; cls < 5; cls++) {
    for (k = 0; k < IR_STAT_N; k++) {
      const char *nm;
      if (ir_stat_ok[cls][k] == 0 && ir_stat_gap[cls][k] == 0) continue;
      nm = ir_kind_name(cls, k);
      fprintf(stderr, "ir-stat %s %s lowered %lu unsupported %lu\n", cls_name[cls],
              nm != NULL ? nm : "?", ir_stat_ok[cls][k], ir_stat_gap[cls][k]);
      ok_total += ir_stat_ok[cls][k];
      gap_total += ir_stat_gap[cls][k];
    }
  }
  fprintf(stderr, "ir-stat total lowered %lu unsupported %lu\n", ok_total, gap_total);
}

/* ================================================================ values and emission */

/* A lowered value. s is the operand; t the EDG type (object type for addresses, NULL for bools);
   ty the IR type text of the operand; vol set for volatile lvalues. */
struct ir_val {
  char *s;
  a_type_ptr t;
  char *ty;
  int vol;
  /* A bit-field lvalue: s is the address of the storage unit (bf_unit bytes), the field occupies bf_width bits
     from bit bf_boff of the unit, t is the declared type. bf_unit == 0: not a bit-field. */
  unsigned bf_unit, bf_boff, bf_width;
  char *bf_ty; /* IR type text of the field value: the declared type with the field's own signedness */
};

static ir_val ir_mk_value(char *s, a_type_ptr t)
{
  ir_val v;
  v.s = s;
  v.t = t;
  v.ty = ir_valtext(t);
  v.vol = 0;
  v.bf_unit = v.bf_boff = v.bf_width = 0;
  v.bf_ty = NULL;
  return v;
}

static ir_val ir_mk_addr(char *s, a_type_ptr t, int vol)
{
  ir_val v;
  v.s = s;
  v.t = t;
  v.ty = ir_ptext(t);
  v.vol = vol;
  v.bf_unit = v.bf_boff = v.bf_width = 0;
  v.bf_ty = NULL;
  return v;
}

static ir_val ir_mk_bool(char *s)
{
  ir_val v;
  v.s = s;
  v.t = NULL;
  v.ty = (char *)"bool";
  v.vol = 0;
  v.bf_unit = v.bf_boff = v.bf_width = 0;
  v.bf_ty = NULL;
  return v;
}

static ir_val ir_mk_void(void)
{
  ir_val v;
  v.s = NULL;
  v.t = NULL;
  v.ty = (char *)"void";
  v.vol = 0;
  v.bf_unit = v.bf_boff = v.bf_width = 0;
  v.bf_ty = NULL;
  return v;
}

/* Per function: next register number, and the operand of the hidden result pointer (NULL if none). */
static int ir_nreg;
static char *ir_sret;
static a_type_ptr ir_ret_type;
static int ir_in_main;   /* the routine being lowered is main */
static a_routine_ptr ir_cur_rout;   /* the routine being lowered (thunks: enk_result_of_overriding_function) */

/* Indentation of the next expression-level line. Statement lowering sets it before lowering. */
static int ir_depth;

/* Module output (globals, data, functions) and per-function output (slots). */
static ir_buf ir_out_globals;
static ir_buf ir_out_types;   /* (abi-type ...) forms: the C ABI shape of aggregates passed or returned by value */
static ir_buf ir_out_data;
static ir_buf ir_out_funcs;
static ir_buf ir_slot_buf;

/* A routine declared __attribute__((weak)) and not defined in this translation unit is a weak reference: the symbol
   may be absent at link time and then reads as a null address. It is carried through as a top-level
   (declare "NAME" (weak)), printed once, when the module first refers to the routine. A defined weak routine
   instead has the marker (weak attr) on its (function ...). A weakref alias is not handled (it names another
   symbol). */
#define IR_WEAK_DECL_MAX 1024
static a_routine_ptr ir_weak_decls[IR_WEAK_DECL_MAX];
static int ir_weak_decl_n;
static void nf_put_quoted_name(const char *name);
static void ir_weak_decl(a_routine_ptr r)
{
  int i;
  ir_buf g;
  if (r->is_tls_init_alias && r->storage_class != sc_extern) return; /* defined here by ir_tls_init_alias */
  if (r->function_def_number != NULL_function_def_number || r->is_weakref || ir_weak_decl_n >= IR_WEAK_DECL_MAX) return;
  for (i = 0; i < ir_weak_decl_n; i++)
    if (ir_weak_decls[i] == r) return;
  ir_weak_decls[ir_weak_decl_n++] = r;
  ir_buf_open(&g);
  ir_buf_begin(&g);
  fputs("(declare ", nf_out);
  nf_put_quoted_name(r->source_corresp.name);
  fputs(" (weak))\n", nf_out);
  ir_buf_end(&g);
  ir_buf_write(&g, ir_out_globals.f);
  ir_buf_close(&g);
}

static void ir_line(int d, const char *text)
{
  int i;
  fputc('\n', nf_out);
  for (i = 0; i < d; i++) fputs("  ", nf_out);
  fputs(text, nf_out);
}

static void ir_emit(const char *text)
{
  ir_line(ir_depth, text);
}

static void ir_close(int n)
{
  while (n-- > 0) fputc(')', nf_out);
}

static char *ir_newreg(void)
{
  return ir_fmt("%%%d", ir_nreg++);
}

/* (let %N TY RHS) at ir_depth. Returns the register. */
static char *ir_let(const char *ty, const char *rhs)
{
  char *r = ir_newreg();
  ir_emit(ir_fmt("(let %s %s %s)", r, ty, rhs));
  return r;
}

static char *ir_zero(a_type_ptr t)
{
  if (ir_is_pointer(t)) return ir_fmt("(null %s)", ir_valtext(t));
  if (ir_is_float(t)) return ir_fmt("(const %s 0.0)", ir_valtext(t));
  return ir_fmt("(const %s 0)", ir_valtext(t));
}

/* A bool operand for any scalar value (a pointer or float compares with its zero). */
static char *ir_to_bool(ir_val v)
{
  if (v.t == NULL) return v.s; /* already a bool */
  if (ir_is_bool(v.t)) return v.s;
  return ir_let("bool", ir_fmt("(ne %s %s %s)", v.ty, v.s, ir_zero(v.t)));
}

static void ir_store(a_type_ptr t, const char *addr, const char *val, int vol)
{
  ir_emit(ir_fmt("(store%s %s %s %s)", vol ? ".v" : "", ir_valtext(t), addr, val));
}

static void ir_copy(a_type_ptr t, const char *dst, const char *src)
{
  ir_emit(ir_fmt("(copy %lu %s %s)", ir_size_of(t), dst, src));
}

/* A scalar loaded from an address. An aggregate is already its address. */
static ir_val ir_load(ir_val a)
{
  char *r;
  if (a.bf_unit != 0) { /* bit-field: read the storage unit and extract the field */
    r = ir_let(a.bf_ty, ir_fmt("(bfload%s %s %u %s %u %u)", a.vol ? ".v" : "", a.bf_ty, a.bf_unit, a.s, a.bf_boff,
                               a.bf_width));
    return ir_mk_value(r, a.t);
  }
  if (ir_is_aggregate(a.t)) return ir_mk_value(a.s, a.t);
  /* A function lvalue (`*fp`, a reference to a function): its value is its address, nothing is read. */
  if (a.t != NULL && skip_typerefs(a.t)->kind == tk_routine) return ir_mk_addr(a.s, a.t, 0);
  r = ir_let(ir_valtext(a.t), ir_fmt("(load%s %s %s)", a.vol ? ".v" : "", ir_valtext(a.t), a.s));
  return ir_mk_value(r, a.t);
}

/* The same address viewed as an address of type to (a bitcast when the IR types differ). */
static ir_val ir_retype_addr(ir_val a, a_type_ptr to, int vol)
{
  char *want = ir_ptext(to);
  if (strcmp(want, a.ty) == 0) return ir_mk_addr(a.s, to, vol);
  return ir_mk_addr(ir_let(want, ir_fmt("(bitcast %s %s)", want, a.s)), to, vol);
}

/* Address of the subobject at byte offset off of base (an address operand), of type t. */
static ir_val ir_subobject(const char *base, unsigned long off, a_type_ptr t, int vol)
{
  if (off == 0) return ir_mk_addr((char *)base, t, vol);
  return ir_mk_addr(ir_let(ir_ptext(t), ir_fmt("(offset %s %lu)", base, off)), t, vol);
}

static char *ir_size_text(a_type_ptr t);

/* Address of element idx of an array whose element type is elem. */
static ir_val ir_elem_addr(const char *base, const char *idx, a_type_ptr elem, int vol)
{
  char *sz = ir_size_text(elem);
  return ir_mk_addr(ir_let(ir_ptext(elem), ir_fmt("(index %s %s %s)", base, idx, sz)), elem, vol);
}

/* Pointer value base + idx * sizeof(elem), of pointer type ptr_t. */
static ir_val ir_ptr_add(const char *base, const char *idx, a_type_ptr ptr_t, a_type_ptr elem)
{
  char *sz = ir_size_text(elem);
  char *r = ir_let(ir_valtext(ptr_t), ir_fmt("(index %s %s %s)", base, idx, sz));
  return ir_mk_value(r, ptr_t);
}

static void ir_global_print(a_variable_ptr var, const char *name);

/* Thread storage duration: thread_local sets is_thread_local; the GNU __thread only sets DM_THREAD in decl_modifiers
   (il_def.h: "Not used for variables declared with __thread"). */
static int ir_var_is_thread(a_variable_ptr var)
{
  return (var->is_thread_local || (var->decl_modifiers & DM_THREAD) != 0) &&
         var_has_static_or_thread_storage_duration(var);
}

/* The symbol of a static object: its GNU asm label (`extern int x __asm__("y")`) if it has one, else its name. */
static const char *ir_var_sym(a_variable_ptr var)
{
  if (var->asm_name_is_valid && var->asm_name_or_reg.name != NULL && var->asm_name_or_reg.name[0] != '\0')
    return var->asm_name_or_reg.name;
  return var->source_corresp.name;
}

/* Static object (global, static local, or string data) operand; the module entry is printed on first use. */
static const char *ir_global_op(a_variable_ptr var)
{
  int fresh = ir_tab_find(&ir_mod, var) == NULL;
  const char *op = ir_tab_get(&ir_mod, var, ir_name_or(ir_var_sym(var), "tmp"), "@");
  if (fresh) ir_global_print(var, op + 1);
  return op;
}

/* Stack slot operand for an object of the current function, created on first use. */
/* al: the object's own alignment (alignas / aligned attribute included), or 0 for the type's. */
static const char *ir_slot_op(const void *key, const char *base, a_type_ptr t, unsigned long al)
{
  int fresh = ir_tab_find(&ir_slots, key) == NULL;
  const char *op = ir_tab_get(&ir_slots, key, base, "$");
  if (fresh) {
    ir_buf_begin(&ir_slot_buf);
    fprintf(nf_out, "\n  (slot %s ", op + 1);
    nf_put_type(t);
    fprintf(nf_out, " %lu %lu)", ir_size_of(t), al != 0 ? al : ir_align_of(t));
    ir_buf_end(&ir_slot_buf);
  }
  return op;
}

/* A fresh anonymous stack slot for an aggregate temporary. */
static ir_val ir_temp(a_type_ptr t)
{
  const char *op = ir_tab_add(&ir_slots, NULL, "tmp", "$");
  ir_buf_begin(&ir_slot_buf);
  fprintf(nf_out, "\n  (slot %s ", op + 1);
  nf_put_type(t);
  fprintf(nf_out, " %lu %lu)", ir_size_of(t), ir_align_of(t));
  ir_buf_end(&ir_slot_buf);
  return ir_mk_addr((char *)op, t, 0);
}

/* Address of a variable: the operand bound to it (a parameter), else its slot or static object. */
static ir_val ir_vla_addr(a_variable_ptr var, a_type_ptr t, int vol);

static ir_val ir_var_addr(a_variable_ptr var, a_type_ptr t, int vol)
{
  const char *op;
#if !LOWER_VARIABLE_LENGTH_ARRAYS
  if (var->is_vla) return ir_vla_addr(var, t, vol); /* else the lowered VLA variable is an ordinary pointer */
#endif
  op = ir_tab_find(&ir_slots, var);
  if (op != NULL) return ir_mk_addr((char *)op, t, vol);
  if (var_has_static_or_thread_storage_duration(var)) {
    return ir_mk_addr((char *)ir_global_op(var), t, vol);
  }
  return ir_mk_addr((char *)ir_slot_op(var, ir_name_or(var->source_corresp.name, "tmp"), var->type, (unsigned long)alignment_of_variable(var)), t, vol);
}

/* Marker for a node that is not lowered. The value of the marker has the type t (void: a statement). */
static ir_val ir_gap(a_type_ptr t, const char *what, int cls, int kind)
{
  ir_note(cls, kind, 0);
  if (t == NULL || ir_is_void(t)) {
    ir_emit(ir_fmt("(unsupported %s)", what));
    return ir_mk_void();
  }
  return ir_mk_value(ir_let(ir_valtext(t), ir_fmt("(unsupported %s)", what)), t);
}

/* ================================================================ variable-length arrays and bit-fields */

static void ir_stmt(a_statement_ptr s, int d);
static ir_val ir_rval(an_expr_node_ptr e);

/* The function scope being lowered (its vla_dimensions list finds the dimension variable of a VLA type). */
static a_scope_ptr ir_cur_scope;

/* 1 when the array type t, or an array it is made of, has a run-time bound. */
static int ir_type_is_variable(a_type_ptr t)
{
  a_type_ptr s = skip_typerefs(t);
  while (s->kind == tk_array) {
    if (s->variant.array.is_vla || s->variant.array.is_variable_size_array) return 1;
    s = skip_typerefs(s->variant.array.element_type);
  }
  return 0;
}

/* The a_vla_dimension of a VLA array type (the original one for a compiler-generated copy), or NULL. */
static a_vla_dimension_ptr ir_find_vla_dim(a_type_ptr s)
{
  a_vla_dimension_ptr d;
  if (ir_cur_scope == NULL) return NULL;
  for (d = ir_cur_scope->vla_dimensions; d != NULL; d = d->next) {
    if (d->type == s) return d->original_dimension != NULL ? d->original_dimension : d;
  }
  return NULL;
}

/* Operand (a register or a constant) of type unsigned_long holding sizeof(t). A VLA type computes
   count * sizeof(element) from the dimension variables that the stmk_set_vla_size statements set. */
static char *ir_size_operand(a_type_ptr t)
{
  a_type_ptr s = skip_typerefs(t);
  char *esz, *cnt;
  if (!ir_type_is_variable(t)) return ir_fmt("(const unsigned_long %lu)", ir_size_of(t));
  esz = ir_size_operand(s->variant.array.element_type);
  if (s->variant.array.is_vla) {
#if LOWER_VARIABLE_LENGTH_ARRAYS
    /* The front end lowers VLA types (setup-pathb.sh sets the macro), so none reaches the IR. */
    ir_note(2, enk_sizeof, 0);
    return ir_let("unsigned_long", "(unsupported vla-dimension)");
#else
    a_vla_dimension_ptr d = ir_find_vla_dim(s);
    ir_val dv;
    if (d == NULL || d->dimension_variable == NULL) {
      ir_note(2, enk_sizeof, 0);
      return ir_let("unsigned_long", "(unsupported vla-dimension)");
    }
    dv = ir_load(ir_var_addr(d->dimension_variable, d->dimension_variable->type, 0));
    cnt = ir_let("unsigned_long", ir_fmt("(iconv unsigned_long %s)", dv.s));
#endif
  } else if (!s->variant.array.is_variable_size_array) {
    cnt = ir_fmt("(const unsigned_long %lu)", (unsigned long)s->variant.array.variant.number_of_elements);
  } else {
    ir_note(2, enk_sizeof, 0);
    return ir_let("unsigned_long", "(unsupported vla-bound)");
  }
  return ir_let("unsigned_long", ir_fmt("(wmul unsigned_long %s %s)", cnt, esz));
}

/* The SIZE field of index and pdiff: a number, or a register when the element type is a VLA type. */
static char *ir_size_text(a_type_ptr t)
{
  if (!ir_type_is_variable(t)) return ir_fmt("%lu", ir_size_of(t));
  return ir_size_operand(t);
}

/* The slot that holds the address of a VLA variable's storage (see vlaalloc). Created on first use. */
static const char *ir_vla_slot(a_variable_ptr var)
{
  const void *key = (const char *)var + 1; /* a key of its own: the variable itself may be bound elsewhere */
  int fresh = ir_tab_find(&ir_slots, key) == NULL;
  const char *op = ir_tab_get(&ir_slots, key, ir_name_or(var->source_corresp.name, "vla"), "$");
  if (fresh) {
    ir_buf_begin(&ir_slot_buf);
    fprintf(nf_out, "\n  (slot %s (ptr ", op + 1);
    nf_put_type(var->type);
    fputs(") 8 8)", nf_out);
    ir_buf_end(&ir_slot_buf);
  }
  return op;
}

/* The address of a VLA's storage: loaded from its slot. */
static ir_val ir_vla_addr(a_variable_ptr var, a_type_ptr t, int vol)
{
  const char *slot = ir_vla_slot(var);
  char *pt = ir_ptext(t);
  return ir_mk_addr(ir_let(pt, ir_fmt("(load %s %s)", pt, slot)), t, vol);
}

/* stmk_vla_decl of a VLA variable: allocate count * sizeof(base element) bytes of dynamic stack storage.
   The count is the variable that EDG's lowering assigned just before this statement. */
static void ir_vla_alloc(a_variable_ptr var)
{
  a_variable_ptr cv = var->vla_element_count_variable;
  a_type_ptr base = skip_typerefs(var->type);
  const char *slot;
  ir_val c;
  char *n, *b;
  if (cv == NULL) {
    ir_note(1, stmk_vla_decl, 0);
    ir_emit("(unsupported stmt vla_decl)");
    return;
  }
  while (base->kind == tk_array) base = skip_typerefs(base->variant.array.element_type);
  slot = ir_vla_slot(var);
  c = ir_load(ir_var_addr(cv, cv->type, 0));
  n = ir_let("unsigned_long", ir_fmt("(iconv unsigned_long %s)", c.s));
  b = ir_let("unsigned_long", ir_fmt("(wmul unsigned_long %s (const unsigned_long %lu))", n, ir_size_of(base)));
  ir_emit(ir_fmt("(vlaalloc %s %s)", slot, b));
  ir_note(1, stmk_vla_decl, 1);
}

/* Storage unit of the bit-field f inside a parent object of parent_size bytes. The unit is the declared type's
   size when the field fits in the aligned unit of that size inside the parent (the usual case), else the smallest
   power of two (1, 2, 4, 8 bytes) at an aligned or end-of-parent position that holds the field. 0: no unit. */
static int ir_bf_layout(a_field_ptr f, unsigned long parent_size, unsigned long *uoff, unsigned *unit, unsigned *boff)
{
  unsigned long start = (unsigned long)f->offset * 8UL + (unsigned long)f->offset_bit_remainder;
  unsigned long w = (unsigned long)f->bit_size;
  unsigned long cand[5], u, base;
  int n = 0, i;
  if (w == 0 || w > 64) return 0;
  cand[n++] = ir_size_of(f->type);
  cand[n++] = 1;
  cand[n++] = 2;
  cand[n++] = 4;
  cand[n++] = 8;
  for (i = 0; i < n; i++) {
    u = cand[i];
    if ((u != 1 && u != 2 && u != 4 && u != 8) || u * 8 < w) continue;
    base = start / (8 * u) * u;
    if (start + w > (base + u) * 8 || base + u > parent_size) {
      if (parent_size < u) continue;
      base = parent_size - u; /* slide the window to the end of the parent */
      if (base * 8 > start || start + w > (base + u) * 8) continue;
    }
    *uoff = base;
    *unit = (unsigned)u;
    *boff = (unsigned)(start - base * 8);
    return 1;
  }
  return 0;
}

/* The IR type text of a bit-field value: t's own text, or its counterpart of the other signedness when the field
   differs (an enumeration whose bit-field is unsigned is printed as int). NULL when there is no such type. */
static char *ir_bf_type(a_type_ptr t, int want_signed)
{
  char *txt = ir_valtext(t);
  const char *base = txt;
  if (!ir_is_integer(t) || ir_is_bool(t)) return want_signed ? NULL : txt;
  if (ir_is_signed(t) == want_signed) return txt;
  if (strncmp(base, "unsigned_", 9) == 0) base += 9;
  else if (strncmp(base, "signed_", 7) == 0) base += 7;
  if (!want_signed) return ir_fmt("unsigned_%s", base);
  return strcmp(base, "char") == 0 ? ir_dup("signed_char") : ir_dup(base);
}

/* Lvalue of the bit-field f of the object at base (type parent), declared type t. */
static ir_val ir_bf_lval(const char *base, a_field_ptr f, a_type_ptr parent, a_type_ptr t, int vol)
{
  unsigned long uoff = 0;
  unsigned unit = 0, boff = 0;
  ir_val a;
  char *bty = ir_bf_type(t, f->bit_field_is_signed != 0);
  if (bty == NULL || !ir_bf_layout(f, ir_size_of(parent), &uoff, &unit, &boff)) {
    /* EDG truncates a width larger than the declared type (with a warning), so only a 128-bit declared type
       (unsigned __int128 f : 100) can be wider than 64 bits; the emitter has no 128-bit type either way. */
    ir_val v = ir_gap(t, f->bit_size > 64 ? "bit-field-wider-than-64-bits" : "bit-field-layout", 0, (int)eok_dot_field);
    return ir_mk_addr(v.s, t, vol);
  }
  a = ir_subobject(base, uoff, t, vol);
  a.bf_unit = unit;
  a.bf_boff = boff;
  a.bf_width = (unsigned)f->bit_size;
  a.bf_ty = bty;
  return a;
}

/* Store val into the lvalue lhs: a plain store, or a read-modify-write of the bit-field's storage unit. */
static void ir_store_lv(ir_val lhs, const char *val)
{
  if (lhs.bf_unit != 0) {
    ir_emit(ir_fmt("(bfstore%s %s %u %s %u %u %s)", lhs.vol ? ".v" : "", lhs.bf_ty, lhs.bf_unit, lhs.s,
                   lhs.bf_boff, lhs.bf_width, val));
    return;
  }
  ir_store(lhs.t, lhs.s, val, lhs.vol);
}

/* The value of an assignment-like expression on the lvalue lhs whose new value is nv: a bit-field stores only
   its low bits (and sign-extends on reading), so a used result is read back. */
static ir_val ir_assign_result(an_expr_node_ptr e, ir_val lhs, ir_val nv)
{
  if (lhs.bf_unit != 0 && !e->result_is_not_used) return ir_load(lhs);
  return nv;
}

/* GNU statement expression ({ ... }): the statements run inline, and the value is that of the last one when
   it is an expression statement (otherwise the expression is void). */
static ir_val ir_stmt_expr(an_expr_node_ptr e)
{
  a_statement_ptr blk = e->variant.statement, s, res = NULL;
  int d = ir_depth;
  ir_val v = ir_mk_void();
  ir_note(2, enk_statement, 1);
  if (blk == NULL) return v;
  if (blk->kind != stmk_block) {
    ir_stmt(blk, d);
    ir_depth = d;
    return v;
  }
  /* The statement that produces the value: normally the last one. A class result that IL lowering copies out of the
     block with a copy constructor is a nested statement expression in an ordinary expression statement, followed by
     the destructor calls of the block's locals, so the value statement is then the last class-typed one. */
  for (s = blk->variant.block.statements; s != NULL; s = s->next) {
    if ((s->kind == stmk_stmt_expr_result || s->kind == stmk_expr) && s->expr != NULL && !ir_is_void(s->expr->type) &&
        (s->next == NULL || (ir_is_aggregate(e->type) && s->expr->kind == enk_statement))) {
      res = s;
    }
  }
  for (s = blk->variant.block.statements; s != NULL; s = s->next) {
    if (s == res) {
      ir_note(1, (int)s->kind, 1);
      ir_depth = d;
      v = ir_rval(s->expr);
    } else {
      ir_stmt(s, d);
    }
  }
  ir_depth = d;
  if (v.s == NULL && !ir_is_void(e->type)) return ir_gap(e->type, "statement-expression-value", 2, (int)enk_statement);
  return v;
}

/* ================================================================ constants */

/* A scalar constant operand of type t. */
static ir_val ir_const_value(a_constant_ptr c, a_type_ptr t)
{
  if (c->kind == ck_integer && ir_is_pointer(t)) return ir_mk_value(ir_zero(t), t);
  return ir_mk_value(ir_fmt("(const %s %s)", ir_valtext(t), ir_capture_constant(c)), t);
}

/* Static storage for a string literal, emitted on first use. */
static const char *ir_string_data(a_constant_ptr c)
{
  int fresh = ir_tab_find(&ir_mod, c) == NULL;
  const char *op = ir_tab_get(&ir_mod, c, "const", "@");
  if (fresh) {
    ir_buf_begin(&ir_out_data);
    fprintf(nf_out, "(data %s ", op + 1);
    nf_put_type(c->type);
    fputc(' ', nf_out);
    nf_put_constant(c);
    fputs(")\n", nf_out);
    ir_buf_end(&ir_out_data);
  }
  return op;
}

/* An address constant of type t. */
static ir_val ir_address_const(a_constant_ptr c, a_type_ptr t)
{
  const char *base = NULL;
  unsigned long off = (unsigned long)c->variant.address.offset;
  switch (c->variant.address.kind) {
    case abk_routine:
      if (off == 0) {
        ir_note(3, ck_address, 1);
        return ir_mk_value(ir_fmt("&\"%s\"", ir_rout_name(c->variant.address.variant.routine)),
                           t);
      }
      break;
    case abk_variable:
      base = ir_global_op(c->variant.address.variant.variable);
      break;
    case abk_constant:
      if (c->variant.address.variant.constant->kind == ck_string) {
        base = ir_string_data(c->variant.address.variant.constant);
      }
      break;
    default:
      break;
  }
  if (base == NULL) {
    return ir_gap(t, ir_fmt("op-address %d", (int)c->variant.address.kind), 3, ck_address);
  }
  ir_note(3, ck_address, 1);
  if (off == 0) return ir_mk_value((char *)base, t);
  return ir_mk_value(ir_let(ir_valtext(t), ir_fmt("(offset %s %lu)", base, off)), t);
}

/* A constant of type t (an expression constant or an initializer element). */
static ir_val ir_constant(a_constant_ptr c, a_type_ptr t)
{
  switch (c->kind) {
    case ck_integer:
      ir_note(3, ck_integer, 1);
      return ir_const_value(c, t);
    case ck_float:
      ir_note(3, ck_float, 1);
      return ir_const_value(c, t);
    case ck_address:
      return ir_address_const(c, t);
    case ck_string:
      ir_note(3, ck_string, 1);
      return ir_mk_addr((char *)ir_string_data(c), t, 0);
    case ck_void: /* `(void)0` as a constant expression: no value */
      ir_note(3, ck_void, 1);
      return ir_mk_void();
    default:
      return ir_gap(t, ir_fmt("const %s", nfcxx_ck_name(c->kind) != NULL ? nfcxx_ck_name(c->kind) : "?"), 3,
                    (int)c->kind);
  }
}

/* ================================================================ expressions */

static an_expr_node_ptr ir_operand(an_expr_node_ptr e, int i)
{
  an_expr_node_ptr p = e->variant.operation.operands;
  while (p != NULL && i > 0) {
    p = p->next;
    i--;
  }
  return p;
}

static ir_val ir_rval(an_expr_node_ptr e);
static ir_val ir_lval(an_expr_node_ptr e);
static ir_val ir_rval_op(an_expr_node_ptr e);
static ir_val ir_vaarg_aggregate(an_expr_node_ptr e, const char *ap);
static ir_val ir_lval_op(an_expr_node_ptr e);
static ir_val ir_roof(an_expr_node_ptr e);

/* Set by the address-of operator while it lowers its operand when that is `p->field` or `*p`: the address of a
   member or of an object through a pointer reads no memory, so a null p is not a trap. EDG lowers the conversion of
   a pointer to a derived class to a pointer to its base as `&p->__b_N`, and that has to give a null base pointer
   for a null p (std::map's node pointers are null all the time). ir_lval_op reads and clears it on entry, so the
   operands of the operand are checked as usual. */
static int ir_addr_only;

static char *ir_valist_addr(an_expr_node_ptr n);

/* Pointer that may be null: emit (nonnull P) unless the operand is known to be an address. */
static void ir_nonnull(an_expr_node_ptr src, ir_val p)
{
  if (src != NULL && src->kind == enk_operation &&
      (src->variant.operation.kind == eok_array_to_pointer || src->variant.operation.kind == eok_address_of)) {
    return;
  }
  ir_emit(ir_fmt("(nonnull %s)", p.s));
}

static ir_val ir_rval(an_expr_node_ptr e)
{
  if (e == NULL) return ir_mk_void();
  switch (e->kind) {
    case enk_constant:
      ir_note(2, enk_constant, 1);
      return ir_constant(e->variant.constant.ptr, e->type);
    case enk_routine:
      ir_note(2, enk_routine, 1);
      return ir_mk_value(ir_fmt("&\"%s\"", ir_rout_name(e->variant.routine.ptr)), e->type);
    case enk_variable:
      ir_note(2, enk_variable, 1);
      return ir_load(ir_lval(e));
    case enk_object_lifetime:
      ir_note(2, enk_object_lifetime, 1);
      return ir_rval(e->variant.object_lifetime.expr);
    case enk_statement:
      return ir_stmt_expr(e);
    case enk_sizeof: {
      /* sizeof is folded to a constant except for a variable-length array (a type or an expression of VLA type). */
      a_type_ptr st = e->variant.sizeof_info.is_type ? e->variant.sizeof_info.variant.type
                                                     : e->variant.sizeof_info.variant.expr->type;
      char *sz;
      if (st == NULL) return ir_gap(e->type, "sizeof", 2, (int)enk_sizeof);
      if (!ir_type_is_variable(st)) {
        ir_note(2, enk_sizeof, 1);
        return ir_mk_value(ir_fmt("(const %s %lu)", ir_valtext(e->type), ir_size_of(st)), e->type);
      }
      sz = ir_size_operand(st);
      ir_note(2, enk_sizeof, 1);
      if (ir_is_integer(e->type) && ir_size_of(e->type) == 8 && !ir_is_signed(e->type)) return ir_mk_value(sz, e->type);
      return ir_mk_value(ir_let(ir_valtext(e->type), ir_fmt("(iconv %s %s)", ir_valtext(e->type), sz)), e->type);
    }
    case enk_operation:
      return ir_rval_op(e);
    case enk_result_of_overriding_function:
      return ir_roof(e);
    default:
      return ir_gap(e->type, ir_fmt("node %s", nfcxx_enk_name(e->kind) != NULL ? nfcxx_enk_name(e->kind) : "?"),
                    2, (int)e->kind);
  }
}

/* The address of an lvalue (or of an aggregate value). */
static ir_val ir_lval(an_expr_node_ptr e)
{
  if (e == NULL) return ir_mk_void();
  if (e->kind == enk_variable) {
    ir_note(2, enk_variable, 1);
    return ir_var_addr(e->variant.variable.ptr, e->type,
                       ir_is_volatile(e->type) || ir_is_volatile(e->variant.variable.ptr->type));
  }
  if (e->kind == enk_object_lifetime) return ir_lval(e->variant.object_lifetime.expr);
  if (e->kind == enk_operation) return ir_lval_op(e);
  if (e->kind == enk_routine) {
    /* A function designator (the operand of & outside a constant expression, for example `throw &f`): its address. */
    ir_note(2, enk_routine, 1);
    return ir_mk_addr(ir_fmt("&\"%s\"", ir_name_or(ir_rout_sym(e->variant.routine.ptr), "fn")), e->type, 0);
  }
  if (ir_is_aggregate(e->type)) return ir_rval(e);
  return ir_gap(e->type, "lvalue", 2, (int)e->kind);
}

/* Arithmetic mnemonic for an operator on type t, or NULL when it is not lowered. */
static const char *ir_arith_name(an_expr_operator_kind k, a_type_ptr t)
{
  int fl = ir_is_float(t);
  int checked = ir_is_signed(t) && ir_trap_overflow;
  switch (k) {
    case eok_add: return fl ? "fadd" : checked ? "cadd" : "wadd";
    case eok_subtract: return fl ? "fsub" : checked ? "csub" : "wsub";
    case eok_multiply: return fl ? "fmul" : checked ? "cmul" : "wmul";
    case eok_divide: return fl ? "fdiv" : "cdiv";
    case eok_remainder: return fl ? NULL : "crem";
    case eok_shiftl: return fl ? NULL : "cshl";
    case eok_shiftr: return fl ? NULL : "cshr";
    case eok_and: return fl ? NULL : "and";
    case eok_or: return fl ? NULL : "or";
    case eok_xor: return fl ? NULL : "xor";
    default: return NULL;
  }
}

/* Arithmetic of kind k on values a and b; the result has type rt. NULL when not lowered. */
static ir_val ir_arith(an_expr_operator_kind k, a_type_ptr rt, ir_val a, ir_val b, int *ok)
{
  const char *mn = ir_arith_name(k, rt);
  *ok = mn != NULL;
  if (mn == NULL) return ir_mk_void();
  return ir_mk_value(ir_let(ir_valtext(rt), ir_fmt("(%s %s %s %s)", mn, ir_valtext(rt), a.s, b.s)), rt);
}

/* Comparison: eq/ne by operand type; lt/le get a signedness suffix (.s, .u, .f). gt and ge swap operands. */
static ir_val ir_compare(an_expr_operator_kind k, ir_val a, ir_val b)
{
  const char *suffix = "u";
  const char *op;
  ir_val x = a, y = b;
  if (ir_is_float(a.t)) suffix = "f";
  else if (ir_is_signed(a.t)) suffix = "s";
  switch (k) {
    case eok_eq: op = "eq"; break;
    case eok_ne: op = "ne"; break;
    case eok_lt: op = "lt"; break;
    case eok_le: op = "le"; break;
    case eok_gt: op = "lt"; x = b; y = a; break;
    default: op = "le"; x = b; y = a; break; /* eok_ge */
  }
  if (k == eok_eq || k == eok_ne) {
    return ir_mk_bool(ir_let("bool", ir_fmt("(%s %s %s %s)", op, a.ty, x.s, y.s)));
  }
  return ir_mk_bool(ir_let("bool", ir_fmt("(%s.%s %s %s %s)", op, suffix, a.ty, x.s, y.s)));
}

static ir_val ir_cast(an_expr_node_ptr e);
static ir_val ir_call(an_expr_node_ptr e);
static ir_val ir_question(an_expr_node_ptr e);
static ir_val ir_logic(an_expr_node_ptr e, int is_and);
static ir_val ir_assign(an_expr_node_ptr e, int want_addr);
static ir_val ir_incr(an_expr_node_ptr e, int pre, int inc);

/* Map a compound assignment to its binary operator. */
static an_expr_operator_kind ir_compound_base(an_expr_operator_kind k, int *ok)
{
  *ok = 1;
  switch (k) {
    case eok_add_assign: return eok_add;
    case eok_subtract_assign: return eok_subtract;
    case eok_multiply_assign: return eok_multiply;
    case eok_divide_assign: return eok_divide;
    case eok_remainder_assign: return eok_remainder;
    case eok_shiftl_assign: return eok_shiftl;
    case eok_shiftr_assign: return eok_shiftr;
    case eok_and_assign: return eok_and;
    case eok_or_assign: return eok_or;
    case eok_xor_assign: return eok_xor;
    case eok_padd_assign: return eok_padd;
    case eok_psubtract_assign: return eok_psubtract;
    default: *ok = 0; return k;
  }
}

/* Lvalue-valued operators, as addresses. */
static ir_val ir_lval_op(an_expr_node_ptr e)
{
  int addr_only = ir_addr_only;
  an_expr_operator_kind k = e->variant.operation.kind;
  ir_addr_only = 0;
  an_expr_node_ptr a0 = ir_operand(e, 0);
  an_expr_node_ptr a1 = ir_operand(e, 1);
  int vol = ir_is_volatile(e->type);
  switch (k) {
    case eok_dot_field: {
      ir_val base;
      an_expr_node_ptr fe = a1;
      if (fe == NULL || fe->kind != enk_field) break;
      ir_note(0, k, 1);
      base = ir_lval(a0);
      /* a member of a volatile object is volatile, and so is a volatile member */
      vol = vol || base.vol || ir_is_volatile(fe->variant.field.ptr->type);
      if (fe->variant.field.ptr->is_bit_field) return ir_bf_lval(base.s, fe->variant.field.ptr, a0->type, e->type, vol);
      return ir_subobject(base.s, (unsigned long)fe->variant.field.ptr->offset, e->type, vol);
    }
    case eok_points_to_field: {
      ir_val p;
      an_expr_node_ptr fe = a1;
      if (fe == NULL || fe->kind != enk_field) break;
      ir_note(0, k, 1);
      p = ir_rval(a0);
      if (!addr_only) ir_nonnull(a0, p);
      vol = vol || ir_pointee_is_volatile(a0->type) || ir_is_volatile(fe->variant.field.ptr->type);
      if (fe->variant.field.ptr->is_bit_field) {
        return ir_bf_lval(p.s, fe->variant.field.ptr, skip_typerefs(a0->type)->variant.pointer.type, e->type, vol);
      }
      return ir_subobject(p.s, (unsigned long)fe->variant.field.ptr->offset, e->type, vol);
    }
    case eok_subscript: {
      ir_val base, idx;
      if (a0 == NULL || a1 == NULL) break;
      ir_note(0, k, 1);
      if (ir_is_aggregate(a0->type)) base = ir_lval(a0);
      else base = ir_rval(a0);
      idx = ir_rval(a1);
      /* A subscript of array_to_pointer(array N) is checked against N. Pointers carry no length. */
      if (a0->kind == enk_operation && a0->variant.operation.kind == eok_array_to_pointer) {
        an_expr_node_ptr arr = ir_operand(a0, 0);
        if (arr != NULL && arr->type != NULL && skip_typerefs(arr->type)->kind == tk_array &&
            !skip_typerefs(arr->type)->variant.array.is_variable_size_array) {
          unsigned long n = (unsigned long)skip_typerefs(arr->type)->variant.array.variant.number_of_elements;
          ir_emit(ir_fmt("(bounds %s %lu)", idx.s, n));
        }
      }
      vol = vol || (ir_is_aggregate(a0->type) ? base.vol : 0) || ir_pointee_is_volatile(a0->type);
      return ir_elem_addr(base.s, idx.s, e->type, vol);
    }
    case eok_indirect: {
      ir_val p;
      if (a0 == NULL) break;
      ir_note(0, k, 1);
      p = ir_rval(a0);
      if (!addr_only) ir_nonnull(a0, p);
      return ir_mk_addr(p.s, e->type, vol || ir_pointee_is_volatile(a0->type));
    }
    case eok_assign:
    case eok_add_assign:
    case eok_subtract_assign:
    case eok_multiply_assign:
    case eok_divide_assign:
    case eok_remainder_assign:
    case eok_shiftl_assign:
    case eok_shiftr_assign:
    case eok_and_assign:
    case eok_or_assign:
    case eok_xor_assign:
    case eok_padd_assign:
    case eok_psubtract_assign:
      return ir_assign(e, 1);
    case eok_pre_incr:
    case eok_pre_decr:
      return ir_incr(e, 1, k == eok_pre_incr);
    case eok_comma: {
      ir_note(0, k, 1);
      (void)ir_rval(a0);
      return ir_lval(a1);
    }
    case eok_lvalue_adjust:
      /* Only the qualifiers of the lvalue change (a `const int c = f();` initializer writes through the adjusted
         lvalue of c), so the address is the operand's. */
      ir_note(0, k, 1);
      if (ir_is_aggregate(e->type)) return ir_lval(a0);
      {
        ir_val base = ir_lval(a0);
        return ir_mk_addr(base.s, e->type, vol);
      }
    default:
      break;
  }
  if (ir_is_aggregate(e->type)) return ir_rval(e);
  {
    ir_val v = ir_gap(e->type, ir_fmt("lvalue %s", nfcxx_eok_name(k) != NULL ? nfcxx_eok_name(k) : "?"), 0, (int)k);
    return ir_mk_addr(v.s, e->type, vol);
  }
}

/* Value-valued operators. */
static ir_val ir_rval_op(an_expr_node_ptr e)
{
  an_expr_operator_kind k = e->variant.operation.kind;
  an_expr_node_ptr a0 = ir_operand(e, 0);
  an_expr_node_ptr a1 = ir_operand(e, 1);
  const char *mn;
  int ok = 1;

  switch (k) {
    case eok_dot_field:
    case eok_points_to_field:
    case eok_subscript:
    case eok_indirect: {
      ir_val a;
      /* `*__f` of a reference to a function (a pointer to the function in the lowered IL) whose result type is already
         the decayed pointer type: the function-to-pointer conversion, the value is the operand's. Nothing is read. */
      if (k == eok_indirect && a0 != NULL && a0->type != NULL && e->type != NULL && skip_typerefs(e->type)->kind == tk_pointer &&
          skip_typerefs(a0->type)->kind == tk_pointer && skip_typerefs(skip_typerefs(a0->type)->variant.pointer.type)->kind == tk_routine) {
        ir_val p = ir_rval(a0);
        ir_note(0, k, 1);
        return ir_mk_value(p.s, e->type);
      }
      a = ir_lval_op(e);
      if (a.s == NULL) return a;
      ir_note(0, k, 1);
      return ir_load(a);
    }
    case eok_lvalue_adjust: {
      if (ir_is_aggregate(e->type)) {
        ir_note(0, k, 1);
        return ir_lval(a0);
      }
      ir_note(0, k, 1);
      return ir_load(ir_lval(a0));
    }
    case eok_class_rvalue_adjust:
      ir_note(0, k, 1);
      return ir_rval(a0);
    case eok_array_to_pointer: {
      ir_val a = ir_lval(a0);
      ir_note(0, k, 1);
      return ir_mk_value(ir_retype_addr(a, skip_typerefs(e->type)->variant.pointer.type, 0).s, e->type);
    }
    case eok_address_of: {
      ir_val a;
      if (a0->kind == enk_operation &&
          (a0->variant.operation.kind == eok_points_to_field || a0->variant.operation.kind == eok_indirect)) {
        ir_addr_only = 1;
      }
      a = ir_lval(a0);
      ir_addr_only = 0;
      ir_note(0, k, 1);
      return ir_mk_value(ir_retype_addr(a, skip_typerefs(e->type)->variant.pointer.type, 0).s, e->type);
    }
    case eok_call:
      return ir_call(e);
    /* <stdarg.h>: the System V va_list is the 24-byte __va_list_tag, which QBE's vastart/vaarg fill and read in the
       same layout glibc's v*printf functions use. va_end has nothing to do. An aggregate va_arg is a gap marker. */
    case eok_va_start:
    case eok_va_start_single_operand:
      ir_emit(ir_fmt("(vastart %s)", ir_valist_addr(a0)));
      ir_note(0, k, 1);
      return ir_mk_void();
    case eok_va_end:
      (void)ir_valist_addr(a0);
      ir_note(0, k, 1);
      return ir_mk_void();
    case eok_va_copy: {
      char *dst = ir_valist_addr(a0), *src = ir_valist_addr(a1);
      ir_emit(ir_fmt("(copy 24 %s %s)", dst, src));
      ir_note(0, k, 1);
      return ir_mk_void();
    }
    case eok_va_arg:
      if (ir_is_aggregate(e->type)) return ir_vaarg_aggregate(e, ir_valist_addr(a0));
      if (ir_is_bool(e->type)) return ir_gap(e->type, "op va_arg (bool)", 0, (int)k);
      {
        char *ap = ir_valist_addr(a0);
        ir_note(0, k, 1);
        return ir_mk_value(ir_let(ir_valtext(e->type), ir_fmt("(vaarg %s %s)", ir_valtext(e->type), ap)), e->type);
      }
    case eok_cast:
      return ir_cast(e);
    case eok_question:
      return ir_question(e);
    case eok_land:
    case eok_lor:
      return ir_logic(e, k == eok_land);
    case eok_comma:
      ir_note(0, k, 1);
      (void)ir_rval(a0);
      return ir_rval(a1);
    case eok_assign:
    case eok_add_assign:
    case eok_subtract_assign:
    case eok_multiply_assign:
    case eok_divide_assign:
    case eok_remainder_assign:
    case eok_shiftl_assign:
    case eok_shiftr_assign:
    case eok_and_assign:
    case eok_or_assign:
    case eok_xor_assign:
    case eok_padd_assign:
    case eok_psubtract_assign:
      return ir_assign(e, 0);
    case eok_bassign: {
      /* Block assignment (IL lowering: a default member initializer of an array member copies a static array). It is a
         memcpy of the source operand's size; the result is void. */
      ir_val dst, src;
      if (a0 == NULL || a1 == NULL) break;
      ir_note(0, k, 1);
      dst = ir_lval(a0);
      src = ir_rval(a1);
      ir_emit(ir_fmt("(copy %lu %s %s)", ir_size_of(a1->type), dst.s, src.s));
      return ir_mk_void();
    }
    case eok_pre_incr:
    case eok_pre_decr:
    case eok_post_incr:
    case eok_post_decr:
      return ir_incr(e, k == eok_pre_incr || k == eok_pre_decr, k == eok_pre_incr || k == eok_post_incr);
    case eok_negate:
    case eok_unary_plus:
    case eok_complement: {
      ir_val a = ir_rval(a0);
      ir_note(0, k, 1);
      if (k == eok_unary_plus) return a;
      if (k == eok_complement) {
        return ir_mk_value(ir_let(ir_valtext(e->type), ir_fmt("(not %s %s)", ir_valtext(e->type), a.s)), e->type);
      }
      if (ir_is_float(e->type)) {
        return ir_mk_value(ir_let(ir_valtext(e->type), ir_fmt("(fneg %s %s)", ir_valtext(e->type), a.s)), e->type);
      }
      mn = (ir_is_signed(e->type) && ir_trap_overflow) ? "cneg" : "wneg";
      return ir_mk_value(ir_let(ir_valtext(e->type), ir_fmt("(%s %s %s)", mn, ir_valtext(e->type), a.s)), e->type);
    }
    case eok_not: {
      ir_val a = ir_rval(a0);
      ir_note(0, k, 1);
      /* A bool operand has no EDG type (a.t is NULL): compare it with false. */
      if (a.t == NULL) return ir_mk_bool(ir_let("bool", ir_fmt("(eq bool %s (const bool 0))", a.s)));
      return ir_mk_bool(ir_let("bool", ir_fmt("(eq %s %s %s)", a.ty, a.s, ir_zero(a.t))));
    }
    case eok_eq:
    case eok_ne:
    case eok_lt:
    case eok_le:
    case eok_gt:
    case eok_ge: {
      ir_val a = ir_rval(a0);
      ir_val b = ir_rval(a1);
      ir_note(0, k, 1);
      return ir_compare(k, a, b);
    }
    case eok_padd:
    case eok_psubtract: {
      ir_val p = ir_rval(a0);
      ir_val i = ir_rval(a1);
      char *idx = i.s;
      a_type_ptr elem = skip_typerefs(e->type)->variant.pointer.type;
      ir_note(0, k, 1);
      if (k == eok_psubtract) idx = ir_let(i.ty, ir_fmt("(wneg %s %s)", i.ty, i.s));
      return ir_ptr_add(p.s, idx, e->type, elem);
    }
    case eok_pdiff: {
      ir_val a = ir_rval(a0);
      ir_val b = ir_rval(a1);
      a_type_ptr elem = skip_typerefs(a0->type)->variant.pointer.type;
      ir_note(0, k, 1);
      {
        char *sz = ir_size_text(elem);
        return ir_mk_value(ir_let(ir_valtext(e->type), ir_fmt("(pdiff %s %s %s)", a.s, b.s, sz)), e->type);
      }
    }
    case eok_add:
    case eok_subtract:
    case eok_multiply:
    case eok_divide:
    case eok_remainder:
    case eok_shiftl:
    case eok_shiftr:
    case eok_and:
    case eok_or:
    case eok_xor: {
      ir_val a = ir_rval(a0);
      ir_val b = ir_rval(a1);
      ir_val r = ir_arith(k, e->type, a, b, &ok);
      if (!ok) break;
      ir_note(0, k, 1);
      return r;
    }
    default:
      break;
  }
  return ir_gap(e->type, ir_fmt("op %s", nfcxx_eok_name(k) != NULL ? nfcxx_eok_name(k) : "?"), 0, (int)k);
}

/* Assignment (scalar or aggregate, plain or compound). want_addr returns the address of the lhs. */
/* Value a converted to the arithmetic type dst (an integer or floating type). */
static ir_val ir_conv_num(ir_val a, a_type_ptr dst)
{
  if (strcmp(ir_valtext(dst), a.ty) == 0) return ir_mk_value(a.s, dst);
  if (ir_is_integer(dst)) {
    if (ir_is_float(a.t)) return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(cf2i %s %s)", ir_valtext(dst), a.s)), dst);
    return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(iconv %s %s)", ir_valtext(dst), a.s)), dst);
  }
  if (ir_is_float(a.t)) return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(fconv %s %s)", ir_valtext(dst), a.s)), dst);
  return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(%s %s %s)", ir_is_signed(a.t) ? "i2f" : "u2f", ir_valtext(dst), a.s)), dst);
}

/* The type a compound assignment computes in (C's usual arithmetic conversions of the object and the right-hand
   side), as one of the two operand types, or NULL when that is neither (both narrower than int): the caller then
   computes in the object's type. EDG leaves the operands of `unsigned n; n /= 10UL;` in their own types. */
static a_type_ptr ir_common_type(a_type_ptr a, a_type_ptr b)
{
  if (a == NULL || b == NULL) return NULL;
  if (ir_is_float(a) || ir_is_float(b)) {
    if (ir_is_float(a) && ir_is_float(b)) return ir_size_of(a) >= ir_size_of(b) ? a : b;
    return ir_is_float(a) ? a : b;
  }
  if (ir_is_integer(a) && ir_is_integer(b) && !ir_is_bool(a) && !ir_is_bool(b)) {
    unsigned long sa = ir_size_of(a), sb = ir_size_of(b);
    int ua = !ir_is_signed(a) && sa >= 4, ub = !ir_is_signed(b) && sb >= 4;
    if (sa < 4) sa = 4;
    if (sb < 4) sb = 4;
    if (sa > sb) return ir_size_of(a) == sa ? a : NULL;
    if (sb > sa) return ir_size_of(b) == sb ? b : NULL;
    if (ua || ub) {
      if (ua && ir_size_of(a) == sa) return a;
      if (ub && ir_size_of(b) == sb) return b;
      return NULL;
    }
    return ir_size_of(a) == sa ? a : (ir_size_of(b) == sb ? b : NULL);
  }
  return NULL;
}

static ir_val ir_assign(an_expr_node_ptr e, int want_addr)
{
  an_expr_operator_kind k = e->variant.operation.kind;
  an_expr_node_ptr a0 = ir_operand(e, 0);
  an_expr_node_ptr a1 = ir_operand(e, 1);
  ir_val lhs, rhs, nv;
  int ok = 1;
  if (k == eok_assign) {
    rhs = ir_rval(a1);
    lhs = ir_lval(a0);
    if (ir_is_aggregate(lhs.t)) {
      ir_copy(lhs.t, lhs.s, rhs.s);
      ir_note(0, eok_assign, 1);
      return want_addr ? lhs : ir_mk_value(lhs.s, lhs.t);
    }
    ir_store_lv(lhs, rhs.s);
    ir_note(0, eok_assign, 1);
    return want_addr ? lhs : ir_assign_result(e, lhs, rhs);
  }
  {
    an_expr_operator_kind base = ir_compound_base(k, &ok);
    ir_val cur;
    if (!ok) return ir_gap(e->type, "assign-op", 0, (int)k);
    rhs = ir_rval(a1);
    lhs = ir_lval(a0);
    cur = ir_load(lhs);
    if (base == eok_padd || base == eok_psubtract) {
      char *idx = rhs.s;
      a_type_ptr elem = skip_typerefs(lhs.t)->variant.pointer.type;
      if (base == eok_psubtract) idx = ir_let(rhs.ty, ir_fmt("(wneg %s %s)", rhs.ty, rhs.s));
      nv = ir_ptr_add(cur.s, idx, lhs.t, elem);
    } else {
      a_type_ptr ct = NULL;
      if (base != eok_shiftl && base != eok_shiftr && rhs.t != NULL) ct = ir_common_type(lhs.t, rhs.t);
      if (ct != NULL && strcmp(ir_valtext(ct), ir_valtext(lhs.t)) != 0) {
        /* compute in the common type, then convert back for the store */
        nv = ir_arith(base, ct, ir_conv_num(cur, ct), ir_conv_num(rhs, ct), &ok);
        if (ok) nv = ir_conv_num(nv, lhs.t);
      } else {
        nv = ir_arith(base, lhs.t, cur, rhs, &ok);
      }
      if (!ok) return ir_gap(e->type, "assign-op", 0, (int)k);
    }
    ir_note(0, k, 1);
    ir_store_lv(lhs, nv.s);
    return want_addr ? lhs : ir_assign_result(e, lhs, nv);
  }
}

/* ++ and --. The value is the new value when pre, the old value otherwise. */
static ir_val ir_incr(an_expr_node_ptr e, int pre, int inc)
{
  an_expr_node_ptr a0 = ir_operand(e, 0);
  ir_val lhs = ir_lval(a0);
  ir_val cur = ir_load(lhs);
  ir_val nv;
  if (ir_is_pointer(lhs.t)) {
    a_type_ptr elem = skip_typerefs(lhs.t)->variant.pointer.type;
    nv = ir_ptr_add(cur.s, inc ? "(const long 1)" : "(const long -1)", lhs.t, elem);
  } else if (ir_is_integer(lhs.t) && !ir_is_bool(lhs.t)) {
    int ok = 1;
    char *one = ir_fmt("(const %s 1)", ir_valtext(lhs.t));
    nv = ir_arith(inc ? eok_add : eok_subtract, lhs.t, cur, ir_mk_value(one, lhs.t), &ok);
    if (!ok) return ir_gap(e->type, "incr", 0, (int)e->variant.operation.kind);
  } else if (ir_is_float(lhs.t)) {
    char *one = ir_fmt("(const %s 1.0)", ir_valtext(lhs.t));
    nv = ir_mk_value(ir_let(ir_valtext(lhs.t),
                            ir_fmt("(%s %s %s %s)", inc ? "fadd" : "fsub", ir_valtext(lhs.t), cur.s, one)),
                     lhs.t);
  } else {
    return ir_gap(e->type, "incr", 0, (int)e->variant.operation.kind);
  }
  ir_store_lv(lhs, nv.s);
  ir_note(0, pre ? eok_pre_incr : eok_post_incr, 1);
  return pre ? ir_assign_result(e, lhs, nv) : cur;
}

/* The address of the va_list object an operand of a va_* operation names: an lvalue of the va_list array type (its
   address), or a pointer (a va_list parameter, which decays to a pointer to the tag). */
static char *ir_valist_addr(an_expr_node_ptr n)
{
  if (n != NULL && n->type != NULL && skip_typerefs(n->type)->kind == tk_array) return ir_lval(n).s;
  return ir_rval(n).s;
}

/* The function type a call goes through: the routine's own type, or the pointee of a function pointer. */
static a_type_ptr ir_callee_fn_type(an_expr_node_ptr f)
{
  a_type_ptr t = f->kind == enk_routine ? f->variant.routine.ptr->type : f->type;
  if (t == NULL) return NULL;
  t = skip_typerefs(t);
  if (t->kind == tk_pointer) t = skip_typerefs(t->variant.pointer.type);
  return t->kind == tk_routine ? t : NULL;
}

/* GCC built-in functions (`__builtin_NAME`), which libstdc++'s headers call directly. Hint and query built-ins
   become values or markers; the bit operations (popcount, clz, ctz, ffs, parity, clrsb, bswap16/32/64) and the
   overflow-checked arithmetic are expanded inline (straight-line IR, no libgcc call, so a freestanding link works);
   every other built-in that has a C library function (`__builtin_memcpy`, `__builtin_strlen`, `__builtin_fabs`, ...)
   is a call of that function. `__builtin_alloca` is the (alloca N) node. A built-in that has no library function and
   no lowering here (`__builtin_frame_address`, `__builtin_ia32_*`, ...) is an (unsupported builtin NAME) marker, so
   the emitter refuses with the name instead of the program failing to link. docs/notes/pathb-hosted.md lists them. */

/* Small helpers for the expansions: typed constants and two-operand lets on IR type names. */
static char *ir_k(const char *ty, unsigned long v)
{
  return ir_fmt("(const %s %lu)", ty, v);
}

static char *ir_o2(const char *op, const char *ty, const char *a, const char *b)
{
  return ir_let(ty, ir_fmt("(%s %s %s %s)", op, ty, a, b));
}

/* x shifted by the constant n (left or right; arithmetic when ty is signed). */
static char *ir_sh(int left, const char *ty, const char *a, int n)
{
  return ir_o2(left ? "cshl" : "cshr", ty, a, ir_fmt("(const int %d)", n));
}

static char *ir_cv(const char *ty, const char *a)
{
  return ir_let(ty, ir_fmt("(iconv %s %s)", ty, a));
}

/* Population count of the unsigned value x (type ut, bits wide): the parallel bit-sum. */
static char *ir_bi_popcount(const char *ut, int bits, const char *x)
{
  unsigned long m1 = bits == 64 ? 0x5555555555555555UL : 0x55555555UL;
  unsigned long m2 = bits == 64 ? 0x3333333333333333UL : 0x33333333UL;
  unsigned long m4 = bits == 64 ? 0x0f0f0f0f0f0f0f0fUL : 0x0f0f0f0fUL;
  unsigned long h01 = bits == 64 ? 0x0101010101010101UL : 0x01010101UL;
  char *t = ir_o2("and", ut, ir_sh(0, ut, x, 1), ir_k(ut, m1));
  char *x1 = ir_o2("wsub", ut, x, t);
  char *a = ir_o2("and", ut, x1, ir_k(ut, m2));
  char *b = ir_o2("and", ut, ir_sh(0, ut, x1, 2), ir_k(ut, m2));
  char *x2 = ir_o2("wadd", ut, a, b);
  char *c = ir_o2("and", ut, ir_o2("wadd", ut, x2, ir_sh(0, ut, x2, 4)), ir_k(ut, m4));
  return ir_sh(0, ut, ir_o2("wmul", ut, c, ir_k(ut, h01)), bits - 8);
}

/* Number of leading zero bits (bits for x == 0): smear the top bit down, count the zeros. */
static char *ir_bi_clz(const char *ut, int bits, const char *x)
{
  int s;
  char *v = (char *)x;
  for (s = 1; s < bits; s *= 2) v = ir_o2("or", ut, v, ir_sh(0, ut, v, s));
  return ir_o2("wsub", ut, ir_k(ut, (unsigned long)bits), ir_bi_popcount(ut, bits, v));
}

/* Number of trailing zero bits (bits for x == 0): the bits below the lowest set bit are ~x & (x - 1). */
static char *ir_bi_ctz(const char *ut, int bits, const char *x)
{
  char *nx = ir_let(ut, ir_fmt("(not %s %s)", ut, x));
  char *m = ir_o2("wsub", ut, x, ir_k(ut, 1));
  return ir_bi_popcount(ut, bits, ir_o2("and", ut, nx, m));
}

/* Byte swap of the unsigned value x (type ut) of 2, 4 or 8 bytes: each byte moves to the mirrored position. */
static char *ir_bi_bswap(const char *ut, int bytes, const char *x)
{
  char *r = NULL;
  int i;
  for (i = 0; i < bytes; i++) {
    /* byte i of x (the top byte needs no mask: x has no bits above its width) moves to byte bytes - 1 - i */
    char *b = i == 0 ? (char *)x : ir_sh(0, ut, x, 8 * i);
    char *m;
    if (i != bytes - 1) b = ir_o2("and", ut, b, ir_k(ut, 255));
    m = i == bytes - 1 ? b : ir_sh(1, ut, b, 8 * (bytes - 1 - i));
    r = r == NULL ? m : ir_o2("or", ut, r, m);
  }
  return r;
}

/* The integer built-in NAME (popcount, clz, ctz, ffs, parity, clrsb, with an l or ll suffix) as (kind, bits). kind:
   1 popcount, 2 clz, 3 ctz, 4 ffs, 5 parity, 6 clrsb; 7 bswap16, 8 bswap32, 9 bswap64. 0: not one of them. */
static int ir_bit_name(const char *n, int *bits)
{
  static const struct { const char *base; int kind; } tab[] = {
    { "popcount", 1 }, { "clz", 2 }, { "ctz", 3 }, { "ffs", 4 }, { "parity", 5 }, { "clrsb", 6 },
  };
  size_t i;
  if (strcmp(n, "bswap16") == 0) { *bits = 16; return 7; }
  if (strcmp(n, "bswap32") == 0) { *bits = 32; return 8; }
  if (strcmp(n, "bswap64") == 0) { *bits = 64; return 9; }
  for (i = 0; i < sizeof tab / sizeof tab[0]; i++) {
    size_t l = strlen(tab[i].base);
    if (strncmp(n, tab[i].base, l) != 0) continue;
    if (n[l] == '\0') { *bits = 32; return tab[i].kind; }
    if (strcmp(n + l, "l") == 0 || strcmp(n + l, "ll") == 0) { *bits = 64; return tab[i].kind; }
  }
  return 0;
}

static ir_val ir_bit_builtin(an_expr_node_ptr e, int kind, int bits)
{
  an_expr_node_ptr arg = ir_operand(e, 1);
  const char *ut = bits == 64 ? "unsigned_long" : "unsigned_int";
  const char *st = bits == 64 ? "long" : "int";
  ir_val a;
  char *x, *r = NULL;
  if (arg == NULL || ir_operand(e, 2) != NULL || !ir_is_integer(arg->type)) return ir_gap(e->type, "builtin bit operation (arguments)", 0, (int)eok_call);
  a = ir_rval(arg);
  if (kind == 7) ut = "unsigned_int"; /* bswap16 works in 32 bits and narrows at the end */
  x = ir_cv(ut, a.s);
  switch (kind) {
    case 1: r = ir_bi_popcount(ut, bits, x); break;
    case 2: r = ir_bi_clz(ut, bits, x); break;
    case 3: r = ir_bi_ctz(ut, bits, x); break;
    case 4: {
      /* ffs: the index (from 1) of the lowest set bit, 0 for 0. x ^ (x - 1) has the bits up to and including the lowest one. */
      char *pc = ir_bi_popcount(ut, bits, ir_o2("xor", ut, x, ir_o2("wsub", ut, x, ir_k(ut, 1))));
      char *nz = ir_cv(ut, ir_let("bool", ir_fmt("(ne %s %s %s)", ut, x, ir_k(ut, 0))));
      r = ir_o2("wmul", ut, pc, nz);
      break;
    }
    case 5: r = ir_o2("and", ut, ir_bi_popcount(ut, bits, x), ir_k(ut, 1)); break;
    case 6: {
      /* clrsb: the redundant sign bits are the leading zeros of ((x ^ (x >> (bits - 1))) << 1) | 1 (never zero). */
      char *sg = ir_cv(ut, ir_sh(0, st, ir_cv(st, a.s), bits - 1));
      char *y = ir_o2("xor", ut, x, sg);
      r = ir_bi_clz(ut, bits, ir_o2("or", ut, ir_sh(1, ut, y, 1), ir_k(ut, 1)));
      break;
    }
    case 7: r = ir_bi_bswap(ut, 2, ir_o2("and", ut, x, ir_k(ut, 65535))); break;
    case 8: r = ir_bi_bswap(ut, 4, x); break;
    default: r = ir_bi_bswap(ut, 8, x); break;
  }
  ir_note(0, eok_call, 1);
  return ir_mk_value(ir_cv(ir_valtext(e->type), r), e->type);
}

/* The floating-point classification and comparison built-ins (<cmath>'s isnan, isinf, isfinite, isnormal, signbit, fpclassify,
   isgreater ...): 1 when NAME is one and its lowering is in *out. x - x is 0 for a finite x and NaN for an infinity or a NaN,
   which tells them apart without bit tricks; the comparisons are the ordered ones QBE has (false when unordered), which is
   what isgreater and friends mean (no exception is raised, there is no floating-point environment here). The results are int. */
static int ir_float_builtin(an_expr_node_ptr e, const char *name, ir_val *out)
{
  static const char *const cmp[] = { "isgreater", "isgreaterequal", "isless", "islessequal", "islessgreater", "isunordered" };
  an_expr_node_ptr a1 = ir_operand(e, 1), a2 = ir_operand(e, 2);
  const char *it = ir_valtext(e->type);
  int k = -1, i;
  for (i = 0; i < 6; i++) if (strcmp(name, cmp[i]) == 0) k = i;
  if (k >= 0 && a1 != NULL && a2 != NULL && ir_is_float(a1->type) && ir_is_float(a2->type)) {
    ir_val x = ir_rval(a1), y = ir_rval(a2);
    const char *t = x.ty;
    char *r;
    if (k == 5) {
      r = ir_o2("or", it, ir_cv(it, ir_let("bool", ir_fmt("(ne %s %s %s)", t, x.s, x.s))), ir_cv(it, ir_let("bool", ir_fmt("(ne %s %s %s)", t, y.s, y.s))));
    } else if (k == 4) {
      r = ir_o2("or", it, ir_cv(it, ir_let("bool", ir_fmt("(lt.f %s %s %s)", t, x.s, y.s))), ir_cv(it, ir_let("bool", ir_fmt("(lt.f %s %s %s)", t, y.s, x.s))));
    } else {
      /* isgreater(x, y) is y < x, isgreaterequal y <= x, isless x < y, islessequal x <= y */
      static const char *const op[4] = { "lt.f", "le.f", "lt.f", "le.f" };
      int swap = k < 2;
      r = ir_cv(it, ir_let("bool", ir_fmt("(%s %s %s %s)", op[k], t, swap ? y.s : x.s, swap ? x.s : y.s)));
    }
    ir_note(0, eok_call, 1);
    *out = ir_mk_value(r, e->type);
    return 1;
  }
  if (strcmp(name, "fpclassify") == 0) {
    an_expr_node_ptr xa = ir_operand(e, 6);
    if (xa != NULL && ir_is_float(xa->type) && ir_size_of(xa->type) <= 8) {
      /* libm's classification returns the FP_* values of the same <math.h> that supplied the five constants */
      ir_val x = ir_rval(xa);
      ir_note(0, eok_call, 1);
      *out = ir_mk_value(ir_let(it, ir_fmt("(call %s &\"%s\" %s)", it, ir_size_of(xa->type) == 4 ? "__fpclassifyf" : "__fpclassify", x.s)), e->type);
      return 1;
    }
    return 0;
  }
  if ((strcmp(name, "isnan") == 0 || strcmp(name, "isinf") == 0 || strcmp(name, "isfinite") == 0 || strcmp(name, "isnormal") == 0 ||
       strcmp(name, "isinf_sign") == 0 || strcmp(name, "signbit") == 0) && a1 != NULL && ir_operand(e, 2) == NULL && ir_is_float(a1->type) &&
      ir_size_of(a1->type) <= 8) {
    ir_val x = ir_rval(a1);
    const char *t = x.ty;
    int single = ir_size_of(a1->type) == 4;
    char *r;
    ir_note(0, eok_call, 1);
    if (strcmp(name, "signbit") == 0) {
      *out = ir_mk_value(ir_let(it, ir_fmt("(call %s &\"%s\" %s)", it, single ? "__signbitf" : "__signbit", x.s)), e->type);
      return 1;
    }
    {
      char *d = ir_let(t, ir_fmt("(fsub %s %s %s)", t, x.s, x.s));
      char *isnum = ir_cv(it, ir_let("bool", ir_fmt("(eq %s %s %s)", t, x.s, x.s)));        /* not a NaN */
      char *finite = ir_cv(it, ir_let("bool", ir_fmt("(eq %s %s %s)", t, d, d)));           /* neither NaN nor infinite */
      if (strcmp(name, "isnan") == 0) {
        r = ir_o2("xor", it, isnum, ir_k(it, 1));
      } else if (strcmp(name, "isfinite") == 0) {
        r = finite;
      } else if (strcmp(name, "isnormal") == 0) {
        /* finite and |x| >= the smallest normal number */
        const char *mn = single ? "1.17549435082228750797e-38" : "2.2250738585072013831e-308";
        char *big = ir_cv(it, ir_let("bool", ir_fmt("(le.f %s (const %s %s) %s)", t, t, mn, x.s)));
        char *small = ir_cv(it, ir_let("bool", ir_fmt("(le.f %s %s (const %s -%s))", t, x.s, t, mn)));
        r = ir_o2("and", it, ir_o2("or", it, big, small), finite);
      } else {
        char *isinf = ir_o2("and", it, isnum, ir_o2("xor", it, finite, ir_k(it, 1)));   /* a number that is not finite */
        if (strcmp(name, "isinf") == 0) {
          r = isinf;
        } else {
          char *neg = ir_cv(it, ir_let("bool", ir_fmt("(lt.f %s %s %s)", t, x.s, ir_zero(a1->type))));
          char *sgn = ir_o2("wsub", it, ir_k(it, 1), ir_o2("wmul", it, neg, ir_k(it, 2)));   /* 1 or -1 */
          r = ir_o2("wmul", it, isinf, sgn);
        }
      }
    }
    *out = ir_mk_value(r, e->type);
    return 1;
  }
  return 0;
}

/* [su]?(add|sub|mul)(l|ll)?_overflow and the generic add/sub/mul_overflow[_p]: op 0 add, 1 sub, 2 mul; *pred is 1 for the
   _p predicates (no result pointer, the third argument is only a value of the result type). 1 when NAME is one. */
static int ir_ovf_op(const char *q)
{
  if (strncmp(q, "add", 3) == 0) return 0;
  if (strncmp(q, "sub", 3) == 0) return 1;
  if (strncmp(q, "mul", 3) == 0) return 2;
  return -1;
}

static int ir_ovf_name(const char *n, int *op, int *pred)
{
  const char *q = n;
  int sized = 0, o;
  *pred = 0;
  if ((q[0] == 's' || q[0] == 'u') && ir_ovf_op(q + 1) >= 0) { q++; sized = 1; }
  o = ir_ovf_op(q);
  if (o < 0) return 0;
  q += 3;
  if (sized && q[0] == 'l') { q++; if (q[0] == 'l') q++; } /* the C type of the sized forms: int, long, long long */
  *op = o;
  if (strcmp(q, "_overflow") == 0) return 1;
  if (!sized && strcmp(q, "_overflow_p") == 0) { *pred = 1; return 1; }
  return 0;
}

/* __builtin_add_overflow / sub_overflow / mul_overflow (A, B, &R) with GCC's meaning: R gets the exact result of the
   arithmetic on the mathematical integers A and B converted to R's type (wrapped), the value is whether the exact
   result did not fit R. A, B and R may be any integer types of any signedness and width up to 64 bits. The _p forms and
   the __builtin_[su]{add,sub,mul}{,l,ll}_overflow forms are the same with a value instead of the result pointer / with
   fixed types.
   Two lowerings. The textbook one, when A, B and R are one integer type (not bool): the wrapped result uses the wrapping
   operations (wadd, wsub, wmul) even in trap mode, unsigned add r < a, sub a < b, mul a != 0 && r / a != b, signed
   add ((a ^ r) & (b ^ r)) < 0, sub ((a ^ b) & (a ^ r)) < 0.
   The general one (signed multiply, mixed widths or signs): the operands are extended to 64 bits by their own signedness
   and the exact result is formed as a pair (hi, lo) of 64-bit words (a 128-bit two's complement integer: for add and
   sub the sum of the sign words and the carry or borrow; for multiply the product of the magnitudes, negated when the
   signs differ, with the unsigned 64-bit overflow of the magnitude product caught by a division). R receives lo
   truncated; the result fits R exactly when hi equals the sign extension of lo (all ones or zero for a signed R, zero
   for an unsigned R) and, for R narrower than 64 bits, lo equals its own truncation extended again. */
static ir_val ir_builtin_overflow(an_expr_node_ptr e, int op, int pred)
{
  an_expr_node_ptr n0 = ir_operand(e, 1), n1 = ir_operand(e, 2), n2 = ir_operand(e, 3);
  a_type_ptr rt;
  ir_val x, y, p;
  char *ov;
  int sg;
  const char *U = "unsigned_long";
  if (n0 == NULL || n1 == NULL || n2 == NULL || ir_operand(e, 4) != NULL) return ir_gap(e->type, "builtin overflow (arguments)", 0, (int)eok_call);
  if (pred) {
    rt = skip_typerefs(n2->type);
  } else {
    if (!ir_is_pointer(n2->type)) return ir_gap(e->type, "builtin overflow (result is not a pointer)", 0, (int)eok_call);
    rt = skip_typerefs(skip_typerefs(n2->type)->variant.pointer.type);
  }
  sg = ir_is_signed(rt);
  if (!ir_is_integer(rt) || ir_is_bool(rt) || !ir_is_integer(n0->type) || !ir_is_integer(n1->type) ||
      ir_size_of(n0->type) > 8 || ir_size_of(n1->type) > 8 || ir_size_of(rt) > 8) {
    return ir_gap(e->type, "builtin overflow (operand types)", 0, (int)eok_call);
  }
  x = ir_rval(n0);
  y = ir_rval(n1);
  p = pred ? ir_mk_void() : ir_rval(n2);
  if (!ir_is_bool(n0->type) && !ir_is_bool(n1->type) && ir_size_of(n0->type) == ir_size_of(rt) &&
      ir_size_of(n1->type) == ir_size_of(rt) && ir_is_signed(n0->type) == sg && ir_is_signed(n1->type) == sg &&
      !(sg && op == 2) && getenv("NFCXX_IR_OVF_GENERAL") == NULL) {
    ir_val r = ir_mk_value(ir_let(ir_valtext(rt), ir_fmt("(%s %s %s %s)", op == 0 ? "wadd" : op == 1 ? "wsub" : "wmul",
                                                          ir_valtext(rt), x.s, y.s)), rt);
    if (!pred) ir_store(rt, p.s, r.s, 0);
    if (!sg) {
      if (op == 0) {
        ov = ir_compare(eok_lt, r, x).s;
      } else if (op == 1) {
        ov = ir_compare(eok_lt, x, y).s;
      } else {
        int d = ir_depth;
        ov = ir_let("bool", "(const bool 0)");
        ir_line(d, ir_fmt("(if %s", ir_compare(eok_ne, x, ir_mk_value(ir_zero(rt), rt)).s));
        ir_line(d + 1, "(then");
        ir_depth = d + 2;
        {
          ir_val q = ir_mk_value(ir_let(ir_valtext(rt), ir_fmt("(cdiv %s %s %s)", ir_valtext(rt), r.s, x.s)), rt);
          ir_emit(ir_fmt("(set %s %s)", ov, ir_compare(eok_ne, q, y).s));
        }
        ir_close(1);
        ir_close(1);
        ir_depth = d;
      }
    } else {
      char *t1, *t2, *t3;
      /* add: (x ^ r) & (y ^ r); sub: (x ^ y) & (x ^ r) */
      if (op == 0) {
        t1 = ir_let(ir_valtext(rt), ir_fmt("(xor %s %s %s)", ir_valtext(rt), x.s, r.s));
        t2 = ir_let(ir_valtext(rt), ir_fmt("(xor %s %s %s)", ir_valtext(rt), y.s, r.s));
      } else {
        t1 = ir_let(ir_valtext(rt), ir_fmt("(xor %s %s %s)", ir_valtext(rt), x.s, y.s));
        t2 = ir_let(ir_valtext(rt), ir_fmt("(xor %s %s %s)", ir_valtext(rt), x.s, r.s));
      }
      t3 = ir_let(ir_valtext(rt), ir_fmt("(and %s %s %s)", ir_valtext(rt), t1, t2));
      ov = ir_compare(eok_lt, ir_mk_value(t3, rt), ir_mk_value(ir_zero(rt), rt)).s;
    }
    ir_note(0, eok_call, 1);
    return ir_mk_bool(ov);
  }
  {
    int sx = ir_is_signed(n0->type), sy = ir_is_signed(n1->type);
    unsigned long wr = ir_size_of(rt) * 8UL;
    char *zero = ir_k(U, 0);
    char *X = ir_cv(U, x.s), *Y = ir_cv(U, y.s);
    char *hx = sx ? ir_cv(U, ir_sh(0, "long", ir_cv("long", x.s), 63)) : zero;
    char *hy = sy ? ir_cv(U, ir_sh(0, "long", ir_cv("long", y.s), 63)) : zero;
    char *lo, *hi, *stored, *ext, *t, *ov64 = NULL;
    if (op != 2) {
      char *c;
      if (op == 0) {
        lo = ir_o2("wadd", U, X, Y);
        c = ir_cv(U, ir_let("bool", ir_fmt("(lt.u %s %s %s)", U, lo, X)));
        hi = ir_o2("wadd", U, ir_o2("wadd", U, hx, hy), c);
      } else {
        lo = ir_o2("wsub", U, X, Y);
        c = ir_cv(U, ir_let("bool", ir_fmt("(lt.u %s %s %s)", U, X, Y)));
        hi = ir_o2("wsub", U, ir_o2("wsub", U, hx, hy), c);
      }
    } else {
      /* magnitudes, their 64-bit product, and the sign mask (all ones when the exact product is negative) */
      char *mx = sx ? ir_o2("wsub", U, ir_o2("xor", U, X, hx), hx) : X;
      char *my = sy ? ir_o2("wsub", U, ir_o2("xor", U, Y, hy), hy) : Y;
      char *pr = ir_o2("wmul", U, mx, my);
      char *hn, *nz, *mask;
      int d = ir_depth;
      ov64 = ir_let("bool", "(const bool 0)");
      ir_line(d, ir_fmt("(if %s", ir_let("bool", ir_fmt("(ne %s %s %s)", U, mx, zero))));
      ir_line(d + 1, "(then");
      ir_depth = d + 2;
      {
        char *q = ir_o2("cdiv", U, pr, mx);
        ir_emit(ir_fmt("(set %s %s)", ov64, ir_let("bool", ir_fmt("(ne %s %s %s)", U, q, my))));
      }
      ir_close(1);
      ir_close(1);
      ir_depth = d;
      hn = ir_o2("xor", U, hx, hy);
      nz = ir_cv(U, ir_let("bool", ir_fmt("(ne %s %s %s)", U, pr, zero)));
      mask = ir_o2("wsub", U, zero, nz);
      hn = ir_o2("and", U, hn, mask);
      lo = ir_o2("wsub", U, ir_o2("xor", U, pr, hn), hn);
      hi = hn;
    }
    stored = ir_cv(ir_valtext(rt), lo);
    if (!pred) ir_store(rt, p.s, stored, 0);
    ext = sg ? ir_cv(U, ir_sh(0, "long", ir_cv("long", lo), 63)) : zero;
    t = ir_o2("xor", U, hi, ext);
    if (wr < 64) t = ir_o2("or", U, t, ir_o2("xor", U, ir_cv(U, stored), lo));
    if (ov64 != NULL) t = ir_o2("or", U, t, ir_cv(U, ov64));
    ov = ir_let("bool", ir_fmt("(ne %s %s %s)", U, t, zero));
    ir_note(0, eok_call, 1);
    return ir_mk_bool(ov);
  }
}

/* The constant integer value of a built-in's argument, or -1 when it is not an integer constant. */
static long ir_const_arg(an_expr_node_ptr n)
{
  while (n != NULL && n->kind == enk_operation && n->variant.operation.kind == eok_cast) n = ir_operand(n, 0);
  if (n == NULL || n->kind != enk_constant || n->variant.constant.ptr->kind != ck_integer) return -1;
  return atol(ir_capture_constant(n->variant.constant.ptr));
}

/* Built-ins that no code here lowers and that have no C library function of the same name either: calling
   `__builtin_NAME` as a function would only fail at link time with a symbol nobody can explain. */
static int ir_builtin_unlowerable(const char *n)
{
  static const char *const names[] = {
    "frame_address", "return_address", "extract_return_addr", "frob_return_addr", "dwarf_cfa", "unwind_init",
    "apply", "apply_args", "return", "setjmp", "longjmp", "nonlocal_goto", "cpu_init", "cpu_is", "cpu_supports",
    "va_arg_pack", "va_arg_pack_len", "speculation_safe_value", "thread_pointer", "set_thread_pointer",
  };
  size_t i;
  if (strncmp(n, "ia32_", 5) == 0 && strcmp(n, "ia32_pause") != 0) return 1;
  for (i = 0; i < sizeof names / sizeof names[0]; i++) if (strcmp(n, names[i]) == 0) return 1;
  return 0;
}

/* 1 when the call e of the built-in `name` (without the prefix) is lowered here; the value is in *out. */
static int ir_builtin_call(an_expr_node_ptr e, const char *name, ir_val *out)
{
  an_expr_node_ptr arg = ir_operand(e, 1);
  int op, pred, bits, kind;
  if (ir_ovf_name(name, &op, &pred)) {
    *out = ir_builtin_overflow(e, op, pred);
    return 1;
  }
  if ((kind = ir_bit_name(name, &bits)) != 0) {
    *out = ir_bit_builtin(e, kind, bits);
    return 1;
  }
  if (ir_float_builtin(e, name, out)) return 1;
  if (strcmp(name, "expect") == 0 || strcmp(name, "expect_with_probability") == 0) {
    ir_val a = ir_rval(arg);
    ir_note(0, eok_call, 1);
    *out = a;
    return 1;
  }
  /* __builtin_is_constant_evaluated(): true only while the compiler evaluates a constant expression; code that runs is not. */
  if (strcmp(name, "is_constant_evaluated") == 0) {
    ir_note(0, eok_call, 1);
    *out = ir_mk_value(ir_fmt("(const %s 0)", ir_valtext(e->type)), e->type);
    return 1;
  }
  if (strcmp(name, "constant_p") == 0) {
    ir_note(0, eok_call, 1);
    *out = ir_mk_value(ir_fmt("(const %s 0)", ir_valtext(e->type)), e->type);
    return 1;
  }
  if (strcmp(name, "unreachable") == 0 || strcmp(name, "trap") == 0) {
    ir_note(0, eok_call, 1);
    ir_emit("(unreachable)");
    *out = ir_is_void(e->type) ? ir_mk_void() : ir_mk_value(ir_zero(e->type), e->type);
    return 1;
  }
  /* __builtin_object_size(P, TYPE) without optimization: (size_t)-1 for types 0 and 1, 0 for types 2 and 3 (what gcc
     -O0 gives). P is not evaluated. */
  if (strcmp(name, "object_size") == 0 || strcmp(name, "dynamic_object_size") == 0) {
    long t = ir_const_arg(ir_operand(e, 2));
    ir_note(0, eok_call, 1);
    *out = ir_mk_value(ir_k(ir_valtext(e->type), (t == 2 || t == 3) ? 0UL : ~0UL), e->type);
    return 1;
  }
  /* __builtin_assume_aligned(P, ALIGN [, OFFSET]) and __builtin_launder(P) are P. */
  if (strcmp(name, "assume_aligned") == 0 || strcmp(name, "launder") == 0) {
    an_expr_node_ptr rest;
    ir_val a = ir_rval(arg);
    for (rest = arg != NULL ? arg->next : NULL; rest != NULL; rest = rest->next) (void)ir_rval(rest);
    ir_note(0, eok_call, 1);
    *out = ir_mk_value(a.s, e->type);
    return 1;
  }
  /* __builtin_prefetch(ADDR [, RW [, LOCALITY]]) is a hint: the arguments are evaluated and nothing else happens. */
  if (strcmp(name, "prefetch") == 0) {
    an_expr_node_ptr a;
    for (a = arg; a != NULL; a = a->next) (void)ir_rval(a);
    ir_note(0, eok_call, 1);
    *out = ir_mk_void();
    return 1;
  }
  /* The x86 `pause` hint does nothing observable; a call of an empty function keeps it where it is (see (barrier)). */
  if (strcmp(name, "ia32_pause") == 0) {
    ir_note(0, eok_call, 1);
    ir_emit("(barrier)");
    *out = ir_mk_void();
    return 1;
  }
  /* __builtin_alloca(N) and the _with_align forms: dynamic stack storage that lives until the function returns. */
  if (strcmp(name, "alloca") == 0 || strcmp(name, "alloca_with_align") == 0 || strcmp(name, "alloca_with_align_and_max") == 0) {
    ir_val n;
    long al = name[6] == '_' ? ir_const_arg(ir_operand(e, 2)) : 0;
    if (arg == NULL || !ir_is_integer(arg->type) || al < 0 || al > 32768 || (al > 0 && (al & (al - 1)) != 0)) {
      *out = ir_gap(e->type, "builtin alloca (alignment argument)", 0, (int)eok_call);
      return 1;
    }
    n = ir_rval(arg);
    ir_note(0, eok_call, 1);
    if (al > 128) {
      /* more than the 16 bytes alloca gives: take A - 1 bytes more and round the address up */
      unsigned long a = (unsigned long)al / 8;
      char *sz = ir_o2("wadd", "unsigned_long", ir_cv("unsigned_long", n.s), ir_k("unsigned_long", a));
      char *raw = ir_let(ir_valtext(e->type), ir_fmt("(alloca %s)", sz));
      char *ad = ir_o2("wadd", "unsigned_long", ir_let("unsigned_long", ir_fmt("(p2i unsigned_long %s)", raw)), ir_k("unsigned_long", a - 1));
      char *rd = ir_o2("and", "unsigned_long", ad, ir_k("unsigned_long", ~(a - 1)));
      *out = ir_mk_value(ir_let(ir_valtext(e->type), ir_fmt("(i2p %s %s)", ir_valtext(e->type), rd)), e->type);
      return 1;
    }
    *out = ir_mk_value(ir_let(ir_valtext(e->type), ir_fmt("(alloca %s)", ir_cv("unsigned_long", n.s))), e->type);
    return 1;
  }
  if (ir_builtin_unlowerable(name)) {
    *out = ir_gap(e->type, ir_fmt("builtin %s (no lowering)", name), 0, (int)eok_call);
    return 1;
  }
  return 0;
}

/* The symbol a built-in's call goes to, or NULL when the name has no prefix. */
static const char *ir_builtin_sym(const char *name)
{
  if (name == NULL || strncmp(name, "__builtin_", 10) != 0) return NULL;
  return name + 10;
}

/* The integer type text of an N-byte atomic operand. */
static const char *ir_uty(int n)
{
  return n == 1 ? "unsigned_char" : n == 2 ? "unsigned_short" : n == 4 ? "unsigned_int" : "unsigned_long";
}

/* A full memory barrier (seq_cst fence): a locked read-modify-write of a private word through libatomic. On x86 any
   locked instruction is a full barrier; the call is opaque, so the compiler cannot reorder around it either. */
static void ir_full_fence(void)
{
  ir_val t = ir_temp(integer_type(ik_int));
  ir_emit(ir_fmt("(eval (call void &\"__atomic_fetch_or_4\" %s (const int 0) (const int 5)))", t.s));
}

/* Atomic built-ins that EDG leaves as calls of functions nothing exports (the sized `__atomic_{load,store,...}_N` names
   are libatomic's and need no help): __atomic_test_and_set, __atomic_clear, __atomic_thread_fence, __atomic_signal_fence,
   and the legacy `__sync_*` family (EDG calls them `__sync_fetch_and_add_4` ...; GCC expands them inline). They are
   lowered to calls of libatomic's `__atomic_*_N`, always sequentially consistent (stronger than any __sync_ order). */
static int ir_atomic_call(an_expr_node_ptr e, const char *name, ir_val *out)
{
  static const char *const ops[] = { "add", "sub", "or", "and", "xor", "nand" };
  an_expr_node_ptr a[4] = { NULL, NULL, NULL, NULL };
  ir_val v[4];
  int i, n = 0, mode = 0, op = -1, sz = 0;
  /* 1 signal fence, 2 full fence, 3 test_and_set, 4 clear, 5 fetch_OP, 6 OP_fetch, 7 bool cas, 8 val cas, 9 lock_test_and_set, 10 lock_release */
  if (strcmp(name, "__atomic_signal_fence") == 0) mode = 1;
  else if (strcmp(name, "__atomic_thread_fence") == 0 || strcmp(name, "__sync_synchronize") == 0) mode = 2;
  else if (strcmp(name, "__atomic_test_and_set") == 0) mode = 3;
  else if (strcmp(name, "__atomic_clear") == 0) mode = 4;
  else if (strncmp(name, "__sync_", 7) == 0) {
    const char *tail = strrchr(name, '_');
    char base[40];
    size_t bl;
    if (tail == NULL || tail <= name + 7) return 0;
    sz = atoi(tail + 1);
    bl = (size_t)(tail - (name + 7));
    if ((sz != 1 && sz != 2 && sz != 4 && sz != 8) || bl >= sizeof base) return 0;
    memcpy(base, name + 7, bl);
    base[bl] = '\0';
    for (i = 0; i < 6 && mode == 0; i++) {
      char want[40];
      snprintf(want, sizeof want, "fetch_and_%s", ops[i]);
      if (strcmp(base, want) == 0) { mode = 5; op = i; }
      snprintf(want, sizeof want, "%s_and_fetch", ops[i]);
      if (strcmp(base, want) == 0) { mode = 6; op = i; }
    }
    if (strcmp(base, "bool_compare_and_swap") == 0) mode = 7;
    else if (strcmp(base, "val_compare_and_swap") == 0) mode = 8;
    else if (strcmp(base, "lock_test_and_set") == 0) mode = 9;
    else if (strcmp(base, "lock_release") == 0) mode = 10;
  }
  if (mode == 0) return 0;
  for (a[0] = ir_operand(e, 1); a[n] != NULL && n < 3; n++) a[n + 1] = a[n]->next;
  for (i = 0; i < n; i++) v[i] = ir_rval(a[i]);
  if ((mode == 3 || mode == 4 || mode == 10) && n < 1) return 0;
  if ((mode == 5 || mode == 6 || mode == 9) && n < 2) return 0;
  if ((mode == 7 || mode == 8) && n < 3) return 0;
  ir_note(0, eok_call, 1);
  {
    const char *ty = ir_uty(sz), *rt = ir_valtext(e->type);
    switch (mode) {
      case 1:
        ir_emit("(barrier)");
        *out = ir_mk_void();
        return 1;
      case 2:
        ir_full_fence();
        *out = ir_mk_void();
        return 1;
      case 3: {
        char *old = ir_let("unsigned_char", ir_fmt("(call unsigned_char &\"__atomic_exchange_1\" %s (const unsigned_char 1) (const int 5))", v[0].s));
        *out = ir_mk_bool(ir_let("bool", ir_fmt("(ne unsigned_char %s (const unsigned_char 0))", old)));
        return 1;
      }
      case 4:
        ir_emit(ir_fmt("(eval (call void &\"__atomic_store_1\" %s (const unsigned_char 0) (const int 5)))", v[0].s));
        *out = ir_mk_void();
        return 1;
      case 5:
        *out = ir_mk_value(ir_let(rt, ir_fmt("(call %s &\"__atomic_fetch_%s_%d\" %s %s (const int 5))", rt, ops[op], sz, v[0].s, v[1].s)), e->type);
        return 1;
      case 6:
        *out = ir_mk_value(ir_let(rt, ir_fmt("(call %s &\"__atomic_%s_fetch_%d\" %s %s (const int 5))", rt, ops[op], sz, v[0].s, v[1].s)), e->type);
        return 1;
      case 7:
      case 8: {
        /* the expected value lives in a temporary that the exchange updates with the value it found */
        ir_val t = ir_temp(integer_type(sz == 1 ? ik_unsigned_char : sz == 2 ? ik_unsigned_short : sz == 4 ? ik_unsigned_int : ik_unsigned_long));
        char *ok;
        ir_emit(ir_fmt("(store %s %s %s)", ty, t.s, ir_cv(ty, v[1].s)));
        ok = ir_let("bool", ir_fmt("(call bool &\"__atomic_compare_exchange_%d\" %s %s %s (const int 0) (const int 5) (const int 5))", sz, v[0].s, t.s, ir_cv(ty, v[2].s)));
        if (mode == 7) *out = ir_mk_value(ir_cv(rt, ok), e->type);
        else *out = ir_mk_value(ir_cv(rt, ir_let(ty, ir_fmt("(load %s %s)", ty, t.s))), e->type);
        return 1;
      }
      case 9:
        *out = ir_mk_value(ir_let(rt, ir_fmt("(call %s &\"__atomic_exchange_%d\" %s %s (const int 5))", rt, sz, v[0].s, v[1].s)), e->type);
        return 1;
      default:
        ir_emit(ir_fmt("(eval (call void &\"__atomic_store_%d\" %s (const %s 0) (const int 5)))", sz, v[0].s, ty));
        *out = ir_mk_void();
        return 1;
    }
  }
}

/* 1 when the asm entry is a single `pause` / `rep nop` / `rep; nop` / `nop` with no operands, no labels and at most
   "memory" and "cc" clobbers: an instruction with no effect the program can observe. 2 when it is such an instruction but
   declares a register clobber (the call that replaces it would not clobber that register: refused as asm-clobbers). */
static int ir_asm_is_nop(an_asm_entry_ptr ae)
{
  char norm[16];
  size_t k, m = 0, len;
  const char *t;
  a_named_register_list_ptr cl;
  if (ae == NULL || ae->asm_string == NULL || ae->asm_string->kind != ck_string || ae->is_asm_goto || ae->operands != NULL) return 0;
  t = ae->asm_string->variant.string.value;
  len = (size_t)ae->asm_string->variant.string.length;
  for (k = 0; k < len && t[k] != '\0'; k++) {
    char c = t[k];
    if (c == ' ' || c == '\t' || c == '\n' || c == ';') continue;
    if (m >= sizeof norm - 1) return 0;
    norm[m++] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
  }
  norm[m] = '\0';
  if (strcmp(norm, "pause") != 0 && strcmp(norm, "repnop") != 0 && strcmp(norm, "nop") != 0) return 0;
  for (cl = ae->clobbers; cl != NULL; cl = cl->next) if (cl->reg != anr_memory && cl->reg != anr_flags) return 2;
  return 1;
}

static void ir_abi_note(a_type_ptr t);
/* The type text of an aggregate in a call: `(struct "N")`, unqualified. */
static char *ir_abi_ty(a_type_ptr t)
{
  ir_abi_note(t);
  return ir_capture_type(t, 1);
}

/* Call of a routine or through a function pointer. Aggregate arguments are copied into temporaries and passed as
   (byval TYPE ADDR); an aggregate result is written to a temporary passed as the first argument, (sret TYPE ADDR). The
   emitter turns both into the C calling convention of the target (docs/notes/pathb-hosted.md, "Aggregates by value"). */
static ir_val ir_call(an_expr_node_ptr e)
{
  an_expr_node_ptr f = ir_operand(e, 0);
  an_expr_node_ptr arg;
  char *callee;
  char *args = ir_dup("");
  int agg_ret = ir_is_aggregate(e->type);
  ir_val sret = ir_mk_void();
  if (f->kind == enk_routine) {
    const char *bsym = ir_builtin_sym(f->variant.routine.ptr->source_corresp.name);
    ir_note(2, enk_routine, 1);
    if (bsym != NULL) {
      ir_val bv;
      if (ir_builtin_call(e, f->variant.routine.ptr->source_corresp.name + 10, &bv)) return bv;
    } else if (f->variant.routine.ptr->source_corresp.name != NULL &&
               strcmp(f->variant.routine.ptr->source_corresp.name, "alloca") == 0 &&
               f->variant.routine.ptr->function_def_number == NULL_function_def_number) {
      /* <alloca.h>'s `alloca` declared as a function (EDG does not apply the macro): the same dynamic stack storage */
      ir_val bv;
      if (ir_builtin_call(e, "alloca", &bv)) return bv;
    } else if (f->variant.routine.ptr->source_corresp.name != NULL &&
               (strncmp(f->variant.routine.ptr->source_corresp.name, "__sync_", 7) == 0 ||
                strncmp(f->variant.routine.ptr->source_corresp.name, "__atomic_", 9) == 0)) {
      ir_val bv;
      if (ir_atomic_call(e, f->variant.routine.ptr->source_corresp.name, &bv)) return bv;
    }
    callee = ir_fmt("&\"%s\"", bsym != NULL ? bsym : ir_rout_name(f->variant.routine.ptr));
  } else {
    ir_val fv = ir_rval(f);
    ir_nonnull(f, fv); /* a call through a null function pointer traps (stage 2, gap 9) */
    callee = fv.s;
  }
  if (agg_ret) {
    sret = ir_temp(e->type);
    args = ir_fmt("%s (sret %s %s)", args, ir_abi_ty(e->type), sret.s);
  }
  for (arg = ir_operand(e, 1); arg != NULL; arg = arg->next) {
    ir_val a = ir_rval(arg);
    if (ir_is_aggregate(a.t)) {
      ir_val tmp = ir_temp(a.t);
      ir_copy(a.t, tmp.s, a.s);
      args = ir_fmt("%s (byval %s %s)", args, ir_abi_ty(a.t), tmp.s);
    } else {
      args = ir_fmt("%s %s", args, a.s);
    }
  }
  /* A variadic callee: (variadic N) gives the number of leading ARGs (the hidden result pointer included)
     that match named parameters; the rest are the "..." arguments. */
  {
    a_type_ptr ft = ir_callee_fn_type(f);
    if (ft != NULL && ft->variant.routine.extra_info != NULL && ft->variant.routine.extra_info->has_ellipsis) {
      a_param_type_ptr p;
      int named = agg_ret ? 1 : 0;
      for (p = ft->variant.routine.extra_info->param_type_list; p != NULL; p = p->next) named++;
      callee = ir_fmt("%s (variadic %d)", callee, named);
    }
  }
  ir_note(0, eok_call, 1);
  if (ir_is_void(e->type) || agg_ret) {
    ir_emit(ir_fmt("(eval (call void %s%s))", callee, args));
    if (agg_ret) return ir_mk_addr(sret.s, e->type, 0);
    return ir_mk_void();
  }
  return ir_mk_value(ir_let(ir_valtext(e->type), ir_fmt("(call %s %s%s)", ir_valtext(e->type), callee, args)), e->type);
}

/* enk_result_of_overriding_function: the body of an IA-64 this-adjusting thunk (for example the destructor of a
   second base class) or of a covariant-return wrapper calls the underlying function with the thunk's own
   parameters, as c_gen_be.c's dump_result_of_overriding_function writes it. The thunk has already adjusted its
   `this` parameter in its slot. */
static ir_val ir_roof(an_expr_node_ptr e)
{
  a_routine_ptr under = ir_cur_rout != NULL ? ir_cur_rout->overriding_function_for_wrapper : NULL;
  a_scope_ptr scope = ir_cur_rout != NULL ? scope_for_routine(ir_cur_rout) : NULL;
  a_variable_ptr param;
  char *args = ir_dup("");
  int agg_ret = ir_is_aggregate(e->type);
  ir_val sret = ir_mk_void();
  char *callee;
  a_type_ptr ft;
  if (under == NULL || scope == NULL) return ir_gap(e->type, "node result_of_overriding_function", 2, (int)e->kind);
  ft = skip_typerefs(ir_cur_rout->type);
  if (ft->variant.routine.extra_info != NULL && ft->variant.routine.extra_info->has_ellipsis) {
    return ir_gap(e->type, "node result_of_overriding_function (variadic)", 2, (int)e->kind);
  }
  ir_note(2, enk_result_of_overriding_function, 1);
  callee = ir_fmt("&\"%s\"", ir_name_or(ir_rout_sym(under), "fn"));
  if (agg_ret) {
    sret = ir_temp(e->type);
    args = ir_fmt("%s (sret %s %s)", args, ir_abi_ty(e->type), sret.s);
  }
  for (param = scope->variant.routine.parameters; param != NULL; param = param->next) {
    ir_val a = ir_var_addr(param, param->type, 0);
    if (ir_is_aggregate(param->type)) {
      ir_val tmp = ir_temp(param->type);
      ir_copy(param->type, tmp.s, a.s);
      args = ir_fmt("%s (byval %s %s)", args, ir_abi_ty(param->type), tmp.s);
    } else {
      args = ir_fmt("%s %s", args, ir_load(a).s);
    }
  }
  ir_note(0, eok_call, 1);
  if (ir_is_void(e->type) || agg_ret) {
    ir_emit(ir_fmt("(eval (call void %s%s))", callee, args));
    if (agg_ret) return ir_mk_addr(sret.s, e->type, 0);
    return ir_mk_void();
  }
  return ir_mk_value(ir_let(ir_valtext(e->type), ir_fmt("(call %s %s%s)", ir_valtext(e->type), callee, args)), e->type);
}

/* Conversions. Integer conversions extend by the source signedness and truncate otherwise. */
static ir_val ir_cast(an_expr_node_ptr e)
{
  an_expr_node_ptr a0 = ir_operand(e, 0);
  a_type_ptr dst = e->type;
  ir_val a;
  if (ir_is_void(dst)) {
    (void)ir_rval(a0);
    ir_note(0, eok_cast, 1);
    return ir_mk_void();
  }
  a = ir_rval(a0);
  if (ir_is_aggregate(dst)) {
    ir_note(0, eok_cast, 1);
    return ir_mk_value(a.s, dst);
  }
  if (ir_is_bool(dst)) {
    ir_note(0, eok_cast, 1);
    return ir_mk_bool(ir_to_bool(a));
  }
  if (a.t == NULL) {
    /* A bool value (a comparison, !, &&, ||) has no EDG type. It converts as the 0 or 1 it holds. */
    if (ir_is_integer(dst)) {
      ir_note(0, eok_cast, 1);
      return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(iconv %s %s)", ir_valtext(dst), a.s)), dst);
    }
    if (ir_is_float(dst)) {
      ir_note(0, eok_cast, 1);
      return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(u2f %s %s)", ir_valtext(dst), a.s)), dst);
    }
  }
  if (ir_is_integer(dst)) {
    if (ir_is_integer(a.t)) {
      if (strcmp(ir_valtext(dst), a.ty) == 0) return ir_mk_value(a.s, dst);
      return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(iconv %s %s)", ir_valtext(dst), a.s)), dst);
    }
    if (ir_is_float(a.t)) {
      ir_note(0, eok_cast, 1);
      return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(cf2i %s %s)", ir_valtext(dst), a.s)), dst);
    }
    if (ir_is_pointer(a.t)) {
      ir_note(0, eok_cast, 1);
      return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(p2i %s %s)", ir_valtext(dst), a.s)), dst);
    }
  } else if (ir_is_float(dst)) {
    if (ir_is_integer(a.t)) {
      ir_note(0, eok_cast, 1);
      return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(%s %s %s)", ir_is_signed(a.t) ? "i2f" : "u2f",
                                                        ir_valtext(dst), a.s)),
                         dst);
    }
    if (ir_is_float(a.t)) {
      if (strcmp(ir_valtext(dst), a.ty) == 0) return ir_mk_value(a.s, dst);
      return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(fconv %s %s)", ir_valtext(dst), a.s)), dst);
    }
  } else if (ir_is_pointer(dst)) {
    if (ir_is_pointer(a.t)) {
      if (strcmp(ir_valtext(dst), a.ty) == 0) return ir_mk_value(a.s, dst);
      return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(bitcast %s %s)", ir_valtext(dst), a.s)), dst);
    }
    if (ir_is_integer(a.t)) {
      ir_note(0, eok_cast, 1);
      return ir_mk_value(ir_let(ir_valtext(dst), ir_fmt("(i2p %s %s)", ir_valtext(dst), a.s)), dst);
    }
  }
  return ir_gap(dst, "cast", 0, (int)eok_cast);
}

/* ?: as control flow. A scalar or address result is a register assigned on each arm. */
static ir_val ir_question(an_expr_node_ptr e)
{
  an_expr_node_ptr c0 = ir_operand(e, 0), x = ir_operand(e, 1), y = ir_operand(e, 2);
  int d = ir_depth;
  char *cb;
  cb = ir_to_bool(ir_rval(c0));
  if (ir_is_void(e->type)) {
    ir_line(d, ir_fmt("(if %s", cb));
    ir_line(d + 1, "(then");
    ir_depth = d + 2;
    (void)ir_rval(x);
    ir_close(1);
    ir_line(d + 1, "(else");
    ir_depth = d + 2;
    (void)ir_rval(y);
    ir_close(1);
    ir_close(1);
    ir_depth = d;
    ir_note(0, eok_question, 1);
    return ir_mk_void();
  } else {
    char *r = ir_newreg();
    char *zero = ir_is_aggregate(e->type) ? ir_fmt("(null %s)", ir_valtext(e->type)) : ir_zero(e->type);
    ir_emit(ir_fmt("(let %s %s %s)", r, ir_valtext(e->type), zero));
    ir_line(d, ir_fmt("(if %s", cb));
    ir_line(d + 1, "(then");
    ir_depth = d + 2;
    {
      ir_val v = ir_rval(x);
      ir_emit(ir_fmt("(set %s %s)", r, v.s));
    }
    ir_close(1);
    ir_line(d + 1, "(else");
    ir_depth = d + 2;
    {
      ir_val v = ir_rval(y);
      ir_emit(ir_fmt("(set %s %s)", r, v.s));
    }
    ir_close(1);
    ir_close(1);
    ir_depth = d;
    ir_note(0, eok_question, 1);
    return ir_mk_value(r, e->type);
  }
}

/* && and || as control flow, with a bool register for the result. */
static ir_val ir_logic(an_expr_node_ptr e, int is_and)
{
  an_expr_node_ptr a0 = ir_operand(e, 0), a1 = ir_operand(e, 1);
  int d = ir_depth;
  char *ab = ir_to_bool(ir_rval(a0));
  char *r = ir_let("bool", is_and ? "(const bool 0)" : "(const bool 1)");
  if (is_and) {
    ir_line(d, ir_fmt("(if %s", ab));
    ir_line(d + 1, "(then");
    ir_depth = d + 2;
    {
      char *bb = ir_to_bool(ir_rval(a1));
      ir_emit(ir_fmt("(set %s %s)", r, bb));
    }
    ir_close(1);
    ir_close(1);
  } else {
    ir_line(d, ir_fmt("(if %s", ab));
    ir_line(d + 1, "(then)");
    ir_line(d + 1, "(else");
    ir_depth = d + 2;
    {
      char *bb = ir_to_bool(ir_rval(a1));
      ir_emit(ir_fmt("(set %s %s)", r, bb));
    }
    ir_close(1);
    ir_close(1);
  }
  ir_depth = d;
  ir_note(0, is_and ? eok_land : eok_lor, 1);
  return ir_mk_bool(r);
}

/* ================================================================ initializers */

/* One element of an aggregate constant: a direct base class or a non-static data member, in the order
   EDG's aggregate constants use (direct bases first, then the members). Returns -1 when the class has a
   virtual base. Named bit-fields are members (bf set); unnamed ones are skipped. */
struct ir_member {
  unsigned long off;
  a_type_ptr t;
  a_field_ptr bf; /* the field when it is a bit-field (off is then its byte offset component), else NULL */
};

static int ir_is_base_storage(a_class_type_supplement_ptr extra, a_field_ptr f)
{
  a_base_class_ptr b;
  if (extra == NULL) return 0;
  for (b = extra->direct_base_classes; b != NULL; b = b->next_direct) {
    if (b->is_virtual || b->offset != f->offset) continue;
    if (skip_typerefs(b->type) == skip_typerefs(f->type)) return 1;
    /* A base whose tail padding is reused (a non-POD base) gets a field of the EDG-made type "base without the
       padding", also named __b_N, and smaller than the base. It is the same storage as the base. */
    if (f->source_corresp.name != NULL && strncmp(f->source_corresp.name, "__b_", 4) == 0 &&
        f->type != NULL && ir_is_aggregate(f->type) && ir_size_of(f->type) <= ir_size_of(b->type)) {
      return 1;
    }
  }
  return 0;
}

static int ir_class_members(a_type_ptr t, ir_member *out, int max)
{
  a_type_ptr s = skip_typerefs(t);
  int n = 0;
  a_class_type_supplement_ptr extra = s->variant.class_struct_union.extra_info;
  a_base_class_ptr b;
  a_field_ptr f;
  if (extra != NULL) {
    for (b = extra->direct_base_classes; b != NULL; b = b->next_direct) {
      /* A direct empty base takes no part in the lowered struct, and a constant list has no entry for it. */
      if (b->is_optimized_empty_base) continue;
      if (b->is_virtual || n >= max) return -1;
      out[n].off = (unsigned long)b->offset;
      out[n].t = b->type;
      out[n].bf = NULL;
      n++;
    }
  }
  for (f = s->variant.class_struct_union.field_list; f != NULL; f = f->next) {
    /* EDG adds a field __b_N for a base subobject that is already a direct base (same type, same offset).
       It is the same storage as that base, so it is not a second element. */
    if (ir_is_base_storage(extra, f)) continue;
    if (f->is_optimized_empty_class) continue; /* [[no_unique_address]] empty member: not in the lowered struct */
    /* An unnamed bit-field (padding, or :0) takes no initializer. */
    if (f->is_bit_field && (f->source_corresp.name == NULL || f->source_corresp.name[0] == '\0')) continue;
    if (n >= max) return -1;
    out[n].off = (unsigned long)f->offset;
    out[n].t = f->type;
    out[n].bf = f->is_bit_field ? f : NULL;
    n++;
  }
  return n;
}

/* Store zero bytes over [off, off + n) of the object at base, in the widest naturally aligned integer stores.
   Returns 0 (and emits nothing) when that would take more than 128 stores. */
/* 1 when the constant is the integer 0 (a repeated zero is a block of zero bytes). */
static int ir_const_is_zero(a_constant_ptr c)
{
  return c != NULL && c->kind == ck_integer && strcmp(ir_capture_constant(c), "0") == 0;
}

static int ir_zero_bytes(const char *base, unsigned long off, unsigned long n)
{
  unsigned long cnt = 0, o = off, left = n;
  while (left > 0) {
    unsigned long w = (o % 8 == 0 && left >= 8) ? 8 : (o % 4 == 0 && left >= 4) ? 4 : (o % 2 == 0 && left >= 2) ? 2 : 1;
    o += w;
    left -= w;
    if (++cnt > 128) {
      /* too many stores: one fill of the whole range (a call of memset in the emitter) */
      ir_emit(ir_fmt("(zero-fill %lu %s)", n, ir_subobject(base, off, integer_type(ik_unsigned_char), 0).s));
      return 1;
    }
  }
  o = off;
  left = n;
  while (left > 0) {
    unsigned long w = (o % 8 == 0 && left >= 8) ? 8 : (o % 4 == 0 && left >= 4) ? 4 : (o % 2 == 0 && left >= 2) ? 2 : 1;
    a_type_ptr it = integer_type(w == 8 ? ik_unsigned_long : w == 4 ? ik_unsigned_int : w == 2 ? ik_unsigned_short : ik_unsigned_char);
    ir_val sub = ir_subobject(base, o, it, 0);
    ir_store(it, sub.s, ir_zero(it), 0);
    o += w;
    left -= w;
  }
  return 1;
}

/* Zero an object: a scalar store, or the zero stores over an aggregate's bytes (a pointer's zero is all-bits-zero
   on every target Path B emits). */
static void ir_zero_object(ir_val dst, a_type_ptr t)
{
  if (ir_is_aggregate(t)) {
    if (!ir_zero_bytes(dst.s, 0, ir_size_of(t))) ir_emit("(unsupported init zero-aggregate)");
    return;
  }
  ir_store(t, dst.s, ir_zero(t), dst.vol);
}

/* The member a union's aggregate constant initializes: a ck_designator in front of the value names it, else it is
   the first non-empty initializable field (EDG's own rule in dump_initializer_part). *val is the value constant,
   NULL for an empty initializer. Returns NULL when there is no field to initialize. */
static a_field_ptr ir_union_member(a_type_ptr u, a_constant_ptr c, a_constant_ptr *val)
{
  a_constant_ptr ce = c->variant.aggregate.first_constant;
  a_field_ptr f = NULL;
  *val = NULL;
  if (ce != NULL && ce->kind == ck_designator) {
    f = ce->variant.designator.variant.field;
    ce = ce->next;
  } else {
    f = next_applicable_field(skip_typerefs(u)->variant.class_struct_union.field_list,
                              (a_next_field_options_set)(NF_INITIALIZABLE | NF_SKIP_OPTIMIZED_EMPTY_CLASS | NF_SKIP_PROPERTY_OR_EVENT));
  }
  *val = ce;
  return f;
}

/* ---------------------------------------------------------------- C ABI shape of aggregates by value

   A struct or class passed or returned by value follows the platform's C calling convention (System V x86-64 here), so
   that calls to and from code the C++ library, C and other compilers built agree: std::pair<bool, size_t> comes back from
   libstdc++'s hashtable policy in rax:rdx, a div_t from div(). The IR cannot say how, so every aggregate used in a
   (sret ...) or (byval ...) gets a module-level form
     (abi-type "NAME" SIZE ALIGN (leaf OFF K)...)   its scalars, K one of b h w l s d (QBE's names), at their offsets
     (abi-type "NAME" SIZE ALIGN (memory))          more than 16 bytes: passed in memory
     (abi-type "NAME" SIZE ALIGN (empty))           no data: not passed at all
     (abi-type "NAME" SIZE ALIGN (unsupported "WHY"))  a shape the emitter cannot describe (union, bit-field, long double)
   The emitter classifies the eightbytes from the leaves (QBE does it for its aggregate types). EDG's lowering has
   already turned classes with a non-trivial copy constructor or destructor into pointer arguments and results, so
   what reaches here is trivial aggregates, for which the Itanium C++ ABI follows the C rules. */
struct ir_leaf {
  unsigned long off;
  char kind;
};

#define IR_LEAF_MAX 32

/* The scalars of t at offset base: 1 on success, else 0 with the reason in *why. */
static int ir_abi_collect(a_type_ptr t, unsigned long base, ir_leaf *lv, int *n, const char **why)
{
  a_type_ptr s = skip_typerefs(t);
  unsigned long sz = ir_size_of(s);
  switch (s->kind) {
    case tk_integer: {
      char k = sz == 1 ? 'b' : sz == 2 ? 'h' : sz == 4 ? 'w' : sz == 8 ? 'l' : 0;
      if (k == 0) { *why = "integer type of this size"; return 0; }
      if (*n >= IR_LEAF_MAX) { *why = "too many members"; return 0; }
      lv[*n].off = base; lv[*n].kind = k; (*n)++;
      return 1;
    }
    case tk_pointer:
      if (*n >= IR_LEAF_MAX) { *why = "too many members"; return 0; }
      lv[*n].off = base; lv[*n].kind = 'l'; (*n)++;
      return 1;
    case tk_float:
      if (sz != 4 && sz != 8) { *why = "long double"; return 0; }
      if (*n >= IR_LEAF_MAX) { *why = "too many members"; return 0; }
      lv[*n].off = base; lv[*n].kind = sz == 4 ? 's' : 'd'; (*n)++;
      return 1;
    case tk_ptr_to_member:
      if (sz != 8 && sz != 16) { *why = "pointer to member of this size"; return 0; }
      if (*n + 2 > IR_LEAF_MAX) { *why = "too many members"; return 0; }
      lv[*n].off = base; lv[*n].kind = 'l'; (*n)++;
      if (sz == 16) { lv[*n].off = base + 8; lv[*n].kind = 'l'; (*n)++; }
      return 1;
    case tk_array: {
      a_type_ptr el = s->variant.array.element_type;
      unsigned long cnt = (unsigned long)s->variant.array.variant.number_of_elements, esz = ir_size_of(el), i;
      if (s->variant.array.is_variable_size_array) { *why = "variable-length array"; return 0; }
      for (i = 0; i < cnt; i++) {
        if (!ir_abi_collect(el, base + i * esz, lv, n, why)) return 0;
      }
      return 1;
    }
    case tk_class:
    case tk_struct: {
      ir_member mem[256];
      int cnt = ir_class_members(t, mem, 256), i, j;
      if (cnt < 0) { *why = "virtual base"; return 0; }
      for (i = 0; i < cnt; i++) {
        if (mem[i].bf != NULL) {
          /* A bit-field only makes its eightbyte INTEGER: one byte leaf at its byte offset (the size of the type is
             declared separately). Several fields in one byte give one leaf. */
          int dup = 0;
          for (j = 0; j < *n; j++) if (lv[j].off == base + mem[i].off && lv[j].kind == 'b') dup = 1;
          if (!dup) {
            if (*n >= IR_LEAF_MAX) { *why = "too many members"; return 0; }
            lv[*n].off = base + mem[i].off; lv[*n].kind = 'b'; (*n)++;
          }
          continue;
        }
        if (!ir_abi_collect(mem[i].t, base + mem[i].off, lv, n, why)) return 0;
      }
      return 1;
    }
    case tk_union: {
      /* The members overlap, so each eightbyte of the union is INTEGER when any member puts an integer or pointer in
         it, else SSE (the psABI merge). The union becomes leaves that are not its members': l (or w, h, b for a tail)
         for INTEGER, d or s for SSE. */
      ir_leaf sub[IR_LEAF_MAX];
      int sn = 0, k, i;
      a_field_ptr f;
      unsigned long nb = (sz + 7) / 8;
      for (f = s->variant.class_struct_union.field_list; f != NULL; f = f->next) {
        if (f->is_bit_field) {
          if (sn >= IR_LEAF_MAX) { *why = "too many members"; return 0; }
          sub[sn].off = 0; sub[sn].kind = 'b'; sn++;
          continue;
        }
        if (!ir_abi_collect(f->type, 0, sub, &sn, why)) return 0;
      }
      for (k = 0; (unsigned long)k < nb; k++) {
        int is_int = 0, is_sse = 0;
        unsigned long left = sz - (unsigned long)k * 8 < 8 ? sz - (unsigned long)k * 8 : 8, off = (unsigned long)k * 8;
        for (i = 0; i < sn; i++) {
          if (sub[i].off >= off + 8 || sub[i].off + (sub[i].kind == 'b' ? 1 : sub[i].kind == 'h' ? 2 : (sub[i].kind == 'w' || sub[i].kind == 's') ? 4 : 8) <= off) continue;
          if (sub[i].kind == 's' || sub[i].kind == 'd') is_sse = 1; else is_int = 1;
        }
        if (!is_int && !is_sse) continue;
        if (!is_int) {
          if (left != 8 && left != 4) { *why = "union with a float in an odd-sized eightbyte"; return 0; }
          if (*n >= IR_LEAF_MAX) { *why = "too many members"; return 0; }
          lv[*n].off = base + off; lv[*n].kind = left == 8 ? 'd' : 's'; (*n)++;
          continue;
        }
        while (left > 0) {
          unsigned long chunk = left >= 8 ? 8 : left >= 4 ? 4 : left >= 2 ? 2 : 1;
          if (*n >= IR_LEAF_MAX) { *why = "too many members"; return 0; }
          lv[*n].off = base + off; lv[*n].kind = chunk == 8 ? 'l' : chunk == 4 ? 'w' : chunk == 2 ? 'h' : 'b'; (*n)++;
          off += chunk; left -= chunk;
        }
      }
      return 1;
    }
    default:
      *why = "type kind";
      return 0;
  }
}

/* va_arg of a struct, class or union by value, System V x86-64. The va_list is the 24-byte tag { unsigned gp_offset;
   unsigned fp_offset; void *overflow_arg_area; void *reg_save_area; } that QBE's vastart fills (and glibc's v*printf read).
   QBE's own vaarg takes scalars only, so the psABI's algorithm is spelled out in IR, with the classification the
   by-value calls use (ir_abi_collect): an aggregate of up to 16 bytes whose eightbytes are INTEGER or SSE is fetched
   from the register save area, one eightbyte from the next general register slot (8 bytes at gp_offset) or the next
   vector slot (16 bytes at fp_offset), when enough of both kinds are left (gp_offset <= 48 - 8 * n_int and
   fp_offset <= 176 - 16 * n_sse); otherwise, and for every larger or memory-class aggregate (more than 16 bytes, a long
   double member), it is copied from overflow_arg_area, which then advances by the size rounded up to 8. An empty class
   takes nothing from the list. An aggregate aligned to 16 bytes or more, or a shape the by-value convention cannot
   describe, stays a gap marker. */
static ir_val ir_vaarg_aggregate(an_expr_node_ptr e, const char *ap)
{
  a_type_ptr t = e->type;
  unsigned long size = ir_size_of(t), align = ir_align_of(t);
  ir_leaf lv[IR_LEAF_MAX];
  int n = 0, i, ngp = 0, nfp = 0, cls[2] = { 0, 0 }, reg = 0, d = ir_depth;
  const char *why = "";
  ir_val tmp;
  char *gp = NULL, *fp = NULL, *ok = NULL;
  if (align > 8) return ir_gap(t, "op va_arg (aggregate aligned to 16 bytes)", 0, (int)eok_va_arg);
  if (size <= 16) {
    if (ir_abi_collect(t, 0, lv, &n, &why)) {
      reg = n > 0;
      for (i = 0; i < n; i++) {
        int c = (lv[i].kind == 's' || lv[i].kind == 'd') ? 2 : 1, idx = (int)(lv[i].off / 8);
        if (idx > 1) { reg = 0; break; }
        if (cls[idx] == 0 || c == 1) cls[idx] = c;
      }
      if (n == 0) {
        ir_note(0, eok_va_arg, 1);
        tmp = ir_temp(t);
        return ir_mk_addr(tmp.s, t, 0);
      }
      if (reg) {
        for (i = 0; i < (int)((size + 7) / 8); i++) { if (cls[i] == 0) cls[i] = 1; if (cls[i] == 1) ngp++; else nfp++; }
      }
    } else if (strcmp(why, "long double") != 0) {
      return ir_gap(t, ir_fmt("op va_arg (aggregate: %s)", why), 0, (int)eok_va_arg);
    }
  }
  ir_note(0, eok_va_arg, 1);
  tmp = ir_temp(t);
  if (reg) {
    char *pgp = ir_let("(ptr unsigned_int)", ir_fmt("(offset %s 0)", ap)), *pfp = ir_let("(ptr unsigned_int)", ir_fmt("(offset %s 4)", ap));
    gp = ir_let("unsigned_int", ir_fmt("(load unsigned_int %s)", pgp));
    fp = ir_let("unsigned_int", ir_fmt("(load unsigned_int %s)", pfp));
    ok = ir_let("bool", "(const bool 1)");
    if (ngp > 0) {
      ir_line(d, ir_fmt("(if %s", ir_let("bool", ir_fmt("(lt.u unsigned_int %s %s)", ir_k("unsigned_int", 48 - 8UL * (unsigned long)ngp), gp))));
      ir_line(d + 1, "(then");
      ir_line(d + 2, ir_fmt("(set %s (const bool 0))", ok));
      ir_close(1);
      ir_close(1);
    }
    if (nfp > 0) {
      ir_line(d, ir_fmt("(if %s", ir_let("bool", ir_fmt("(lt.u unsigned_int %s %s)", ir_k("unsigned_int", 176 - 16UL * (unsigned long)nfp), fp))));
      ir_line(d + 1, "(then");
      ir_line(d + 2, ir_fmt("(set %s (const bool 0))", ok));
      ir_close(1);
      ir_close(1);
    }
    ir_line(d, ir_fmt("(if %s", ok));
    ir_line(d + 1, "(then");
    ir_depth = d + 2;
    {
      char *prs = ir_let("(ptr void)", ir_fmt("(offset %s 16)", ap));
      char *rsa = ir_let("(ptr void)", ir_fmt("(load (ptr void) %s)", prs));
      char *gb = ir_let("(ptr void)", ir_fmt("(index %s %s 1)", rsa, ir_cv("long", gp)));
      char *fb = ir_let("(ptr void)", ir_fmt("(index %s %s 1)", rsa, ir_cv("long", fp)));
      int gi = 0, fi = 0;
      for (i = 0; i < (int)((size + 7) / 8); i++) {
        unsigned long nb = size - 8UL * (unsigned long)i < 8 ? size - 8UL * (unsigned long)i : 8;
        char *src = cls[i] == 1 ? ir_let("(ptr void)", ir_fmt("(offset %s %d)", gb, 8 * gi++)) : ir_let("(ptr void)", ir_fmt("(offset %s %d)", fb, 16 * fi++));
        char *dst = ir_let("(ptr void)", ir_fmt("(offset %s %d)", tmp.s, 8 * i));
        ir_emit(ir_fmt("(copy %lu %s %s)", nb, dst, src));
      }
      if (ngp > 0) ir_emit(ir_fmt("(store unsigned_int %s %s)", pgp, ir_o2("wadd", "unsigned_int", gp, ir_k("unsigned_int", 8UL * (unsigned long)ngp))));
      if (nfp > 0) ir_emit(ir_fmt("(store unsigned_int %s %s)", pfp, ir_o2("wadd", "unsigned_int", fp, ir_k("unsigned_int", 16UL * (unsigned long)nfp))));
    }
    ir_close(1);
    ir_line(d + 1, "(else");
    ir_depth = d + 2;
  }
  {
    char *pov = ir_let("(ptr void)", ir_fmt("(offset %s 8)", ap));
    char *ov = ir_let("(ptr void)", ir_fmt("(load (ptr void) %s)", pov));
    ir_emit(ir_fmt("(copy %lu %s %s)", size, tmp.s, ov));
    ir_emit(ir_fmt("(store (ptr void) %s %s)", pov, ir_let("(ptr void)", ir_fmt("(offset %s %lu)", ov, (size + 7) & ~7UL))));
  }
  if (reg) {
    ir_close(1);
    ir_close(1);
  }
  ir_depth = d;
  return ir_mk_addr(tmp.s, t, 0);
}

static ir_tab ir_abi_tab;

/* Print the (abi-type ...) form of aggregate type t once. */
static void ir_abi_note(a_type_ptr t)
{
  a_type_ptr s = skip_typerefs(t);
  char *txt, *q1, *q2;
  ir_leaf lv[IR_LEAF_MAX];
  int n = 0, i;
  const char *why = "";
  unsigned long size = ir_size_of(s), align = ir_align_of(s);
  int fresh = ir_tab_find(&ir_abi_tab, s) == NULL;
  if (!fresh) return;
  ir_tab_put(&ir_abi_tab, s, "x");
  txt = ir_capture_type(s, 1);
  q1 = strchr(txt, '"');
  q2 = strrchr(txt, '"');
  if (q1 == NULL || q2 == q1) return; /* not a named struct type */
  *q2 = '\0';
  ir_buf_begin(&ir_out_types);
  fprintf(nf_out, "(abi-type \"%s\" %lu %lu", q1 + 1, size, align);
  if (size > 16) {
    fputs(" (memory))\n", nf_out);
  } else if (!ir_abi_collect(s, 0, lv, &n, &why)) {
    fprintf(nf_out, " (unsupported \"%s\"))\n", why);
  } else if (n == 0) {
    fputs(" (empty))\n", nf_out);
  } else {
    for (i = 0; i < n; i++) fprintf(nf_out, " (leaf %lu %c)", lv[i].off, lv[i].kind);
    fputs(")\n", nf_out);
  }
  ir_buf_end(&ir_out_types);

}

/* Store constant c (of type t) into the object at address dst. Arrays are element-wise, classes are
   member-wise, and the remaining elements of either are zeroed when they are scalars. */
static void ir_init_constant(ir_val dst, a_constant_ptr c, a_type_ptr t)
{
  a_type_ptr s = skip_typerefs(t);
  if (c->kind == ck_aggregate && s->kind == tk_array) {
    a_type_ptr elem = s->variant.array.element_type;
    unsigned long n = (unsigned long)s->variant.array.variant.number_of_elements;
    unsigned long i = 0, esz = ir_size_of(elem);
    a_constant_ptr ce;
    for (ce = c->variant.aggregate.first_constant; ce != NULL && i < n; ce = ce->next, i++) {
      ir_val sub = ir_subobject(dst.s, i * esz, elem, 0);
      if (ce->kind == ck_init_repeat) {
        /* `T a[N] = {}` and friends: one constant repeated count times (a count that does not count whole elements is a
           multidimensional leaf count, which is not lowered) */
        a_constant_ptr rc = ce->variant.init_repeat.constant;
        unsigned long cnt = (unsigned long)ce->variant.init_repeat.count, j;
        if (cnt == 0 || rc == NULL || skip_typerefs(elem)->kind == tk_array) {
          ir_note(4, dik_constant, 0);
          ir_emit("(unsupported init repeat)");
          return;
        }
        if (cnt > n - i) cnt = n - i;
        if (ir_const_is_zero(rc) && !ir_is_aggregate(elem)) {
          ir_zero_bytes(dst.s, i * esz, cnt * esz);
        } else {
          for (j = 0; j < cnt; j++) {
            ir_val sj = ir_subobject(dst.s, (i + j) * esz, elem, 0);
            if (rc->kind == ck_aggregate || ir_is_aggregate(elem)) {
              ir_init_constant(sj, rc, elem);
            } else {
              ir_val v = ir_constant(rc, elem);
              ir_store(elem, sj.s, v.s, 0);
            }
          }
        }
        i += cnt - 1;
        continue;
      }
      if (ce->kind == ck_aggregate || ir_is_aggregate(elem)) {
        ir_init_constant(sub, ce, elem);
      } else {
        ir_val v = ir_constant(ce, elem);
        ir_store(elem, sub.s, v.s, 0);
      }
    }
    for (; i < n; i++) ir_zero_object(ir_subobject(dst.s, i * esz, elem, 0), elem);
    ir_note(4, dik_constant, 1);
    return;
  }
  if (c->kind == ck_aggregate && (s->kind == tk_class || s->kind == tk_struct)) {
    ir_member mem[256];
    int n = ir_class_members(t, mem, 256);
    int i = 0;
    a_constant_ptr ce;
    if (n < 0) {
      ir_note(4, dik_constant, 0);
      ir_emit("(unsupported init virtual-base)");
      return;
    }
    for (ce = c->variant.aggregate.first_constant; ce != NULL && i < n; ce = ce->next, i++) {
      if (mem[i].bf != NULL) {
        ir_val v = ir_constant(ce, mem[i].t);
        ir_store_lv(ir_bf_lval(dst.s, mem[i].bf, t, mem[i].t, 0), v.s);
        continue;
      }
      {
        ir_val sub = ir_subobject(dst.s, mem[i].off, mem[i].t, 0);
        if (ce->kind == ck_aggregate || ir_is_aggregate(mem[i].t)) {
          ir_init_constant(sub, ce, mem[i].t);
        } else {
          ir_val v = ir_constant(ce, mem[i].t);
          ir_store(mem[i].t, sub.s, v.s, 0);
        }
      }
    }
    for (; i < n; i++) {
      if (mem[i].bf != NULL) {
        ir_store_lv(ir_bf_lval(dst.s, mem[i].bf, t, mem[i].t, 0), ir_zero(mem[i].t));
        continue;
      }
      ir_zero_object(ir_subobject(dst.s, mem[i].off, mem[i].t, 0), mem[i].t);
    }
    ir_note(4, dik_constant, 1);
    return;
  }
  if (c->kind == ck_aggregate && s->kind == tk_union) {
    /* One member is initialized (see ir_union_member); the rest of the union's bytes are zero. */
    a_constant_ptr val;
    a_field_ptr f = ir_union_member(t, c, &val);
    unsigned long usz = ir_size_of(t);
    if (f == NULL || val == NULL || f->is_bit_field || ir_size_of(f->type) != usz) {
      if (!ir_zero_bytes(dst.s, 0, usz)) {
        ir_note(4, dik_constant, 0);
        ir_emit("(unsupported init zero-aggregate)");
        return;
      }
    }
    if (f != NULL && val != NULL) {
      if (f->is_bit_field) {
        ir_val v = ir_constant(val, f->type);
        ir_store_lv(ir_bf_lval(dst.s, f, t, f->type, 0), v.s);
      } else {
        ir_val sub = ir_subobject(dst.s, (unsigned long)f->offset, f->type, 0);
        if (val->kind == ck_aggregate || ir_is_aggregate(f->type)) {
          ir_init_constant(sub, val, f->type);
        } else {
          ir_val v = ir_constant(val, f->type);
          ir_store(f->type, sub.s, v.s, 0);
        }
      }
    }
    ir_note(4, dik_constant, 1);
    return;
  }
  if (c->kind == ck_aggregate) {
    /* Any other aggregate kind with an initializer list: not lowered yet. */
    ir_note(4, dik_constant, 0);
    ir_emit("(unsupported init aggregate-constant)");
    return;
  }
  if (c->kind == ck_string && s->kind == tk_array) {
    ir_val src = ir_constant(c, t);
    if (ir_size_of(t) != ir_size_of(c->type)) {
      ir_note(4, dik_constant, 0);
      ir_emit("(unsupported init string-size)");
      return;
    }
    ir_copy(t, dst.s, src.s);
    ir_note(4, dik_constant, 1);
    return;
  }
  if (c->kind == ck_integer && ir_is_aggregate(t)) {
    /* An empty class (an allocator, a comparison object) initialized by `{}` has the constant 0 */
    ir_zero_object(dst, t);
    ir_note(4, dik_constant, 1);
    return;
  }
  if (ir_is_aggregate(t)) {
    ir_note(4, dik_constant, 0);
    ir_emit("(unsupported init aggregate-constant)");
    return;
  }
  {
    ir_val v = ir_constant(c, t);
    ir_store(t, dst.s, v.s, dst.vol);
    ir_note(4, dik_constant, 1);
  }
}

/* ================================================================ static initializers */

/* File-scope objects print their static initializer as items at byte offsets. There is no function to hold
   the stores that ir_init_constant emits for locals, so each element becomes one item at the same offset, in
   the same order and with the same member and base ordering:
     (scalar OFF TYPE (const TYPE V))  a number, or (null PTR) for a null pointer
     (addr OFF TYPE TARGET ADD)        an address: TARGET is @"x" or &"f", ADD is a byte addend
     (bytes OFF BYTES @"const")        the bytes of a string literal, copied into an array
     (zero OFF BYTES)                  elements the initializer does not name (trailing array elements)
   Bytes that no item covers are padding. Nothing here creates a register, so these items are valid at module
   scope. */
static void ir_gi_items(unsigned long off, a_constant_ptr c, a_type_ptr t);

static void ir_gi_unsupported(const char *what)
{
  fprintf(nf_out, "\n    (unsupported init %s)", what);
}

static void ir_gi_scalar(unsigned long off, a_constant_ptr c, a_type_ptr t)
{
  const char *target = NULL;
  long add = 0;
  if (c->kind == ck_integer || c->kind == ck_float) {
    ir_val v = ir_const_value(c, t);
    ir_note(3, (int)c->kind, 1);
    fprintf(nf_out, "\n    (scalar %lu %s %s)", off, ir_valtext(t), v.s);
    return;
  }
  if (c->kind == ck_string) {
    target = ir_string_data(c);
  } else if (c->kind == ck_address) {
    add = (long)c->variant.address.offset;
    switch (c->variant.address.kind) {
      case abk_routine:
        if (add == 0) {
          target = ir_fmt("&\"%s\"", ir_rout_name(c->variant.address.variant.routine));
        }
        break;
      case abk_variable:
        target = ir_global_op(c->variant.address.variant.variable);
        break;
      case abk_constant:
        if (c->variant.address.variant.constant->kind == ck_string) {
          target = ir_string_data(c->variant.address.variant.constant);
        }
        break;
      default:
        break;
    }
    if (target == NULL) {
      ir_note(3, ck_address, 0);
      ir_gi_unsupported("address-constant");
      return;
    }
    ir_note(3, ck_address, 1);
  } else {
    ir_note(3, (int)c->kind, 0);
    ir_gi_unsupported(ir_fmt("constant %s", nfcxx_ck_name(c->kind) != NULL ? nfcxx_ck_name(c->kind) : "?"));
    return;
  }
  fprintf(nf_out, "\n    (addr %lu %s %s %ld)", off, ir_valtext(t), target, add);
}

static void ir_gi_items(unsigned long off, a_constant_ptr c, a_type_ptr t)
{
  a_type_ptr s = skip_typerefs(t);
  if (c == NULL) {
    fprintf(nf_out, "\n    (zero %lu %lu)", off, ir_size_of(t));
    return;
  }
  if (c->kind == ck_string && s->kind == tk_array) {
    if (ir_size_of(t) != ir_size_of(c->type)) {
      ir_gi_unsupported("string-size");
      return;
    }
    fprintf(nf_out, "\n    (bytes %lu %lu %s)", off, ir_size_of(t), ir_string_data(c));
    return;
  }
  if (c->kind == ck_aggregate && s->kind == tk_array) {
    a_type_ptr elem = s->variant.array.element_type;
    unsigned long n = (unsigned long)s->variant.array.variant.number_of_elements;
    unsigned long i = 0, esz = ir_size_of(elem);
    a_constant_ptr ce;
    for (ce = c->variant.aggregate.first_constant; ce != NULL && i < n; ce = ce->next, i++) {
      if (ce->kind == ck_init_repeat) {
        a_constant_ptr rc = ce->variant.init_repeat.constant;
        unsigned long cnt = (unsigned long)ce->variant.init_repeat.count, j;
        if (cnt == 0 || rc == NULL || skip_typerefs(elem)->kind == tk_array) {
          ir_gi_unsupported("repeat");
          return;
        }
        if (cnt > n - i) cnt = n - i;
        if (ir_const_is_zero(rc) && !ir_is_aggregate(elem)) fprintf(nf_out, "\n    (zero %lu %lu)", off + i * esz, cnt * esz);
        else for (j = 0; j < cnt; j++) ir_gi_items(off + (i + j) * esz, rc, elem);
        i += cnt - 1;
        continue;
      }
      ir_gi_items(off + i * esz, ce, elem);
    }
    if (i < n) fprintf(nf_out, "\n    (zero %lu %lu)", off + i * esz, (n - i) * esz);
    return;
  }
  if (c->kind == ck_aggregate && (s->kind == tk_class || s->kind == tk_struct)) {
    ir_member mem[256];
    int n = ir_class_members(t, mem, 256);
    int i = 0;
    a_constant_ptr ce;
    if (n < 0) {
      ir_gi_unsupported("virtual-base");
      return;
    }
    for (ce = c->variant.aggregate.first_constant; ce != NULL && i < n; ce = ce->next, i++) {
      if (mem[i].bf != NULL) {
        unsigned long uoff = 0;
        unsigned unit = 0, boff = 0;
        if (ce->kind != ck_integer || !ir_bf_layout(mem[i].bf, ir_size_of(t), &uoff, &unit, &boff)) {
          ir_gi_unsupported("bitfield");
          continue;
        }
        /* One item per bit-field; the consumer merges items that share a storage unit. */
        fprintf(nf_out, "\n    (bitfield %lu %u %u %u %s %s)", off + uoff, unit, boff, (unsigned)mem[i].bf->bit_size,
                ir_valtext(mem[i].t), ir_const_value(ce, mem[i].t).s);
        continue;
      }
      ir_gi_items(off + mem[i].off, ce, mem[i].t);
    }
    for (; i < n; i++) {
      if (mem[i].bf == NULL) fprintf(nf_out, "\n    (zero %lu %lu)", off + mem[i].off, ir_size_of(mem[i].t));
    }
    return;
  }
  if (c->kind == ck_integer && ir_is_aggregate(t)) {
    /* An empty class (an allocator, a comparison object) initialized by `{}` has the constant 0. Its one byte may
       share an offset with the first member (empty base optimization), so a size-1 object gets no item (uncovered
       bytes are zero anyway). */
    if (ir_size_of(t) != 1) fprintf(nf_out, "\n    (zero %lu %lu)", off, ir_size_of(t));
    return;
  }
  if (c->kind == ck_aggregate && s->kind == tk_union) {
    /* The initialized member, then zero for the rest of the union (see ir_union_member). */
    a_constant_ptr val;
    a_field_ptr f = ir_union_member(t, c, &val);
    unsigned long usz = ir_size_of(t), done = 0;
    if (f != NULL && val != NULL) {
      if (f->is_bit_field) {
        unsigned long uoff = 0;
        unsigned unit = 0, boff = 0;
        if (val->kind != ck_integer || !ir_bf_layout(f, usz, &uoff, &unit, &boff)) {
          ir_gi_unsupported("bitfield");
          return;
        }
        if (uoff > 0) fprintf(nf_out, "\n    (zero %lu %lu)", off, uoff);
        fprintf(nf_out, "\n    (bitfield %lu %u %u %u %s %s)", off + uoff, unit, boff, (unsigned)f->bit_size,
                ir_valtext(f->type), ir_const_value(val, f->type).s);
        done = uoff + unit;
      } else {
        ir_gi_items(off + (unsigned long)f->offset, val, f->type);
        done = (unsigned long)f->offset + ir_size_of(f->type);
      }
    }
    if (done < usz) fprintf(nf_out, "\n    (zero %lu %lu)", off + done, usz - done);
    return;
  }
  if (c->kind == ck_aggregate || ir_is_aggregate(t)) {
    ir_gi_unsupported("aggregate-constant");
    return;
  }
  ir_gi_scalar(off, c, t);
}

/* The initializer part of a (global ...) entry. See the item grammar above. Function-local statics take their
   initializer from the function's local-static-variable-init entry (get_variable_initializer). */
static void ir_global_init(a_variable_ptr var)
{
  unsigned long size = ir_size_of(var->type);
  an_init_kind kind;
  an_initializer_ptr ini;
  get_variable_initializer(var, NULL, &kind, &ini);
  switch (kind) {
    case initk_static:
      fputs(" (init", nf_out);
      ir_gi_items(0, ini->constant, var->type);
      fputc(')', nf_out);
      break;
    case initk_zero:
      fprintf(nf_out, " (init (zero 0 %lu))", size);
      break;
    case initk_none:
      if (var->storage_class == sc_extern) fputs(" (extern)", nf_out);
      else fprintf(nf_out, " (init (zero 0 %lu))", size);
      break;
    case initk_dynamic:
      fputs(" (unsupported init dynamic)", nf_out);
      break;
    default:
      fputs(" (unsupported init binding)", nf_out);
      break;
  }
}

/* Print the (global ...) entry of var into the module output. The entry is built in its own buffer, because
   printing the initializer can print other globals (address constants) and string data first. */
static void ir_global_print(a_variable_ptr var, const char *name)
{
  ir_buf g;
  ir_buf_open(&g);
  ir_buf_begin(&g);
  fprintf(nf_out, "(global %s ", name);
  nf_put_type(var->type);
  fprintf(nf_out, " %lu %lu", ir_size_of(var->type), (unsigned long)alignment_of_variable(var));
  if (var->storage_class == sc_static) fputs(" (static)", nf_out);
  else if (var->comdat_group != NULL) fputs(" (weak)", nf_out); /* EDG: COMDAT, which c_gen_be.c writes as __weak__ */
  else if (var->is_weak) fputs(var->storage_class == sc_extern ? " (weak)" : " (weak attr)", nf_out); /* __attribute__((weak)): declaration / definition */
  if (ir_var_is_thread(var)) fputs(" (thread)", nf_out); /* __thread / thread_local: one copy per thread */
  ir_global_init(var);
  fputs(")\n", nf_out);
  ir_buf_end(&g);
  ir_buf_write(&g, ir_out_globals.f);
  ir_buf_close(&g);
}

/* ================================================================ statements */

static void ir_stmt(a_statement_ptr s, int d);

/* `continue`. The lowered IL turns it into a goto to an unnamed label that ends the loop body. Each loop on the
   way down pushes that label (NULL when its body has none); a goto to the innermost loop's label prints as
   (continue), and the label itself is then dropped. A goto to the label of an outer loop (which source `continue`
   never produces) stays a goto, and keeps its label. */
#define IR_LOOP_MAX 256
static void *ir_loop_cont[IR_LOOP_MAX];
static int ir_loop_kept[IR_LOOP_MAX]; /* a plain goto reached this loop's label from an inner loop */
static int ir_loop_n;

/* The label that ends a loop body, or NULL: the last statement of the body (a block) is an unnamed label. */
static void *ir_cont_label(a_statement_ptr body)
{
  a_statement_ptr last = NULL, t;
  if (body == NULL || body->kind != stmk_block) return NULL;
  for (t = body->variant.block.statements; t != NULL; t = t->next) last = t;
  if (last == NULL || last->kind != stmk_label) return NULL;
  if (last->variant.label.ptr->source_corresp.name != NULL && last->variant.label.ptr->source_corresp.name[0] != '\0') return NULL;
  return last->variant.label.ptr;
}

static void ir_loop_push(a_statement_ptr body)
{
  if (ir_loop_n >= IR_LOOP_MAX) abort();
  ir_loop_cont[ir_loop_n] = ir_cont_label(body);
  ir_loop_kept[ir_loop_n] = 0;
  ir_loop_n++;
}

static void ir_loop_pop(void) { ir_loop_n--; }

static void ir_stmt_list(a_statement_ptr s, int d)
{
  for (; s != NULL; s = s->next) ir_stmt(s, d);
}

/* The loop-exit test: (if COND (then) (else (break))). */
static void ir_exit_unless(int d, an_expr_node_ptr cond)
{
  ir_depth = d;
  {
    char *cb = ir_to_bool(ir_rval(cond));
    ir_line(d, ir_fmt("(if %s (then) (else (break)))", cb));
  }
}

static void ir_stmt(a_statement_ptr s, int d)
{
  ir_depth = d;
  if (s == NULL) {
    ir_line(d, "(nil-stmt)");
    return;
  }
  switch (s->kind) {
    case stmk_empty:
      ir_note(1, stmk_empty, 1);
      return;
    case stmk_expr:
      ir_note(1, stmk_expr, 1);
      (void)ir_rval(s->expr);
      return;
    case stmk_block:
      ir_note(1, stmk_block, 1);
      ir_line(d, "(block");
      ir_stmt_list(s->variant.block.statements, d + 1);
      ir_close(1);
      return;
    case stmk_if: {
      char *cb;
      ir_note(1, stmk_if, 1);
      ir_depth = d;
      cb = ir_to_bool(ir_rval(s->expr));
      ir_line(d, ir_fmt("(if %s", cb));
      ir_line(d + 1, "(then");
      ir_stmt(s->variant.if_stmt.then_statement, d + 2);
      ir_close(1);
      if (s->variant.if_stmt.else_statement != NULL) {
        ir_line(d + 1, "(else");
        ir_stmt(s->variant.if_stmt.else_statement, d + 2);
        ir_close(1);
      }
      ir_close(1);
      return;
    }
    /* `if constexpr`, `if consteval`: the run-time code has only the branch that is taken (as c_gen_be.c puts it out).
       An instantiated template has its untaken branch replaced by an empty statement already. */
    case stmk_constexpr_if: {
      a_constexpr_if_ptr cip = s->variant.constexpr_if;
      ir_note(1, stmk_constexpr_if, 1);
      if (cip->value) ir_stmt(cip->then_statement, d);
      else if (cip->else_statement != NULL) ir_stmt(cip->else_statement, d);
      return;
    }
    case stmk_if_consteval:
      ir_note(1, stmk_if_consteval, 1);
      if (s->variant.if_stmt.else_statement != NULL) ir_stmt(s->variant.if_stmt.else_statement, d);
      return;
    case stmk_if_not_consteval:
      ir_note(1, stmk_if_not_consteval, 1);
      ir_stmt(s->variant.if_stmt.then_statement, d);
      return;
    case stmk_while:
      ir_note(1, stmk_while, 1);
      ir_line(d, "(loop");
      ir_line(d + 1, "(body");
      ir_exit_unless(d + 2, s->expr);
      ir_loop_push(s->variant.loop_statement);
      ir_stmt(s->variant.loop_statement, d + 2);
      ir_loop_pop();
      ir_close(1);
      ir_line(d + 1, "(step)");
      ir_close(1);
      return;
    case stmk_end_test_while:
      ir_note(1, stmk_end_test_while, 1);
      ir_line(d, "(loop");
      ir_line(d + 1, "(body");
      ir_loop_push(s->variant.loop_statement);
      ir_stmt(s->variant.loop_statement, d + 2);
      ir_loop_pop();
      ir_close(1);
      ir_line(d + 1, "(step");
      ir_exit_unless(d + 2, s->expr);
      ir_close(1);
      ir_close(1);
      return;
    case stmk_for: {
      a_for_loop_ptr extra = s->variant.for_loop.extra_info;
      ir_note(1, stmk_for, 1);
      if (extra != NULL && extra->initialization != NULL) ir_stmt(extra->initialization, d);
      ir_line(d, "(loop");
      ir_line(d + 1, "(body");
      if (s->expr != NULL) ir_exit_unless(d + 2, s->expr);
      ir_loop_push(s->variant.for_loop.statement);
      ir_stmt(s->variant.for_loop.statement, d + 2);
      ir_loop_pop();
      ir_close(1);
      ir_line(d + 1, "(step");
      if (extra != NULL && extra->increment != NULL) {
        ir_depth = d + 2;
        (void)ir_rval(extra->increment);
      }
      ir_close(1);
      ir_close(1);
      return;
    }
    case stmk_switch: {
      ir_val v;
      ir_note(1, stmk_switch, 1);
      ir_depth = d;
      v = ir_rval(s->expr);
      ir_line(d, ir_fmt("(switch %s", v.s));
      ir_line(d + 1, "(body");
      ir_stmt(s->variant.switch_stmt.body_statement, d + 2);
      ir_close(1);
      ir_close(1);
      return;
    }
    case stmk_switch_case: {
      a_switch_case_entry_ptr entry = s->variant.switch_case.extra_info;
      ir_note(1, stmk_switch_case, 1);
      if (entry != NULL && entry->case_value != NULL) {
        ir_line(d, ir_fmt("(case %s)", ir_const_value(entry->case_value, entry->case_value->type).s));
      } else {
        ir_line(d, "(default)");
      }
      return;
    }
    case stmk_goto:
      ir_note(1, stmk_goto, 1);
      if (ir_loop_n > 0 && ir_loop_cont[ir_loop_n - 1] == (void *)s->variant.label.ptr) {
        ir_line(d, "(continue)");
        return;
      }
      {
        int i;
        for (i = 0; i < ir_loop_n - 1; i++)
          if (ir_loop_cont[i] == (void *)s->variant.label.ptr) ir_loop_kept[i] = 1;
      }
      ir_line(d, ir_fmt("(goto %s)",
                        ir_tab_get(&ir_labels, s->variant.label.ptr,
                                   ir_name_or(s->variant.label.ptr->source_corresp.name, "label"), "")));
      return;
    case stmk_label:
      ir_note(1, stmk_label, 1);
      if (ir_loop_n > 0 && ir_loop_cont[ir_loop_n - 1] == (void *)s->variant.label.ptr && !ir_loop_kept[ir_loop_n - 1])
        return; /* the end of the loop body: fall-through reaches the step */
      ir_line(d, ir_fmt("(label %s)",
                        ir_tab_get(&ir_labels, s->variant.label.ptr,
                                   ir_name_or(s->variant.label.ptr->source_corresp.name, "label"), "")));
      return;
    case stmk_return:
      ir_note(1, stmk_return, 1);
      if (s->expr == NULL) {
        /* Falling off the end of a non-void function is undefined; main returns 0 (see ir_function). */
        if (ir_is_void(ir_ret_type) || ir_is_aggregate(ir_ret_type)) ir_line(d, "(return)");
        else if (ir_in_main) ir_line(d, ir_fmt("(return %s)", ir_zero(ir_ret_type)));
        else ir_line(d, "(unreachable)");
      } else if (ir_is_void(s->expr->type)) {
        (void)ir_rval(s->expr);
        ir_line(d, "(return)");
      } else if (ir_is_aggregate(ir_ret_type)) {
        ir_val v = ir_rval(s->expr);
        ir_copy(ir_ret_type, ir_sret, v.s);
        ir_line(d, "(return)");
      } else {
        ir_val v = ir_rval(s->expr);
        ir_line(d, ir_fmt("(return %s)", v.s));
      }
      return;
    case stmk_decl:
      /* The declaration point. Storage is per function, so nothing is printed. */
      ir_note(1, stmk_decl, 1);
      return;
    case stmk_set_vla_size: {
      /* The dimension of a VLA type is evaluated here, once, into its dimension variable. */
      a_vla_dimension_ptr dim = s->variant.vla_dimension;
      ir_note(1, stmk_set_vla_size, 1);
#if !LOWER_VARIABLE_LENGTH_ARRAYS
      if (dim != NULL && dim->dimension_variable != NULL && dim->dimension_expr != NULL) (void)ir_rval(dim->dimension_expr);
#else
      (void)dim;
#endif
      return;
    }
    case stmk_vla_decl:
      /* A variable-length array gets its storage here; a typedef of a variably modified type has none. */
#if !LOWER_VARIABLE_LENGTH_ARRAYS
      if (!s->variant.vla.is_typedef_decl && s->variant.vla.variant.variable->is_vla) {
        ir_vla_alloc(s->variant.vla.variant.variable);
      } else
#endif
      {
        ir_note(1, stmk_vla_decl, 1);
      }
      return;
    case stmk_asm: {
      /* Inline assembly. QBE has no inline asm, so the only subset that can be lowered is the one that does nothing
         but constrain the compiler: an empty template with no operands and no labels, whose clobbers are "memory"
         and/or "cc" (a basic asm("") counts as having the memory clobber, as in gcc). With "memory" it is a
         compiler barrier, (barrier); without it, it emits nothing at all.
         Everything else (a template, operands, a register clobber, asm goto) stays an unsupported marker with the
         reason, and the emitter refuses the module with that text. */
      an_asm_entry_ptr ae = s->variant.asm_entry;
      const char *why = NULL;
      int mem = 0;
      a_named_register_list_ptr cl;
      const char *tx;
      if (ae == NULL || ae->asm_string == NULL || ae->asm_string->kind != ck_string) why = "asm-template";
      else {
        a_constant_ptr sc = ae->asm_string;
        unsigned long i;
        tx = sc->variant.string.value;
        for (i = 0; i < (unsigned long)sc->variant.string.length; i++) {
          if (tx[i] != '\0' && tx[i] != ' ' && tx[i] != '\t' && tx[i] != '\n') why = "asm-template";
        }
      }
      if (why == NULL && !ae->gnu_asm_form) mem = 1; /* basic asm(""): gcc treats it as clobbering memory */
      if (why == NULL && ae->is_asm_goto) why = "asm-goto";
      if (why == NULL && ae->operands != NULL) why = "asm-operands";
      if (why == NULL) {
        for (cl = ae->clobbers; cl != NULL; cl = cl->next) {
          if (cl->reg == anr_memory) mem = 1;
          else if (cl->reg != anr_flags) why = "asm-clobbers";
        }
      }
      /* doctest's debugger break, `__asm__ volatile("int $3\n" : :)`: raise SIGTRAP, which is what the instruction does
         when no debugger is attached (path A's qbe-prep.rb calls a stub for it). */
      if (why != NULL && ae != NULL && ae->asm_string != NULL && ae->asm_string->kind == ck_string &&
          !ae->is_asm_goto && ae->operands == NULL && ae->clobbers == NULL) {
        const char *t3 = ae->asm_string->variant.string.value;
        char norm[16];
        size_t k, m = 0;
        for (k = 0; t3[k] != '\0' && m < sizeof norm - 1; k++) {
          if (t3[k] != ' ' && t3[k] != '\t' && t3[k] != '\n') norm[m++] = t3[k];
        }
        norm[m] = '\0';
        if (t3[k] == '\0' && strcmp(norm, "int$3") == 0) {
          ir_note(1, stmk_asm, 1);
          ir_line(d, "(eval (call void &\"raise\" (const int 5)))");
          return;
        }
      }
      /* `pause` (a.k.a. `rep nop`) and `nop`, with no operands and at most memory / cc clobbers: no observable effect
         (pause is a spin-wait hint), so the opaque call of (barrier) is a correct lowering. Any other instruction (mfence,
         lock-prefixed ops, cpuid, ...) has an effect a call cannot reproduce and is refused with its text. */
      if (why != NULL && ir_asm_is_nop(ae) == 1) {
        ir_note(1, stmk_asm, 1);
        ir_line(d, "(barrier)");
        return;
      }
      if (why != NULL && ir_asm_is_nop(ae) == 2) why = "asm-clobbers";
      ir_note(1, stmk_asm, why == NULL);
      if (why != NULL && strcmp(why, "asm-template") == 0 && ae != NULL && ae->asm_string != NULL &&
          ae->asm_string->kind == ck_string) {
        /* the template text makes the refusal readable: refused: (unsupported stmt asm-template "mfence") */
        char shown[64];
        const char *tx2 = ae->asm_string->variant.string.value;
        size_t k, m = 0;
        for (k = 0; k < (size_t)ae->asm_string->variant.string.length && tx2[k] != '\0' && m < sizeof shown - 1; k++) {
          char c = tx2[k];
          if (c == '\n' || c == '\t') c = ' ';
          if (c == '"' || c == '\\' || (unsigned char)c < 32 || (unsigned char)c > 126) c = '?';
          if (c == ' ' && m > 0 && shown[m - 1] == ' ') continue;
          shown[m++] = c;
        }
        shown[m] = '\0';
        ir_line(d, ir_fmt("(unsupported stmt asm-template \"%s\")", shown));
      } else if (why != NULL) ir_line(d, ir_fmt("(unsupported stmt %s)", why));
      else if (mem) ir_line(d, "(barrier)");
      return;
    }
    case stmk_init: {
      a_dynamic_init_ptr init = s->variant.dynamic_init;
      ir_note(1, stmk_init, 1);
      if (init->variable == NULL) {
        ir_line(d, "(unsupported init no-variable)");
        return;
      }
      if (init->kind == dik_constant) {
        ir_val dst = ir_var_addr(init->variable, init->variable->type, ir_is_volatile(init->variable->type));
        ir_init_constant(dst, init->variant.constant.ptr, init->variable->type);
        return;
      }
      if (init->kind == dik_expression) {
        ir_val v = ir_rval(init->variant.expression);
        ir_val dst = ir_var_addr(init->variable, init->variable->type, ir_is_volatile(init->variable->type));
        if (ir_is_aggregate(dst.t)) ir_copy(dst.t, dst.s, v.s);
        else ir_store(dst.t, dst.s, v.s, dst.vol);
        ir_note(4, dik_expression, 1);
        return;
      }
      if (init->kind == dik_constructor && init->variant.constructor.ptr != NULL &&
          !init->variant.constructor.is_copy_constructor_with_implied_source && !init->variant.constructor.is_array_copy &&
          !init->variant.constructor.value_initialization) {
        /* A constructor call on the object: (eval (call void &"ctor" OBJ ARG*)). DO_IL_LOWERING expands every
           constructor into an explicit call before we see the IL, so this form is not reached on the programs in
           tests (it is the shape the unlowered IL would need); array copies, implied copy sources and value
           initialization stay unsupported. */
        a_routine_ptr ctor = init->variant.constructor.ptr;
        a_type_ptr ct = skip_typerefs(ctor->type);
        if (ct->variant.routine.extra_info == NULL || !ct->variant.routine.extra_info->has_ellipsis) {
          ir_val dst = ir_var_addr(init->variable, init->variable->type, 0);
          char *args = ir_fmt(" %s", dst.s);
          an_expr_node_ptr arg;
          for (arg = init->variant.constructor.args; arg != NULL; arg = arg->next) {
            ir_val a = ir_rval(arg);
            if (ir_is_aggregate(a.t)) {
              ir_val tmp = ir_temp(a.t);
              ir_copy(a.t, tmp.s, a.s);
              args = ir_fmt("%s %s", args, tmp.s);
            } else {
              args = ir_fmt("%s %s", args, a.s);
            }
          }
          ir_note(4, dik_constructor, 1);
          ir_line(d, ir_fmt("(eval (call void &\"%s\"%s))", ir_rout_name(ctor), args));
          return;
        }
      }
      ir_note(4, (int)init->kind, 0);
      ir_line(d, ir_fmt("(unsupported init %s)",
                        nfcxx_dik_name(init->kind) != NULL ? nfcxx_dik_name(init->kind) : "?"));
      return;
    }
    default:
      ir_note(1, (int)s->kind, 0);
      ir_line(d, ir_fmt("(unsupported stmt %s)",
                        nfcxx_stmk_name(s->kind) != NULL ? nfcxx_stmk_name(s->kind) : "?"));
      return;
  }
}

/* 1 when the body statement ends in a return (so no fall-through marker is needed). */
static int ir_ends_in_return(a_statement_ptr body)
{
  a_statement_ptr last = NULL, p;
  if (body == NULL) return 0;
  if (body->kind == stmk_return) return 1;
  if (body->kind != stmk_block) return 0;
  for (p = body->variant.block.statements; p != NULL; p = p->next) last = p;
  return last != NULL && ir_ends_in_return(last);
}

/* ================================================================ routines and module */

/* A source name as a quoted atom, with a placeholder when it has none. */
static void nf_put_quoted_name(const char *name)
{
  const char *n = ir_name_or(name, "tmp");
  nf_put_quoted(n, strlen(n));
}

/* Startup and exit markers of a function: (constructor [PRIO]) and (destructor [PRIO]). A routine runs before main
   when it has __attribute__((constructor [(PRIO)])), or when it is an initialization routine made by IL lowering
   (the __sti__ routine that runs a translation unit's dynamic initializers; with GNU init_priority there is one
   per priority, and rout->init_priority is that priority). The C back end marks the same routines with
   __attribute__((constructor)) (or a .ctors.N section for a priority), which is what path A runs. A destructor
   routine (__attribute__((destructor [(PRIO)]))) runs at exit. Without a PRIO the routine has the default
   priority, which runs after every prioritized one. A consumer must keep these routines whatever refers to them. */
static void ir_startup_markers(a_routine_ptr rout)
{
  const char *name = rout->source_corresp.name;
  int ctor = 0, dtor = 0;
  unsigned long cprio = 0, dprio = 0;
  if (rout->is_initialization_routine) {
    ctor = 1;
    if (rout->has_ctor_priority && has_gnu_routine_supp(rout)) cprio = (unsigned long)gnu_routine_supp(rout)->ctor_priority;
  } else if (name != NULL && strncmp(name, IL_LOWERING_INIT_ROUTINE_PREFIX, strlen(IL_LOWERING_INIT_ROUTINE_PREFIX)) == 0) {
    ctor = 1;
    cprio = (unsigned long)rout->init_priority;
  }
  if (rout->is_finalization_routine) {
    dtor = 1;
    if (rout->has_dtor_priority && has_gnu_routine_supp(rout)) dprio = (unsigned long)gnu_routine_supp(rout)->dtor_priority;
  }
  if (ctor) {
    if (cprio != 0) fprintf(nf_out, "\n  (constructor %lu)", cprio);
    else fputs("\n  (constructor)", nf_out);
  }
  if (dtor) {
    if (dprio != 0) fprintf(nf_out, "\n  (destructor %lu)", dprio);
    else fputs("\n  (destructor)", nf_out);
  }
}

/* Lower one routine body into the function output. Same selection as the IL dump (stage 1). */
static void ir_function(a_routine_ptr rout)
{
  a_scope_ptr scope;
  a_variable_ptr param;
  a_type_ptr fn_type, ret;
  ir_buf params, body, hdr;
  struct ir_pending {
    a_variable_ptr var;
    char *reg;
  } pending[256];
  int npending = 0;

  if (ignore_routine_in_back_end(rout)) return;
  if (rout->function_def_number == NULL_function_def_number) return;
#if MAINTAIN_NEEDED_FLAGS
  if (!rout->definition_needed) return;
#endif /* MAINTAIN_NEEDED_FLAGS */
  /* A body kept only for inlining is not a stand-alone definition: a gnu_inline function (definition_for_inlining_only;
     the C library has the real one) is skipped. suppress_inline_body without that flag is an inline member of an
     `extern template` class such as std::allocator<char>::allocate, whose copy gcc inlines in the C back end's
     output. Path B has no inliner, so that body is emitted (weak), and the emitter keeps it only when something
     refers to it. */
  if (rout->suppress_inline_body && rout->definition_for_inlining_only) return;
  scope = scope_for_routine(rout);
  if (scope == NULL || scope->assoc_block == NULL) return;

  fn_type = skip_typerefs(rout->type);
  ret = fn_type->variant.routine.return_type;

  ir_nreg = 0;
  ir_sret = NULL;
  ir_ret_type = ret;
  ir_in_main = rout->source_corresp.name != NULL && strcmp(rout->source_corresp.name, "main") == 0;
  ir_cur_rout = rout;
  ir_slots.n = 0;
  ir_labels.n = 0;
  ir_loop_n = 0;
  ir_cur_scope = scope;
  ir_buf_open(&ir_slot_buf);

  /* Parameters: a hidden result pointer first, then one register per parameter. Aggregate parameters are
     byval: the register is the address of the callee's copy, and the variable is that copy. */
  ir_buf_open(&params);
  ir_buf_begin(&params);
  if (ir_is_aggregate(ret)) {
    ir_sret = ir_newreg();
    ir_abi_note(ret);
    fprintf(nf_out, " (sret %s ", ir_sret);
    nf_put_type(ret);
    fputc(')', nf_out);
  }
  for (param = scope->variant.routine.parameters; param != NULL; param = param->next) {
    char *reg = ir_newreg();
    fprintf(nf_out, " (param %s ", reg);
    nf_put_quoted_name(param->source_corresp.name);
    if (ir_is_aggregate(param->type)) {
      ir_abi_note(param->type);
      fputs(" (byval ", nf_out);
      nf_put_type(param->type);
      fputs("))", nf_out);
      ir_tab_put(&ir_slots, param, reg);
    } else {
      fputc(' ', nf_out);
      nf_put_type(param->type);
      fputc(')', nf_out);
      if (npending < 256) {
        pending[npending].var = param;
        pending[npending].reg = reg;
        npending++;
      }
    }
  }
  if (fn_type->variant.routine.extra_info != NULL && fn_type->variant.routine.extra_info->has_ellipsis) {
    fputs(" (ellipsis)", nf_out);
  }
  ir_buf_end(&params);

  /* Body. Scalar parameters are copied into slots first, so that every named variable has an address. */
  ir_buf_open(&body);
  ir_buf_begin(&body);
  {
    int i;
    for (i = 0; i < npending; i++) {
      ir_val slot;
      ir_depth = 1;
      slot = ir_var_addr(pending[i].var, pending[i].var->type, 0);
      ir_store(pending[i].var->type, slot.s, pending[i].reg, 0);
    }
  }
  if (scope->assoc_block->kind == stmk_block) {
    ir_stmt_list(scope->assoc_block->variant.block.statements, 1);
  } else {
    ir_stmt(scope->assoc_block, 1);
  }
  /* Falling off the end of a non-void routine is UB in C++; main returns 0. Both forms are explicit. */
  if (!ir_is_void(ret) && !ir_ends_in_return(scope->assoc_block)) {
    if (strcmp(rout->source_corresp.name != NULL ? rout->source_corresp.name : "", "main") == 0) {
      ir_line(1, ir_fmt("(return %s)", ir_zero(ret)));
    } else {
      ir_line(1, "(unreachable)");
    }
  }
  ir_buf_end(&body);

  /* Output: header, slots, body. */
  ir_buf_open(&hdr);
  ir_buf_begin(&hdr);
  fputs("\n(function ", nf_out);
  nf_put_quoted_name(ir_rout_name(rout));
  fputs("\n  (ret ", nf_out);
  if (ir_is_aggregate(ret)) fputs("void", nf_out); /* the result goes through (sret ...) */
  else nf_put_unqualified_type(skip_typerefs(ret));
  fputs(")\n  (params", nf_out);
  ir_buf_end(&hdr);

  ir_buf_begin(&ir_out_funcs);
  ir_buf_write(&hdr, nf_out);
  ir_buf_write(&params, nf_out);
  fputs(")", nf_out);
  if (rout->storage_class == sc_static) fputs("\n  (static)", nf_out);
  else if (rout->use_comdat || rout->suppress_inline_body) fputs("\n  (weak)", nf_out); /* EDG: COMDAT (inline, template), written as __weak__ by c_gen_be.c */
  else if (rout->is_weak && rout->source_corresp.name != NULL && strncmp(rout->source_corresp.name, "_ZT", 3) == 0)
    fputs("\n  (weak)", nf_out); /* the _ZTW wrapper / _ZTH function of a thread_local: every unit that uses the variable defines it */
  else if (rout->is_weak) fputs("\n  (weak attr)", nf_out); /* __attribute__((weak)) definition: an interface symbol, kept by pruning */
  ir_startup_markers(rout);
  ir_buf_write(&ir_slot_buf, nf_out);
  ir_buf_write(&body, nf_out);
  fputs(")\n", nf_out);
  ir_buf_end(&ir_out_funcs);

  ir_buf_close(&hdr);
  ir_buf_close(&params);
  ir_buf_close(&body);
  ir_buf_close(&ir_slot_buf);
}

/* The `_ZTH<name>` initialization routine of a thread_local variable (EDG routine->is_tls_init_alias). IL lowering
   gives it no body: it is "an alias for the __tls_init routine" of the translation unit, which runs the dynamic
   initialization of every thread_local object defined here once per thread (a thread_local guard). c_gen_be.c writes
   `.global _ZTH..; _ZTH.. = __tls_init` for an externally visible one and a one-line routine that calls __tls_init for a
   static one. The IR has no aliases, so both become that routine. The storage class is the variable's: extern means
   the variable is defined in another unit (no definition here: the `_ZTW` wrapper refers to a weak undefined
   function), unspecified is external and (weak) as EDG sets is_weak, static is internal. The wrappers `_ZTW<name>`
   have an ordinary body and are printed by ir_function. */
static void ir_tls_init_alias(a_routine_ptr rout, a_scope_ptr scope)
{
  a_routine_ptr r, tls_init = NULL;
  if (rout->storage_class == sc_extern) return;
  for (r = scope->routines; r != NULL; r = r->next) {
    if (r->is_tls_init_routine && r->function_def_number != NULL_function_def_number) tls_init = r;
  }
  ir_buf_begin(&ir_out_funcs);
  fputs("\n(function ", nf_out);
  nf_put_quoted_name(ir_rout_name(rout));
  fputs("\n  (ret void)\n  (params)", nf_out);
  if (rout->storage_class == sc_static) fputs("\n  (static)", nf_out);
  else if (rout->is_weak || rout->use_comdat) fputs("\n  (weak)", nf_out);
  if (tls_init != NULL) fprintf(nf_out, "\n  (eval (call void &\"%s\"))", ir_rout_name(tls_init));
  fputs("\n  (return))\n", nf_out);
  ir_buf_end(&ir_out_funcs);
}

/* Entry point. Called by back_end() when NFCXX_PATHB_MODE=ir. */
void nfcxx_ir_back_end(void)
{
  a_scope_ptr scope = il_header.primary_scope;
  const char *file_name = il_header.primary_source_file->file_name;
  const char *slash = strrchr(file_name, '/');
  a_variable_ptr var;
  a_routine_ptr rout;
  const char *ov = getenv("NFCXX_IR_OVERFLOW");

  ir_trap_overflow = ov != NULL && strcmp(ov, "trap") == 0;
  ir_buf_open(&ir_out_globals);
  ir_buf_open(&ir_out_types);
  ir_buf_open(&ir_out_data);
  ir_buf_open(&ir_out_funcs);
  ir_mod.n = 0;

  for (var = scope->variables; var != NULL; var = var->next) {
    /* Variables of a dependent type (the function parameter packs of libstdc++'s templates) have no object. */
    if (!ignore_variable_in_back_end(var) && !is_template_dependent_type(var->type)) (void)ir_global_op(var);
  }
  for (rout = scope->routines; rout != NULL; rout = rout->next) ir_reserve_name(ir_rout_sym(rout));
  for (rout = scope->routines; rout != NULL; rout = rout->next) {
    if (rout->is_tls_init_alias && rout->function_def_number == NULL_function_def_number) ir_tls_init_alias(rout, scope);
    else ir_function(rout);
  }

  nf_out = stdout;
  /* The scalar sizes are EDG's for the target. A consumer that assumes a layout (the QBE emitter: LP64) checks them. */
  fprintf(stdout, "(ir-module \"%s\" (layout (short %lu) (int %lu) (long %lu) (long_long %lu) (pointer %lu) (float %lu) (double %lu) (long_double %lu)))\n",
          slash != NULL ? slash + 1 : file_name, (unsigned long)targ_sizeof_short, (unsigned long)targ_sizeof_int,
          (unsigned long)targ_sizeof_long, (unsigned long)targ_sizeof_long_long, (unsigned long)targ_sizeof_pointer,
          (unsigned long)targ_sizeof_float, (unsigned long)targ_sizeof_double, (unsigned long)targ_sizeof_long_double);
  ir_buf_write(&ir_out_types, stdout);
  ir_buf_write(&ir_out_globals, stdout);
  ir_buf_write(&ir_out_data, stdout);
  ir_buf_write(&ir_out_funcs, stdout);
  fflush(stdout);
  if (getenv("NFCXX_PATHB_STATS") != NULL) ir_print_stats();
}
