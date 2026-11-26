// Ruby 3.3 YARV bytecode -> Path B IR text (tools/yarvbc/yarv_lower.cpp; the first subset).
#ifndef NFCXX_YARVBC_LOWER_HPP
#define NFCXX_YARVBC_LOWER_HPP

#include <string>

#include "yarv_ibf.hpp"

namespace yarvbc {

// The IR module of a Ruby 3.3 iseq module (the root iseq and the methods it defines with def). Throws yarv::Refused for a
// program the producer does not lower (the message starts with "refused: "), and yarv::ReadError for malformed bytecode.
std::string lower_module(const yarv::Module &module, const std::string &source_name);

}  // namespace yarvbc

#endif  // NFCXX_YARVBC_LOWER_HPP
