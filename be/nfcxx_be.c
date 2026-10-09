/*
nfcxx_be.c -- Path B stage 1: a back end for the EDG front end that dumps the lowered IL
as s-expressions instead of generating C. Output format: see nfcxx_be.h.

The front end calls back_end() (cfe.c) once the file-scope IL is complete and lowered. This
file replaces c_gen_be.c in cpfe (scripts/setup-pathb.sh); the macro config sets
BACK_END_IS_C_GEN_BE=0 so the C-generation specific code paths in EDG are compiled out.

Names are quoted. Unnamed entities (compiler temporaries, labels) get an id in order of first
appearance within the dump, so output is stable across runs.
*/

#include "basic_hdrs.h"
#include "fe_common.h"
#include "il.h"
#include "nfcxx_be.h"
#include "types.h"
#include "const_ints.h"
#include "float_pt.h"
#include "il_to_str.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The EDG names live in namespace edg; back_end() itself must stay global because
   cfe.c declares it at global scope. Everything else in this file is file-local. */
USING_NAMESPACE_EDG

#include "nfcxx_be_int.h"
#include "nfcxx_names.h"

FILE *nf_out;

#define NF_MAX_ANON 8192
static const void *nf_anon_key[NF_MAX_ANON];
static int nf_anon_count;

static void nf_indent(int depth)
{
  int i;
  fputc('\n', nf_out);
  for (i = 0; i < depth; i++) fputs("  ", nf_out);
}

/* Print a symbol: spaces inside integer type names become underscores so each
   type is a single s-expression atom. */
void nf_put_atom(const char *s)
{
  for (; *s != '\0'; s++) fputc(*s == ' ' ? '_' : *s, nf_out);
}

/* Print a quoted string, escaping quotes, backslashes and non-printables. */
void nf_put_quoted(const char *s, size_t len)
{
  size_t i;
  fputc('"', nf_out);
  for (i = 0; i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c == '"' || c == '\\') {
      fputc('\\', nf_out);
      fputc(c, nf_out);
    } else if (c == '\n') {
      fputs("\\n", nf_out);
    } else if (c < 32 || c > 126) {
      fprintf(nf_out, "\\%03o", (unsigned)c);
    } else {
      fputc(c, nf_out);
    }
  }
  fputc('"', nf_out);
}

/* Return a stable small id for an unnamed entity, in order of first use. */
static int nf_anon_id(const void *key)
{
  int i;
  for (i = 0; i < nf_anon_count; i++) {
    if (nf_anon_key[i] == key) return i + 1;
  }
  if (nf_anon_count < NF_MAX_ANON) {
    nf_anon_key[nf_anon_count++] = key;
    return nf_anon_count;
  }
  return 0;
}

/* Print the name of an entity: its source name if it has one, otherwise a
   stable placeholder ("tmp<N>" for variables, "label<N>" for labels). */
static void nf_put_name(a_const_char *name, const void *key, const char *what)
{
  if (name != NULL && name[0] != '\0') {
    nf_put_quoted(name, strlen(name));
  } else {
    char buf[64];
    (void)snprintf(buf, sizeof(buf), "%s%d", what, nf_anon_id(key));
    nf_put_quoted(buf, strlen(buf));
  }
}

static void nf_put_expr(an_expr_node_ptr expr);
static void nf_put_stmt(a_statement_ptr stmt, int depth);

/* ---------------------------------------------------------------- types */

