#!/usr/bin/env python3
"""libclang-edg: generate the rest of libclang's C API, and a ctypes binding, from the Python binding's function table.

The Python binding (clang.cindex, the package on PyPI) registers every function it uses with a signature in
`functionList`. A libclang shared object without one of those symbols makes `import clang.cindex` fail, so
libclang-edg exports all of them. This script writes:

  lib/libclang-edg/include/clang-c/Index_api.h   the prototype of every function in the table (C types)
  lib/libclang-edg/generated/stubs.c            a stub for every function that clang_edg.c does not implement;
                                                a stub notes once on stderr that it is not implemented and
                                                returns a zero value of its return type
  lib/libclang-edg/bindings/python/libclang_edg.py  a ctypes module over libclang-edg.so: argtypes and restype of
                                                every function, the structs, the visitor type and the kinds

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

# The binding's ctypes classes whose layout the C structs must match: name -> C struct.
LAYOUTS = {
    "Cursor": "CXCursor", "Type": "CXType", "SourceLocation": "CXSourceLocation", "SourceRange": "CXSourceRange",
    "_CXString": "CXString", "Token": "CXToken", "CCRStructure": "CXCodeCompleteResults",
}

# For the Python module: C type -> ctypes expression.
PY_SCALAR = {
    "unsigned int": "c_uint", "int": "c_int", "long": "c_long", "unsigned long": "c_ulong",
    "long long": "c_longlong", "unsigned long long": "c_ulonglong", "size_t": "c_size_t",
    "unsigned char": "c_ubyte", "char": "c_char", "double": "c_double", "float": "c_float", "void": "None",
    "void *": "c_void_p", "const char *": "c_char_p", "enum CXCursorKind": "c_int",
}
PY_STRUCTS = {"CXCursor", "CXType", "CXSourceLocation", "CXSourceRange", "CXString", "CXToken",
              "CXCodeCompleteResults", "CXUnsavedFile"}
PY_OPAQUE = {"CXIndex", "CXTranslationUnit", "CXFile", "CXDiagnostic"}

PY_HEADER = '''"""libclang-edg: ctypes bindings for libclang-edg.so (libclang's C API on the EDG front end).

GENERATED by scripts/gen-libclang-edg-api.py from clang.cindex's function table. Do not edit.

    import libclang_edg
    lib = libclang_edg.load()                  # or load("/path/to/libclang-edg.so.1")
    index = lib.clang_createIndex(0, 0)
    tu = lib.clang_parseTranslationUnit(index, b"file.cpp", None, 0, None, 0, 0)

The functions take and return the C types of clang-c/Index.h. A visitor is a libclang_edg.CXCursorVisitor.
See docs/notes/libclang-edg.md for what is implemented.
"""

import os
from ctypes import (CDLL, CFUNCTYPE, POINTER, Structure, c_char, c_char_p, c_double, c_float, c_int, c_long,
                    c_longlong, c_size_t, c_ubyte, c_uint, c_ulong, c_ulonglong, c_void_p)


class CXString(Structure):
    _fields_ = [("data", c_void_p), ("private_flags", c_uint)]


class CXSourceLocation(Structure):
    _fields_ = [("ptr_data", c_void_p * 2), ("int_data", c_uint)]


class CXSourceRange(Structure):
    _fields_ = [("ptr_data", c_void_p * 2), ("begin_int_data", c_uint), ("end_int_data", c_uint)]


class CXCursor(Structure):
    _fields_ = [("kind", c_int), ("xdata", c_int), ("data", c_void_p * 3)]


class CXType(Structure):
    _fields_ = [("kind", c_int), ("data", c_void_p * 2)]


class CXToken(Structure):
    _fields_ = [("int_data", c_uint * 4), ("ptr_data", c_void_p)]


class CXCodeCompleteResults(Structure):
    _fields_ = [("Results", c_void_p), ("NumResults", c_uint)]


class CXUnsavedFile(Structure):
    _fields_ = [("Filename", c_char_p), ("Contents", c_char_p), ("Length", c_ulong)]


CXCursorVisitor = CFUNCTYPE(c_int, CXCursor, CXCursor, c_void_p)

CXChildVisit_Break = 0
CXChildVisit_Continue = 1
CXChildVisit_Recurse = 2

'''

PY_FOOTER = '''

def load(path=None):
    """Load libclang-edg.so: PATH, else $LIBCLANG_EDG_LIBRARY, else libclang-edg.so.1 from the loader's search path."""
    lib = CDLL(path or os.environ.get("LIBCLANG_EDG_LIBRARY") or "libclang-edg.so.1")
    _register(lib)
    return lib
'''


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


def py_type(c):
    """The ctypes expression of a C type spelled by c_type()."""
    if c in PY_SCALAR:
        return PY_SCALAR[c]
    if c in PY_STRUCTS:
        return c
    if c in PY_OPAQUE:
        return "c_void_p"
    if c.endswith("*"):
        # The pointer depth is the number of stars; void * is c_void_p, void ** is POINTER(c_void_p), and so on.
        depth = c.count("*")
        base = c.replace("*", "").strip()
        t = None if base == "void" else py_type(base)
        for i in range(depth):
            t = "c_void_p" if t is None else "POINTER(%s)" % t
        return t
    raise SystemExit("gen-libclang-edg-api: no ctypes type for %r" % c)


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


# C spelling (after const/struct are dropped) -> ctypes, for the prototypes of the header.
PY_C = {
    "unsigned int": "c_uint", "unsigned": "c_uint", "int": "c_int", "long": "c_long", "unsigned long": "c_ulong",
    "long long": "c_longlong", "unsigned long long": "c_ulonglong", "size_t": "c_size_t", "double": "c_double",
    "float": "c_float", "char": "c_char", "unsigned char": "c_ubyte", "void": "None", "enum CXCursorKind": "c_int",
    "enum CXChildVisitResult": "c_int", "CXClientData": "c_void_p", "CXIndex": "c_void_p",
    "CXTranslationUnit": "c_void_p", "CXFile": "c_void_p", "CXDiagnostic": "c_void_p",
    "CXCursorVisitor": "CXCursorVisitor", "CXString": "CXString", "CXCursor": "CXCursor", "CXType": "CXType",
    "CXSourceLocation": "CXSourceLocation", "CXSourceRange": "CXSourceRange", "CXToken": "CXToken",
    "CXCodeCompleteResults": "CXCodeCompleteResults", "CXUnsavedFile": "CXUnsavedFile",
}


def py_of_c(t):
    """The ctypes expression of a C type of a libclang prototype (const and struct dropped)."""
    t = re.sub(r"\bconst\b", "", t)
    t = re.sub(r"\bstruct\s+", "", t)
    t = " ".join(t.split())
    if "*" in t:
        depth = t.count("*")
        base = " ".join(t.replace("*", " ").split())
        if base == "char":                       # char * is a string; char ** is an array of them
            inner, depth = "c_char_p", depth - 1
        else:
            inner = py_of_c(base) if base != "void" else None
        for _ in range(depth):
            inner = "c_void_p" if inner is None else "POINTER(%s)" % inner
        return inner
    if t not in PY_C:
        raise SystemExit("gen-libclang-edg-api: no ctypes type for C type %r" % t)
    return PY_C[t]


def py_params(params):
    """The ctypes argument types of a C parameter list: parameter names are dropped (a type alone is kept)."""
    params = " ".join(params.split())
    if params in ("", "void"):
        return []
    out = []
    for p in params.split(","):
        p = p.strip()
        base = " ".join(re.sub(r"\bconst\b", "", p).split())
        if "*" in base:
            base = re.sub(r"(?<=\*)\s*\w+$", "", base)   # the name of the parameter, after a star
        elif base not in PY_C:
            base = re.sub(r"\s*\w+$", "", base)           # or after a plain type
        out.append(py_of_c(base))
    return out


def write_python_binding(header_text):
    """bindings/python/libclang_edg.py: argtypes and restype of every libclang prototype in the header (the
    hand-written ones and the generated ones), and the CXCursorKind values of Index.h as module constants."""
    text = re.sub(r"/\*.*?\*/", " ", header_text, flags=re.S)
    text = re.sub(r"#.*", " ", text)
    text = " ".join(text.split())
    lines = []
    seen = set()
    for m in re.finditer(r"([A-Za-z_][\w ]*?[\w\*]\s*\**)\s*\b(clang_\w+)\s*\(([^()]*)\)\s*;", text):
        ret, name, params = m.group(1), m.group(2), m.group(3)
        if name in seen:
            continue
        seen.add(name)
        args = py_params(params)
        if name == "clang_visitChildren":
            args[1] = "CXCursorVisitor"
        ret_py = py_of_c(ret.strip())
        lines.append("    lib.%s.argtypes = [%s]" % (name, ", ".join(args)))
        if ret_py != "None":
            lines.append("    lib.%s.restype = %s" % (name, ret_py))
    kinds = re.findall(r"^  (CXCursor_\w+) = (\d+),?$", header_text, re.M)
    consts = "\n".join("%s = %s" % (k, v) for k, v in kinds)
    register = "\n\ndef _register(lib):\n" + "\n".join(lines) + "\n"
    os.makedirs(os.path.join(LIB, "bindings", "python"), exist_ok=True)
    with open(os.path.join(LIB, "bindings", "python", "libclang_edg.py"), "w") as f:
        f.write(PY_HEADER + consts + "\n" + register + PY_FOOTER)
    return len(seen)


def main():
    table = ci.functionList
    names = [item[0] for item in table]
    if len(set(names)) != len(names):
        raise SystemExit("gen-libclang-edg-api: duplicate names in the table")

    impl_src = open(os.path.join(LIB, "clang_edg.c")).read()
    for name in sorted(IMPLEMENTED):
        if not re.search(r"^[^\s(].*\b%s\(" % re.escape(name), impl_src, re.M):
            raise SystemExit("gen-libclang-edg-api: %s is listed as implemented but clang_edg.c does not define it"
                             % name)

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
        asserts.append("_Static_assert(sizeof(%s) == %d, \"%s: layout differs from clang.cindex's %s\");"
                       % (c, ctypes.sizeof(getattr(ci, py)), c, py))

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

    with open(os.path.join(LIB, "include", "clang-c", "Index.h")) as f:
        header = f.read()
    with open(os.path.join(LIB, "include", "clang-c", "Index_api.h")) as f:
        header += f.read()
    bound = write_python_binding(header)
    if bound != len(table) and bound < len(table):
        raise SystemExit("gen-libclang-edg-api: the Python binding has %d functions, the table %d" % (bound, len(table)))

    implemented = sum(1 for n in names if n in IMPLEMENTED)
    print("gen-libclang-edg-api: %d functions (%d implemented, %d stubbed)" % (len(table), implemented, len(stubs)))


if __name__ == "__main__":
    main()
