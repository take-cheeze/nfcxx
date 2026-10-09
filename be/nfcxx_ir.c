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

#define IR_TAB_MAX 8192

struct ir_ent {
  const void *key; /* entity pointer; NULL for entries made without one */
  char *raw;       /* name used for uniqueness; NULL for explicit mappings */
  char *op;        /* printed form: sigil"name", or an explicit operand */
};

struct ir_tab {
  ir_ent e[IR_TAB_MAX];
  int n;
};

/* Per function: stack slots and labels. Per module: globals, static objects and string data. */
static ir_tab ir_slots;
static ir_tab ir_labels;
static ir_tab ir_mod;

static int ir_raw_used(const ir_tab *t, const char *raw)
{
  int i;
  for (i = 0; i < t->n; i++) {
    if (t->e[i].raw != NULL && strcmp(t->e[i].raw, raw) == 0) return 1;
  }
  return 0;
}

/* Add an entry with a new name. Names are unique within the table: a clash gets a .N suffix. */
static const char *ir_tab_add(ir_tab *t, const void *key, const char *base, const char *sigil)
{
  char cand[300];
  int k = 0;
  if (base == NULL || base[0] == '\0') base = "tmp";
  (void)snprintf(cand, sizeof cand, "%s", base);
  while (ir_raw_used(t, cand)) {
    k++;
    (void)snprintf(cand, sizeof cand, "%s.%d", base, k);
  }
  if (t->n >= IR_TAB_MAX) {
    fprintf(stderr, "nfcxx_ir: name table full\n");
    abort();
  }
  t->e[t->n].key = key;
  t->e[t->n].raw = ir_dup(cand);
  t->e[t->n].op = ir_fmt("%s\"%s\"", sigil, cand);
  t->n++;
  return t->e[t->n - 1].op;
}

