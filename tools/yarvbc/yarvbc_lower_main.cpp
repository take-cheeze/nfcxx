// yarvbc_lower: prints the Path B IR module of a Ruby 3.3 binary iseq on stdout (tools/yarvbc/yarv_lower.hpp).
//
//   yarvbc_lower program.yarb > program.ir
//
// The binary is RubyVM::InstructionSequence.compile(src).to_binary. Exit status: 0 with the IR written; 3 with "refused: ..."
// on stderr when the program uses something not lowered yet, or the format is not Ruby 3.3's (nothing is written to stdout);
// 1 for a file that does not read or malformed bytecode (the message on stderr); 2 for usage.
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "yarv_ibf.hpp"
#include "yarv_lower.hpp"

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s program.yarb\n", argv[0]);
    return 2;
  }
  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "%s: cannot open\n", argv[1]);
    return 1;
  }
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  try {
    yarv::Module m = yarv::read_module(bytes.data(), bytes.size());
    std::string ir = yarvbc::lower_module(m, argv[1]);
    std::fwrite(ir.data(), 1, ir.size(), stdout);
  } catch (const yarv::Refused &e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 3;
  } catch (const std::exception &e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 1;
  }
  return 0;
}
