/*
nfcxx_ast.c -- libclang-edg: a second output of the declaration back end (be/nfcxx_decl.c). With NFCXX_DECL_AST set in
the environment, back_end() calls nfcxx_ast_dump() instead of listing declarations, and the stream (stdout, or
nfcxx_decl_out) gets one JSON document: the translation unit's function definitions, complete record definitions and
file-scope variables, with the statements and expressions of every function body, in the subset of clang's
`-ast-dump=json` that the bc2cpp consumers read (docs/notes/nfcxx-ast.md). The kinds, field names and nesting are
clang's, so tools/bc2cpp/native_ast_returns.rb and its siblings read it unchanged.

The IL here is un-lowered (the libclang-edg configuration has no IL lowering), so a body is the source's: casts and
parentheses are explicit nodes, macros are expanded, enumerators keep their names, and a local's initializer is its
own dynamic-init statement (merged here into the declaration, as clang has it).

Differences from clang that the consumers do not see are listed in the note; the ones that matter are: a node's
"type" carries only qualType; a class copy is its source expression (no CXXConstructExpr); a literal that folded to
a bool constant in C++ is a CXXBoolLiteralExpr; ids are "r<N>" strings, unique within the document.
*/

#include "basic_hdrs.h"
#include "fe_common.h"
#include "il.h"
#include "types.h"
#include "const_ints.h"
#include "float_pt.h"
#include "il_to_str.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

USING_NAMESPACE_EDG


extern FILE *nfcxx_decl_out;   /* be/nfcxx_decl.c */
#define J (nfcxx_decl_out != NULL ? nfcxx_decl_out : stdout)

/* ---------------------------------------------------------------- ids */

/* Pointer -> small integer, by open addressing. Entities are variables, fields, routines and records. */
#define AST_IDS (1 << 20)
static const void *ast_key[AST_IDS];
static int ast_val[AST_IDS];
static int ast_next;

static int ast_id(const void *p)
{
  size_t h = ((size_t)p >> 4) * 2654435761u;
  size_t i = h & (AST_IDS - 1);
  while (ast_key[i] != NULL) {
    if (ast_key[i] == p) return ast_val[i];
    i = (i + 1) & (AST_IDS - 1);
  }
  ast_key[i] = p;
  ast_val[i] = ++ast_next;
  return ast_val[i];
}

/* ------------------------------------------------------------- output */

static void put_str(const char *s)
{
  fputc('"', J);
  for (; s != NULL && *s != '\0'; s++) {
    unsigned char c = (unsigned char)*s;
    if (c == '"' || c == '\\') { fputc('\\', J); fputc(c, J); }
    else if (c == '\n') fputs("\\n", J);
    else if (c < 32) fprintf(J, "\\u%04x", c);
    else fputc(c, J);
  }
  fputc('"', J);
}

static void put_field_str(const char *key, const char *value)
{
  fprintf(J, ",\"%s\":", key);
  put_str(value);
}

static int sep(int *n)
{
  if ((*n)++ > 0) fputc(',', J);
  return *n;
}

static int is_c_source(void) { return il_header.source_language == sl_C; }

static const char *nf_name(a_source_correspondence *corr)
{
  if (corr->name_has_been_mangled && corr->unmangled_name_or_mangled_encoding != NULL)
    return corr->unmangled_name_or_mangled_encoding;
  return corr->name;
}

/* ------------------------------------------------------------- types */

/* A C-like spelling, as clang prints a qualType: typedef names kept, `struct N` in C and `N` in C++. */
static void spell(a_type_ptr type, char *buf, size_t cap);

static void cat(char *buf, size_t cap, const char *s)
{
  size_t n = strlen(buf);
  if (n + 1 < cap) snprintf(buf + n, cap - n, "%s", s);
}

static void spell_quals(a_type_ptr type, char *buf, size_t cap)
{
  a_type_qualifier_set q = get_type_qualifiers(type);
  if (q & TQ_CONST) cat(buf, cap, "const ");
  if (q & TQ_VOLATILE) cat(buf, cap, "volatile ");
}

static void spell(a_type_ptr type, char *buf, size_t cap)
{
  a_type_ptr t;
  char inner[512];
  if (type == NULL) { cat(buf, cap, "?"); return; }
  if (type->kind == tk_typeref && type->source_corresp.name != NULL && type->source_corresp.name[0] != '\0') {
    spell_quals(type, buf, cap);
    cat(buf, cap, type->source_corresp.name);
    return;
  }
  t = skip_typerefs(type);
  switch (t->kind) {
    case tk_void: spell_quals(type, buf, cap); cat(buf, cap, "void"); break;
    case tk_integer:
      spell_quals(type, buf, cap);
      if (is_enum_type(t) && t->source_corresp.name != NULL) {
        /* An enumeration is an integer type with a flag in EDG; clang spells it by name. */
        if (is_c_source()) cat(buf, cap, "enum ");
        cat(buf, cap, t->source_corresp.name);
        break;
      }
      cat(buf, cap, is_bool_type(t) ? (is_c_source() ? "_Bool" : "bool") : int_type_name(t));
      break;
    case tk_float:
      spell_quals(type, buf, cap);
      cat(buf, cap, float_kind_name(t->variant.float_kind, is_c_source()));
      break;
    case tk_pointer:
      spell(t->variant.pointer.type, buf, cap);
      if (buf[0] != '\0' && buf[strlen(buf) - 1] != '*') cat(buf, cap, " ");
      cat(buf, cap, "*");
      if (get_type_qualifiers(type) & TQ_CONST) cat(buf, cap, " const");
      break;
    case tk_array:
      spell(t->variant.array.element_type, buf, cap);
      if (t->variant.array.is_variable_size_array || t->variant.array.is_template_dependent_size_array)
        cat(buf, cap, " []");
      else {
        snprintf(inner, sizeof inner, " [%llu]", (unsigned long long)t->variant.array.variant.number_of_elements);
        cat(buf, cap, inner);
      }
      break;
    case tk_routine: {
      a_param_type_ptr p;
      spell(t->variant.routine.return_type, buf, cap);
      cat(buf, cap, " (");
      if (t->variant.routine.extra_info != NULL) {
        for (p = t->variant.routine.extra_info->param_type_list; p != NULL; p = p->next) {
          inner[0] = '\0';
          spell(p->type, inner, sizeof inner);
          cat(buf, cap, inner);
          if (p->next != NULL || t->variant.routine.extra_info->has_ellipsis) cat(buf, cap, ", ");
        }
        if (t->variant.routine.extra_info->has_ellipsis) cat(buf, cap, "...");
      }
      cat(buf, cap, ")");
      break;
    }
    case tk_class: case tk_struct: case tk_union: {
      const char *name = t->source_corresp.name;
      spell_quals(type, buf, cap);
      if (is_c_source() || name == NULL) cat(buf, cap, t->kind == tk_union ? "union " : "struct ");
      cat(buf, cap, name != NULL ? name : "(anonymous)");
      break;
    }
    default:
      if (is_enum_type(t)) {
        spell_quals(type, buf, cap);
        if (is_c_source()) cat(buf, cap, "enum ");
        cat(buf, cap, t->source_corresp.name != NULL ? t->source_corresp.name : "(anonymous)");
      } else {
        cat(buf, cap, "?");
      }
  }
}

static void put_type(a_type_ptr type)
{
  char buf[1024];
  buf[0] = '\0';
  spell(type, buf, sizeof buf);
  fputs(",\"type\":{\"qualType\":", J);
  put_str(buf);
  fputc('}', J);
}

/* ------------------------------------------------------------- source files */

/* The physical file and line of a position, ignoring `#line` (clang's "file" and "line"; a `#line` only changes the
   "presumedFile"): the consumers decide whether a declaration is in the source by this file. */
