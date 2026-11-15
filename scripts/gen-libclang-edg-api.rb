#!/usr/bin/env ruby
# libclang-edg: generate the rest of libclang's C API from the Python binding's function table (the Ruby port of
# scripts/gen-libclang-edg-api.rb: the same output, byte for byte).
#
# The binding's table (clang.cindex's functionList) and the ctypes sizes of the LAYOUTS classes come from
# scripts/libclang-edg-functions.json, exported once from the binding (see the "source" field there). Ruby cannot
# import clang.cindex, so this script reads that file. This script writes:
#
#   lib/libclang-edg/include/clang-c/Index_api.h   the prototype of every function in the table (C types)
#   lib/libclang-edg/generated/stubs.c            a stub for every function that clang_edg.c does not implement;
#                                                a stub notes once on stderr that it is not implemented and
#                                                returns a zero value of its return type
#
# The functions clang_edg.c implements are IMPLEMENTED below; the script checks that each one is defined there, and
# that every other function is generated. The struct layouts the table uses are checked against the binding's ctypes
# sizes (_Static_assert in Index_api.h), so a layout drift shows up at compile time.
#
# Usage: scripts/gen-libclang-edg-api.rb   (plain Ruby with its standard library; no Python needed)

require "fileutils"
require "json"
require "set"

ROOT = File.expand_path("..", __dir__)
LIB = File.join(ROOT, "lib", "libclang-edg")
FUNCTIONS_JSON = File.join(__dir__, "libclang-edg-functions.json")

# Functions clang_edg.c implements (it must define each one; the script checks).
IMPLEMENTED = Set.new(%w[
  clang_createIndex clang_disposeIndex clang_parseTranslationUnit clang_disposeTranslationUnit
  clang_getTranslationUnitCursor clang_visitChildren clang_getCursorKind clang_getCursorKindSpelling
  clang_getCursorSpelling clang_getCursorLocation clang_getCursorSemanticParent
  clang_getCursorLexicalParent clang_getNullCursor clang_Cursor_isNull clang_equalCursors
  clang_getSpellingLocation clang_Location_isFromMainFile clang_getFileName clang_getCString
  clang_disposeString clang_getClangVersion clang_getNullLocation clang_equalLocations
  clang_getInstantiationLocation clang_getExpansionLocation clang_getFileLocation
  clang_getPresumedLocation clang_Location_isInSystemHeader clang_getNullRange clang_getCursorExtent
  clang_getRangeStart clang_getRangeEnd clang_equalRanges clang_Cursor_getTranslationUnit
  clang_isDeclaration clang_isReference clang_isExpression clang_isStatement clang_isAttribute
  clang_isInvalid clang_isPreprocessing clang_isUnexposed clang_isTranslationUnit
])

# Python binding type name -> C type. Pointers ({"ptr": X} in the JSON) are derived from these.
C_TYPE = {
  "c_uint" => "unsigned int", "c_int" => "int", "c_long" => "long", "c_ulong" => "unsigned long",
  "c_longlong" => "long long", "c_ulonglong" => "unsigned long long", "c_double" => "double", "c_float" => "float",
  "c_size_t" => "size_t", "c_ubyte" => "unsigned char", "c_char" => "char", "c_void_p" => "void *",
  "c_char_p" => "const char *", "c_interop_string" => "const char *", "bool" => "unsigned int",
  "py_object" => "void *", "CFunctionType" => "void *", "from_id" => "int", "CursorKind" => "enum CXCursorKind",
  "TemplateArgumentKind" => "int", "Cursor" => "CXCursor", "Type" => "CXType", "SourceLocation" => "CXSourceLocation",
  "SourceRange" => "CXSourceRange", "_CXString" => "CXString", "Token" => "CXToken",
  "TranslationUnit" => "CXTranslationUnit", "File" => "CXFile", "Index" => "CXIndex", "Diagnostic" => "CXDiagnostic",
  "CodeCompletionResults" => "CXCodeCompleteResults", "CCRStructure" => "CXCodeCompleteResults",
}

# The binding's ctypes classes whose layout the C structs must match: Python class name -> C struct.
LAYOUTS = {
  "Cursor" => "CXCursor", "Type" => "CXType", "SourceLocation" => "CXSourceLocation", "SourceRange" => "CXSourceRange",
  "_CXString" => "CXString", "Token" => "CXToken", "CCRStructure" => "CXCodeCompleteResults",
}

