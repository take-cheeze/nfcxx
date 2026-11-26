// sq_lower: prints the Path B IR module of a Squirrel 3.2 bytecode stream on stdout (sq_lower.hpp).
//
//   sq_lower chunk.cnut > chunk.ir
//
// Exit status: 0 the module is printed; 3 refused (an opcode or operand is not lowered yet; nothing on stdout);
// 1 the stream is malformed or cannot be read; 2 usage.
#include <cstdio>
#include <exception>
#include <fstream>
#include <iterator>
#include <vector>

#include "sq_lower.hpp"

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s chunk.cnut\n", argv[0]);
    return 2;
  }
  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "%s: cannot open\n", argv[1]);
    return 1;
  }
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  try {
    squirrel::Chunk chunk = squirrel::load(bytes.data(), bytes.size());
    std::string ir = squirrel::lower_module(chunk, argv[1]);
    std::fwrite(ir.data(), 1, ir.size(), stdout);
  } catch (const squirrel::Refused &e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 3;
  } catch (const std::exception &e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 1;
  }
  return 0;
}