static const char *file_of(a_source_position *pos, a_line_number *line)
{
  a_source_file_ptr sfp;
  a_boolean at_end;
  if (pos->seq == 0) return NULL;
  sfp = source_file_for_seq(pos->seq, line, &at_end, /*physical_line=*/TRUE);
  if (sfp == NULL) return NULL;
  return sfp->full_name != NULL ? sfp->full_name : sfp->file_name;
}

static void put_loc(a_source_position *pos)
{
  a_line_number line = 0;
  const char *file = file_of(pos, &line);
  if (file == NULL) return;
  fputs(",\"loc\":{\"file\":", J);
  put_str(file);
  fprintf(J, ",\"line\":%d,\"col\":%d}", (int)line, (int)pos->column);
}

/* ------------------------------------------------------------- expressions */

static void expr(an_expr_node_ptr e);
static void stmt(a_statement_ptr s);
static void constant(a_constant_ptr c, a_type_ptr type);

static void expr_rv(an_expr_node_ptr e);
static a_lambda_ptr cur_lambda;   /* the lambda whose body is being written */

static void expr_kids(an_expr_node_ptr list)
{
  int n = 0;
  for (; list != NULL; list = list->next) { sep(&n); expr(list); }
}

/* The operands as values (what clang's implicit LValueToRValue conversions apply to). */
static void expr_kids_rv(an_expr_node_ptr list)
{
  int n = 0;
  for (; list != NULL; list = list->next) { sep(&n); expr_rv(list); }
}

/* A node with the given kind whose children are the operand list; the first operand stays an lvalue when lv0 (the
   target of an assignment, the operand of & ++ --), the others are values. */
static void node_ops_lv(const char *kind, an_expr_node_ptr e, const char *opcode, an_expr_node_ptr ops, int lv0)
{
  int n = 0;
  fprintf(J, "{\"kind\":\"%s\"", kind);
  if (opcode != NULL) put_field_str("opcode", opcode);
  put_type(e->type);
  fputs(",\"inner\":[", J);
  for (; ops != NULL; ops = ops->next) {
    sep(&n);
    if (lv0 && n == 1) expr(ops); else expr_rv(ops);
  }
  fputs("]}", J);
}

static void node_ops(const char *kind, an_expr_node_ptr e, const char *opcode, an_expr_node_ptr ops)
{
  node_ops_lv(kind, e, opcode, ops, 0);
}

static void put_var_ref(a_variable_ptr v, a_type_ptr type)
{
  const char *name = v->source_corresp.name;
  if (v->is_this_parameter) {
    fputs("{\"kind\":\"CXXThisExpr\"", J);
    put_type(type);
    fputc('}', J);
    return;
  }
  fputs("{\"kind\":\"DeclRefExpr\"", J);
  put_type(type);
  fprintf(J, ",\"referencedDecl\":{\"id\":\"r%d\",\"kind\":\"%s\"", ast_id(v), v->is_parameter ? "ParmVarDecl" : "VarDecl");
  put_field_str("name", name != NULL ? name : "");
  put_type(v->type);
  fputs("}}", J);
}

/* clang's declaration kind of a routine: a member function is a CXXMethodDecl (a constructor and a destructor have their
   own kinds), anything else a FunctionDecl. */
static const char *routine_kind(a_routine_ptr r)
{
  if (r == NULL || is_c_source()) return "FunctionDecl";
  if (r->special_kind == sfk_constructor) return "CXXConstructorDecl";
  if (r->special_kind == sfk_destructor) return "CXXDestructorDecl";
  if (r->source_corresp.is_class_member) return "CXXMethodDecl";
  return "FunctionDecl";
}

static void put_routine_ref(a_routine_ptr r, a_type_ptr type)
{
  const char *name = r != NULL ? nf_name(&r->source_corresp) : NULL;
  fputs("{\"kind\":\"DeclRefExpr\"", J);
  put_type(type);
  fprintf(J, ",\"referencedDecl\":{\"id\":\"r%d\",\"kind\":\"%s\"", ast_id(r), routine_kind(r));
  put_field_str("name", name != NULL ? name : "");
  if (r != NULL) put_type(r->type);
  fputs("}}", J);
}

static const char *binop(an_expr_operator_kind k)
{
  switch (k) {
    case eok_add: case eok_padd: return "+";
    case eok_subtract: case eok_psubtract: case eok_pdiff: return "-";
    case eok_multiply: return "*";
    case eok_divide: return "/";
    case eok_remainder: return "%";
    case eok_shiftl: return "<<";
    case eok_shiftr: return ">>";
    case eok_and: return "&";
    case eok_or: return "|";
    case eok_xor: return "^";
    case eok_eq: return "==";
    case eok_ne: return "!=";
    case eok_gt: return ">";
    case eok_lt: return "<";
    case eok_ge: return ">=";
    case eok_le: return "<=";
    case eok_land: return "&&";
    case eok_lor: return "||";
    case eok_comma: return ",";
    case eok_assign: case eok_bassign: return "=";
    default: return NULL;
  }
}

static const char *compound_assign(an_expr_operator_kind k)
{
  switch (k) {
    case eok_add_assign: case eok_padd_assign: return "+=";
    case eok_subtract_assign: case eok_psubtract_assign: return "-=";
    case eok_multiply_assign: return "*=";
    case eok_divide_assign: return "/=";
    case eok_remainder_assign: return "%=";
    case eok_shiftl_assign: return "<<=";
    case eok_shiftr_assign: return ">>=";
    case eok_and_assign: return "&=";
    case eok_or_assign: return "|=";
    case eok_xor_assign: return "^=";
    default: return NULL;
  }
}

static const char *unop(an_expr_operator_kind k)
{
  switch (k) {
    case eok_negate: return "-";
    case eok_unary_plus: return "+";
    case eok_complement: return "~";
    case eok_not: return "!";
    case eok_pre_incr: return "++";
    case eok_pre_decr: return "--";
    case eok_post_incr: return "++";
    case eok_post_decr: return "--";
    case eok_address_of: return "&";
    case eok_indirect: return "*";
    default: return NULL;
  }
}

static int is_cast_kind(an_expr_operator_kind k)
{
  switch (k) {
    case eok_cast: case eok_lvalue_cast: case eok_ref_cast: case eok_lvalue_adjust: case eok_class_rvalue_adjust:
    case eok_base_class_cast: case eok_derived_class_cast: case eok_bool_cast: case eok_array_to_pointer:
    case eok_reference_to: case eok_ref_indirect:
      return 1;
    default:
      return 0;
  }
}

static int int_like(a_type_ptr t) { return t->kind == tk_integer || is_enum_type(t); }

static int is_zero_constant(an_expr_node_ptr op)
{
  a_constant_ptr c;
  if (op == NULL || op->kind != enk_constant) return 0;
  c = op->variant.constant.ptr;
  if (c == NULL || c->kind != ck_integer) return 0;
  return strcmp(str_for_integer_constant(c).as_temp_characters(), "0") == 0;
}

/* clang's castKind for an EDG conversion: from the operand's and the result's types. */
static const char *cast_kind(an_expr_node_ptr e)
{
  an_expr_node_ptr op = e->variant.operation.operands;
  an_expr_operator_kind k = e->variant.operation.kind;
  a_type_ptr d, s;
  if (k == eok_array_to_pointer) return "ArrayToPointerDecay";
  if (k == eok_base_class_cast) return "UncheckedDerivedToBase";
  if (k == eok_derived_class_cast) return "BaseToDerived";
  if (k == eok_bool_cast) return "IntegralToBoolean";
  if (op == NULL || op->type == NULL || e->type == NULL) return "NoOp";
  if (k != eok_cast) return "NoOp";
  d = skip_typerefs(e->type);
  s = skip_typerefs(op->type);
  if (d->kind == tk_integer && is_bool_type(d)) {
    if (s->kind == tk_pointer) return "PointerToBoolean";
    if (s->kind == tk_float) return "FloatingToBoolean";
    return is_bool_type(s) ? "NoOp" : "IntegralToBoolean";
  }
  if (int_like(d)) {
    if (int_like(s)) return d == s ? "NoOp" : "IntegralCast";
    if (s->kind == tk_float) return "FloatingToIntegral";
    if (s->kind == tk_pointer) return "PointerToIntegral";
    return "NoOp";
  }
  if (d->kind == tk_float) {
    if (s->kind == tk_float) return d == s ? "NoOp" : "FloatingCast";
    if (int_like(s)) return "IntegralToFloating";
    return "NoOp";
  }
  if (d->kind == tk_pointer) {
    if (s->kind == tk_pointer)
      return skip_typerefs(d->variant.pointer.type) == skip_typerefs(s->variant.pointer.type) ? "NoOp" : "BitCast";
    if (int_like(s)) return is_zero_constant(op) ? "NullToPointer" : "IntegralToPointer";
    if (s->kind == tk_routine) return "FunctionToPointerDecay";
    if (s->kind == tk_array) return "ArrayToPointerDecay";
  }
  return "NoOp";
}

