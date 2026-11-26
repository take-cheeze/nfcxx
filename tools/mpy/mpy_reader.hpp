// MicroPython .mpy reader (format version 6, the bytecode-only kind): the header, the qstr and object tables, and the tree
// of raw code objects with their bytecode. It follows py/persistentcode.c of MicroPython v1.29.0 (the pin in
// docs/notes/mpy-pathb.md); the layout of a function's data follows py/bc.c and py/bc.h. Plain C++17, no dependencies.
//
// Native code (an arch in the header) is refused: only the bytecode kind is read.
#ifndef NFCXX_MPY_READER_HPP
#define NFCXX_MPY_READER_HPP

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace mpy {

// A constant object of the module (persistentcode.c's load_obj).
struct Obj {
  enum class Kind { None, False, True, Ellipsis, Str, Bytes, Int, Float, Complex, Tuple };
  Kind kind = Kind::None;
  std::string text;          // Str, Bytes, and the digits of Int, Float and Complex
  std::vector<Obj> items;    // Tuple
};

// One raw code object: the function's data (prelude, code info, cells, bytecode) and its children.
struct RawCode {
  std::vector<uint8_t> data;
  std::vector<RawCode> children;
};

struct Module {
  unsigned version = 0;
  unsigned flags = 0;
  unsigned small_int_bits = 0;
  std::vector<std::string> qstrs;   // the module's qstr table; bytecode operands index it
  std::vector<Obj> objs;            // the constant table
  RawCode top;
};

// Reads a whole .mpy image. Throws std::runtime_error with the reason on bad or unsupported input.
Module load(const uint8_t *data, size_t size);

// The prelude of a function's data (py/bc.h's MP_BC_PRELUDE_*): the state sizes, the scope flags and the argument counts,
// and where the code info, the cell list and the bytecode start.
struct Prelude {
  unsigned n_state = 0, n_exc_stack = 0, scope_flags = 0, n_pos_args = 0, n_kwonly_args = 0, n_def_pos_args = 0;
  size_t n_info = 0, n_cell = 0;
  size_t info_offset = 0;     // the code info: the source qstr, the argument names, and the line table
  size_t cells_offset = 0;    // n_cell bytes: the local index of each cell argument
  size_t code_offset = 0;     // the bytecode
};

Prelude read_prelude(const std::vector<uint8_t> &data);

// One instruction (persistentcode.c's mp_opcode_decode): its opcode, its operand format (MP_BC_FORMAT_*), its size in
// bytes, and the decoded operand. The operand of a multi-opcode (LOAD_FAST_MULTI and the rest) is in the opcode byte.
struct Insn {
  size_t offset = 0;
  uint8_t opcode = 0;
  uint8_t format = 0;
  uint8_t size = 0;
  int64_t arg = 0;
  uint8_t extra = 0;   // the extra byte of MAKE_CLOSURE and the others that have one
};

// Decodes the bytecode from its start to its end. Throws if an instruction runs past the end.
std::vector<Insn> decode_code(const uint8_t *code, size_t n);

}  // namespace mpy

#endif  // NFCXX_MPY_READER_HPP