void nf_put_unqualified_type(a_type_ptr type)
{
  switch (type->kind) {
    case tk_void:
      fputs("void", nf_out);
      break;
    case tk_integer:
      /* bool is an integer type in EDG (no kind of its own); is_bool_type tells it apart from char. */
      nf_put_atom(is_bool_type(type) ? "bool" : int_type_name(type));
      break;
    case tk_float:
      nf_put_atom(float_kind_name(type->variant.float_kind, /*use_C_form=*/FALSE));
      break;
    case tk_pointer:
      fputs("(ptr ", nf_out);
      nf_put_type(type->variant.pointer.type);
      fputc(')', nf_out);
      break;
    case tk_array:
      fputs("(array ", nf_out);
      if (type->variant.array.is_variable_size_array ||
          type->variant.array.is_template_dependent_size_array) {
        fputs("?", nf_out);
      } else {
        fprintf(nf_out, "%lu", (unsigned long)type->variant.array.variant.number_of_elements);
      }
      fputc(' ', nf_out);
      nf_put_type(type->variant.array.element_type);
      fputc(')', nf_out);
      break;
    case tk_routine: {
      a_param_type_ptr p;
      fputs("(fn ", nf_out);
      nf_put_type(type->variant.routine.return_type);
      fputs(" (", nf_out);
      if (type->variant.routine.extra_info != NULL) {
        for (p = type->variant.routine.extra_info->param_type_list; p != NULL; p = p->next) {
          if (p != type->variant.routine.extra_info->param_type_list) fputc(' ', nf_out);
          nf_put_type(p->type);
        }
        if (type->variant.routine.extra_info->has_ellipsis) fputs(" ...", nf_out);
      }
      fputs("))", nf_out);
      break;
    }
    case tk_class:
    case tk_struct:
    case tk_union:
      fputs(type->kind == tk_class ? "(class " : type->kind == tk_struct ? "(struct " : "(union ", nf_out);
      nf_put_name(type->source_corresp.name, type, "anon");
      fputc(')', nf_out);
      break;
    case tk_nullptr:
      fputs("nullptr_t", nf_out);
      break;
    default:
      fprintf(nf_out, "(unsupported-type %d)", (int)type->kind);
      break;
  }
}

void nf_put_type(a_type_ptr type)
{
  a_type_qualifier_set quals;
  int opened = 0;
  if (type == NULL) {
    fputs("nil-type", nf_out);
    return;
  }
  quals = get_type_qualifiers(type);
  if (quals & TQ_CONST) { fputs("(const ", nf_out); opened++; }
  if (quals & TQ_VOLATILE) { fputs("(volatile ", nf_out); opened++; }
  nf_put_unqualified_type(skip_typerefs(type));
  while (opened-- > 0) fputc(')', nf_out);
}

/* ------------------------------------------------------------ constants */

void nf_put_constant(a_constant_ptr constant)
{
  if (constant == NULL) {
    fputs("nil-const", nf_out);
    return;
  }
  switch (constant->kind) {
    case ck_integer: {
      a_number_buffer digits = str_for_integer_constant(constant);
      fputs(digits.as_temp_characters(), nf_out);
      break;
    }
    case ck_float: {
      a_boolean pos_inf = FALSE, neg_inf = FALSE, nan_val = FALSE;
      a_number_buffer text = fp_to_string(skip_typerefs(constant->type)->variant.float_kind,
                                          &constant->variant.float_value,
                                          &pos_inf, &neg_inf, &nan_val);
      fputs(text.as_temp_characters(), nf_out);
      break;
    }
    case ck_string:
      fputs("(string ", nf_out);
      nf_put_quoted(constant->variant.string.value, (size_t)constant->variant.string.length);
      fputc(')', nf_out);
      break;
    case ck_address: {
      fputs("(address ", nf_out);
      switch (constant->variant.address.kind) {
        case abk_routine:
          fputs("(routine ", nf_out);
          nf_put_name(constant->variant.address.variant.routine->source_corresp.name,
                      constant->variant.address.variant.routine, "fn");
          fputc(')', nf_out);
          break;
        case abk_variable:
          fputs("(variable ", nf_out);
          nf_put_name(constant->variant.address.variant.variable->source_corresp.name,
                      constant->variant.address.variant.variable, "tmp");
          fputc(')', nf_out);
          break;
        case abk_constant:
        case abk_temporary:
          fputs(constant->variant.address.kind == abk_constant ? "(constant " : "(temporary ", nf_out);
          nf_put_constant(constant->variant.address.variant.constant);
          fputc(')', nf_out);
          break;
        case abk_label:
          fputs("(label ", nf_out);
          nf_put_name(constant->variant.address.variant.label->source_corresp.name,
                      constant->variant.address.variant.label, "label");
          fputc(')', nf_out);
          break;
        default:
          fprintf(nf_out, "(unsupported-base %d)", (int)constant->variant.address.kind);
          break;
      }
      fprintf(nf_out, " %ld)", (long)constant->variant.address.offset);
      break;
    }
    case ck_aggregate: {
      a_constant_ptr elem;
      fputs("(aggregate", nf_out);
      for (elem = constant->variant.aggregate.first_constant; elem != NULL; elem = elem->next) {
        fputc(' ', nf_out);
        nf_put_constant(elem);
      }
      fputc(')', nf_out);
      break;
    }
    default: {
      a_const_char *name = nfcxx_ck_name(constant->kind);
      fprintf(nf_out, "(unsupported-const %s)", name != NULL ? name : "?");
      break;
    }
  }
}

