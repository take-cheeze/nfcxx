// Ruby 3.3 binary iseq reader (the "YARB" format of RubyVM::InstructionSequence#to_binary; compile.c's ibf_* functions of
// Ruby 3.3.6). See tools/yarvbc/yarv_lower.cpp for what is lowered from it.
//
// read_module() checks the header (magic, format version 3.3, endianness, word size, the size of the file), then reads
// every iseq record of the iseq list: the body fields, the instruction stream, the local table, the call-data table
// (ci entries) and the catch table. An instruction the reader does not know the operands of is refused (Refused, the
// "refused: ..." message), so a program is refused rather than misread.
#ifndef NFCXX_YARVBC_IBF_HPP
#define NFCXX_YARVBC_IBF_HPP

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace yarv {

// The format of Ruby 3.3 (RUBY_API_VERSION 3.3 is the major and minor version the header records).
constexpr std::uint32_t kFormatMajor = 3;
constexpr std::uint32_t kFormatMinor = 3;

struct ReadError : std::runtime_error {
  using std::runtime_error::runtime_error;
};

// A program the producer does not lower: an instruction, operand form, format version or table it does not handle. The
// message starts with "refused: ".
struct Refused : std::runtime_error {
  using std::runtime_error::runtime_error;
};

// vm_core.h's enum rb_iseq_type.
enum class IseqType : std::uint64_t { Top = 0, Method = 1, Block = 2, Class = 3, Rescue = 4, Ensure = 5, Eval = 6, Main = 7, Plain = 8 };

// A constant of the object table: nil, true, false, a fixnum, a float, a symbol, a string or another object type.
struct Value {
  enum class Kind { Nil, False, True, Fixnum, Float, Symbol, String, Other };
  Kind kind = Kind::Other;
  std::int64_t i = 0;     // Fixnum
  double f = 0.0;         // Float
  std::string s;          // Symbol (its name) and String (its bytes)
  int type = 0;           // Other: the T_xxx type of the object (a Bignum is 0x0a)
};

// A call-data entry (the call info of one CALL_DATA operand): the method name, vm_call_flag bits, the positional argument
// count and the number of keyword arguments. present is false for a call-data slot with no call info.
struct CallInfo {
  bool present = false;
  std::string mid;
  std::uint64_t flag = 0;
  std::uint64_t argc = 0;
  std::uint64_t kwlen = 0;
};

// One instruction. The operands are in order. Their meaning follows the instruction's kind (the table in yarv_ibf.cpp):
// a value or symbol operand is an object index (resolve it with Module::object), a CALL_DATA operand is an index into the
// iseq's calls, an ISEQ operand is an index into Module::iseqs (-1 for none), and a number operand is the raw value (a local
// index, a level, or a jump target as a word offset).
struct Insn {
  std::size_t pc = 0;   // word offset of the opcode in the iseq
  std::size_t len = 0;  // words: the opcode and one word per operand (a CALL_DATA operand takes a word too)
  int op = 0;           // opcode number
  std::string name;     // mnemonic
  std::vector<std::uint64_t> operands;
};

struct Iseq {
  IseqType type = IseqType::Plain;
  std::vector<std::int64_t> children;   // the iseqs the instructions name (a send's block, a definemethod's body)
  std::uint64_t words = 0;              // iseq_size: the instruction stream in words
  std::uint64_t lead_num = 0;           // required parameters
  std::uint64_t param_flags = 0;        // bit 0 has_lead, 1 has_opt, 2 has_rest, 3 has_post, 4 has_kw, 5 has_kwrest, 6 has_block
  std::uint64_t stack_max = 0;
  std::uint64_t catch_count = 0;        // entries of the catch table (the reader does not decode them)
  std::string label;                    // base_label of the iseq (its name)
  std::vector<std::string> locals;      // the local table: names by table index
  std::vector<CallInfo> calls;          // the call-data table, by call-data index
  std::vector<Insn> insns;              // the instruction stream
};

struct Module {
  std::uint32_t minor = 0;
  std::vector<Iseq> iseqs;
  std::vector<Value> objects;           // the object table, by object index (index 0 is nil)
  std::size_t root = 0;                 // the top iseq: the one no instruction names

  // The constant of an object index (Value::Kind::Nil for index 0).
  const Value &object(std::uint64_t index) const;
};

// Reads a whole YARB file. Throws Refused for another format version, or an instruction the reader does not decode;
// ReadError for a malformed file.
Module read_module(const std::uint8_t *data, std::size_t size);

}  // namespace yarv

#endif  // NFCXX_YARVBC_IBF_HPP
