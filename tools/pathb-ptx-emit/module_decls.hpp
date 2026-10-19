// The module-level declarations of scripts/pathb-ptx-emit.rb's emit_module (phase 3, memory): the global, shared,
// constant and string-constant declarations, classified from the IR's top-level forms in the Ruby's order. The Ruby
// function interleaves this with the function compile; this part depends only on the top-level forms.
#pragma once

#include <map>
#include <set>
#include <string>
#include <vector>

#include "ir.hpp"

// The names of the module's data symbols, by the Ruby's @shared, @globals, @consts, @externs and @strings (the keys of
// the hashes emit_module builds). An operand @name is looked up in them, in that order (see FnCtx::operand).
struct ModuleSymbols {
  std::set<std::string> shared, globals, consts, externs, strings;
  // A string or constant with the value of an earlier one: its name => the earlier name, which is the one emitted (see
  // data_name).
  std::map<std::string, std::string> data_alias;
  const std::string &data_name(const std::string &name) const {
    auto it = data_alias.find(name);
    return it == data_alias.end() ? name : it->second;
  }
};

// The declarations of the module, as the Ruby's emit_module writes them after the header: the extern dynamic shared
// symbol and the vprintf declaration (when the functions use them), the string constants, the .shared, .global and
// .const declarations, and the blank line after them. When syms is given, it also receives the names the module
// declares (the sets the function lowering looks its @name operands up in). Throws Refused (the Ruby's refusals) and
// BadIR.
std::string emit_module_decls(const std::string &src, bool uses_dynshared, bool uses_printf,
                              ModuleSymbols *syms = nullptr);

// The same declarations from the module's top-level forms (the non-function forms, in order: the function forms are skipped).
std::string emit_module_decls(const std::vector<Node> &forms, bool uses_dynshared, bool uses_printf,
                              ModuleSymbols *syms = nullptr);

// One data symbol of the declarations: a string constant, a shared, global or constant object. The lines are the
// declarations as emit_module_decls writes them (without the newline).
struct DataDecl {
  enum Kind { String, Shared, Global, Const };
  Kind kind = String;
  std::string sym;   // the PTX symbol (string_const_sym or ptx_sym)
  size_t bytes = 0;  // the constant data's size (String and Const); 0 otherwise
  std::string line;
};
struct DataDecls {
  std::vector<DataDecl> items;  // in the output order: the strings, the shared, the global and the constant symbols
};

// The data symbols of the module (the declarations' values; the checks of emit_module_decls). Fills syms when given.
DataDecls collect_data_decls(const std::vector<Node> &forms, ModuleSymbols *syms = nullptr);

// The declarations text for the items whose keep flag is set (all of them when keep is empty): the dynamic shared symbol and
// the vprintf declaration when they are used, the items in order, and a blank line after the shared and global symbols.
std::string render_data_decls(const DataDecls &d, const std::vector<bool> &keep, bool uses_dynshared, bool uses_printf);