/* ---------------------------------------------------------- expressions */

static void nf_put_expr_list(an_expr_node_ptr list)
{
  for (; list != NULL; list = list->next) {
    fputc(' ', nf_out);
    nf_put_expr(list);
  }
}

static void nf_put_expr(an_expr_node_ptr expr)
{
  if (expr == NULL) {
    fputs("nil", nf_out);
    return;
  }
  switch (expr->kind) {
    case enk_operation: {
      a_const_char *op = nfcxx_eok_name(expr->variant.operation.kind);
      if (op == NULL) {
        fprintf(nf_out, "(unsupported-op %d)", (int)expr->variant.operation.kind);
        return;
      }
      fprintf(nf_out, "(%s ", op);
      nf_put_type(expr->type);
      nf_put_expr_list(expr->variant.operation.operands);
      fputc(')', nf_out);
      return;
    }
    case enk_constant:
      fputs("(const ", nf_out);
      nf_put_type(expr->type);
      fputc(' ', nf_out);
      nf_put_constant(expr->variant.constant.ptr);
      fputc(')', nf_out);
      return;
    case enk_variable:
      fputs("(var ", nf_out);
      nf_put_type(expr->type);
      fputc(' ', nf_out);
      nf_put_name(expr->variant.variable.ptr->source_corresp.name,
                  expr->variant.variable.ptr, "tmp");
      fputc(')', nf_out);
      return;
    case enk_routine:
      fputs("(routine ", nf_out);
      nf_put_type(expr->type);
      fputc(' ', nf_out);
      nf_put_name(expr->variant.routine.ptr->source_corresp.name,
                  expr->variant.routine.ptr, "fn");
      fputc(')', nf_out);
      return;
    case enk_object_lifetime:
      fputs("(lifetime ", nf_out);
      nf_put_expr(expr->variant.object_lifetime.expr);
      fputc(')', nf_out);
      return;
    case enk_field:
      fputs("(field ", nf_out);
      nf_put_name(expr->variant.field.ptr->source_corresp.name,
                  expr->variant.field.ptr, "field");
      fputc(')', nf_out);
      return;
    default:
      if (nfcxx_enk_name(expr->kind) != NULL) {
        fprintf(nf_out, "(unsupported %s)", nfcxx_enk_name(expr->kind));
      } else {
        fprintf(nf_out, "(unsupported enk-%d)", (int)expr->kind);
      }
      return;
  }
}

/* ----------------------------------------------------------- statements */

static void nf_put_stmt_list(a_statement_ptr stmt, int depth)
{
  for (; stmt != NULL; stmt = stmt->next) nf_put_stmt(stmt, depth);
}

/* Print a block's own (non-static) local variables, one per line. */
static void nf_put_locals(a_scope_ptr scope, int depth)
{
  a_variable_ptr var;
  if (scope == NULL) return;
  for (var = scope->nonstatic_variables; var != NULL; var = var->next) {
    nf_indent(depth);
    fputs("(local ", nf_out);
    nf_put_name(var->source_corresp.name, var, "tmp");
    fputc(' ', nf_out);
    nf_put_type(var->type);
    fputc(')', nf_out);
  }
}

