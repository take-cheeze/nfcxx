/*
mrb_libclang_edg.c -- mruby classes over libclang-edg's C API (lib/libclang-edg, docs/notes/libclang-edg.md).

  LibclangEdg::Index.new
  index.parse(path, *args)        -> LibclangEdg::TranslationUnit (raises LibclangEdg::ParseError on failure)
  tu.cursor                       -> LibclangEdg::Cursor of the translation unit
  tu.spelling                     -> the main file's name
  cursor.kind                     -> the kind's spelling ("FunctionDecl", "StructDecl", ...)
  cursor.spelling                 -> the name
  cursor.line, cursor.column      -> the position of the declaration
  cursor.children                 -> an Array of the children (the walk of walk.c, one level)
  cursor.main_file?               -> true for a declaration in the main file
  cursor.semantic_parent          -> the enclosing declaration, or the translation unit's cursor
  cursor == other                 -> libclang's clang_equalCursors

A Cursor keeps its translation unit alive. Objects are freed by the garbage collector (dfree).
*/

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include <stdlib.h>
#include <string.h>

#include "clang-c/Index.h"

static struct RClass *lce_module(mrb_state *mrb)
{
  return mrb_module_get(mrb, "LibclangEdg");
}

/* A class of the LibclangEdg module (a constant of it; mrb_class_get would only look at top-level classes). */
static struct RClass *lce_class(mrb_state *mrb, const char *name)
{
  mrb_value v = mrb_const_get(mrb, mrb_obj_value(lce_module(mrb)), mrb_intern_cstr(mrb, name));
  return mrb_class_ptr(v);
}

static void index_free(mrb_state *mrb, void *p)
{
  (void)mrb;
  if (p != NULL) clang_disposeIndex((CXIndex)p);
}

static void tu_free(mrb_state *mrb, void *p)
{
  (void)mrb;
  if (p != NULL) clang_disposeTranslationUnit((CXTranslationUnit)p);
}

static void cursor_free(mrb_state *mrb, void *p)
{
  (void)mrb;
  free(p);
}

static const mrb_data_type index_type = {"LibclangEdg::Index", index_free};
static const mrb_data_type tu_type = {"LibclangEdg::TranslationUnit", tu_free};
static const mrb_data_type cursor_type = {"LibclangEdg::Cursor", cursor_free};

/* A Cursor object for c. tu is the translation unit object it belongs to; the cursor keeps it alive. */
static mrb_value new_cursor(mrb_state *mrb, mrb_value tu, CXCursor c)
{
  CXCursor *p = malloc(sizeof *p);
  struct RData *data;
  mrb_value v;

  if (p == NULL) mrb_raise(mrb, mrb->eStandardError_class, "libclang-edg: out of memory");
  *p = c;
  data = mrb_data_object_alloc(mrb, lce_class(mrb, "Cursor"), p, &cursor_type);
  v = mrb_obj_value(data);
  mrb_iv_set(mrb, v, mrb_intern_lit(mrb, "@tu"), tu);
  return v;
}

static CXCursor *cursor_ptr(mrb_state *mrb, mrb_value self)
{
  return (CXCursor *)mrb_data_check_get_ptr(mrb, self, &cursor_type);
}

static CXTranslationUnit tu_ptr(mrb_state *mrb, mrb_value self)
{
  return (CXTranslationUnit)mrb_data_check_get_ptr(mrb, self, &tu_type);
}

/* Index#initialize: creates the libclang index. */
static mrb_value index_initialize(mrb_state *mrb, mrb_value self)
{
  CXIndex index = clang_createIndex(0, 0);
  if (index == NULL) mrb_raise(mrb, mrb->eStandardError_class, "libclang-edg: clang_createIndex failed");
  DATA_TYPE(self) = &index_type;
  DATA_PTR(self) = index;
  return self;
}

/* Index#parse(path, *args) */
static mrb_value index_parse(mrb_state *mrb, mrb_value self)
{
  mrb_value *argv;
  mrb_int argc, i;
  char *path;
  const char **args;
  CXIndex index = (CXIndex)mrb_data_check_get_ptr(mrb, self, &index_type);
  CXTranslationUnit tu;
  mrb_value tu_obj;

  mrb_get_args(mrb, "z*", &path, &argv, &argc);
  args = calloc((size_t)argc + 1, sizeof *args);
  if (args == NULL) mrb_raise(mrb, mrb->eStandardError_class, "libclang-edg: out of memory");
  for (i = 0; i < argc; i++) {
    args[i] = mrb_string_cstr(mrb, argv[i]);
  }
  tu = clang_parseTranslationUnit(index, path, args, (int)argc, NULL, 0, 0);
  free((void *)args);
  if (tu == NULL) {
    mrb_raisef(mrb, lce_class(mrb, "ParseError"), "libclang-edg: could not parse %S", mrb_str_new_cstr(mrb, path));
  }
  tu_obj = mrb_obj_value(mrb_data_object_alloc(mrb, lce_class(mrb, "TranslationUnit"), tu, &tu_type));
  return tu_obj;
}

static mrb_value tu_cursor(mrb_state *mrb, mrb_value self)
{
  CXTranslationUnit tu = tu_ptr(mrb, self);
  if (tu == NULL) mrb_raise(mrb, mrb->eStandardError_class, "libclang-edg: translation unit is closed");
  return new_cursor(mrb, self, clang_getTranslationUnitCursor(tu));
}

static mrb_value tu_spelling(mrb_state *mrb, mrb_value self)
{
  CXTranslationUnit tu = tu_ptr(mrb, self);
  CXString s;
  mrb_value r;
  if (tu == NULL) mrb_raise(mrb, mrb->eStandardError_class, "libclang-edg: translation unit is closed");
  s = clang_getCursorSpelling(clang_getTranslationUnitCursor(tu));
  r = mrb_str_new_cstr(mrb, clang_getCString(s));
  clang_disposeString(s);
  return r;
}