/* A conversion that keeps its operand an lvalue (references, an array's decay). */
static int keeps_lvalue(an_expr_operator_kind k)
{
  switch (k) {
    case eok_lvalue_cast: case eok_ref_cast: case eok_lvalue_adjust: case eok_reference_to: case eok_ref_indirect:
    case eok_array_to_pointer: case eok_class_rvalue_adjust: case eok_base_class_cast: case eok_derived_class_cast:
      return 1;
    default:
      return 0;
  }
}

static void cast_node(an_expr_node_ptr e)
{
  an_expr_node_ptr op = e->variant.operation.operands;
  fprintf(J, "{\"kind\":\"ImplicitCastExpr\",\"castKind\":\"%s\"", cast_kind(e));
  put_type(e->type);
  fputs(",\"inner\":[", J);
  if (op != NULL) { if (keeps_lvalue(e->variant.operation.kind)) expr(op); else expr_rv(op); }
  fputs("]}", J);
}

/* Whether an expression designates an object: a variable, a dereference, a subscript, a member of an object. */
static int is_lv(an_expr_node_ptr e)
{
  an_expr_node_ptr op;
  if (e == NULL) return 0;
  if (e->kind == enk_variable) return 1;
  if (e->kind != enk_operation) return e->is_lvalue != 0;
  op = e->variant.operation.operands;
  switch (e->variant.operation.kind) {
    case eok_indirect: case eok_subscript: case eok_points_to_field: return 1;
    case eok_dot_field: return is_lv(op);
    case eok_parens: return is_lv(op);
    default: return e->is_lvalue != 0;
  }
}

/* Whether a use of this expression as a value reads an lvalue of scalar type (clang inserts an LValueToRValue cast). */
static int needs_l2r(an_expr_node_ptr e)
{
  a_type_ptr t;
  if (e == NULL || !is_lv(e) || e->type == NULL || e->kind == enk_constant) return 0;
  t = skip_typerefs(e->type);
  if (is_reference_type(t)) t = skip_typerefs(t->variant.pointer.type);
  switch (t->kind) {
    case tk_class: case tk_struct: case tk_union: case tk_array: case tk_routine: case tk_void: return 0;
    default: return 1;
  }
}

static void expr_rv(an_expr_node_ptr e)
{
  if (needs_l2r(e)) {
    fputs("{\"kind\":\"ImplicitCastExpr\",\"castKind\":\"LValueToRValue\"", J);
    put_type(e->type);
    fputs(",\"inner\":[", J);
    expr(e);
    fputs("]}", J);
  } else {
    expr(e);
  }
}

static void field_member(an_expr_node_ptr e, int arrow)
{
  an_expr_node_ptr obj = e->variant.operation.operands;
  an_expr_node_ptr f = obj != NULL ? obj->next : NULL;
  if (cur_lambda != NULL && f != NULL && f->kind == enk_field) {
    /* Inside a lambda, a captured variable is a field of the closure object; clang names the variable itself. */
    a_lambda_capture_ptr cap;
    for (cap = cur_lambda->capture_list; cap != NULL; cap = cap->next) {
      if (cap->is_init_capture || cap->closure_field != f->variant.field.ptr || cap->captured.variable == NULL) continue;
      put_var_ref(cap->captured.variable, e->type);
      return;
    }
  }
  fputs("{\"kind\":\"MemberExpr\"", J);
  if (f != NULL && f->kind == enk_field) {
    const char *name = f->variant.field.ptr->source_corresp.name;
    put_field_str("name", name != NULL ? name : "");
    fprintf(J, ",\"referencedMemberDecl\":\"r%d\"", ast_id(f->variant.field.ptr));
  }
  fprintf(J, ",\"isArrow\":%s", arrow ? "true" : "false");
  put_type(e->type);
  fputs(",\"inner\":[", J);
  if (obj != NULL) { if (arrow) expr_rv(obj); else expr(obj); }
  fputs("]}", J);
}

static void dynamic_init_value(a_dynamic_init_ptr d, a_type_ptr type);
static void lambda_expr(an_expr_node_ptr e);
static void lambda_node(a_lambda_ptr l, a_type_ptr type);
static void var_decl_with(a_variable_ptr v, a_dynamic_init_ptr d);

/* x.f(args) / p->f(args): CXXMemberCallExpr[MemberExpr{name, referencedMemberDecl, isArrow}[object], args...]. */
static void member_call(an_expr_node_ptr e, int arrow)
{
  an_expr_node_ptr rt = e->variant.operation.operands;
  an_expr_node_ptr obj = rt != NULL ? rt->next : NULL;
  a_routine_ptr r = rt != NULL && rt->kind == enk_routine ? rt->variant.routine.ptr : NULL;
  const char *name = r != NULL ? nf_name(&r->source_corresp) : NULL;
  fputs("{\"kind\":\"CXXMemberCallExpr\"", J);
  put_type(e->type);
  fputs(",\"inner\":[{\"kind\":\"MemberExpr\"", J);
  put_field_str("name", name != NULL ? name : "");
  fprintf(J, ",\"referencedMemberDecl\":\"r%d\",\"isArrow\":%s,\"inner\":[", ast_id(r), arrow ? "true" : "false");
  if (obj != NULL) { if (arrow) expr_rv(obj); else expr(obj); }
  fputs("]}", J);
  if (obj != NULL && obj->next != NULL) { fputc(',', J); expr_kids_rv(obj->next); }
  fputs("]}", J);
}

/* An aggregate constant as an InitListExpr: one element per field, in order. */
static void aggregate(a_constant_ptr c, a_type_ptr type)
{
  a_constant_ptr el;
  int n = 0;
  fputs("{\"kind\":\"InitListExpr\"", J);
  put_type(type);
  fputs(",\"inner\":[", J);
  for (el = c->variant.aggregate.first_constant; el != NULL; el = el->next) {
    sep(&n);
    constant(el, el->type);
  }
  fputs("]}", J);
}

/* The named constant (an enumerator) a folded constant came from, or NULL: folding an enumerator through a conversion
   (`m.tt == MRB_TT_STRING` converts it to int) leaves an unnamed constant whose `expr` is the expression it was folded from. */
static a_constant_ptr named_origin(a_constant_ptr c)
{
  int depth;
  for (depth = 0; c != NULL && depth < 8; depth++) {
    an_expr_node_ptr e;
    if (c->source_corresp.name != NULL && c->source_corresp.name[0] != '\0') return c;
    e = c->expr;
    while (e != NULL && e->kind == enk_operation &&
           (e->variant.operation.kind == eok_cast || e->variant.operation.kind == eok_parens) &&
           e->variant.operation.operands != NULL)
      e = e->variant.operation.operands;
    c = (e != NULL && e->kind == enk_constant) ? e->variant.constant.ptr : NULL;
  }
  return NULL;
}