static void nf_put_stmt(a_statement_ptr stmt, int depth)
{
  nf_indent(depth);
  if (stmt == NULL) {
    fputs("(nil-stmt)", nf_out);
    return;
  }
  switch (stmt->kind) {
    case stmk_empty:
      fputs("(empty)", nf_out);
      break;
    case stmk_expr:
      fputs("(expr ", nf_out);
      nf_put_expr(stmt->expr);
      fputc(')', nf_out);
      break;
    case stmk_block:
      fputs("(block", nf_out);
      nf_put_locals(stmt->variant.block.extra_info != NULL
                      ? stmt->variant.block.extra_info->assoc_scope : NULL,
                    depth + 1);
      nf_put_stmt_list(stmt->variant.block.statements, depth + 1);
      fputc(')', nf_out);
      break;
    case stmk_if:
      fputs("(if ", nf_out);
      nf_put_expr(stmt->expr);
      nf_put_stmt(stmt->variant.if_stmt.then_statement, depth + 1);
      if (stmt->variant.if_stmt.else_statement != NULL) {
        nf_put_stmt(stmt->variant.if_stmt.else_statement, depth + 1);
      }
      fputc(')', nf_out);
      break;
    case stmk_while:
      fputs("(while ", nf_out);
      nf_put_expr(stmt->expr);
      nf_put_stmt(stmt->variant.loop_statement, depth + 1);
      fputc(')', nf_out);
      break;
    case stmk_end_test_while:
      fputs("(do-while", nf_out);
      nf_put_stmt(stmt->variant.loop_statement, depth + 1);
      nf_indent(depth + 1);
      fputs("(until ", nf_out);
      nf_put_expr(stmt->expr);
      fputc(')', nf_out);
      fputc(')', nf_out);
      break;
    case stmk_for: {
      a_for_loop_ptr extra = stmt->variant.for_loop.extra_info;
      fputs("(for", nf_out);
      if (extra != NULL && extra->initialization != NULL) {
        nf_put_stmt(extra->initialization, depth + 1);
      }
      if (stmt->expr != NULL) {
        nf_indent(depth + 1);
        fputs("(cond ", nf_out);
        nf_put_expr(stmt->expr);
        fputc(')', nf_out);
      }
      if (extra != NULL && extra->increment != NULL) {
        nf_indent(depth + 1);
        fputs("(step ", nf_out);
        nf_put_expr(extra->increment);
        fputc(')', nf_out);
      }
      nf_put_stmt(stmt->variant.for_loop.statement, depth + 1);
      fputc(')', nf_out);
      break;
    }
    case stmk_switch:
      fputs("(switch ", nf_out);
      nf_put_expr(stmt->expr);
      nf_put_stmt(stmt->variant.switch_stmt.body_statement, depth + 1);
      fputc(')', nf_out);
      break;
    case stmk_switch_case: {
      a_switch_case_entry_ptr entry = stmt->variant.switch_case.extra_info;
      if (entry != NULL && entry->case_value != NULL) {
        fputs("(case ", nf_out);
        nf_put_constant(entry->case_value);
        fputc(')', nf_out);
      } else {
        fputs("(default)", nf_out);
      }
      break;
    }
    case stmk_goto:
      fputs("(goto ", nf_out);
      nf_put_name(stmt->variant.label.ptr->source_corresp.name, stmt->variant.label.ptr, "label");
      fputc(')', nf_out);
      break;
    case stmk_label:
      fputs("(label ", nf_out);
      nf_put_name(stmt->variant.label.ptr->source_corresp.name, stmt->variant.label.ptr, "label");
      fputc(')', nf_out);
      break;
    case stmk_return:
      fputs("(return", nf_out);
      if (stmt->expr != NULL) {
        fputc(' ', nf_out);
        nf_put_expr(stmt->expr);
      }
      fputc(')', nf_out);
      break;
    case stmk_decl: {
      an_il_entity_list_entry_ptr entry;
      /* One line per declared entity; the statement itself is the point of declaration. */
      for (entry = stmt->variant.decl.entities; entry != NULL; entry = entry->next) {
        if (entry->entity.kind == iek_variable) {
          a_variable_ptr var = (a_variable_ptr)entry->entity.ptr;
          fputs("(decl ", nf_out);
          nf_put_name(var->source_corresp.name, var, "tmp");
          fputc(' ', nf_out);
          nf_put_type(var->type);
          fputc(')', nf_out);
        } else {
          fputs("(decl-other)", nf_out);
        }
        if (entry->next != NULL) nf_indent(depth);
      }
      if (stmt->variant.decl.entities == NULL) fputs("(decl-empty)", nf_out);
      break;
    }
    case stmk_init: {
      a_dynamic_init_ptr init = stmt->variant.dynamic_init;
      fputs("(init ", nf_out);
      nf_put_name(init->variable != NULL ? init->variable->source_corresp.name : NULL,
                  init->variable, "tmp");
      fprintf(nf_out, " %s", nfcxx_dik_name(init->kind) != NULL ? nfcxx_dik_name(init->kind) : "?");
      if (init->kind == dik_expression) {
        fputc(' ', nf_out);
        nf_put_expr(init->variant.expression);
      } else if (init->kind == dik_constant) {
        fputc(' ', nf_out);
        nf_put_constant(init->variant.constant.ptr);
      } else if (init->kind == dik_constructor) {
        fputs(" (ctor ", nf_out);
        nf_put_name(init->variant.constructor.ptr->source_corresp.name,
                    init->variant.constructor.ptr, "fn");
        fputc(' ', nf_out);
        nf_put_expr(init->variant.constructor.args);
        fputc(')', nf_out);
      }
      fputc(')', nf_out);
      break;
    }
    default: {
      a_const_char *name = nfcxx_stmk_name(stmt->kind);
      if (name != NULL) {
        fprintf(nf_out, "(unsupported %s)", name);
      } else {
        fprintf(nf_out, "(unsupported stmk-%d)", (int)stmt->kind);
      }
      break;
    }
  }
}

