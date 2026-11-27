// mruby 4.0 RITE -> Path B mid-level IR text (tools/mrbbc/mrb_lower.cpp; docs/notes/mrbbc-pathb.md).
#ifndef NFCXX_MRBBC_LOWER_HPP
#define NFCXX_MRBBC_LOWER_HPP

#include <stdexcept>
#include <string>
#include <vector>

#include "mrb_rite.hpp"

namespace mrbbc {

// A program the producer does not lower (an opcode, an operand form or a table it does not handle yet). Such a
// program is refused with exit status 3 and no IR is written.
struct Refused : std::runtime_error {
  using std::runtime_error::runtime_error;
};

// The value layout of the registers: value_bytes 8 (a 64-bit tagged word, the default), 4 (a 32-bit word) or 16 (a tag
// byte and an int64). The runtime must be built with the same MRBBC_VALUE (tests/mrbbc/runtime/mrbrt.h).
struct LowerOptions {
  int value_bytes = 8;
  std::vector<std::string> i64_exports;
};

// The IR module of the main program (the root irep). Throws Refused, or std::runtime_error for a malformed irep.
std::string lower_module(const mrb::Module &module, const std::string &source_name, const LowerOptions &options = {});

// Every refusal of the module, one line each ("<function> (<method name>): refused: ..."), instead of stopping at the
// first: a census of what the lowering still lacks. No IR is produced. A body whose scan cannot go on past a refused
// instruction is reported as "stopped:" and the other bodies are still scanned. *functions, when given, is set to the
// number of functions scanned.
std::vector<std::string> report_refusals(const mrb::Module &module, const LowerOptions &options = {},
                                         std::size_t *functions = nullptr);

}  // namespace mrbbc

#endif  // NFCXX_MRBBC_LOWER_HPP
