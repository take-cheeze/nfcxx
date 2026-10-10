// TU c: the one explicit instantiation behind `extern template struct Box<long>`, a global defined here and
// used from the other TUs, std::string again, an exception thrown here and caught in main.cpp.
#include <stdexcept>
#include "common.hpp"

template struct Box<long>;

int program_wide_value = 42;

std::string unit_c() {
  Box<long> b(7);
  Box<std::string> bs("s");
  std::string r = std::to_string(b.get() + b.plus(1)) + bs.get() + bs.plus("t");
  if (r.size() > 3) throw std::logic_error("c: " + r);
  return r;
}
