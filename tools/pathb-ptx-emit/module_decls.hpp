// The module-level declarations of scripts/pathb-ptx-emit.rb's emit_module (phase 3, memory): the global, shared,
// constant and string-constant declarations, classified from the IR's top-level forms in the Ruby's order. The Ruby
// function interleaves this with the function compile; this part depends only on the top-level forms.
#pragma once

#include <set>
#include <string>

#include "ir.hpp"

// The names of the module's data symbols, by the Ruby's @shared, @globals, @consts, @externs and @strings (the keys of
// the hashes emit_module builds). An operand @name is looked up in them, in that order (see FnCtx::operand).
struct ModuleSymbols {
  std::set<std::string> shared, globals, consts, externs, strings;
};

// The declarations of the module, as the Ruby's emit_module writes them after the header: the extern dynamic shared
// symbol and the vprintf declaration (when the functions use them), the string constants, the .shared, .global and
// .const declarations, and the blank line after them. When syms is given, it also receives the names the module
// declares (the sets the function lowering looks its @name operands up in). Throws Refused (the Ruby's refusals) and
// BadIR.
std::string emit_module_decls(const std::string &src, bool uses_dynshared, bool uses_printf,
                              ModuleSymbols *syms = nullptr);
