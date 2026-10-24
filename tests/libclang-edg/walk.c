/*
walk.c -- list the declarations of the main file through the libclang C API, one per line:

  KIND LINE:COL NAME in PARENT_KIND@LINE:COL

Uses only the subset in lib/libclang-edg/include/clang-c/Index.h, so it runs against libclang-edg.so and against
the system libclang with the same output. tests/libclang-edg/run.sh compares the two.
Usage: walk FILE [-std=... | -I... | -D... | -U...]...
For the front end inside libclang-edg.so, which one process calls again and again: WALK_REPEAT=N parses and walks the
file N times, and WALK_FIRST=FILE2 parses FILE2 first (its result, a failure included, is dropped).
*/

#include "clang-c/Index.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *kind_name(enum CXCursorKind k)
{
  CXString s = clang_getCursorKindSpelling(k);
  static char buf[64];
  snprintf(buf, sizeof buf, "%s", clang_getCString(s));
  clang_disposeString(s);
  return buf;
}

static int is_scope(enum CXCursorKind k)
{
  return k == CXCursor_TranslationUnit || k == CXCursor_Namespace || k == CXCursor_StructDecl ||
         k == CXCursor_ClassDecl || k == CXCursor_UnionDecl || k == CXCursor_EnumDecl ||
         k == CXCursor_ClassTemplate;
}

static int is_function(enum CXCursorKind k)
{
  return k == CXCursor_FunctionDecl || k == CXCursor_CXXMethod || k == CXCursor_Constructor ||
         k == CXCursor_Destructor || k == CXCursor_FunctionTemplate;
}

static int is_declaration(enum CXCursorKind k)
{
  return (is_scope(k) && k != CXCursor_TranslationUnit) || is_function(k) || k == CXCursor_VarDecl ||
         k == CXCursor_FieldDecl || k == CXCursor_EnumConstantDecl || k == CXCursor_TypedefDecl ||
         k == CXCursor_ParmDecl;
}

static void print_location(CXCursor c, const char *prefix)
{
  unsigned line = 0, col = 0;
  clang_getSpellingLocation(clang_getCursorLocation(c), NULL, &line, &col, NULL);
  printf("%s%u:%u", prefix, line, col);
}

static enum CXChildVisitResult visit(CXCursor c, CXCursor parent, CXClientData data);

/* The children of a scope or a function (parameters only: a function's body is not walked). */
static void walk(CXCursor parent)
{
  clang_visitChildren(parent, visit, NULL);
}

static enum CXChildVisitResult visit(CXCursor c, CXCursor parent, CXClientData data)
{
  enum CXCursorKind k = clang_getCursorKind(c);
  enum CXCursorKind pk = clang_getCursorKind(parent);
  CXString name;

  (void)data;
  if (!is_declaration(k)) return CXChildVisit_Continue;
  if (!clang_Location_isFromMainFile(clang_getCursorLocation(c))) return CXChildVisit_Continue;
  if (is_function(pk) ? k != CXCursor_ParmDecl : !is_scope(pk)) return CXChildVisit_Continue;

  name = clang_getCursorSpelling(c);
  printf("%s ", kind_name(k));
  print_location(c, "");
  printf(" %s in %s", clang_getCString(name), kind_name(pk));
  print_location(parent, "@");
  printf("\n");
  clang_disposeString(name);

  if (is_scope(k) || is_function(k)) walk(c);
  return CXChildVisit_Continue;
}

int main(int argc, char **argv)
{
  CXIndex index;
  CXTranslationUnit tu;
  const char *first = getenv("WALK_FIRST"), *repeat = getenv("WALK_REPEAT");
  int i, n = repeat != NULL ? atoi(repeat) : 1;

  if (argc < 2) {
    fprintf(stderr, "usage: walk FILE [options]\n");
    return 2;
  }
  index = clang_createIndex(0, 0);
  if (first != NULL && first[0] != '\0') {
    tu = clang_parseTranslationUnit(index, first, NULL, 0, NULL, 0, 0);
    if (tu != NULL) clang_disposeTranslationUnit(tu);
  }
  for (i = 0; i < n; i++) {
    tu = clang_parseTranslationUnit(index, argv[1], (const char *const *)(argv + 2), argc - 2, NULL, 0, 0);
    if (tu == NULL) {
      fprintf(stderr, "walk: parse failed\n");
      clang_disposeIndex(index);
      return 1;
    }
    walk(clang_getTranslationUnitCursor(tu));
    clang_disposeTranslationUnit(tu);
  }
  clang_disposeIndex(index);
  return 0;
}
