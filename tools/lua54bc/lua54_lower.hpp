// Lua 5.4 chunk -> Path B mid-level IR text (see lua54_lower.cpp for the templates and docs/notes/lua54-pathb.md).
#ifndef NFCXX_LUA54_LOWER_HPP
#define NFCXX_LUA54_LOWER_HPP

#include <string>

#include "lua54_chunk.hpp"

namespace lua54 {

// Returns the IR module text for every function of the chunk (the main function first, then nested prototypes in
// pre-order). Throws std::runtime_error with "refused: ..." for an opcode, constant or form that is not lowered yet.
// Nothing is emitted for a chunk that is refused: the result is all or nothing.
std::string lower_module(const Chunk &chunk, const std::string &source_name);

}  // namespace lua54

#endif  // NFCXX_LUA54_LOWER_HPP
