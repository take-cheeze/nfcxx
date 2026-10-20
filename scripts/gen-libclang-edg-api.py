#!/usr/bin/env python3
"""libclang-edg: generate the rest of libclang's C API from the Python binding's function table.

The Python binding (clang.cindex, the package on PyPI) registers every function it uses with a signature in
`functionList`. A libclang shared object without one of those symbols makes `import clang.cindex` fail, so
libclang-edg exports all of them. This script writes:

  lib/libclang-edg/include/clang-c/Index_api.h   the prototype of every function in the table (C types)
  lib/libclang-edg/generated/stubs.c            a stub for every function that clang_edg.c does not implement;
                                                a stub notes once on stderr that it is not implemented and
                                                returns a zero value of its return type

The functions clang_edg.c implements are IMPLEMENTED below; the script checks that each one is defined there, and
that every other function is generated. The struct layouts the table uses are checked against the binding's ctypes
classes (_Static_assert in Index_api.h), so a layout drift shows up at compile time.

Usage: LIBCLANG_EDG_PYTHON=DIR scripts/gen-libclang-edg-api.py   (DIR holds the clang/ package; default: installed)
"""

import ctypes
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "lib", "libclang-edg")

if os.environ.get("LIBCLANG_EDG_PYTHON"):
    sys.path.insert(0, os.environ["LIBCLANG_EDG_PYTHON"])
import clang.cindex as ci  # noqa: E402

# Functions clang_edg.c implements (it must define each one; the script checks).
IMPLEMENTED = {
    "clang_createIndex", "clang_disposeIndex", "clang_parseTranslationUnit", "clang_disposeTranslationUnit",
    "clang_getTranslationUnitCursor", "clang_visitChildren", "clang_getCursorKind", "clang_getCursorKindSpelling",
    "clang_getCursorSpelling", "clang_getCursorLocation", "clang_getCursorSemanticParent",
    "clang_getCursorLexicalParent", "clang_getNullCursor", "clang_Cursor_isNull", "clang_equalCursors",
    "clang_getSpellingLocation", "clang_Location_isFromMainFile", "clang_getFileName", "clang_getCString",
    "clang_disposeString", "clang_getClangVersion", "clang_getNullLocation", "clang_equalLocations",
    "clang_getInstantiationLocation", "clang_getExpansionLocation", "clang_getFileLocation",
    "clang_getPresumedLocation", "clang_Location_isInSystemHeader", "clang_getNullRange", "clang_getCursorExtent",
    "clang_getRangeStart", "clang_getRangeEnd", "clang_equalRanges", "clang_Cursor_getTranslationUnit",
    "clang_isDeclaration", "clang_isReference", "clang_isExpression", "clang_isStatement", "clang_isAttribute",
    "clang_isInvalid", "clang_isPreprocessing", "clang_isUnexposed", "clang_isTranslationUnit",
}

# Python binding type name -> C type. Pointers (LP_X, POINTER(X)) are derived from these.
C_TYPE = {
    "c_uint": "unsigned int", "c_int": "int", "c_long": "long", "c_ulong": "unsigned long",
    "c_longlong": "long long", "c_ulonglong": "unsigned long long", "c_double": "double", "c_float": "float",
    "c_size_t": "size_t", "c_ubyte": "unsigned char", "c_char": "char", "c_void_p": "void *",
    "c_char_p": "const char *", "c_interop_string": "const char *", "bool": "unsigned int",
    "py_object": "void *", "CFunctionType": "void *", "from_id": "int", "CursorKind": "enum CXCursorKind",
    "TemplateArgumentKind": "int", "Cursor": "CXCursor", "Type": "CXType", "SourceLocation": "CXSourceLocation",
    "SourceRange": "CXSourceRange", "_CXString": "CXString", "Token": "CXToken",
    "TranslationUnit": "CXTranslationUnit", "File": "CXFile", "Index": "CXIndex", "Diagnostic": "CXDiagnostic",
    "CodeCompletionResults": "CXCodeCompleteResults", "CCRStructure": "CXCodeCompleteResults",
}

# The binding's ctypes classes whose layout the C structs must match: name -> (C struct, size in bytes).
LAYOUTS = {
    "Cursor": "CXCursor", "Type": "CXType", "SourceLocation": "CXSourceLocation", "SourceRange": "CXSourceRange",
    "_CXString": "CXString", "Token": "CXToken", "CCRStructure": "CXCodeCompleteResults",
}


