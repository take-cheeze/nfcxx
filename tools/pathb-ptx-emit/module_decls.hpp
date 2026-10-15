// The module-level declarations of scripts/pathb-ptx-emit.rb's emit_module (phase 3, memory): the global, shared,
// constant and string-constant declarations, classified from the IR's top-level forms in the Ruby's order. The Ruby
// function interleaves this with the function compile; this part depends only on the top-level forms.
#pragma once

#include <string>

#include "ir.hpp"

// The declarations of the module, as the Ruby's emit_module writes them after the header: the extern dynamic shared
// symbol and the vprintf declaration (when the functions use them), the string constants, the .shared, .global and
// .const declarations, and the blank line after them. Throws Refused (the Ruby's refusals) and BadIR.
std::string emit_module_decls(const std::string &src, bool uses_dynshared, bool uses_printf);
