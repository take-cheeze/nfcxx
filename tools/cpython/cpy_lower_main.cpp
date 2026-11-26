// cpy_lower: prints the Path B IR module of a CPython 3.13 .pyc on stdout (see cpy_lower.hpp).
//
//   cpy_lower module.pyc > module.ir
//
// Exit status: 0 on success, 3 when a construct is refused (the reason is on stderr, after "refused: "), 1 when the file
// cannot be read or is malformed.
#include <cstdio>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

#include "cpy_lower.hpp"

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s module.pyc\n", argv[0]);
    return 2;
  }
  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "%s: cannot open\n", argv[1]);
    return 1;
  }
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  try {
    cpy::Pyc pyc = cpy::load_pyc(bytes);
    std::string ir = cpy::lower_module(pyc, argv[1]);
    std::fwrite(ir.data(), 1, ir.size(), stdout);
  } catch (const std::exception &e) {
    std::string msg = e.what();
    std::fprintf(stderr, "%s\n", msg.c_str());
    return msg.rfind("refused: ", 0) == 0 ? 3 : 1;
  }
  return 0;
}
