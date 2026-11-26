#include "qjs_insn.hpp"

#include <stdexcept>
#include <vector>

#include "qjs_tables.inc"   // kQjsOps

namespace qjs {

namespace {

std::uint32_t get_u32(const std::vector<std::uint8_t> &c, std::size_t p) {
  return static_cast<std::uint32_t>(c[p]) | (static_cast<std::uint32_t>(c[p + 1]) << 8) |
         (static_cast<std::uint32_t>(c[p + 2]) << 16) | (static_cast<std::uint32_t>(c[p + 3]) << 24);
}

std::uint32_t get_u16(const std::vector<std::uint8_t> &c, std::size_t p) {
  return static_cast<std::uint32_t>(c[p]) | (static_cast<std::uint32_t>(c[p + 1]) << 8);
}

// The last character of a name that ends in a digit (get_loc3 -> 3, call2 -> 2): the index that the short forms encode.
int suffix_digit(const std::string &name) { return name.back() - '0'; }

}  // namespace

Insn decode_insn(const std::vector<std::uint8_t> &code, std::size_t pc) {
  if (pc >= code.size()) throw std::runtime_error("pc past the end of the code");
  int op = code[pc];
  if (op >= kQjsNumOps) throw std::runtime_error("opcode " + std::to_string(op) + " is not a QuickJS opcode");
  const QjsOp &info = kQjsOps[op];
  Insn in;
  in.pc = pc;
  in.op = op;
  in.name = info.name;
  in.size = info.size;
  in.npop = info.npop;
  in.npush = info.npush;
  if (pc + static_cast<std::size_t>(in.size) > code.size()) {
    throw std::runtime_error("instruction " + in.name + " runs past the end of the code");
  }
  const std::string fmt = info.fmt;
  std::size_t p = pc + 1;   // the operand
  auto s8 = [&](std::size_t q) { return static_cast<std::int64_t>(static_cast<std::int8_t>(code[q])); };
  auto s16 = [&](std::size_t q) { return static_cast<std::int64_t>(static_cast<std::int16_t>(get_u16(code, q))); };
  auto s32 = [&](std::size_t q) { return static_cast<std::int64_t>(static_cast<std::int32_t>(get_u32(code, q))); };
  auto rel = [&](std::int64_t off) { return static_cast<std::int64_t>(pc) + 1 + off; };

  if (fmt == "none") {
  } else if (fmt == "none_int") {
    in.arg = in.name == "push_minus1" ? -1 : suffix_digit(in.name);
  } else if (fmt == "none_loc" || fmt == "none_arg" || fmt == "none_var_ref") {
    in.arg = suffix_digit(in.name);
  } else if (fmt == "npopx") {
    in.arg = suffix_digit(in.name);   // call0..call3: the argument count is in the name
  } else if (fmt == "u8" || fmt == "loc8" || fmt == "const8") {
    in.arg = code[p];
  } else if (fmt == "i8") {
    in.arg = s8(p);
  } else if (fmt == "label8") {
    in.target = rel(s8(p));
  } else if (fmt == "u16" || fmt == "npop" || fmt == "loc" || fmt == "arg" || fmt == "var_ref" || fmt == "const16") {
    in.arg = get_u16(code, p);
  } else if (fmt == "i16") {
    in.arg = s16(p);
  } else if (fmt == "label16") {
    in.target = rel(s16(p));
  } else if (fmt == "npop_u16") {
    in.arg = get_u16(code, p);                  // the argument count; the second u16 is the flags of eval
  } else if (fmt == "u32" || fmt == "const") {
    in.arg = get_u32(code, p);
  } else if (fmt == "i32") {
    in.arg = s32(p);
  } else if (fmt == "label") {
    in.target = rel(s32(p));
  } else if (fmt == "label_u16") {
    in.target = rel(s32(p));
    in.arg = get_u16(code, p + 4);
  } else if (fmt == "atom") {
    in.atom = get_u32(code, p);
  } else if (fmt == "atom_u8") {
    in.atom = get_u32(code, p);
    in.arg = code[p + 4];
  } else if (fmt == "atom_u16") {
    in.atom = get_u32(code, p);
    in.arg = get_u16(code, p + 4);
  } else if (fmt == "atom_label_u8") {
    // the with_* and scope forms: their label is not decoded (they are refused by the lowering)
    in.atom = get_u32(code, p);
    in.arg = code[p + 8];
  } else if (fmt == "atom_label_u16") {
    in.atom = get_u32(code, p);
    in.arg = get_u16(code, p + 8);
  } else {
    throw std::runtime_error("operand format '" + fmt + "' of " + in.name + " is not decoded");
  }
  return in;
}

}  // namespace qjs