# The C spelling of a binding type from the JSON: a leaf is a class name, {"ptr" => inner} a pointer to inner.
# A return of POINTER(c_void_p) is an opaque handle (the binding's CXIndex), so it is spelled void *, not void **.
def c_type(t, leaf_reprs, is_return = false)
  if t.is_a?(Hash)
    return "void *" if is_return && t["ptr"] == "c_void_p"
    base = c_type(t["ptr"], leaf_reprs)
    base.end_with?("*") ? base + "*" : base + " *"
  else
    C_TYPE.fetch(t) { abort "gen-libclang-edg-api: no C type for #{leaf_reprs.fetch(t)}" }
  end
end

# The statement that returns a zero value of the C return type ret.
def zero_return(ret)
  return "" if ret == "void"
  return "  return NULL;\n" if ret.end_with?("*") || %w[CXFile CXIndex CXDiagnostic CXTranslationUnit].include?(ret)
  if ["unsigned int", "int", "long", "unsigned long", "long long", "unsigned long long", "size_t",
      "unsigned char", "char", "double", "float"].include?(ret) || ret.start_with?("enum ")
    return "  return 0;\n"
  end
  "  #{ret} r;\n  memset(&r, 0, sizeof r);\n  return r;\n"
end

def main
  data = JSON.parse(File.read(FUNCTIONS_JSON))
  table = data.fetch("functions")
  leaf_reprs = data.fetch("leaf_reprs")
  layout_sizes = data.fetch("layout_sizes")

  names = table.map { |item| item.fetch("name") }
  abort "gen-libclang-edg-api: duplicate names in the table" if names.uniq.size != names.size

  impl_src = File.read(File.join(LIB, "clang_edg.c"))
  IMPLEMENTED.sort.each do |name|
    next if impl_src.match?(/^[^\s(].*\b#{Regexp.escape(name)}\(/)
    abort "gen-libclang-edg-api: #{name} is listed as implemented but clang_edg.c does not define it"
  end

  protos = []
  stubs = []
  table.each do |item|
    name = item.fetch("name")
    ret = item.fetch("ret")
    ret_c = ret.nil? ? "void" : c_type(ret, leaf_reprs, true)
    arg_c = item.fetch("args").map { |a| c_type(a, leaf_reprs) }
    next if IMPLEMENTED.include?(name)   # its prototype is hand-written in clang-c/Index.h, with libclang's own types

    params = arg_c.empty? ? "void" : arg_c.join(", ")
    protos << "#{ret_c} #{name}(#{params});"
    pdecl = arg_c.empty? ? "void" : arg_c.each_with_index.map { |t, i| "#{t} a#{i}" }.join(", ")
    body = ["  static int warned;", "  if (!warned) { warned = 1; nfc_not_implemented(\"#{name}\"); }"]
    body += arg_c.each_index.map { |i| "  (void)a#{i};" }
    stubs << "#{ret_c} #{name}(#{pdecl})\n{\n#{body.join("\n")}\n\n#{zero_return(ret_c)}}\n"
  end

  # Layout checks: the binding's ctypes sizes must equal the C structs' (Index.h defines them).
  asserts = LAYOUTS.sort.map do |py, c|
    "_Static_assert(sizeof(#{c}) == #{layout_sizes.fetch(py)}, \"#{c}: layout differs from clang.cindex's #{py}\");"
  end

  FileUtils.mkdir_p(File.join(LIB, "generated"))
  # The header comments name the Python script on purpose: the output must stay byte-identical to the Python's.
  File.write(File.join(LIB, "include", "clang-c", "Index_api.h"),
    "/* GENERATED by scripts/gen-libclang-edg-api.rb from clang.cindex's function table. Do not edit. */\n" \
    "#ifndef CLANG_C_INDEX_API_H\n#define CLANG_C_INDEX_API_H\n\n" \
    "#include <stddef.h>\n\n" \
    "#{asserts.join("\n")}\n\n" \
    "#{protos.join("\n")}\n\n#endif /* CLANG_C_INDEX_API_H */\n")
  File.write(File.join(LIB, "generated", "stubs.c"),
    "/* GENERATED by scripts/gen-libclang-edg-api.rb. Do not edit. Functions not implemented yet. */\n" \
    "#include \"clang-c/Index.h\"\n\n#include <stdio.h>\n#include <string.h>\n\n" \
    "static void nfc_not_implemented(const char *name)\n{\n" \
    "  fprintf(stderr, \"libclang-edg: %s is not implemented yet\\n\", name);\n}\n\n" \
    "#{stubs.join("\n")}")
  implemented = names.count { |n| IMPLEMENTED.include?(n) }
  puts "gen-libclang-edg-api: #{table.size} functions (#{implemented} implemented, #{stubs.size} stubbed)"
end

main if $PROGRAM_NAME == __FILE__