static void constant(a_constant_ptr c, a_type_ptr type)
{
  if (c == NULL) { fputs("{\"kind\":\"NullConstant\"}", J); return; }
  switch (c->kind) {
    case ck_integer: {
      a_constant_ptr named = named_origin(c);
      const char *name = named != NULL ? named->source_corresp.name : NULL;
      if (name != NULL && name[0] != '\0') {
        /* A reference to an enumerator keeps its name, and the enumeration's type; a conversion the front end folded
           into the constant (`(mrb_sym)MRB_SYM_each`) is the IntegralCast clang writes. */
        a_type_ptr ety = named->type != NULL ? named->type : type;
        int folded = type != NULL && ety != NULL && skip_typerefs(type) != skip_typerefs(ety);
        if (folded) {
          fputs("{\"kind\":\"ImplicitCastExpr\",\"castKind\":\"IntegralCast\"", J);
          put_type(type);
          fputs(",\"inner\":[", J);
        }
        fputs("{\"kind\":\"DeclRefExpr\"", J);
        put_type(ety);
        fprintf(J, ",\"referencedDecl\":{\"id\":\"r%d\",\"kind\":\"EnumConstantDecl\"", ast_id(named));
        put_field_str("name", name);
        fputs("}}", J);
        if (folded) fputs("]}", J);
      } else if (type != NULL && is_bool_type(skip_typerefs(type)) && !is_c_source()) {
        a_number_buffer digits = str_for_integer_constant(c);
        an_expr_node_ptr src = c->expr;
        a_constant_ptr from = NULL;
        while (src != NULL && src->kind == enk_operation &&
               (src->variant.operation.kind == eok_parens || src->variant.operation.kind == eok_cast ||
                src->variant.operation.kind == eok_bool_cast) &&
               src->variant.operation.operands != NULL) {
          if (src->variant.operation.kind != eok_parens && src->variant.operation.operands->kind == enk_constant) {
            a_constant_ptr fc = src->variant.operation.operands->variant.constant.ptr;
            if (fc != NULL && fc->kind == ck_integer && fc->type != NULL && !is_bool_type(skip_typerefs(fc->type))) from = fc;
          }
          src = src->variant.operation.operands;
        }
        if (from != NULL || c->expr != NULL) {
          /* `bool b = 1;`: the integer literal, converted (a literal `true` has no source expression). */
          fputs("{\"kind\":\"ImplicitCastExpr\",\"castKind\":\"IntegralToBoolean\"", J);
          put_type(type);
          fputs(",\"inner\":[", J);
          if (from != NULL) {
            constant(from, from->type);
          } else {
            fputs("{\"kind\":\"IntegerLiteral\"", J);
            put_field_str("value", digits.as_temp_characters());
            fputs(",\"type\":{\"qualType\":\"int\"}}", J);
          }
          fputs("]}", J);
        } else {
          fprintf(J, "{\"kind\":\"CXXBoolLiteralExpr\",\"value\":%s", strcmp(digits.as_temp_characters(), "0") == 0 ? "false" : "true");
          put_type(type);
          fputc('}', J);
        }
      } else {
        a_number_buffer digits = str_for_integer_constant(c);
        fputs("{\"kind\":\"IntegerLiteral\"", J);
        put_field_str("value", digits.as_temp_characters());
        put_type(type);
        fputc('}', J);
      }
      break;
    }
    case ck_float: {
      a_boolean pos_inf = FALSE, neg_inf = FALSE, nan_val = FALSE;
      a_number_buffer text = fp_to_string(skip_typerefs(c->type)->variant.float_kind, &c->variant.float_value,
                                          &pos_inf, &neg_inf, &nan_val);
      fputs("{\"kind\":\"FloatingLiteral\"", J);
      put_field_str("value", text.as_temp_characters());
      put_type(type);
      fputc('}', J);
      break;
    }
    case ck_string: {
      /* clang's value is the literal's spelling: a narrow string without its terminating NUL, in C escapes; a wide
         string (L, u, U) is not read by anything, so it only gets a prefix. */
      a_type_ptr arr = c->type != NULL ? skip_typerefs(c->type) : NULL;
      int narrow = arr == NULL || arr->kind != tk_array || skip_typerefs(arr->variant.array.element_type)->size == 1;
      a_targ_size_t len = c->variant.string.length, i;
      const unsigned char *bytes = (const unsigned char *)c->variant.string.value;
      fputs("{\"kind\":\"StringLiteral\"", J);
      put_type(type);
      fputs(",\"value\":\"", J);
      if (!narrow) {
        fputs("L\\\"\\\"", J);
      } else {
        fputs("\\\"", J);
        if (len > 0 && bytes[len - 1] == 0) len--;
        for (i = 0; i < len; i++) {
          unsigned char ch = bytes[i];
          if (ch == '"') fputs("\\\\\\\"", J);
          else if (ch == '\\') fputs("\\\\\\\\", J);
          else if (ch >= 32 && ch < 127) fputc(ch, J);
          else fprintf(J, "\\\\%03o", ch);
        }
        fputs("\\\"", J);
      }
      fputs("\"}", J);
      break;
    }
    case ck_address: {
      if (c->variant.address.kind == abk_constant && c->variant.address.variant.constant != NULL &&
          c->variant.address.variant.constant->kind == ck_string) {
        /* A string literal's address (`"x"` as a char pointer): the array's decay over the literal. */
        fputs("{\"kind\":\"ImplicitCastExpr\",\"castKind\":\"ArrayToPointerDecay\"", J);
        put_type(type);
        fputs(",\"inner\":[", J);
        constant(c->variant.address.variant.constant, c->variant.address.variant.constant->type);
        fputs("]}", J);
        break;
      }
      /* &routine, &variable (+ offset), an array's decay: UnaryOperator & over the object, offset dropped. */
      fputs("{\"kind\":\"UnaryOperator\",\"opcode\":\"&\"", J);
      put_type(type);
      fputs(",\"inner\":[", J);
      switch (c->variant.address.kind) {
        case abk_routine: put_routine_ref(c->variant.address.variant.routine, type); break;
        case abk_variable: put_var_ref(c->variant.address.variant.variable, type); break;
        default: fputs("{\"kind\":\"AddressConstant\"}", J); break;
      }
      fputs("]}", J);
      break;
    }
    case ck_aggregate:
      aggregate(c, type);
      break;
    case ck_dynamic_init:
      dynamic_init_value(c->variant.dynamic_init.ptr, type);
      break;
    default:
      fputs("{\"kind\":\"UnknownConstant\"}", J);
  }
}

/* The value a dynamic initialization computes, as an expression node (an object's initializer, or a temporary's). */
static void dynamic_init_value(a_dynamic_init_ptr d, a_type_ptr type)
{
  if (d == NULL) { fputs("{\"kind\":\"ImplicitValueInitExpr\"}", J); return; }
  switch (d->kind) {
    case dik_constant:
    case dik_nonconstant_aggregate:
      constant(d->variant.constant.ptr, type);
      break;
    case dik_expression:
    case dik_class_result_via_ctor:
      expr_rv(d->variant.expression);
      break;
    case dik_lambda:
      lambda_node(d->variant.constant.lambda, type);
      break;
    case dik_constructor: {
      fputs("{\"kind\":\"CXXConstructExpr\"", J);
      put_type(type);
      fputs(",\"inner\":[", J);
      expr_kids_rv(d->variant.constructor.args);
      fputs("]}", J);
      break;
    }
    default:
      fputs("{\"kind\":\"ImplicitValueInitExpr\"}", J);
  }
}

