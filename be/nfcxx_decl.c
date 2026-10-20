/*
nfcxx_decl.c -- libclang-edg: a back end for the EDG front end that lists the declarations of the
primary source file as tab-separated records, for the libclang shim (lib/libclang-edg).

The front end calls back_end() (cfe.c) once the file-scope IL is complete. This file replaces the C++-generating
back end's back_end() in cpfe (scripts/setup-libclang-edg.sh). That configuration keeps the source sequence and the
class member-declaration lists this file reads, and has no IL lowering.

One record per declaration:

  KIND <TAB> ID <TAB> PARENT <TAB> LINE <TAB> COLUMN <TAB> NAME

PARENT is 0 for a declaration at file scope. KIND is one of: namespace, struct, class, union, enum,
enumerator, typedef, function, method, constructor, destructor, var, field, param, function_template,
class_template. Only declarations whose position is in the primary source file are listed; declarations from
headers and compiler-generated entities are not. A declaration without a name is not listed. Template
instances (a function or class made from a template) are not listed: EDG gives them the template's position.
A template pattern is listed as function_template or class_template.

Members of a class come from the class's member-declaration list (EDG records it in declaration order),
not from the scope lists: EDG also lists a member routine at file scope, with the file scope as its
parent. A declaration is listed once, however many lists name it.

Limitations (docs/notes/libclang-edg.md): a function declaration without a body has no parameter names in
the IL (EDG keeps them only in rare cases), so it lists no param records. The tables below hold NF_MAX_ENTITIES
declarations; past that a declaration is printed again if a list names it twice.
*/

#include "basic_hdrs.h"
#include "fe_common.h"
#include "il.h"
#include "types.h"
#include "const_ints.h"

#include <stdio.h>
#include <string.h>

USING_NAMESPACE_EDG

#define NF_MAX_ENTITIES 65536

static int nf_next_id;
static int nf_count;
static a_source_correspondence *nf_corr[NF_MAX_ENTITIES];  /* listed entity ... */
static int nf_corr_id[NF_MAX_ENTITIES];                    /* ... and its record id */

/* Is the position in the primary source file? Sets *line to its line. */
static a_boolean nf_locate(a_source_position *pos, a_line_number *line)
{
  a_const_char *file_name, *full_name;
  a_boolean at_end;
  a_source_file_ptr sfp;

  if (pos->seq == 0) return FALSE;
  sfp = conv_seq_to_file_and_line(pos->seq, &file_name, &full_name, line, &at_end);
  return sfp == il_header.primary_source_file;
}

/* The source spelling of an entity. EDG keeps the mangled name in source_corresp.name for some entities;
   the source name is then in unmangled_name_or_mangled_encoding. */
static const char *nf_name(a_source_correspondence *corr)
{
  if (corr->name_has_been_mangled && corr->unmangled_name_or_mangled_encoding != NULL) {
    return corr->unmangled_name_or_mangled_encoding;
  }
  return corr->name;
}

/* The record id of an entity already listed, or 0. */
static int nf_listed(a_source_correspondence *corr)
{
  int i;
  for (i = 0; i < nf_count; i++) {
    if (nf_corr[i] == corr) return nf_corr_id[i];
  }
  return 0;
}

/* Emit one record and return its id. Returns 0 when the entity is unnamed or not in the primary file, and
   the existing id (without a new record) when it was listed already. */
static int nf_emit(const char *kind, int parent, a_source_correspondence *corr)
{
  a_line_number line = 0;
  int id;
  const char *name;

  id = nf_listed(corr);
  if (id != 0) return id;
  name = nf_name(corr);
  if (name == NULL || name[0] == '\0') return 0;
  if (!nf_locate(&corr->decl_position, &line)) return 0;
  id = ++nf_next_id;
  if (nf_count < NF_MAX_ENTITIES) {
    nf_corr[nf_count] = corr;
    nf_corr_id[nf_count] = id;
    nf_count++;
  }
  printf("%s\t%d\t%d\t%d\t%d\t%s\n", kind, id, parent, (int)line, (int)corr->decl_position.column, name);
  return id;
}

static void nf_emit_type(a_type_ptr type, int parent);

static void nf_emit_params(a_scope_ptr scope, int parent)
{
  a_variable_ptr param;
  if (scope == NULL) return;
  for (param = scope->variant.routine.parameters; param != NULL; param = param->next) {
    nf_emit("param", parent, &param->source_corresp);
  }
}

/* The scope that holds a routine's parameters: its definition's, else its prototype's (usually none). */
static a_scope_ptr rout_scope_or_proto(a_routine_ptr rout)
{
  a_scope_ptr scope = rout->function_def_number != NULL_function_def_number ? scope_for_routine_or_null(rout) : NULL;
  a_type_ptr fn_type;
  if (scope == NULL) {
    fn_type = skip_typerefs(rout->type);
    if (fn_type->variant.routine.extra_info != NULL) scope = fn_type->variant.routine.extra_info->prototype_scope;
  }
  return scope;
}

/* True for a routine that is not a member of a class (its type has no this_class). */
static int fn_type_has_no_class(a_routine_ptr rout)
{
  a_type_ptr fn_type = skip_typerefs(rout->type);
  return fn_type->variant.routine.extra_info == NULL || fn_type->variant.routine.extra_info->this_class == NULL;
}

