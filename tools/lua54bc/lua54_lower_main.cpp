// lua54_lower: prints the Path B IR module of a Lua 5.4 binary chunk on stdout (see lua54_lower.hpp).
//
//   lua54_lower chunk.luac > chunk.ir
#include <cstdio>
#include <fstream>
#include <iterator>
#include <vector>

#include "lua54_lower.hpp"

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s chunk.luac\n", argv[0]);
    return 2;
  }
  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "%s: cannot open\n", argv[1]);
    return 1;
  }
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  try {
    lua54::Chunk chunk = lua54::load(bytes.data(), bytes.size(), argv[1]);
    std::string ir = lua54::lower_module(chunk, argv[1]);
    std::fwrite(ir.data(), 1, ir.size(), stdout);
  } catch (const std::exception &e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 3;
  }
  return 0;
}