static void expr(an_expr_node_ptr e)
{
  if (e == NULL) { fputs("{\"kind\":\"NullExpr\"}", J); return; }
  switch (e->kind) {
    case enk_constant:
      constant(e->variant.constant.ptr, e->type);
      return;
    case enk_variable:
      put_var_ref(e->variant.variable.ptr, e->type);
      return;
    case enk_routine:
      put_routine_ref(e->variant.routine.ptr, e->type);
      return;
    case enk_field: {
      const char *name = e->variant.field.ptr->source_corresp.name;
      fputs("{\"kind\":\"FieldRef\"", J);
      put_field_str("name", name != NULL ? name : "");
      fputc('}', J);
      return;
    }
    case enk_temp_init:
      /* A temporary's initialization: its value is the initializer. */
      dynamic_init_value(e->variant.init.dynamic_init, e->type);
      return;
    case enk_lambda:
      lambda_expr(e);
      return;
    case enk_condition: {
      /* if (T x = f()): the variable declaration with its value, then the value tested. */
      a_condition_supplement_ptr cs = e->variant.condition;
      fputs("{\"kind\":\"ConditionExpr\",\"inner\":[", J);
      if (cs != NULL && cs->dynamic_init != NULL && cs->dynamic_init->variable != NULL) {
        var_decl_with(cs->dynamic_init->variable, cs->dynamic_init);
        fputc(',', J);
      }
      if (cs != NULL && cs->expr != NULL) expr_rv(cs->expr);
      fputs("]}", J);
      return;
    }
    case enk_new_delete: {
      a_new_delete_supplement_ptr nd = e->variant.new_delete;
      fputs(nd != NULL && nd->is_new ? "{\"kind\":\"CXXNewExpr\"" : "{\"kind\":\"CXXDeleteExpr\"", J);
      put_type(e->type);
      fputs(",\"inner\":[", J);
      if (nd != NULL) {
        if (nd->is_new && nd->dynamic_init != NULL) dynamic_init_value(nd->dynamic_init, nd->type);
        else if (nd->arg != NULL) expr_kids_rv(nd->arg);
      }
      fputs("]}", J);
      return;
    }
    case enk_throw: {
      a_throw_supplement_ptr th = e->variant.throw_info;
      fputs("{\"kind\":\"CXXThrowExpr\",\"inner\":[", J);
      if (th != NULL && th->dynamic_init != NULL) dynamic_init_value(th->dynamic_init, th->type);
      fputs("]}", J);
      return;
    }
    case enk_object_lifetime:
      fputs("{\"kind\":\"ExprWithCleanups\"", J);
      put_type(e->type);
      fputs(",\"inner\":[", J);
      expr(e->variant.object_lifetime.expr);
      fputs("]}", J);
      return;
    case enk_operation: {
      an_expr_operator_kind k = e->variant.operation.kind;
      an_expr_node_ptr ops = e->variant.operation.operands;
      const char *op;
      if (k == eok_parens) { node_ops("ParenExpr", e, NULL, ops); return; }
      if (k == eok_address_of && ops != NULL && ops->kind == enk_routine) {
        /* A function's address, from a decay or an explicit &f: clang's FunctionToPointerDecay over the reference. */
        fputs("{\"kind\":\"ImplicitCastExpr\",\"castKind\":\"FunctionToPointerDecay\"", J);
        put_type(e->type);
        fputs(",\"inner\":[", J);
        expr(ops);
        fputs("]}", J);
        return;
      }
      if (is_cast_kind(k)) { cast_node(e); return; }
      if (k == eok_question) { node_ops("ConditionalOperator", e, NULL, ops); return; }
      if (k == eok_dot_member_call) { member_call(e, 0); return; }
      if (k == eok_points_to_member_call) { member_call(e, 1); return; }
      if (k == eok_dot_field) { field_member(e, 0); return; }
      if (k == eok_points_to_field) { field_member(e, 1); return; }
      if (k == eok_subscript) { node_ops("ArraySubscriptExpr", e, NULL, ops); return; }
      if (k == eok_call) {
        /* A direct call names its routine; the callee is wrapped in a cast, as clang's function-to-pointer decay. */
        an_expr_node_ptr callee = ops;
        an_expr_node_ptr inner = callee;
        while (inner != NULL && inner->kind == enk_operation &&
               (is_cast_kind(inner->variant.operation.kind) || inner->variant.operation.kind == eok_parens ||
                inner->variant.operation.kind == eok_address_of || inner->variant.operation.kind == eok_dot_static ||
                inner->variant.operation.kind == eok_points_to_static) &&
               inner->variant.operation.operands != NULL) {
          /* A static member function named through an object: its routine is the second operand. */
          if (inner->variant.operation.kind == eok_dot_static || inner->variant.operation.kind == eok_points_to_static) {
            inner = inner->variant.operation.operands->next;
            break;
          }
          inner = inner->variant.operation.operands;
        }
        fputs("{\"kind\":\"CallExpr\"", J);
        put_type(e->type);
        fputs(",\"inner\":[", J);
        if (inner != NULL && inner->kind == enk_routine) {
          fputs("{\"kind\":\"ImplicitCastExpr\",\"castKind\":\"FunctionToPointerDecay\",\"inner\":[", J);
          put_routine_ref(inner->variant.routine.ptr, inner->type);
          fputc(']', J);
          fputc('}', J);
        } else if (callee != NULL && inner != NULL && inner->kind == enk_constant &&
                   inner->variant.constant.ptr != NULL && inner->variant.constant.ptr->kind != ck_address) {
          /* A call whose function a template parameter decides (a name looked up at instantiation): clang's
             UnresolvedLookupExpr, which the main-root analysis reads as "an unknown function may be called". */
          fputs("{\"kind\":\"UnresolvedLookupExpr\"}", J);
        } else if (callee != NULL) {
          expr_rv(callee);
        }
        if (callee != NULL && callee->next != NULL) { fputc(',', J); expr_kids_rv(callee->next); }
        fputs("]}", J);
        return;
      }
      if ((op = binop(k)) != NULL) {
        node_ops_lv("BinaryOperator", e, op, ops, k == eok_assign || k == eok_bassign);
        return;
      }
      if ((op = compound_assign(k)) != NULL) { node_ops_lv("CompoundAssignOperator", e, op, ops, 1); return; }
      if ((op = unop(k)) != NULL) {
        node_ops_lv("UnaryOperator", e, op, ops,
                    k == eok_address_of || k == eok_pre_incr || k == eok_pre_decr || k == eok_post_incr || k == eok_post_decr);
        return;
      }
      {
        fputs("{\"kind\":\"UnknownExpr\"", J);
        fprintf(J, ",\"eok\":%d", (int)k);
        put_type(e->type);
        fputs(",\"inner\":[", J);
        expr_kids(ops);
        fputs("]}", J);
      }
      return;
    }
    default: {
      fputs("{\"kind\":\"UnknownExpr\"", J);
      fprintf(J, ",\"enk\":%d", (int)e->kind);
      put_type(e->type);
      fputc('}', J);
    }
  }
}

/* ------------------------------------------------------------- statements */

/* A function's dynamic initializations of its locals, by variable, found before the body is written: the
   initializer of a variable is its own statement in the IL, and its declaration (a separate statement) carries it. */
#define AST_MAX_INITS 65536
static a_variable_ptr init_var[AST_MAX_INITS];
static a_dynamic_init_ptr init_val[AST_MAX_INITS];
static int init_count;
static int init_base;
static int in_ctor_dtor;   /* writing the body of a constructor or destructor */   /* the current function's inits are init_var[init_base .. init_count): a lambda nests */

static void collect_inits(a_statement_ptr s)
{
  for (; s != NULL; s = s->next) {
    switch (s->kind) {
      case stmk_init:
        if (s->variant.dynamic_init != NULL && s->variant.dynamic_init->variable != NULL && init_count < AST_MAX_INITS) {
          init_var[init_count] = s->variant.dynamic_init->variable;
          init_val[init_count++] = s->variant.dynamic_init;
        }
        break;
      case stmk_block: collect_inits(s->variant.block.statements); break;
      case stmk_if:
        collect_inits(s->variant.if_stmt.then_statement);
        collect_inits(s->variant.if_stmt.else_statement);
        break;
      case stmk_while: case stmk_end_test_while: collect_inits(s->variant.loop_statement); break;
      case stmk_for:
        if (s->variant.for_loop.extra_info != NULL) collect_inits(s->variant.for_loop.extra_info->initialization);
        collect_inits(s->variant.for_loop.statement);
        break;
      case stmk_switch: collect_inits(s->variant.switch_stmt.body_statement); break;
      case stmk_constexpr_if:
        if (s->variant.constexpr_if != NULL) {
          collect_inits(s->variant.constexpr_if->then_statement);
          collect_inits(s->variant.constexpr_if->else_statement);
        }
        break;
      case stmk_range_based_for: collect_inits(s->variant.range_based_for_loop.statement); break;
      case stmk_try_block:
        if (s->variant.try_block != NULL) {
          a_handler_ptr h;
          collect_inits(s->variant.try_block->statement);
          for (h = s->variant.try_block->handlers; h != NULL; h = h->next) collect_inits(h->statement);
        }
        break;
      default: break;
    }
  }
}

