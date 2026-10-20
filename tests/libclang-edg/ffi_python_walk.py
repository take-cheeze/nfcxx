#!/usr/bin/env python3
"""libclang-edg: the walk of walk.c through the generated ctypes binding (lib/libclang-edg/bindings/python), so the
C ABI is exercised from another language. Usage: ffi_python_walk.py LIBRARY FILE [-std=... | -I... | -D... | -U...]...

The output is walk.c's format; tests/libclang-edg/run.sh compares it with walk-edg exactly.
"""

import ctypes
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib", "libclang-edg", "bindings", "python"))
import libclang_edg as L  # noqa: E402

SCOPE = {L.CXCursor_TranslationUnit, L.CXCursor_Namespace, L.CXCursor_StructDecl, L.CXCursor_ClassDecl,
         L.CXCursor_UnionDecl, L.CXCursor_EnumDecl, L.CXCursor_ClassTemplate}
FUNCTION = {L.CXCursor_FunctionDecl, L.CXCursor_CXXMethod, L.CXCursor_Constructor, L.CXCursor_Destructor,
            L.CXCursor_FunctionTemplate}
DECL = {L.CXCursor_VarDecl, L.CXCursor_FieldDecl, L.CXCursor_EnumConstantDecl, L.CXCursor_TypedefDecl,
        L.CXCursor_ParmDecl}


def main():
    lib = L.load(sys.argv[1])
    path = sys.argv[2]
    args = sys.argv[3:]
    index = lib.clang_createIndex(0, 0)
    argv = (ctypes.c_char_p * len(args))(*[a.encode() for a in args]) if args else None
    tu = lib.clang_parseTranslationUnit(index, path.encode(), argv, len(args), None, 0, 0)
    if not tu:
        print("walk: parse failed", file=sys.stderr)
        return 1

    def kind_name(kind):
        s = lib.clang_getCursorKindSpelling(kind)
        name = lib.clang_getCString(s).decode()
        lib.clang_disposeString(s)
        return name

    def location(cursor):
        line, col = ctypes.c_uint(0), ctypes.c_uint(0)
        lib.clang_getSpellingLocation(lib.clang_getCursorLocation(cursor), None, ctypes.byref(line),
                                      ctypes.byref(col), None)
        return "%u:%u" % (line.value, col.value)

    def spelling(cursor):
        s = lib.clang_getCursorSpelling(cursor)
        name = lib.clang_getCString(s).decode()
        lib.clang_disposeString(s)
        return name

    def visit(cursor, parent, _data):
        kind = lib.clang_getCursorKind(cursor)
        pkind = lib.clang_getCursorKind(parent)
        if not (kind in SCOPE or kind in FUNCTION or kind in DECL):
            return L.CXChildVisit_Continue
        if not lib.clang_Location_isFromMainFile(lib.clang_getCursorLocation(cursor)):
            return L.CXChildVisit_Continue
        if pkind in FUNCTION:
            if kind != L.CXCursor_ParmDecl:
                return L.CXChildVisit_Continue
        elif pkind not in SCOPE:
            return L.CXChildVisit_Continue
        print("%s %s %s in %s@%s" % (kind_name(kind), location(cursor), spelling(cursor), kind_name(pkind),
                                     location(parent)))
        if kind in SCOPE or kind in FUNCTION:
            lib.clang_visitChildren(cursor, visitor, None)
        return L.CXChildVisit_Continue

    visitor = L.CXCursorVisitor(visit)
    lib.clang_visitChildren(lib.clang_getTranslationUnitCursor(tu), visitor, None)
    lib.clang_disposeTranslationUnit(tu)
    lib.clang_disposeIndex(index)
    return 0


if __name__ == "__main__":
    sys.exit(main())
