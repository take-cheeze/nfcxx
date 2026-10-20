/*
clang-c/Index.h -- the subset of libclang's C API that lib/libclang-edg implements.

The types and enumerator values are libclang's (the C API is an ABI: CXCursor is passed by value, and the enum
values are what clients compare). A client written against libclang's header compiles against this one, as long
as it only uses what is declared here. Values checked against libclang 18 by tests/libclang-edg/run.sh.
*/

#ifndef CLANG_C_INDEX_H
#define CLANG_C_INDEX_H

#ifdef __cplusplus
extern "C" {
#endif

typedef void *CXIndex;
typedef struct CXTranslationUnitImpl *CXTranslationUnit;
typedef void *CXFile;
typedef void *CXClientData;

typedef struct {
  const void *data;
  unsigned private_flags;
} CXString;

typedef struct {
  const void *ptr_data[2];
  unsigned int_data;
} CXSourceLocation;

typedef struct {
  const void *ptr_data[2];
  unsigned begin_int_data;
  unsigned end_int_data;
} CXSourceRange;

typedef struct {
  unsigned int_data[4];
  const void *ptr_data;
} CXToken;

typedef enum CXTypeKind {
  CXType_Invalid = 0
} CXTypeKind;

typedef struct {
  enum CXTypeKind kind;
  const void *data[2];
} CXType;

typedef void *CXDiagnostic;

typedef struct {
  void *Results;
  unsigned NumResults;
} CXCodeCompleteResults;

enum CXCursorKind {
  CXCursor_UnexposedDecl = 1,
  CXCursor_StructDecl = 2,
  CXCursor_UnionDecl = 3,
  CXCursor_ClassDecl = 4,
  CXCursor_EnumDecl = 5,
  CXCursor_FieldDecl = 6,
  CXCursor_EnumConstantDecl = 7,
  CXCursor_FunctionDecl = 8,
  CXCursor_VarDecl = 9,
  CXCursor_ParmDecl = 10,
  CXCursor_TypedefDecl = 20,
  CXCursor_CXXMethod = 21,
  CXCursor_Namespace = 22,
  CXCursor_ClassTemplate = 31,
  CXCursor_FunctionTemplate = 30,
  CXCursor_Constructor = 24,
  CXCursor_Destructor = 25,
  CXCursor_TranslationUnit = 350
};

typedef struct {
  enum CXCursorKind kind;
  int xdata;
  const void *data[3];
} CXCursor;

enum CXChildVisitResult {
  CXChildVisit_Break,
  CXChildVisit_Continue,
  CXChildVisit_Recurse
};

typedef enum CXChildVisitResult (*CXCursorVisitor)(CXCursor cursor, CXCursor parent, CXClientData client_data);

struct CXUnsavedFile {
  const char *Filename;
  const char *Contents;
  unsigned long Length;
};

/* The functions clang_edg.c implements, with libclang's own parameter types. */
CXIndex clang_createIndex(int excludeDeclarationsFromPCH, int displayDiagnostics);
void clang_disposeIndex(CXIndex index);

CXTranslationUnit clang_parseTranslationUnit(CXIndex CIdx, const char *source_filename,
                                             const char *const *command_line_args, int num_command_line_args,
                                             struct CXUnsavedFile *unsaved_files, unsigned num_unsaved_files,
                                             unsigned options);
void clang_disposeTranslationUnit(CXTranslationUnit);
CXCursor clang_getTranslationUnitCursor(CXTranslationUnit);

unsigned clang_visitChildren(CXCursor parent, CXCursorVisitor visitor, CXClientData client_data);

enum CXCursorKind clang_getCursorKind(CXCursor);
CXString clang_getCursorKindSpelling(enum CXCursorKind Kind);
CXString clang_getCursorSpelling(CXCursor);
CXSourceLocation clang_getCursorLocation(CXCursor);
CXCursor clang_getCursorSemanticParent(CXCursor cursor);
CXCursor clang_getCursorLexicalParent(CXCursor cursor);
CXCursor clang_getNullCursor(void);
unsigned clang_Cursor_isNull(CXCursor cursor);
unsigned clang_equalCursors(CXCursor, CXCursor);

void clang_getSpellingLocation(CXSourceLocation location, CXFile *file, unsigned *line, unsigned *column,
                               unsigned *offset);
unsigned clang_Location_isFromMainFile(CXSourceLocation location);
CXString clang_getFileName(CXFile SFile);

const char *clang_getCString(CXString string);
void clang_disposeString(CXString string);
CXString clang_getClangVersion(void);

CXSourceLocation clang_getNullLocation(void);
unsigned clang_equalLocations(CXSourceLocation, CXSourceLocation);
void clang_getInstantiationLocation(CXSourceLocation location, CXFile *file, unsigned *line, unsigned *column,
                                    unsigned *offset);
void clang_getExpansionLocation(CXSourceLocation location, CXFile *file, unsigned *line, unsigned *column,
                                unsigned *offset);
void clang_getFileLocation(CXSourceLocation location, CXFile *file, unsigned *line, unsigned *column,
                           unsigned *offset);
void clang_getPresumedLocation(CXSourceLocation location, CXString *filename, unsigned *line, unsigned *column);
unsigned clang_Location_isInSystemHeader(CXSourceLocation location);

CXSourceRange clang_getNullRange(void);
CXSourceRange clang_getCursorExtent(CXCursor);
CXSourceLocation clang_getRangeStart(CXSourceRange);
CXSourceLocation clang_getRangeEnd(CXSourceRange);
unsigned clang_equalRanges(CXSourceRange, CXSourceRange);

CXTranslationUnit clang_Cursor_getTranslationUnit(CXCursor);

unsigned clang_isDeclaration(enum CXCursorKind);
unsigned clang_isReference(enum CXCursorKind);
unsigned clang_isExpression(enum CXCursorKind);
unsigned clang_isStatement(enum CXCursorKind);
unsigned clang_isAttribute(enum CXCursorKind);
unsigned clang_isInvalid(enum CXCursorKind);
unsigned clang_isPreprocessing(enum CXCursorKind);
unsigned clang_isUnexposed(enum CXCursorKind);
unsigned clang_isTranslationUnit(enum CXCursorKind);

/* Every other function of the Python binding's table (clang.cindex): prototypes generated by
   scripts/gen-libclang-edg-api.py. The ones implemented are in clang_edg.c; the rest are stubs. */
#include "clang-c/Index_api.h"

#ifdef __cplusplus
}
#endif

#endif /* CLANG_C_INDEX_H */