static a_dynamic_init_ptr init_of(a_variable_ptr v)
{
  int i;
  for (i = init_base; i < init_count; i++) if (init_var[i] == v) return init_val[i];
  return NULL;
}

static void var_decl_with(a_variable_ptr v, a_dynamic_init_ptr d)
{
  const char *name = v->source_corresp.name;
  fprintf(J, "{\"kind\":\"VarDecl\",\"id\":\"r%d\"", ast_id(v));
  put_field_str("name", name != NULL ? name : "");
  put_type(v->type);
  if (v->storage_class == sc_static) put_field_str("storageClass", "static");
  if (d != NULL) {
    fputs(",\"inner\":[", J);
    dynamic_init_value(d, v->type);
    fputc(']', J);
  }
  fputc('}', J);
}

static void var_decl(a_variable_ptr v)
{
  a_dynamic_init_ptr d = init_of(v);
  if (d == NULL && v->init_kind == initk_dynamic) d = v->initializer.dynamic;
  var_decl_with(v, d);
}

/* static_assert(cond, "message"): StaticAssertDecl[cond, StringLiteral] (a terse one has no message). */
static void static_assertion(a_static_assertion_ptr sa)
{
  fputs("{\"kind\":\"StaticAssertDecl\",\"inner\":[", J);
  constant(sa != NULL ? sa->condition : NULL, sa != NULL && sa->condition != NULL ? sa->condition->type : NULL);
  if (sa != NULL && sa->string_literal != NULL) {
    fputc(',', J);
    constant(sa->string_literal, sa->string_literal->type);
  }
  fputs("]}", J);
}

static void stmt_kids_n(a_statement_ptr s, int *n)
{
  for (; s != NULL; s = s->next) {
    /* The initialization statement of a variable is merged into its declaration. */
    if (s->kind == stmk_init && s->variant.dynamic_init != NULL && s->variant.dynamic_init->variable != NULL) continue;
    /* A block the front end made (the scope around an `if`, a loop) is not in the source: its statements belong to
       the enclosing block, as in clang. */
    if (s->kind == stmk_block && s->compiler_generated) {
      stmt_kids_n(s->variant.block.statements, n);
      continue;
    }
    sep(n);
    stmt(s);
  }
}

static void stmt_kids(a_statement_ptr s)
{
  int n = 0;
  stmt_kids_n(s, &n);
}

static void stmt(a_statement_ptr s)
{
  if (s == NULL) { fputs("{\"kind\":\"NullStmt\"}", J); return; }
  switch (s->kind) {
    case stmk_empty:
      fputs("{\"kind\":\"NullStmt\"}", J);
      break;
    case stmk_expr:
      expr(s->expr);
      break;
    case stmk_block:
      fputs("{\"kind\":\"CompoundStmt\",\"inner\":[", J);
      stmt_kids(s->variant.block.statements);
      fputs("]}", J);
      break;
    case stmk_if:
      fputs("{\"kind\":\"IfStmt\",\"inner\":[", J);
      expr_rv(s->expr);
      fputc(',', J);
      stmt(s->variant.if_stmt.then_statement);
      if (s->variant.if_stmt.else_statement != NULL) { fputc(',', J); stmt(s->variant.if_stmt.else_statement); }
      fputs("]}", J);
      break;
    case stmk_while:
      fputs("{\"kind\":\"WhileStmt\",\"inner\":[", J);
      expr_rv(s->expr);
      fputc(',', J);
      stmt(s->variant.loop_statement);
      fputs("]}", J);
      break;
    case stmk_end_test_while:
      fputs("{\"kind\":\"DoStmt\",\"inner\":[", J);
      stmt(s->variant.loop_statement);
      fputc(',', J);
      expr_rv(s->expr);
      fputs("]}", J);
      break;
    case stmk_for: {
      a_for_loop_ptr x = s->variant.for_loop.extra_info;
      fputs("{\"kind\":\"ForStmt\",\"inner\":[", J);
      if (x != NULL && x->initialization != NULL) stmt(x->initialization); else fputs("{\"kind\":\"NullStmt\"}", J);
      fputc(',', J);
      if (s->expr != NULL) expr_rv(s->expr); else fputs("{\"kind\":\"NullStmt\"}", J);
      fputc(',', J);
      if (x != NULL && x->increment != NULL) expr(x->increment); else fputs("{\"kind\":\"NullStmt\"}", J);
      fputc(',', J);
      stmt(s->variant.for_loop.statement);
      fputs("]}", J);
      break;
    }
    case stmk_constexpr_if: {
      /* if constexpr: both branches are kept (an instantiation replaces the dead one with an empty statement). */
      a_constexpr_if_ptr ci = s->variant.constexpr_if;
      fputs("{\"kind\":\"IfStmt\",\"inner\":[", J);
      expr_rv(s->expr);
      if (ci != NULL) {
        fputc(',', J);
        stmt(ci->then_statement);
        if (ci->else_statement != NULL) { fputc(',', J); stmt(ci->else_statement); }
      }
      fputs("]}", J);
      break;
    }
    case stmk_range_based_for: {
      /* for (decl : range) body: the range, begin and end variables with their initial values, the test, the
         increment, and the loop variable. */
      a_range_based_for_loop_ptr rb = s->variant.range_based_for_loop.extra_info;
      fputs("{\"kind\":\"CXXForRangeStmt\",\"inner\":[", J);
      if (rb != NULL) {
        a_variable_ptr vars[4];
        int i, n = 0;
        vars[0] = rb->range; vars[1] = rb->begin; vars[2] = rb->end; vars[3] = rb->iterator;
        for (i = 0; i < 3; i++) {
          if (vars[i] == NULL) continue;
          sep(&n);
          fputs("{\"kind\":\"DeclStmt\",\"inner\":[", J);
          var_decl(vars[i]);
          fputs("]}", J);
        }
        if (rb->ne_call_expr != NULL) { sep(&n); expr_rv(rb->ne_call_expr); }
        if (rb->incr_call_expr != NULL) { sep(&n); expr(rb->incr_call_expr); }
        if (vars[3] != NULL) {
          sep(&n);
          fputs("{\"kind\":\"DeclStmt\",\"inner\":[", J);
          var_decl(vars[3]);
          fputs("]}", J);
        }
        sep(&n);
        stmt(s->variant.range_based_for_loop.statement);
      }
      fputs("]}", J);
      break;
    }
    case stmk_try_block: {
      a_try_supplement_ptr ts = s->variant.try_block;
      a_handler_ptr h;
      fputs("{\"kind\":\"CXXTryStmt\",\"inner\":[", J);
      if (ts != NULL) {
        stmt(ts->statement);
        for (h = ts->handlers; h != NULL; h = h->next) {
          fputs(",{\"kind\":\"CXXCatchStmt\",\"inner\":[", J);
          if (h->parameter != NULL) { var_decl_with(h->parameter, NULL); fputc(',', J); }
          stmt(h->statement);
          fputs("]}", J);
        }
      }
      fputs("]}", J);
      break;
    }
    case stmk_switch:
      fputs("{\"kind\":\"SwitchStmt\",\"inner\":[", J);
      expr_rv(s->expr);
      fputc(',', J);
      stmt(s->variant.switch_stmt.body_statement);
      fputs("]}", J);
      break;
    case stmk_switch_case: {
      a_switch_case_entry_ptr x = s->variant.switch_case.extra_info;
      if (x != NULL && x->case_value != NULL) {
        fputs("{\"kind\":\"CaseStmt\",\"inner\":[", J);
        constant(x->case_value, x->case_value->type);
        fputs("]}", J);
      } else {
        fputs("{\"kind\":\"DefaultStmt\"}", J);
      }
      break;
    }
    case stmk_goto: {
      const char *name = s->variant.label.ptr->source_corresp.name;
      fputs("{\"kind\":\"GotoStmt\"", J);
      put_field_str("name", name != NULL ? name : "");
      fputc('}', J);
      break;
    }
    case stmk_label: {
      const char *name = s->variant.label.ptr->source_corresp.name;
      fputs("{\"kind\":\"LabelStmt\"", J);
      put_field_str("name", name != NULL ? name : "");
      fputc('}', J);
      break;
    }
    case stmk_return:
      if (in_ctor_dtor && s->expr == NULL && s->variant.return_dynamic_init == NULL) {
        /* EDG ends a constructor or destructor with a return the source does not have. */
        fputs("{\"kind\":\"NullStmt\"}", J);
        break;
      }
      fputs("{\"kind\":\"ReturnStmt\"", J);
      if (s->expr != NULL) { fputs(",\"inner\":[", J); expr_rv(s->expr); fputc(']', J); }
      else if (s->variant.return_dynamic_init != NULL) {
        fputs(",\"inner\":[", J);
        dynamic_init_value(s->variant.return_dynamic_init, NULL);
        fputc(']', J);
      }
      fputc('}', J);
      break;
    case stmk_decl: {
      an_il_entity_list_entry_ptr en;
      int n = 0;
      fputs("{\"kind\":\"DeclStmt\",\"inner\":[", J);
      for (en = s->variant.decl.entities; en != NULL; en = en->next) {
        if (en->entity.kind == iek_static_assertion) {
          sep(&n);
          static_assertion((a_static_assertion_ptr)en->entity.ptr);
          continue;
        }
        if (en->entity.kind != iek_variable) continue;
        sep(&n);
        var_decl((a_variable_ptr)en->entity.ptr);
      }
      fputs("]}", J);
      break;
    }
    case stmk_init: {
      /* An initialization with no variable: a temporary's. */
      a_dynamic_init_ptr d = s->variant.dynamic_init;
      dynamic_init_value(d, NULL);
      break;
    }
    default: {
      fputs("{\"kind\":\"UnknownStmt\"", J);
      fprintf(J, ",\"stmk\":%d", (int)s->kind);
      fputc('}', J);
    }
  }
}

