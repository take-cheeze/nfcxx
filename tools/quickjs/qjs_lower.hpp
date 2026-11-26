// QuickJS bytecode -> Path B mid-level IR text (see qjs_lower.cpp for the design and the subset; the IR is
// docs/notes/pathb-stage2.md).
#ifndef NFCXX_QUICKJS_LOWER_HPP
#define NFCXX_QUICKJS_LOWER_HPP

#include <cstdint>
#include <string>
#include <vector>

namespace qjs {

// Returns the IR module text for a bytecode image (qjs_bc.hpp): fn 0 is the script, the functions it declares are
// qjf_1, qjf_2, ... Throws std::runtime_error with "refused: ..." for a construct that is not lowered, and with another
// message for an image that is malformed. The result is all or nothing.
std::string lower_image(const std::vector<std::uint8_t> &bytes, const std::string &source_name);

}  // namespace qjs

#endif  // NFCXX_QUICKJS_LOWER_HPP
