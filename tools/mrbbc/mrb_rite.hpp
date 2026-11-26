// mruby RITE binary reader (format 04.00, the RITE0400 files that mrbc 4.0.0 writes). See docs/notes/mrbbc-pathb.md.
//
// read_module() parses the binary header, the IREP section (the irep tree with its pools, symbols, catch tables and
// iseq bytes), and the optional DBG and LVAR sections, and checks that the file ends exactly after the END footer.
// decode_iseq() splits an irep's iseq into instructions (opcode, EXT prefix, operands). Layouts follow mruby's
// src/dump.c (writer) and src/load.c (reader); the operand widths follow include/mruby/ops.h (FETCH_*_n macros).
// Multi-byte integers are big-endian, except the bits of a float constant (little-endian, as dump.c writes them).
#ifndef NFCXX_MRB_RITE_HPP
#define NFCXX_MRB_RITE_HPP

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace mrb {

// Opcode numbers, from the generated table mrb_opcodes.inc (ops.h order).
enum Opcode {
#define OPCODE(name, fmt) OP_##name,
#include "mrb_opcodes.inc"
#undef OPCODE
  NUM_OPCODES
};

// The mnemonic of an opcode number, or "?" when it is out of range.
const char *op_name(int op);

struct ReadError : std::runtime_error {
  using std::runtime_error::runtime_error;
};

// A constant of the pool (dump.c's write_pool_block). Strings keep their bytes, big integers their raw record.
struct Pool {
  enum class Kind { Int, Float, Str, BigInt };
  Kind kind = Kind::Int;
  std::int64_t i = 0;  // Int
  double f = 0.0;      // Float
  std::string s;       // Str: the bytes; BigInt: the record (length byte, sign byte, magnitude)
};

// One catch handler: type 0 (rescue) or 1 (ensure), the iseq range [begin, end) and the jump target (byte offsets).
struct Catch {
  std::uint8_t type = 0;
  std::uint32_t begin = 0, end = 0, target = 0;
};

// One irep: the header counts, the iseq bytes, the catch table, the pool, the symbols (sym_null marks a null symbol,
// which dump.c writes as length 0xFFFF), the local variable names when an LVAR section gives them (lv[i] names register
// i + 1; "" when the file has none), and the child ireps.
struct Irep {
  std::uint16_t nlocals = 0, nregs = 0;
  std::vector<std::uint8_t> iseq;  // ilen bytes
  std::vector<Catch> catches;
  std::vector<Pool> pool;
  std::vector<std::string> syms;
  std::vector<bool> sym_null;
  std::vector<std::string> lv;
  bool has_lv = false;
  bool has_dbg = false;
  std::vector<Irep> reps;
};

struct Module {
  std::uint32_t binary_size = 0;
  std::string compiler;          // "MATZ"
  std::string compiler_version;  // "0000"
  Irep root;                     // the top-level irep (the main program is irep 0)
};

// Reads a whole RITE file. Throws ReadError with the reason (a message that names the offset) for anything malformed.
Module read_module(const std::uint8_t *data, std::size_t size);

// One instruction. An EXT1..EXT3 prefix is an instruction of its own (name "EXT1", no operands); the instruction it
// widens follows it with ext set to 1..3, and its operands are as wide as the FETCH_*_n macro of that opcode.
struct Insn {
  std::size_t pc = 0;   // byte offset of the first byte in the iseq
  std::size_t len = 0;  // bytes
  int op = 0;           // opcode number
  int ext = 0;          // 0 unless this instruction is widened by a prefix
  std::string name;     // mnemonic
  std::vector<std::uint32_t> args;  // operands in order, unsigned as read; the signed ones are reinterpreted by the op
};

// The instructions of an irep's iseq, in order. Throws ReadError for an unknown opcode, an EXT prefix that is not
// followed by a widened instruction, or an instruction that runs past the end.
std::vector<Insn> decode_iseq(const Irep &irep);

// The operand widths (in bits) of an opcode's format under an EXT prefix (0 for none): exposed for the tests.
std::vector<int> operand_widths(int op, int ext);

}  // namespace mrb

#endif  // NFCXX_MRB_RITE_HPP
