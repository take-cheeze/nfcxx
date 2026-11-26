// mrbbc_lower: prints the Path B IR module of an mruby 4.0 RITE file on stdout (tools/mrbbc/mrb_lower.hpp).
//
//   mrbbc_lower program.rite > program.ir
//
// Exit status: 0 with the IR written; 3 with "refused: ..." on stderr when the program uses something not lowered yet
// (nothing is written to stdout); 1 for a file that does not read (the reader's message on stderr); 2 for usage.
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "mrb_lower.hpp"
#include "mrb_rite.hpp"

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s program.rite\n", argv[0]);
    return 2;
  }
  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "%s: cannot open\n", argv[1]);
    return 1;
  }
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  try {
    mrb::Module m = mrb::read_module(bytes.data(), bytes.size());
    std::string ir = mrbbc::lower_module(m, argv[1]);
    std::fwrite(ir.data(), 1, ir.size(), stdout);
  } catch (const mrbbc::Refused &e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 3;
  } catch (const std::exception &e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 1;
  }
  return 0;
}
