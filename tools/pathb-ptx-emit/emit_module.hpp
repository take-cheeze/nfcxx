// The module level of scripts/pathb-ptx-emit.rb's emit_module (emit_module.cpp): the PTX text of a module's IR, for the
// target sm (for example "sm_75") and the kernels named (empty: the functions that are not static and not called).
// Throws Refused (exit status 3) and BadIR (exit status 1), as the Ruby does.
#pragma once

#include <string>
#include <vector>

std::string emit_module(const std::string &src, const std::string &sm, const std::vector<std::string> &kernels);