def c_type(t, is_return=False):
    """The C spelling of a ctypes/binding type used in the table. A return of POINTER(c_void_p) is an opaque handle
    (the binding's CXIndex), so it is spelled void *, not void **."""
    if isinstance(t, type) and issubclass(t, ctypes._Pointer):
        if is_return and t._type_ is ctypes.c_void_p:
            return "void *"
        base = c_type(t._type_)
        return base + " *" if not base.endswith("*") else base + "*"
    name = getattr(t, "__name__", None)
    if name in C_TYPE:
        return C_TYPE[name]
    raise SystemExit("gen-libclang-edg-api: no C type for %r" % (t,))


def zero_return(ret):
    """The statement that returns a zero value of the C return type ret."""
    if ret == "void":
        return ""
    if ret.endswith("*") or ret in ("CXFile", "CXIndex", "CXDiagnostic", "CXTranslationUnit"):
        return "  return NULL;\n"
    if ret in ("unsigned int", "int", "long", "unsigned long", "long long", "unsigned long long", "size_t",
               "unsigned char", "char", "double", "float") or ret.startswith("enum "):
        return "  return 0;\n"
    return "  %s r;\n  memset(&r, 0, sizeof r);\n  return r;\n" % ret


def main():
    table = ci.functionList
    names = [item[0] for item in table]
    if len(set(names)) != len(names):
        raise SystemExit("gen-libclang-edg-api: duplicate names in the table")

    impl_src = open(os.path.join(LIB, "clang_edg.c")).read()
    for name in sorted(IMPLEMENTED):
        if not re.search(r"^[^\s(].*\b%s\(" % re.escape(name), impl_src, re.M):
            raise SystemExit("gen-libclang-edg-api: %s is listed as implemented but clang_edg.c does not define it" % name)

    protos = []
    stubs = []
    for item in table:
        name = item[0]
        args = list(item[1] or [])
        ret = item[2] if len(item) >= 3 and item[2] is not None else None
        ret_c = "void" if ret is None else c_type(ret, is_return=True)
        arg_c = [c_type(a) for a in args]
        params = ", ".join(arg_c) if arg_c else "void"
        if name in IMPLEMENTED:
            continue   # its prototype is hand-written in clang-c/Index.h, with libclang's own types
        protos.append("%s %s(%s);" % (ret_c, name, params))
        pdecl = ", ".join("%s a%d" % (t, i) for i, t in enumerate(arg_c)) if arg_c else "void"
        body = ["  static int warned;", "  if (!warned) { warned = 1; nfc_not_implemented(\"%s\"); }" % name]
        body += ["  (void)a%d;" % i for i in range(len(arg_c))]
        stubs.append("%s %s(%s)\n{\n%s\n%s}\n" % (ret_c, name, pdecl, "\n".join(body) + "\n", zero_return(ret_c)))

    # Layout checks: the binding's ctypes sizes must equal the C structs' (Index.h defines them).
    asserts = []
    for py, c in sorted(LAYOUTS.items()):
        cls = getattr(ci, py)
        asserts.append("_Static_assert(sizeof(%s) == %d, \"%s: layout differs from clang.cindex's %s\");"
                       % (c, ctypes.sizeof(cls), c, py))

    os.makedirs(os.path.join(LIB, "generated"), exist_ok=True)
    with open(os.path.join(LIB, "include", "clang-c", "Index_api.h"), "w") as f:
        f.write("/* GENERATED by scripts/gen-libclang-edg-api.py from clang.cindex's function table. Do not edit. */\n")
        f.write("#ifndef CLANG_C_INDEX_API_H\n#define CLANG_C_INDEX_API_H\n\n")
        f.write("#include <stddef.h>\n\n")
        f.write("\n".join(asserts) + "\n\n")
        f.write("\n".join(protos) + "\n\n#endif /* CLANG_C_INDEX_API_H */\n")
    with open(os.path.join(LIB, "generated", "stubs.c"), "w") as f:
        f.write("/* GENERATED by scripts/gen-libclang-edg-api.py. Do not edit. Functions not implemented yet. */\n")
        f.write("#include \"clang-c/Index.h\"\n\n#include <stdio.h>\n#include <string.h>\n\n")
        f.write("static void nfc_not_implemented(const char *name)\n{\n")
        f.write("  fprintf(stderr, \"libclang-edg: %s is not implemented yet\\n\", name);\n}\n\n")
        f.write("\n".join(stubs))
    implemented = sum(1 for n in names if n in IMPLEMENTED)
    print("gen-libclang-edg-api: %d functions (%d implemented, %d stubbed)" % (len(table), implemented, len(stubs)))


if __name__ == "__main__":
    main()
