// The module level of scripts/pathb-ptx-emit.rb's emit_module (phase 3 of the port): the classification of the IR's
// top-level forms, the kernel selection, the functions kept (reachable from the kernels), the recursion check, the
// module's declarations and the call order. The per-function lowering (Fn#compile) is not ported: plan_module stops
// where the Ruby would compile the functions.
#pragma once

#include <string>
#include <vector>

// The module text of the plan: the header, the declarations, and one "// body NAME" line per function in the call order
// (the Ruby's function text is not produced). Throws Refused (exit status 3) and BadIR (exit status 1) as the Ruby raises
// them, in the Ruby's order. sm is the target ("sm_75"); kernels are the names given by --kernel=.
std::string plan_module(const std::string &src, const std::string &sm, const std::vector<std::string> &kernels);
