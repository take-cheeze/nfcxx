// qjs_lower: prints the Path B IR module of a QuickJS bytecode image on stdout (see qjs_lower.hpp).
//
//   qjs_lower image.qjsbc > image.ir
//
// Exit status: 0 on success, 3 when a construct is refused (the reason is on stderr, after "refused: "), 1 when the file
// cannot be read or is malformed.
#include <cstdio>
#include <exception>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "qjs_lower.hpp"

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s image.qjsbc\n", argv[0]);
    return 2;
  }
  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "%s: cannot open\n", argv[1]);
    return 1;
  }
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  try {
    std::string ir = qjs::lower_image(bytes, argv[1]);
    std::fwrite(ir.data(), 1, ir.size(), stdout);
  } catch (const std::exception &e) {
    std::string msg = e.what();
    std::fprintf(stderr, "%s\n", msg.c_str());
    return msg.rfind("refused: ", 0) == 0 ? 3 : 1;
  }
  return 0;
}
