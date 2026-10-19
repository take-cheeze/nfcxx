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

// Grouping (pathb-ptx-emit --groups-dir): the kernels are partitioned into modules, each within the budget. A module is the
// closure of its kernels (the functions they reach), with the data those functions reference. A kernel whose closure alone is
// over the budget is refused (Refused, exit status 3). The sink gets each module's index (in order), its kernels (IR names) and
// its text; the sink is called only once the partition is complete, so a refusal gives no module.
struct GroupBudget {
  size_t max_const_bytes;  // constant data (strings and .const objects) referenced by a module
  size_t max_ptx_lines;    // lines of a module's functions
};
using GroupSink = std::function<void(size_t index, const std::vector<std::string> &kernels, const std::string &ptx)>;
void emit_module_groups(const ModuleText &text, const std::string &sm, const std::vector<std::string> &kernels,
                        const GroupBudget &budget, const GroupSink &sink);
