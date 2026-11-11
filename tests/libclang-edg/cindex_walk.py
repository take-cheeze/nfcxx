#!/usr/bin/env python3
"""libclang-edg: the walk of walk.c through the Python binding (clang.cindex), so the binding's own code path is
checked too. Usage: cindex_walk.py LIBRARY FILE [-std=... | -I... | -D... | -U...]...

LIBRARY is the libclang-edg shared object or the system libclang; the output is the same format as walk.c, so
tests/libclang-edg/run.sh can diff the two. The binding is found by LIBCLANG_EDG_PYTHON (the directory holding the
clang/ package) or as installed.
"""

import os
import sys

if os.environ.get("LIBCLANG_EDG_PYTHON"):
    sys.path.insert(0, os.environ["LIBCLANG_EDG_PYTHON"])
from clang import cindex  # noqa: E402

SCOPE = {"TRANSLATION_UNIT", "NAMESPACE", "STRUCT_DECL", "CLASS_DECL", "UNION_DECL", "ENUM_DECL",
         "CLASS_TEMPLATE"}
FUNCTION = {"FUNCTION_DECL", "CXX_METHOD", "CONSTRUCTOR", "DESTRUCTOR", "FUNCTION_TEMPLATE"}
DECL = {"FIELD_DECL", "VAR_DECL", "ENUM_CONSTANT_DECL", "TYPEDEF_DECL", "PARM_DECL"}


def kind_word(kind):
    # libclang's spelling of the kind, as walk.c prints it (the binding's name is in CursorKind.name)
    return {"CXX_METHOD": "CXXMethod", "CONSTRUCTOR": "CXXConstructor", "DESTRUCTOR": "CXXDestructor",
            "STRUCT_DECL": "StructDecl", "CLASS_DECL": "ClassDecl", "UNION_DECL": "UnionDecl",
            "ENUM_DECL": "EnumDecl", "ENUM_CONSTANT_DECL": "EnumConstantDecl", "TYPEDEF_DECL": "TypedefDecl",
            "FUNCTION_DECL": "FunctionDecl", "VAR_DECL": "VarDecl", "FIELD_DECL": "FieldDecl",
            "PARM_DECL": "ParmDecl", "NAMESPACE": "Namespace", "TRANSLATION_UNIT": "TranslationUnit",
            "FUNCTION_TEMPLATE": "FunctionTemplate", "CLASS_TEMPLATE": "ClassTemplate"}[kind.name]


def location(c):
    loc = c.location
    return "%d:%d" % (loc.line, loc.column)


def walk(parent, path, out):
    for c in parent.get_children():
        k = c.kind.name
        if c.location.file is None or os.path.basename(c.location.file.name) != os.path.basename(path):
            continue
        if k not in SCOPE and k not in FUNCTION and k not in DECL:
            continue
        if parent.kind.name in FUNCTION:
            if k != "PARM_DECL":
                continue
        elif parent.kind.name not in SCOPE:
            continue
        out.append("%s %s %s in %s@%s" % (kind_word(c.kind), location(c), c.spelling,
                                          kind_word(parent.kind), location(parent)))
        if k in SCOPE and k != "TRANSLATION_UNIT" or k in FUNCTION:
            walk(c, path, out)


def main():
    library, path = sys.argv[1], sys.argv[2]
    cindex.Config.set_library_file(library)
    index = cindex.Index.create()
    tu = index.parse(path, args=sys.argv[3:])
    out = []
    walk(tu.cursor, path, out)
    print("\n".join(out))


if __name__ == "__main__":
    main()
