// The module level of scripts/pathb-ptx-emit.rb's emit_module (emit_module.cpp): the PTX text of a module's IR, for the target
// sm (for example "sm_75") and the kernels named (empty: the functions that are not static and not called). The text is given
// to sink in pieces, in order, once the whole module is compiled (nothing is given when a refusal is raised). Throws Refused
// (exit status 3) and BadIR (exit status 1), as the Ruby does.
#pragma once

#include <functional>
#include <string>
#include <vector>

#include "ir.hpp"

void emit_module(const ModuleText &text, const std::string &sm, const std::vector<std::string> &kernels,
                 const std::function<void(const std::string &)> &sink);
