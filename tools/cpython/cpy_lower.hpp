// CPython 3.13 .pyc -> Path B mid-level IR text (see cpy_lower.cpp for the lowering and docs/notes/cpython-pathb.md).
#ifndef NFCXX_CPYTHON_LOWER_HPP
#define NFCXX_CPYTHON_LOWER_HPP

#include <string>

#include "cpy_marshal.hpp"

namespace cpy {

// Returns the IR module text: the module's code (pyf_0) and every function defined at module level (pyf_1, ...). Throws
// std::runtime_error with "refused: ..." for a construct that is not lowered yet. The result is all or nothing.
std::string lower_module(const Pyc &pyc, const std::string &source_name);

}  // namespace cpy

#endif  // NFCXX_CPYTHON_LOWER_HPP