/* ------------------------------------------------------------- declarations */

static int first_decl;

static void decl_sep(void) { if (!first_decl) fputc(',', J); first_decl = 0; }

/* Whether a routine is declared (directly or through classes) in an unnamed namespace: clang's mangled name has
   `_GLOBAL__N_1`, which the main-root analysis reads as "internal linkage". */
static int in_unnamed_namespace(a_scope_ptr scope)
{
  for (; scope != NULL; scope = scope->parent) {
    if (scope->kind == sck_namespace && scope->variant.assoc_namespace != NULL &&
        scope->variant.assoc_namespace->has_internal_linkage)
      return 1;
  }
  return 0;
}

/* The body scope of a routine the dump writes (a definition with a name), or NULL. */
static a_scope_ptr routine_body_scope(a_routine_ptr rout)
{
  a_scope_ptr scope;
  const char *name = nf_name(&rout->source_corresp);
  if (name == NULL || name[0] == '\0') return NULL;
  if (rout->function_def_number == NULL_function_def_number) return NULL;
  scope = scope_for_routine(rout);
  if (scope == NULL || scope->assoc_block == NULL) return NULL;
  return scope;
}

/* clang's storageClass static: `static` at file scope; for a member, a static member function (EDG's storage_class is
   the linkage there: a lambda's call operator is "static" in it). */
static int routine_is_static(a_routine_ptr rout)
{
  if (!is_c_source() && rout->source_corresp.is_class_member)
    return rout->special_kind == sfk_none && !routine_type_is_nonstatic_member_function(rout->type);
  return rout->storage_class == sc_static;
}

/* One routine with its parameters and body: a FunctionDecl, or a CXXMethodDecl / CXXConstructorDecl /
   CXXDestructorDecl for a member (clang puts those inside the class). */
static void write_routine(a_routine_ptr rout, a_scope_ptr scope)
{
  a_variable_ptr param;
  const char *name = nf_name(&rout->source_corresp);
  int n = 0;
  int saved_base = init_base, saved_count = init_count, saved_cd = in_ctor_dtor;
  init_base = init_count;
  in_ctor_dtor = rout->special_kind == sfk_constructor || rout->special_kind == sfk_destructor;
  collect_inits(scope->assoc_block->kind == stmk_block ? scope->assoc_block->variant.block.statements : scope->assoc_block);
  fprintf(J, "{\"kind\":\"%s\",\"id\":\"r%d\"", routine_kind(rout), ast_id(rout));
  put_field_str("name", name);
  put_type(rout->type);
  if (routine_is_static(rout)) put_field_str("storageClass", "static");
  if (rout->is_virtual) fputs(",\"virtual\":true", J);
  if (in_unnamed_namespace(rout->source_corresp.parent_scope)) put_field_str("mangledName", "_ZN12_GLOBAL__N_1");
  put_loc(&rout->source_corresp.decl_position);
  fputs(",\"inner\":[", J);
  for (param = scope->variant.routine.parameters; param != NULL; param = param->next) {
    const char *pn = param->source_corresp.name;
    a_param_type_ptr pt = NULL;
    if (param->is_this_parameter) continue;
    if (!param->is_struct_binding && !param->is_struct_binding_container) pt = param->variant.assoc_param_type;
    sep(&n);
    fprintf(J, "{\"kind\":\"ParmVarDecl\",\"id\":\"r%d\"", ast_id(param));
    put_field_str("name", pn != NULL ? pn : "");
    put_type(param->type);
    if (pt != NULL && pt->default_arg_expr != NULL) {
      fputs(",\"inner\":[", J);
      expr_rv(pt->default_arg_expr);
      fputc(']', J);
    }
    fputc('}', J);
  }
  if (rout->special_kind == sfk_constructor) {
    /* The mem-initializers the source wrote, each with its initial value. */
    a_constructor_init_ptr ci;
    for (ci = scope->variant.routine.constructor_inits; ci != NULL; ci = ci->next) {
      if (ci->compiler_generated || ci->initializer == NULL) continue;
      sep(&n);
      fputs("{\"kind\":\"CXXCtorInitializer\",\"inner\":[", J);
      dynamic_init_value(ci->initializer, NULL);
      fputs("]}", J);
    }
  }
  sep(&n);
  if (scope->assoc_block->kind == stmk_block) {
    /* EDG wraps the source's `{ ... }` in a block of its own (the function scope): the body is the inner one. */
    a_statement_ptr body = scope->assoc_block->variant.block.statements;
    while (body != NULL && body->next == NULL && body->kind == stmk_block) body = body->variant.block.statements;
    fputs("{\"kind\":\"CompoundStmt\",\"inner\":[", J);
    stmt_kids(body);
    fputs("]}", J);
  } else {
    fputs("{\"kind\":\"CompoundStmt\",\"inner\":[", J);
    stmt(scope->assoc_block);
    fputs("]}", J);
  }
  fputs("]}", J);
  init_base = saved_base;
  init_count = saved_count;
  in_ctor_dtor = saved_cd;
}

/* Whether a routine's declaration gives a parameter a default argument. */
static int has_default_args(a_routine_ptr rout)
{
  a_param_type_ptr p;
  a_type_ptr t = rout->type != NULL ? skip_typerefs(rout->type) : NULL;
  if (t == NULL || t->kind != tk_routine || t->variant.routine.extra_info == NULL) return 0;
  for (p = t->variant.routine.extra_info->param_type_list; p != NULL; p = p->next)
    if (p->default_arg_expr != NULL) return 1;
  return 0;
}

