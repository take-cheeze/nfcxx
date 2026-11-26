// QuickJS bytecode reader: a file written by JS_WriteObject with JS_WRITE_OBJ_BYTECODE (what `qjsc -c` and
// tools/quickjs/qjs_compile.c write) for the BC_VERSION of the QuickJS source the tables were generated from
// (tools/quickjs/qjs_tables.inc). The layout is the one of JS_WriteObject2, JS_WriteObjectAtoms, JS_WriteFunctionTag and
// JS_WriteFunctionBytecode in 3rd/quickjs/quickjs.c; the words are little-endian, as the reader expects of the host
// that wrote the file.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace qjs {

// One constant of a function's constant pool (cpool). A function constant is a child function, by its index in Bc.fns.
struct Const {
  enum Kind { Undefined, Null, Bool, Int, Float, Str, Func } kind = Undefined;
  std::int32_t i = 0;   // Bool: 0 or 1; Int: the value; Func: the index into Bc::fns
  double d = 0;         // Float: the value (BC_TAG_FLOAT64)
  std::string s;        // Str: the bytes of a string (BC_TAG_STRING; a wide string is refused by the reader's caller)
  bool wide = false;    // Str: the string is 16-bit (kept as its code units in s, two bytes each)
};

// One local (arg or var) with its name (vardefs). Only the names and the kinds are used.
struct VarDef {
  std::string name;
  int var_kind = 0;
  bool is_const = false, is_lexical = false, is_captured = false;
};

// One closure variable (a captured variable of an outer function).
struct ClosureVar {
  std::string name;
  int closure_type = 0, var_idx = 0;
  bool is_const = false, is_lexical = false;
  int var_kind = 0;
};

// One function of the image. fns[0] is the top-level script.
struct Fn {
  std::string name;
  int js_mode = 0;
  bool has_prototype = false, has_simple_parameter_list = false, has_debug = false, is_derived_class_constructor = false,
       need_home_object = false, new_target_allowed = false, super_call_allowed = false, super_allowed = false,
       arguments_allowed = false, is_direct_or_indirect_eval = false;
  int func_kind = 0;
  int arg_count = 0, var_count = 0, defined_arg_count = 0, stack_size = 0, var_ref_count = 0;
  std::vector<VarDef> vardefs;          // arg_count + var_count entries when present (empty when the image has none)
  std::vector<ClosureVar> closure_vars;
  std::vector<Const> cpool;
  std::vector<std::uint8_t> code;       // the bytecode, atoms already resolved to atom numbers (see Bc::atom_name)
};

// The whole image: the atom table and the functions.
struct Bc {
  std::vector<std::string> user_atoms;  // the atoms the image defines, by their index from quickjs's JS_ATOM_END on
  std::vector<Fn> fns;
  // The name of an atom operand (a number as the bytecode holds it: a predefined atom below kQjsAtomEnd, else an index
  // into user_atoms plus kQjsAtomEnd). Returns false for an atom that is not a name (a tagged integer).
  bool atom_name(std::uint32_t v, std::string &out) const;
};

// Reads the image. On a malformed or truncated image, or a bytecode version other than kQjsBcVersion, throws
// std::runtime_error with a message. An object constant (a tag the reader cannot skip) is refused here, as "refused: ...";
// string and float constants are read and kept, and the lowering refuses them where they are used.
Bc read_bc(const std::vector<std::uint8_t> &bytes);

}  // namespace qjs