static mrb_value cursor_kind(mrb_state *mrb, mrb_value self)
{
  CXString s = clang_getCursorKindSpelling(clang_getCursorKind(*cursor_ptr(mrb, self)));
  mrb_value r = mrb_str_new_cstr(mrb, clang_getCString(s));
  clang_disposeString(s);
  return r;
}

static mrb_value cursor_spelling(mrb_state *mrb, mrb_value self)
{
  CXString s = clang_getCursorSpelling(*cursor_ptr(mrb, self));
  mrb_value r = mrb_str_new_cstr(mrb, clang_getCString(s));
  clang_disposeString(s);
  return r;
}

/* The line or the column of the cursor's location. */
static mrb_value cursor_position(mrb_state *mrb, mrb_value self, int column)
{
  unsigned line = 0, col = 0;
  clang_getSpellingLocation(clang_getCursorLocation(*cursor_ptr(mrb, self)), NULL, &line, &col, NULL);
  return mrb_fixnum_value((mrb_int)(column ? col : line));
}

static mrb_value cursor_line(mrb_state *mrb, mrb_value self)
{
  return cursor_position(mrb, self, 0);
}

static mrb_value cursor_column(mrb_state *mrb, mrb_value self)
{
  return cursor_position(mrb, self, 1);
}

typedef struct {
  mrb_state *mrb;
  mrb_value tu;
  mrb_value ary;
} children_ctx;

static enum CXChildVisitResult collect_child(CXCursor c, CXCursor parent, CXClientData data)
{
  children_ctx *ctx = (children_ctx *)data;
  (void)parent;
  mrb_ary_push(ctx->mrb, ctx->ary, new_cursor(ctx->mrb, ctx->tu, c));
  return CXChildVisit_Continue;
}

static mrb_value cursor_children(mrb_state *mrb, mrb_value self)
{
  children_ctx ctx;
  ctx.mrb = mrb;
  ctx.tu = mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@tu"));
  ctx.ary = mrb_ary_new(mrb);
  mrb_gc_protect(mrb, ctx.ary);
  clang_visitChildren(*cursor_ptr(mrb, self), collect_child, &ctx);
  return ctx.ary;
}

/* true for a declaration of the main file (the file the translation unit was parsed from). */
static mrb_value cursor_main_file(mrb_state *mrb, mrb_value self)
{
  CXSourceLocation loc = clang_getCursorLocation(*cursor_ptr(mrb, self));
  return mrb_bool_value(clang_Location_isFromMainFile(loc));
}

static mrb_value cursor_semantic_parent(mrb_state *mrb, mrb_value self)
{
  mrb_value tu = mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@tu"));
  return new_cursor(mrb, tu, clang_getCursorSemanticParent(*cursor_ptr(mrb, self)));
}

static mrb_value cursor_equal(mrb_state *mrb, mrb_value self)
{
  mrb_value other;
  CXCursor *o;
  mrb_get_args(mrb, "o", &other);
  if (!mrb_obj_is_kind_of(mrb, other, lce_class(mrb, "Cursor"))) return mrb_false_value();
  o = cursor_ptr(mrb, other);
  return mrb_bool_value(clang_equalCursors(*cursor_ptr(mrb, self), *o));
}

void mrb_mruby_libclang_edg_gem_init(mrb_state *mrb)
{
  struct RClass *mod = mrb_define_module(mrb, "LibclangEdg");
  struct RClass *index, *tu, *cursor;

  mrb_define_class_under(mrb, mod, "ParseError", mrb->eStandardError_class);
  index = mrb_define_class_under(mrb, mod, "Index", mrb->object_class);
  MRB_SET_INSTANCE_TT(index, MRB_TT_DATA);
  mrb_define_method(mrb, index, "initialize", index_initialize, MRB_ARGS_NONE());
  mrb_define_method(mrb, index, "parse", index_parse, MRB_ARGS_REQ(1) | MRB_ARGS_REST());

  tu = mrb_define_class_under(mrb, mod, "TranslationUnit", mrb->object_class);
  MRB_SET_INSTANCE_TT(tu, MRB_TT_DATA);
  mrb_define_method(mrb, tu, "cursor", tu_cursor, MRB_ARGS_NONE());
  mrb_define_method(mrb, tu, "spelling", tu_spelling, MRB_ARGS_NONE());

  cursor = mrb_define_class_under(mrb, mod, "Cursor", mrb->object_class);
  MRB_SET_INSTANCE_TT(cursor, MRB_TT_DATA);
  mrb_define_method(mrb, cursor, "kind", cursor_kind, MRB_ARGS_NONE());
  mrb_define_method(mrb, cursor, "spelling", cursor_spelling, MRB_ARGS_NONE());
  mrb_define_method(mrb, cursor, "line", cursor_line, MRB_ARGS_NONE());
  mrb_define_method(mrb, cursor, "column", cursor_column, MRB_ARGS_NONE());
  mrb_define_method(mrb, cursor, "children", cursor_children, MRB_ARGS_NONE());
  mrb_define_method(mrb, cursor, "main_file?", cursor_main_file, MRB_ARGS_NONE());
  mrb_define_method(mrb, cursor, "semantic_parent", cursor_semantic_parent, MRB_ARGS_NONE());
  mrb_define_method(mrb, cursor, "==", cursor_equal, MRB_ARGS_REQ(1));
}

void mrb_mruby_libclang_edg_gem_final(mrb_state *mrb)
{
  (void)mrb;
}