/* A function declared (not defined) here with a default argument: clang's FunctionDecl with its ParmVarDecls, whose
   child is the default value (the main-root analysis reads those values as initializers). */
static void write_decl_only(a_routine_ptr rout)
{
  a_param_type_ptr p;
  const char *name = nf_name(&rout->source_corresp);
  int n = 0;
  fprintf(J, "{\"kind\":\"%s\",\"id\":\"r%d\"", routine_kind(rout), ast_id(rout));
  put_field_str("name", name != NULL ? name : "");
  put_type(rout->type);
  fputs(",\"inner\":[", J);
  for (p = skip_typerefs(rout->type)->variant.routine.extra_info->param_type_list; p != NULL; p = p->next) {
    sep(&n);
    fputs("{\"kind\":\"ParmVarDecl\"", J);
    put_field_str("name", p->name != NULL ? p->name : "");
    put_type(p->type);
    if (p->default_arg_expr != NULL) {
      fputs(",\"inner\":[", J);
      expr_rv(p->default_arg_expr);
      fputc(']', J);
    }
    fputc('}', J);
  }
  fputs("]}", J);
}

static void put_function(a_routine_ptr rout)
{
  a_scope_ptr scope = routine_body_scope(rout);
  if (scope == NULL) {
    const char *name = nf_name(&rout->source_corresp);
    if (is_c_source() || name == NULL || name[0] == '\0' || !has_default_args(rout)) return;
    decl_sep();
    write_decl_only(rout);
    return;
  }
  decl_sep();
  write_routine(rout, scope);
}

/* A lambda: LambdaExpr[CXXRecordDecl[operator() ...]] (the closure class and the call operator that holds the body). */
static void lambda_expr(an_expr_node_ptr e)
{
  lambda_node(e->variant.init.source.lambda, e->type);
}

static void lambda_node(a_lambda_ptr l, a_type_ptr type)
{
  a_scope_ptr scope = l != NULL && l->lambda_routine != NULL ? routine_body_scope(l->lambda_routine) : NULL;
  fputs("{\"kind\":\"LambdaExpr\"", J);
  put_type(type);
  fputs(",\"inner\":[{\"kind\":\"CXXRecordDecl\",\"inner\":[", J);
  if (scope != NULL) {
    a_lambda_ptr saved = cur_lambda;
    cur_lambda = l;
    write_routine(l->lambda_routine, scope);
    cur_lambda = saved;
  }
  fputs("]}]}", J);
}

static void put_record(a_type_ptr type)
{
  an_il_entity_list_entry_ptr en;
  int n = 0;
  const char *name = type->source_corresp.name;
  if (name == NULL || name[0] == '\0') return;
  if (type->variant.class_struct_union.is_template_class && !type->variant.class_struct_union.is_prototype_instantiation) return;
  if (is_incomplete_type(type)) return;
  decl_sep();
  fprintf(J, "{\"kind\":\"%s\",\"id\":\"r%d\"", is_c_source() ? "RecordDecl" : "CXXRecordDecl", ast_id(type));
  put_field_str("name", name);
  put_field_str("tagUsed", type->kind == tk_class ? "class" : type->kind == tk_union ? "union" : "struct");
  fputs(",\"completeDefinition\":true", J);
  put_loc(&type->source_corresp.decl_position);
  fputs(",\"inner\":[", J);
  for (en = class_type_supp(type)->member_declarations; en != NULL; en = en->next) {
    a_field_ptr f;
    const char *fn;
    if (en->entity.kind != iek_field) continue;
    f = (a_field_ptr)en->entity.ptr;
    fn = f->source_corresp.name;
    sep(&n);
    fprintf(J, "{\"kind\":\"FieldDecl\",\"id\":\"r%d\"", ast_id(f));
    put_field_str("name", fn != NULL ? fn : "");
    put_type(f->type);
    /* A default member initializer (`int n = f();`) is the field's child, as in clang. */
    if (f->initializer != NULL) {
      fputs(",\"inner\":[", J);
      dynamic_init_value(f->initializer, f->type);
      fputc(']', J);
    }
    fputc('}', J);
  }
  /* Member functions with a body, in declaration order (a compiler-generated one has no source). */
  if (!is_c_source()) {
    for (en = class_type_supp(type)->member_declarations; en != NULL; en = en->next) {
      a_routine_ptr r;
      a_scope_ptr scope;
      if (en->entity.kind == iek_static_assertion) {
        sep(&n);
        static_assertion((a_static_assertion_ptr)en->entity.ptr);
        continue;
      }
      if (en->entity.kind != iek_routine) continue;
      r = (a_routine_ptr)en->entity.ptr;
      if (r->compiler_generated) continue;
      scope = routine_body_scope(r);
      if (scope == NULL) {
        const char *rn = nf_name(&r->source_corresp);
        if (rn != NULL && rn[0] != '\0' && has_default_args(r)) { sep(&n); write_decl_only(r); }
        continue;
      }
      sep(&n);
      write_routine(r, scope);
    }
  }
  fputs("]}", J);
}

static void put_scope(a_scope_ptr scope, int depth);

static void put_namespace(a_namespace_ptr ns, int depth)
{
  const char *name = ns->source_corresp.name;
  if (ns->is_namespace_alias || ns->variant.assoc_scope == NULL) return;
  decl_sep();
  fputs("{\"kind\":\"NamespaceDecl\"", J);
  put_field_str("name", name != NULL ? name : "");
  fputs(",\"inner\":[", J);
  {
    int saved = first_decl;
    first_decl = 1;
    put_scope(ns->variant.assoc_scope, depth + 1);
    first_decl = saved;
  }
  fputs("]}", J);
}

static void put_scope(a_scope_ptr scope, int depth)
{
  a_namespace_ptr ns;
  a_type_ptr type;
  a_variable_ptr var;
  a_routine_ptr rout;
  for (ns = scope->namespaces; ns != NULL; ns = ns->next) put_namespace(ns, depth);
  for (type = scope->types; type != NULL; type = type->next) {
    if (type->kind == tk_class || type->kind == tk_struct || type->kind == tk_union) put_record(type);
  }
  for (var = scope->variables; var != NULL; var = var->next) {
    const char *name = var->source_corresp.name;
    if (var->compiler_generated || name == NULL || name[0] == '\0') continue;
    decl_sep();
    fprintf(J, "{\"kind\":\"VarDecl\",\"id\":\"r%d\"", ast_id(var));
    put_field_str("name", name);
    put_type(var->type);
    if (var->storage_class == sc_static) put_field_str("storageClass", "static");
    put_loc(&var->source_corresp.decl_position);
    /* The initializer: a constant (an array of structs is an InitListExpr of InitListExprs) or a dynamic one. */
    if (var->init_kind == initk_static && var->initializer.constant != NULL) {
      fputs(",\"inner\":[", J);
      constant(var->initializer.constant, var->type);
      fputc(']', J);
    } else if (var->init_kind == initk_dynamic && var->initializer.dynamic != NULL) {
      fputs(",\"inner\":[", J);
      dynamic_init_value(var->initializer.dynamic, var->type);
      fputc(']', J);
    }
    fputc('}', J);
  }
  for (rout = scope->routines; rout != NULL; rout = rout->next) {
    if (rout->compiler_generated) continue;
    put_function(rout);
  }
}

/* Entry point (called by back_end in nfcxx_decl.c). */
void nfcxx_ast_dump(void)
{
  memset(ast_key, 0, sizeof ast_key);
  ast_next = 0;
  first_decl = 1;
  fputs("{\"kind\":\"TranslationUnitDecl\",\"nfcxx_ast\":1,\"inner\":[", J);
  put_scope(il_header.primary_scope, 0);
  fputs("]}\n", J);
  fflush(J);
}
