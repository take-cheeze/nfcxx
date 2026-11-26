// sq_dump: prints a Squirrel 3.2 bytecode stream (sq -c output), one prototype at a time, with every instruction by name.
//
//   sq_dump FILE.cnut        exit 0 when the stream loads and is fully consumed, 1 when it is refused (reason on stderr)
#include <cstdio>
#include <exception>
#include <fstream>
#include <iterator>
#include <vector>

#include "sq_chunk.hpp"

namespace {

void print_object(const squirrel::Object &o) {
  switch (o.type) {
    case squirrel::kOtNull: std::printf("null"); break;
    case squirrel::kOtBool: std::printf("bool %s", o.integer ? "true" : "false"); break;
    case squirrel::kOtInteger: std::printf("integer %lld", static_cast<long long>(o.integer)); break;
    case squirrel::kOtFloat: std::printf("float %.9g", o.floating); break;
    case squirrel::kOtString: std::printf("string \"%s\"", o.text.c_str()); break;
    default: std::printf("?"); break;
  }
}

void dump_proto(const squirrel::Proto &p, int depth) {
  std::printf("%*sfunction \"%s\" stacksize %lld params %zu literals %zu outers %zu locals %zu lines %zu "
              "instructions %zu functions %zu\n",
              depth * 2, "", p.name.text.c_str(), static_cast<long long>(p.stacksize), p.parameters.size(),
              p.literals.size(), p.outers.size(), p.localvars.size(), p.lines.size(), p.instructions.size(),
              p.functions.size());
  for (std::size_t i = 0; i < p.literals.size(); ++i) {
    std::printf("%*s  literal %zu: ", depth * 2, "", i);
    print_object(p.literals[i]);
    std::printf("\n");
  }
  for (std::size_t i = 0; i < p.instructions.size(); ++i) {
    const squirrel::Instruction &in = p.instructions[i];
    std::printf("%*s  %4zu %-14s %d %d %d %d\n", depth * 2, "", i, squirrel::op_name(in.op), in.arg0, in.arg1,
                in.arg2, in.arg3);
  }
  for (const squirrel::Proto &f : p.functions) dump_proto(f, depth + 1);
}

}  // namespace

int main(int argc, char **argv) {
  if (argc == 2 && std::string(argv[1]) == "--opcodes") {
    for (unsigned op = 0; op < squirrel::kNumOpcodes; ++op) std::printf("%s\n", squirrel::op_name(op));
    return 0;
  }
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s FILE.cnut | --opcodes\n", argv[0]);
    return 2;
  }
  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "%s: cannot open\n", argv[1]);
    return 1;
  }
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  try {
    squirrel::Chunk c = squirrel::load(bytes.data(), bytes.size());
    std::printf("stream: SQChar %u SQInteger %u SQFloat %u, consumed\n", c.char_size, c.integer_size, c.float_size);
    dump_proto(c.main, 0);
  } catch (const std::exception &e) {
    std::fprintf(stderr, "%s: refused: %s\n", argv[1], e.what());
    return 1;
  }
  return 0;
}