static const char *ir_tab_find(const ir_tab *t, const void *key)
{
  int i;
  for (i = 0; i < t->n; i++) {
    if (t->e[i].key == key) return t->e[i].op;
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
  if (t->n >= IR_TAB_MAX) abort();
  t->e[t->n].key = key;
  t->e[t->n].raw = NULL;
  t->e[t->n].op = ir_dup(op);
  t->n++;
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
  if (name == NULL || name[0] == '\0' || ir_raw_used(&ir_mod, name) || ir_mod.n >= IR_TAB_MAX) return;
  ir_mod.e[ir_mod.n].key = NULL;
  ir_mod.e[ir_mod.n].raw = ir_dup(name);
  ir_mod.e[ir_mod.n].op = ir_fmt("&\"%s\"", name);
  ir_mod.n++;
}

static const char *ir_rout_name(a_routine_ptr r)
{
  const char *n = r->source_corresp.name;
  const char *op;
  char *s;
  if (n != NULL && n[0] != '\0') return n;
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
};

static ir_val ir_mk_value(char *s, a_type_ptr t)
{
  ir_val v;
  v.s = s;
  v.t = t;
  v.ty = ir_valtext(t);
  v.vol = 0;
  return v;
}

static ir_val ir_mk_addr(char *s, a_type_ptr t, int vol)
{
  ir_val v;
  v.s = s;
  v.t = t;
  v.ty = ir_ptext(t);
  v.vol = vol;
  return v;
}

static ir_val ir_mk_bool(char *s)
{
  ir_val v;
  v.s = s;
  v.t = NULL;
  v.ty = (char *)"bool";
  v.vol = 0;
  return v;
}

static ir_val ir_mk_void(void)
{
  ir_val v;
  v.s = NULL;
  v.t = NULL;
  v.ty = (char *)"void";
  v.vol = 0;
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
static ir_buf ir_out_data;
static ir_buf ir_out_funcs;
static ir_buf ir_slot_buf;

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
  if (ir_is_aggregate(a.t)) return ir_mk_value(a.s, a.t);
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

/* Address of element idx of an array whose element type is elem. */
static ir_val ir_elem_addr(const char *base, const char *idx, a_type_ptr elem, int vol)
{
  return ir_mk_addr(ir_let(ir_ptext(elem), ir_fmt("(index %s %s %lu)", base, idx, ir_size_of(elem))), elem, vol);
}

/* Pointer value base + idx * sizeof(elem), of pointer type ptr_t. */
static ir_val ir_ptr_add(const char *base, const char *idx, a_type_ptr ptr_t, a_type_ptr elem)
{
  char *r = ir_let(ir_valtext(ptr_t), ir_fmt("(index %s %s %lu)", base, idx, ir_size_of(elem)));
  return ir_mk_value(r, ptr_t);
}

static void ir_global_print(a_variable_ptr var, const char *name);

/* Static object (global, static local, or string data) operand; the module entry is printed on first use. */
static const char *ir_global_op(a_variable_ptr var)
{
  int fresh = ir_tab_find(&ir_mod, var) == NULL;
  const char *op = ir_tab_get(&ir_mod, var, ir_name_or(var->source_corresp.name, "tmp"), "@");
  if (fresh) ir_global_print(var, op + 1);
  return op;
}

/* Stack slot operand for an object of the current function, created on first use. */
static const char *ir_slot_op(const void *key, const char *base, a_type_ptr t)
{
  int fresh = ir_tab_find(&ir_slots, key) == NULL;
  const char *op = ir_tab_get(&ir_slots, key, base, "$");
  if (fresh) {
    ir_buf_begin(&ir_slot_buf);
    fprintf(nf_out, "\n  (slot %s ", op + 1);
    nf_put_type(t);
    fprintf(nf_out, " %lu %lu)", ir_size_of(t), ir_align_of(t));
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
static ir_val ir_var_addr(a_variable_ptr var, a_type_ptr t, int vol)
{
  const char *op = ir_tab_find(&ir_slots, var);
  if (op != NULL) return ir_mk_addr((char *)op, t, vol);
  if (var_has_static_or_thread_storage_duration(var)) {
    return ir_mk_addr((char *)ir_global_op(var), t, vol);
  }
  return ir_mk_addr((char *)ir_slot_op(var, ir_name_or(var->source_corresp.name, "tmp"), var->type), t, vol);
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
static ir_val ir_lval_op(an_expr_node_ptr e);
static ir_val ir_roof(an_expr_node_ptr e);

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
    return ir_var_addr(e->variant.variable.ptr, e->type, ir_is_volatile(e->type));
  }
  if (e->kind == enk_object_lifetime) return ir_lval(e->variant.object_lifetime.expr);
  if (e->kind == enk_operation) return ir_lval_op(e);
  if (e->kind == enk_routine) {
    /* A function designator (the operand of & outside a constant expression, for example `throw &f`): its address. */
    ir_note(2, enk_routine, 1);
    return ir_mk_addr(ir_fmt("&\"%s\"", ir_name_or(e->variant.routine.ptr->source_corresp.name, "fn")), e->type, 0);
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
  an_expr_operator_kind k = e->variant.operation.kind;
  an_expr_node_ptr a0 = ir_operand(e, 0);
  an_expr_node_ptr a1 = ir_operand(e, 1);
  int vol = ir_is_volatile(e->type);
  switch (k) {
    case eok_dot_field: {
      ir_val base;
      an_expr_node_ptr fe = a1;
      if (fe == NULL || fe->kind != enk_field || fe->variant.field.ptr->is_bit_field) break;
      ir_note(0, k, 1);
      base = ir_lval(a0);
      return ir_subobject(base.s, (unsigned long)fe->variant.field.ptr->offset, e->type, vol);
    }
    case eok_points_to_field: {
      ir_val p;
      an_expr_node_ptr fe = a1;
      if (fe == NULL || fe->kind != enk_field || fe->variant.field.ptr->is_bit_field) break;
      ir_note(0, k, 1);
      p = ir_rval(a0);
      ir_nonnull(a0, p);
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
      return ir_elem_addr(base.s, idx.s, e->type, vol);
    }
    case eok_indirect: {
      ir_val p;
      if (a0 == NULL) break;
      ir_note(0, k, 1);
      p = ir_rval(a0);
      ir_nonnull(a0, p);
      return ir_mk_addr(p.s, e->type, vol);
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
      ir_val a = ir_lval_op(e);
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
      ir_val a = ir_lval(a0);
      ir_note(0, k, 1);
      return ir_mk_value(ir_retype_addr(a, skip_typerefs(e->type)->variant.pointer.type, 0).s, e->type);
    }
    case eok_call:
      return ir_call(e);
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
      return ir_mk_value(ir_let(ir_valtext(e->type), ir_fmt("(pdiff %s %s %lu)", a.s, b.s, ir_size_of(elem))),
                         e->type);
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
    ir_store(lhs.t, lhs.s, rhs.s, lhs.vol);
    ir_note(0, eok_assign, 1);
    return want_addr ? lhs : rhs;
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
      nv = ir_arith(base, lhs.t, cur, rhs, &ok);
      if (!ok) return ir_gap(e->type, "assign-op", 0, (int)k);
    }
    ir_note(0, k, 1);
    ir_store(lhs.t, lhs.s, nv.s, lhs.vol);
    return want_addr ? lhs : nv;
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
  ir_store(lhs.t, lhs.s, nv.s, lhs.vol);
  ir_note(0, pre ? eok_pre_incr : eok_post_incr, 1);
  return pre ? nv : cur;
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

/* Call of a routine or through a function pointer. Aggregate arguments are copied into temporaries and
   passed by address; an aggregate result is written to a temporary passed as the first argument. */
static ir_val ir_call(an_expr_node_ptr e)
{
  an_expr_node_ptr f = ir_operand(e, 0);
  an_expr_node_ptr arg;
  char *callee;
  char *args = ir_dup("");
  int agg_ret = ir_is_aggregate(e->type);
  ir_val sret = ir_mk_void();
  if (f->kind == enk_routine) {
    ir_note(2, enk_routine, 1);
    callee = ir_fmt("&\"%s\"", ir_rout_name(f->variant.routine.ptr));
  } else {
    ir_val fv = ir_rval(f);
    callee = fv.s;
  }
  if (agg_ret) {
    sret = ir_temp(e->type);
    args = ir_fmt("%s %s", args, sret.s);
  }
  for (arg = ir_operand(e, 1); arg != NULL; arg = arg->next) {
    ir_val a = ir_rval(arg);
    if (ir_is_aggregate(a.t)) {
      ir_val tmp = ir_temp(a.t);
      ir_copy(a.t, tmp.s, a.s);
      args = ir_fmt("%s %s", args, tmp.s);
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
  callee = ir_fmt("&\"%s\"", ir_name_or(under->source_corresp.name, "fn"));
  if (agg_ret) {
    sret = ir_temp(e->type);
    args = ir_fmt("%s %s", args, sret.s);
  }
  for (param = scope->variant.routine.parameters; param != NULL; param = param->next) {
    ir_val a = ir_var_addr(param, param->type, 0);
    if (ir_is_aggregate(param->type)) {
      ir_val tmp = ir_temp(param->type);
      ir_copy(param->type, tmp.s, a.s);
      args = ir_fmt("%s %s", args, tmp.s);
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
   virtual base or a bit-field, which are not lowered yet. */
struct ir_member {
  unsigned long off;
  a_type_ptr t;
};

static int ir_is_base_storage(a_class_type_supplement_ptr extra, a_field_ptr f)
{
  a_base_class_ptr b;
  if (extra == NULL) return 0;
  for (b = extra->direct_base_classes; b != NULL; b = b->next_direct) {
    if (!b->is_virtual && skip_typerefs(b->type) == skip_typerefs(f->type) && b->offset == f->offset) return 1;
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
      if (b->is_virtual || n >= max) return -1;
      out[n].off = (unsigned long)b->offset;
      out[n].t = b->type;
      n++;
    }
  }
  for (f = s->variant.class_struct_union.field_list; f != NULL; f = f->next) {
    /* EDG adds a field __b_N for a base subobject that is already a direct base (same type, same offset).
       It is the same storage as that base, so it is not a second element. */
    if (ir_is_base_storage(extra, f)) continue;
    if (f->is_bit_field || n >= max) return -1;
    out[n].off = (unsigned long)f->offset;
    out[n].t = f->type;
    n++;
  }
  return n;
}

/* Zero a scalar object; aggregates are not zeroed yet. */
static void ir_zero_object(ir_val dst, a_type_ptr t)
{
  if (ir_is_aggregate(t)) {
    ir_emit("(unsupported init zero-aggregate)");
    return;
  }
  ir_store(t, dst.s, ir_zero(t), dst.vol);
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
      ir_emit("(unsupported init virtual-base-or-bitfield)");
      return;
    }
    for (ce = c->variant.aggregate.first_constant; ce != NULL && i < n; ce = ce->next, i++) {
      ir_val sub = ir_subobject(dst.s, mem[i].off, mem[i].t, 0);
      if (ce->kind == ck_aggregate || ir_is_aggregate(mem[i].t)) {
        ir_init_constant(sub, ce, mem[i].t);
      } else {
        ir_val v = ir_constant(ce, mem[i].t);
        ir_store(mem[i].t, sub.s, v.s, 0);
      }
    }
    for (; i < n; i++) ir_zero_object(ir_subobject(dst.s, mem[i].off, mem[i].t, 0), mem[i].t);
    ir_note(4, dik_constant, 1);
    return;
  }
  if (c->kind == ck_aggregate) {
    /* A union or any other aggregate kind with an initializer list: not lowered yet. */
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
      ir_gi_unsupported("virtual-base-or-bitfield");
      return;
    }
    for (ce = c->variant.aggregate.first_constant; ce != NULL && i < n; ce = ce->next, i++) {
      ir_gi_items(off + mem[i].off, ce, mem[i].t);
    }
    for (; i < n; i++) fprintf(nf_out, "\n    (zero %lu %lu)", off + mem[i].off, ir_size_of(mem[i].t));
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
  fprintf(nf_out, " %lu %lu", ir_size_of(var->type), ir_align_of(var->type));
  if (var->storage_class == sc_static) fputs(" (static)", nf_out);
  else if (var->comdat_group != NULL) fputs(" (weak)", nf_out); /* EDG: COMDAT, which c_gen_be.c writes as __weak__ */
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
  if (rout->suppress_inline_body) return;
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
  ir_buf_open(&ir_slot_buf);

  /* Parameters: a hidden result pointer first, then one register per parameter. Aggregate parameters are
     byval: the register is the address of the callee's copy, and the variable is that copy. */
  ir_buf_open(&params);
  ir_buf_begin(&params);
  if (ir_is_aggregate(ret)) {
    ir_sret = ir_newreg();
    fprintf(nf_out, " (sret %s ", ir_sret);
    nf_put_type(ret);
    fputc(')', nf_out);
  }
  for (param = scope->variant.routine.parameters; param != NULL; param = param->next) {
    char *reg = ir_newreg();
    fprintf(nf_out, " (param %s ", reg);
    nf_put_quoted_name(param->source_corresp.name);
    if (ir_is_aggregate(param->type)) {
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
  else if (rout->use_comdat) fputs("\n  (weak)", nf_out); /* EDG: COMDAT (inline, template), written as __weak__ by c_gen_be.c */
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
  ir_buf_open(&ir_out_data);
  ir_buf_open(&ir_out_funcs);
  ir_mod.n = 0;

  for (var = scope->variables; var != NULL; var = var->next) {
    if (!ignore_variable_in_back_end(var)) (void)ir_global_op(var);
  }
  for (rout = scope->routines; rout != NULL; rout = rout->next) ir_reserve_name(rout->source_corresp.name);
  for (rout = scope->routines; rout != NULL; rout = rout->next) {
    ir_function(rout);
  }

  nf_out = stdout;
  /* The scalar sizes are EDG's for the target. A consumer that assumes a layout (the QBE emitter: LP64) checks them. */
  fprintf(stdout, "(ir-module \"%s\" (layout (short %lu) (int %lu) (long %lu) (long_long %lu) (pointer %lu) (float %lu) (double %lu) (long_double %lu)))\n",
          slash != NULL ? slash + 1 : file_name, (unsigned long)targ_sizeof_short, (unsigned long)targ_sizeof_int,
          (unsigned long)targ_sizeof_long, (unsigned long)targ_sizeof_long_long, (unsigned long)targ_sizeof_pointer,
          (unsigned long)targ_sizeof_float, (unsigned long)targ_sizeof_double, (unsigned long)targ_sizeof_long_double);
  ir_buf_write(&ir_out_globals, stdout);
  ir_buf_write(&ir_out_data, stdout);
  ir_buf_write(&ir_out_funcs, stdout);
  fflush(stdout);
  if (getenv("NFCXX_PATHB_STATS") != NULL) ir_print_stats();
}
