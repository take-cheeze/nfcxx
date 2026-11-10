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

static void expr_kids(an_expr_node_ptr list)
{
  int n = 0;
  for (; list != NULL; list = list->next) { sep(&n); expr(list); }
}

/* A node with the given kind whose children are the operand list. */
static void node_ops(const char *kind, an_expr_node_ptr e, const char *opcode, an_expr_node_ptr ops)
{
  fprintf(J, "{\"kind\":\"%s\"", kind);
  if (opcode != NULL) put_field_str("opcode", opcode);
  put_type(e->type);
  fputs(",\"inner\":[", J);
  expr_kids(ops);
  fputs("]}", J);
}

static void put_var_ref(a_variable_ptr v, a_type_ptr type)
{
  const char *name = v->source_corresp.name;
  fputs("{\"kind\":\"DeclRefExpr\"", J);
  put_type(type);
  fprintf(J, ",\"referencedDecl\":{\"id\":\"r%d\",\"kind\":\"%s\"", ast_id(v), v->is_parameter ? "ParmVarDecl" : "VarDecl");
  put_field_str("name", name != NULL ? name : "");
  put_type(v->type);
  fputs("}}", J);
}

static void put_routine_ref(a_routine_ptr r, a_type_ptr type)
{
  const char *name = r != NULL ? nf_name(&r->source_corresp) : NULL;
  fputs("{\"kind\":\"DeclRefExpr\"", J);
  put_type(type);
  fprintf(J, ",\"referencedDecl\":{\"id\":\"r%d\",\"kind\":\"FunctionDecl\"", ast_id(r));
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

static void field_member(an_expr_node_ptr e, int arrow)
{
  an_expr_node_ptr obj = e->variant.operation.operands;
  an_expr_node_ptr f = obj != NULL ? obj->next : NULL;
  fputs("{\"kind\":\"MemberExpr\"", J);
  if (f != NULL && f->kind == enk_field) {
    const char *name = f->variant.field.ptr->source_corresp.name;
    put_field_str("name", name != NULL ? name : "");
    fprintf(J, ",\"referencedMemberDecl\":\"r%d\"", ast_id(f->variant.field.ptr));
  }
  fprintf(J, ",\"isArrow\":%s", arrow ? "true" : "false");
  put_type(e->type);
  fputs(",\"inner\":[", J);
  if (obj != NULL) expr(obj);
  fputs("]}", J);
}

static void dynamic_init_value(a_dynamic_init_ptr d, a_type_ptr type);

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
        /* A reference to an enumerator keeps its name. */
        fputs("{\"kind\":\"DeclRefExpr\"", J);
        put_type(type);
        fprintf(J, ",\"referencedDecl\":{\"id\":\"r%d\",\"kind\":\"EnumConstantDecl\"", ast_id(named));
        put_field_str("name", name);
        fputs("}}", J);
      } else if (type != NULL && is_bool_type(skip_typerefs(type)) && !is_c_source()) {
        a_number_buffer digits = str_for_integer_constant(c);
        fprintf(J, "{\"kind\":\"CXXBoolLiteralExpr\",\"value\":%s", strcmp(digits.as_temp_characters(), "0") == 0 ? "false" : "true");
        put_type(type);
        fputc('}', J);
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
    case ck_string:
      fputs("{\"kind\":\"StringLiteral\"", J);
      put_type(type);
      fputc('}', J);
      break;
    case ck_address: {
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
      expr(d->variant.expression);
      break;
    case dik_constructor: {
      fputs("{\"kind\":\"CXXConstructExpr\"", J);
      put_type(type);
      fputs(",\"inner\":[", J);
      expr_kids(d->variant.constructor.args);
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
      if (is_cast_kind(k)) { node_ops("ImplicitCastExpr", e, NULL, ops); return; }
      if (k == eok_cast) { node_ops("CStyleCastExpr", e, NULL, ops); return; }
      if (k == eok_question) { node_ops("ConditionalOperator", e, NULL, ops); return; }
      if (k == eok_dot_field) { field_member(e, 0); return; }
      if (k == eok_points_to_field) { field_member(e, 1); return; }
      if (k == eok_subscript) { node_ops("ArraySubscriptExpr", e, NULL, ops); return; }
      if (k == eok_call) {
        /* A direct call names its routine; the callee is wrapped in a cast, as clang's function-to-pointer decay. */
        an_expr_node_ptr callee = ops;
        an_expr_node_ptr inner = callee;
        while (inner != NULL && inner->kind == enk_operation &&
               (is_cast_kind(inner->variant.operation.kind) || inner->variant.operation.kind == eok_parens ||
                inner->variant.operation.kind == eok_address_of) &&
               inner->variant.operation.operands != NULL)
          inner = inner->variant.operation.operands;
        fputs("{\"kind\":\"CallExpr\"", J);
        put_type(e->type);
        fputs(",\"inner\":[", J);
        if (inner != NULL && inner->kind == enk_routine) {
          fputs("{\"kind\":\"ImplicitCastExpr\",\"inner\":[", J);
          put_routine_ref(inner->variant.routine.ptr, inner->type);
          fputc(']', J);
          fputc('}', J);
        } else if (callee != NULL) {
          expr(callee);
        }
        if (callee != NULL && callee->next != NULL) { fputc(',', J); expr_kids(callee->next); }
        fputs("]}", J);
        return;
      }
      if ((op = binop(k)) != NULL) { node_ops("BinaryOperator", e, op, ops); return; }
      if ((op = compound_assign(k)) != NULL) { node_ops("CompoundAssignOperator", e, op, ops); return; }
      if ((op = unop(k)) != NULL) {
        node_ops("UnaryOperator", e, op, ops);
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
      default: break;
    }
  }
}

static a_dynamic_init_ptr init_of(a_variable_ptr v)
{
  int i;
  for (i = 0; i < init_count; i++) if (init_var[i] == v) return init_val[i];
  return NULL;
}

static void var_decl(a_variable_ptr v)
{
  a_dynamic_init_ptr d = init_of(v);
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
      expr(s->expr);
      fputc(',', J);
      stmt(s->variant.if_stmt.then_statement);
      if (s->variant.if_stmt.else_statement != NULL) { fputc(',', J); stmt(s->variant.if_stmt.else_statement); }
      fputs("]}", J);
      break;
    case stmk_while:
      fputs("{\"kind\":\"WhileStmt\",\"inner\":[", J);
      expr(s->expr);
      fputc(',', J);
      stmt(s->variant.loop_statement);
      fputs("]}", J);
      break;
    case stmk_end_test_while:
      fputs("{\"kind\":\"DoStmt\",\"inner\":[", J);
      stmt(s->variant.loop_statement);
      fputc(',', J);
      expr(s->expr);
      fputs("]}", J);
      break;
    case stmk_for: {
      a_for_loop_ptr x = s->variant.for_loop.extra_info;
      fputs("{\"kind\":\"ForStmt\",\"inner\":[", J);
      if (x != NULL && x->initialization != NULL) stmt(x->initialization); else fputs("{\"kind\":\"NullStmt\"}", J);
      fputc(',', J);
      if (s->expr != NULL) expr(s->expr); else fputs("{\"kind\":\"NullStmt\"}", J);
      fputc(',', J);
      if (x != NULL && x->increment != NULL) expr(x->increment); else fputs("{\"kind\":\"NullStmt\"}", J);
      fputc(',', J);
      stmt(s->variant.for_loop.statement);
      fputs("]}", J);
      break;
    }
    case stmk_switch:
      fputs("{\"kind\":\"SwitchStmt\",\"inner\":[", J);
      expr(s->expr);
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
      fputs("{\"kind\":\"ReturnStmt\"", J);
      if (s->expr != NULL) { fputs(",\"inner\":[", J); expr(s->expr); fputc(']', J); }
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

static void put_function(a_routine_ptr rout)
{
  a_scope_ptr scope;
  a_variable_ptr param;
  const char *name = nf_name(&rout->source_corresp);
  int n = 0;
  if (name == NULL || name[0] == '\0') return;
  if (rout->function_def_number == NULL_function_def_number) return;
  scope = scope_for_routine(rout);
  if (scope == NULL || scope->assoc_block == NULL) return;
  init_count = 0;
  collect_inits(scope->assoc_block->kind == stmk_block ? scope->assoc_block->variant.block.statements : scope->assoc_block);
  decl_sep();
  fprintf(J, "{\"kind\":\"FunctionDecl\",\"id\":\"r%d\"", ast_id(rout));
  put_field_str("name", name);
  put_type(rout->type);
  if (rout->storage_class == sc_static) put_field_str("storageClass", "static");
  put_loc(&rout->source_corresp.decl_position);
  fputs(",\"inner\":[", J);
  for (param = scope->variant.routine.parameters; param != NULL; param = param->next) {
    const char *pn = param->source_corresp.name;
    sep(&n);
    fprintf(J, "{\"kind\":\"ParmVarDecl\",\"id\":\"r%d\"", ast_id(param));
    put_field_str("name", pn != NULL ? pn : "");
    put_type(param->type);
    fputc('}', J);
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
    fputc('}', J);
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
    put_loc(&var->source_corresp.decl_position);
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
