// mpy_dump: prints a MicroPython .mpy file (format 6): the tables, and each function's prelude and bytecode size.
//
//   mpy_dump file.mpy
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "mpy_opcodes.inc"
#include "mpy_reader.hpp"

namespace {

// The multi-opcodes carry their operand in the opcode byte (bc0.h): their names come from the range.
const char *op_name(uint8_t op) {
  if (op >= 0x70 && op < 0xb0) return "LOAD_CONST_SMALL_INT_MULTI";
  if (op >= 0xb0 && op < 0xc0) return "LOAD_FAST_MULTI";
  if (op >= 0xc0 && op < 0xd0) return "STORE_FAST_MULTI";
  if (op >= 0xd0 && op < 0xd7) return "UNARY_OP_MULTI";
  if (op >= 0xd7) return "BINARY_OP_MULTI";
  for (const auto &e : kOpNames) {
    if (e.value == op) return e.name;
  }
  return "?";
}

void walk(const mpy::RawCode &rc, int depth, bool listing) {
  mpy::Prelude p = mpy::read_prelude(rc.data);
  size_t code_len = rc.data.size() - p.code_offset;
  std::printf("%*sfunction: state=%u exc=%u flags=0x%x pos=%u kwonly=%u defpos=%u info=%zu cells=%zu code=%zu bytes\n",
              depth * 2, "", p.n_state, p.n_exc_stack, p.scope_flags, p.n_pos_args, p.n_kwonly_args, p.n_def_pos_args,
              p.n_info, p.n_cell, code_len);
  std::vector<mpy::Insn> insns = mpy::decode_code(rc.data.data() + p.code_offset, code_len);
  if (listing) {
    for (const auto &in : insns) {
      char unknown[16];
      std::snprintf(unknown, sizeof unknown, "op%02x", in.opcode);
      const char *name = op_name(in.opcode);
      if (name[0] == '?') name = unknown;
      std::printf("%*s  %4zu %-22s fmt=%u arg=%lld%s\n", depth * 2, "", in.offset, name, in.format,
                  (long long)in.arg, in.extra ? " (extra byte)" : "");
    }
  }
  for (const auto &child : rc.children) walk(child, depth + 1, listing);
}

}  // namespace

int main(int argc, char **argv) {
  bool listing = argc == 3 && std::string(argv[1]) == "-i";
  if (argc == 3 && listing) {
    argv[1] = argv[2];
    argc = 2;
  }
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s [-i] file.mpy\n", argv[0]);
    return 2;
  }
  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "%s: cannot open\n", argv[1]);
    return 1;
  }
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  try {
    mpy::Module m = mpy::load(bytes.data(), bytes.size());
    std::printf("mpy v%u flags=0x%x small_int_bits=%u qstrs=%zu objs=%zu\n", m.version, m.flags, m.small_int_bits,
                m.qstrs.size(), m.objs.size());
    for (size_t i = 0; i < m.qstrs.size(); ++i) std::printf("  qstr %zu: %s\n", i, m.qstrs[i].c_str());
    walk(m.top, 0, listing);
  } catch (const std::exception &e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 1;
  }
  return 0;
}