/* ------------------------------------------------------ routines, scope */

static void nf_put_routine(a_routine_ptr rout)
{
  a_scope_ptr scope;
  a_variable_ptr param;
  a_type_ptr fn_type;

  if (ignore_routine_in_back_end(rout)) return;
  if (rout->function_def_number == NULL_function_def_number) return;
  /* Same rule as the C generator (dump_routine_decl): only bodies the front end marked as needed are
     output; a body kept only for inlining (suppress_inline_body) is not. */
#if MAINTAIN_NEEDED_FLAGS
  if (!rout->definition_needed) return;
#endif /* MAINTAIN_NEEDED_FLAGS */
  if (rout->suppress_inline_body) return;
  scope = scope_for_routine(rout);
  if (scope == NULL || scope->assoc_block == NULL) return;

  fn_type = skip_typerefs(rout->type);
  fputs("\n(function ", nf_out);
  nf_put_name(rout->source_corresp.name, rout, "fn");
  fputs("\n  (returns ", nf_out);
  nf_put_type(fn_type->variant.routine.return_type);
  fputs(")\n  (params", nf_out);
  for (param = scope->variant.routine.parameters; param != NULL; param = param->next) {
    fputs(" (param ", nf_out);
    nf_put_name(param->source_corresp.name, param, "tmp");
    fputc(' ', nf_out);
    nf_put_type(param->type);
    fputc(')', nf_out);
  }
  if (fn_type->variant.routine.extra_info != NULL &&
      fn_type->variant.routine.extra_info->has_ellipsis) {
    fputs(" (ellipsis)", nf_out);
  }
  fputc(')', nf_out);
  if (rout->storage_class == sc_static) fputs("\n  (static)", nf_out);
  if (scope->assoc_block->kind == stmk_block) {
    nf_indent(1);
    fputs("(block", nf_out);
    nf_put_locals(scope, 2);
    nf_put_stmt_list(scope->assoc_block->variant.block.statements, 2);
    fputc(')', nf_out);
  } else {
    nf_put_stmt(scope->assoc_block, 1);
  }
  fputs(")\n", nf_out);
}

static void nf_put_globals(a_scope_ptr scope)
{
  a_variable_ptr var;
  for (var = scope->variables; var != NULL; var = var->next) {
    if (ignore_variable_in_back_end(var)) continue;
    fputs("(global ", nf_out);
    nf_put_name(var->source_corresp.name, var, "tmp");
    fputc(' ', nf_out);
    nf_put_type(var->type);
    fputs(")\n", nf_out);
  }
}

/* Entry point called by the front end (cfe.c) after lowering. */
void back_end(void)
{
  a_scope_ptr scope = il_header.primary_scope;
  const char *mode = getenv("NFCXX_PATHB_MODE");
  a_routine_ptr rout;
  const char *file_name = il_header.primary_source_file->file_name;
  const char *slash = strrchr(file_name, '/');

  if (mode != NULL && strcmp(mode, "ir") == 0) {
    nfcxx_ir_back_end();   /* mid-level IR (nfcxx_ir.c) instead of the IL dump */
    return;
  }
  nf_out = stdout;
  nf_anon_count = 0;
  fprintf(nf_out, "(translation-unit \"%s\")\n", slash != NULL ? slash + 1 : file_name);
  nf_put_globals(scope);
  for (rout = scope->routines; rout != NULL; rout = rout->next) {
    nf_put_routine(rout);
  }
  fflush(nf_out);
}
