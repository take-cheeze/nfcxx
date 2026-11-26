// .mpy top-level code -> Path B IR (docs/notes/mpy-pathb.md). See mpy_lower.cpp for the subset.
#ifndef NFCXX_MPY_LOWER_HPP
#define NFCXX_MPY_LOWER_HPP

#include <string>

#include "mpy_reader.hpp"

namespace mpy {

// The IR text of a module's top-level code: one function, mpy_module, that runs the module body. Throws std::runtime_error
// with a reason ("refused: ...") for anything outside the subset.
std::string lower_module_text(const Module &m, const std::string &source_name);

}  // namespace mpy

#endif  // NFCXX_MPY_LOWER_HPP
