// lua54_list: prints a Lua 5.4 binary chunk, function by function, with each instruction decoded by its format.
// The layout is this tool's own, not luac -l's; it is a reader check, not a disassembler for users.
//
//   lua54_list chunk.luac
#include "lua54_chunk.hpp"

#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace {

void print_operands(const lua54::Insn &i, lua54::Fmt f) {
  switch (f) {
    case lua54::Fmt::ABC:
      std::printf("A=%u B=%u C=%u k=%u", i.A(), i.B(), i.C(), i.k());
      break;
    case lua54::Fmt::ABx:
      std::printf("A=%u Bx=%u", i.A(), i.Bx());
      break;
    case lua54::Fmt::AsBx:
      std::printf("A=%u sBx=%d", i.A(), i.sBx());
      break;
    case lua54::Fmt::Ax:
      std::printf("Ax=%u", i.Ax());
      break;
    case lua54::Fmt::sJ:
      std::printf("sJ=%d", i.sJ());
      break;
  }
}

void print_proto(const lua54::Proto &f, const std::string &parent_source, int depth) {
  const std::string &src = f.source ? *f.source : parent_source;
  std::printf("%*sfunction <%s:%d,%d> params=%u vararg=%d maxstack=%u code=%zu k=%zu upvalues=%zu protos=%zu\n",
              depth * 2, "", src.c_str(), f.linedefined, f.lastlinedefined, f.numparams, f.is_vararg ? 1 : 0,
              f.maxstacksize, f.code.size(), f.k.size(), f.upvalues.size(), f.p.size());
  for (std::size_t pc = 0; pc < f.code.size(); ++pc) {
    const lua54::Insn &i = f.code[pc];
    std::printf("%*s%4zu %-10s ", depth * 2 + 2, "", pc, lua54::op_name(i.op()));
    print_operands(i, lua54::op_format(i.op()));
    std::printf("\n");
  }
  for (const auto &child : f.p) print_proto(*child, src, depth + 1);
}

}  // namespace

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
    std::printf("main of %s: upvalues=%u\n", argv[1], chunk.upvalue_count);
    print_proto(*chunk.main, "", 0);
  } catch (const std::exception &e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 1;
  }
  return 0;
}
