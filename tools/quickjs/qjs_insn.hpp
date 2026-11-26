// Decoding of one QuickJS instruction: the opcode's size and stack effect from qjs_tables.inc, and its operands by the
// operand format (OP_FMT_* in quickjs.c). Jump targets are absolute byte offsets in the function's code: an offset is
// relative to the first byte of its operand, as the interpreter's `pc += offset` does.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

#include "qjs_bc.hpp"

namespace qjs {

struct Insn {
  std::size_t pc = 0;            // the opcode's offset
  int op = 0;                    // the opcode number (the DEF order of quickjs-opcode.h)
  std::string name;
  int size = 1, npop = 0, npush = 0;
  std::int64_t arg = 0;          // the operand: loc/arg/var_ref/const/u8/u16 index or count, or the immediate of push_i*
  std::uint32_t atom = 0;        // atom operands: the atom number (see Bc::atom_name)
  std::int64_t target = -1;      // jump operands: the absolute target offset; -1 when the instruction has none
  std::size_t next() const { return pc + static_cast<std::size_t>(size); }
};

// Decodes the instruction at `pc` of `code`. Throws std::runtime_error for an opcode that is not in the table or an
// instruction that runs past the end of the code.
Insn decode_insn(const std::vector<std::uint8_t> &code, std::size_t pc);

}  // namespace qjs
