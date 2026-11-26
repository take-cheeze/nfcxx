// Squirrel 3.2 bytecode -> Path B mid-level IR text (tools/squirrelbc/sq_lower.cpp; docs/notes/squirrelbc-pathb.md).
#ifndef NFCXX_SQUIRREL_LOWER_HPP
#define NFCXX_SQUIRREL_LOWER_HPP

#include <stdexcept>
#include <string>

#include "sq_chunk.hpp"

namespace squirrel {

// An opcode or constant this producer does not lower yet. The message starts with "refused: ".
class Refused : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

// Returns the IR module text for every prototype of the chunk (the main function first, then nested prototypes in
// pre-order). Each function is `sq_fn_N(SQV *ret, SQV *base)`; a register R is `base + 16*R`, and an SQV is
// { u32 tag at offset 0 (the Squirrel object type word); i64 payload at offset 8 }. Throws Refused for an opcode or
// operand not lowered yet, and std::runtime_error for a stream that is malformed for lowering. Nothing is returned for
// a chunk that is refused: the result is all or nothing.
std::string lower_module(const Chunk &chunk, const std::string &source_name);

}  // namespace squirrel

#endif  // NFCXX_SQUIRREL_LOWER_HPP