/* A routine declared in a class (owner is the class type) or outside one. A routine defined outside its class
   (the file scope lists it) is a member too: its type says which class (this_class; NULL for a static one). */
static void nf_emit_routine(a_routine_ptr rout, int parent, a_type_ptr owner)
{
  const char *kind = "function";
  const char *name;
  a_scope_ptr scope;
  a_type_ptr fn_type;
  int id;

  if (rout->compiler_generated) return;
  if (nf_listed(&rout->source_corresp) != 0) return;
  /* A template function: the prototype instantiation is the pattern; any other (not explicitly specialized) one is
     an instance. */
  if (rout->is_template_function && !rout->is_specialized && !rout->is_prototype_instantiation) return;
  /* A member of a class template pattern is a method of the class_template, as in libclang. */
  if (rout->is_template_function && rout->is_prototype_instantiation && owner == NULL &&
      !rout->source_corresp.is_class_member && fn_type_has_no_class(rout)) {
    id = nf_emit("function_template", parent, &rout->source_corresp);
    if (id != 0) nf_emit_params(rout_scope_or_proto(rout), id);
    return;
  }
  fn_type = skip_typerefs(rout->type);
  if (owner == NULL && fn_type->variant.routine.extra_info != NULL &&
      fn_type->variant.routine.extra_info->this_class != NULL) {
    owner = fn_type->variant.routine.extra_info->this_class;
    parent = nf_listed(&owner->source_corresp);
  }
  if (owner != NULL) {
    kind = "method";
    name = nf_name(&rout->source_corresp);
    if (name != NULL && name[0] == '~') {
      kind = "destructor";
    } else if (name != NULL && strcmp(name, nf_name(&owner->source_corresp)) == 0) {
      kind = "constructor";
    }
  }
  id = nf_emit(kind, parent, &rout->source_corresp);
  if (id == 0) return;
  nf_emit_params(rout_scope_or_proto(rout), id);
}

/* A class or enumeration (or a typedef) declared with parent. */
static void nf_emit_type(a_type_ptr type, int parent)
{
  int id;
  a_constant_ptr con;
  a_field_ptr field;
  an_il_entity_list_entry_ptr entry;
  const char *kind;

  if (type->kind == tk_typeref) {
    nf_emit("typedef", parent, &type->source_corresp);
    return;
  }
  if (is_enum_type(type)) {
    id = nf_emit("enum", parent, &type->source_corresp);
    if (id == 0) return;
    for (con = enum_constants(type); con != NULL; con = con->next) {
      nf_emit("enumerator", id, &con->source_corresp);
    }
    return;
  }
  if (type->kind != tk_class && type->kind != tk_struct && type->kind != tk_union) return;
  /* A class template instance (or a class nested in one) is not listed; the pattern is a class_template. */
  if (type->variant.class_struct_union.is_template_class &&
      !type->variant.class_struct_union.is_prototype_instantiation) {
    return;
  }
  kind = type->kind == tk_class ? "class" : type->kind == tk_struct ? "struct" : "union";
  if (type->variant.class_struct_union.is_prototype_instantiation) kind = "class_template";
  id = nf_emit(kind, parent, &type->source_corresp);
  if (id == 0) return;
  for (entry = class_type_supp(type)->member_declarations; entry != NULL; entry = entry->next) {
    switch (entry->entity.kind) {
      case iek_field:
        field = (a_field_ptr)entry->entity.ptr;
        nf_emit("field", id, &field->source_corresp);
        break;
      case iek_routine:
        nf_emit_routine((a_routine_ptr)entry->entity.ptr, id, type);
        break;
      case iek_variable:
        nf_emit("var", id, &((a_variable_ptr)entry->entity.ptr)->source_corresp);
        break;
      case iek_type:
        nf_emit_type((a_type_ptr)entry->entity.ptr, id);
        break;
      default:
        break;
    }
  }
}

/* List the entities declared in one scope, whose record id is parent (0 at file scope). */
static void nf_emit_scope(a_scope_ptr scope, int parent)
{
  a_namespace_ptr ns;
  a_type_ptr type;
  a_routine_ptr rout;
  a_variable_ptr var;
  int id;

  for (ns = scope->namespaces; ns != NULL; ns = ns->next) {
    if (ns->is_namespace_alias) continue;
    id = nf_emit("namespace", parent, &ns->source_corresp);
    if (id != 0 && ns->variant.assoc_scope != NULL) nf_emit_scope(ns->variant.assoc_scope, id);
  }
  for (type = scope->types; type != NULL; type = type->next) {
    nf_emit_type(type, parent);
  }
  for (var = scope->variables; var != NULL; var = var->next) {
    if (var->compiler_generated) continue;
    nf_emit("var", parent, &var->source_corresp);
  }
  for (rout = scope->routines; rout != NULL; rout = rout->next) {
    nf_emit_routine(rout, parent, NULL);
  }
}

namespace edg {

/* Entry point called by the front end (cfe.c, in namespace edg) after the IL is complete. */
void back_end(void)
{
  nf_next_id = 0;
  nf_count = 0;
  nf_emit_scope(il_header.primary_scope, 0);
  fflush(stdout);
}

}  /* namespace edg */
