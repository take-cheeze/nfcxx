// mruby 4.0 RITE -> Path B mid-level IR text (tools/mrbbc/mrb_lower.cpp; docs/notes/mrbbc-pathb.md).
#ifndef NFCXX_MRBBC_LOWER_HPP
#define NFCXX_MRBBC_LOWER_HPP

#include <stdexcept>
#include <string>

#include "mrb_rite.hpp"

namespace mrbbc {

// A program the producer does not lower (an opcode, an operand form or a table it does not handle yet). Such a
// program is refused with exit status 3 and no IR is written.
struct Refused : std::runtime_error {
  using std::runtime_error::runtime_error;
};

// The IR module of the main program (the root irep). Throws Refused, or std::runtime_error for a malformed irep.
std::string lower_module(const mrb::Module &module, const std::string &source_name);

}  // namespace mrbbc

#endif  // NFCXX_MRBBC_LOWER_HPP
