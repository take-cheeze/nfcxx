// The type, layout, immediate and constant-initializer helpers of scripts/pathb-ptx-emit.rb (phase 2 of the port).
// Each function is the Ruby function of the same name, with the same results: a Ruby `raise Refused` is a thrown
// Refused, a `raise BadIR` is a thrown BadIR, and a Ruby `return nil` is an empty std::optional.
#pragma once

#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "ir.hpp"

// A node this emitter does not handle (the Ruby's Refused, exit status 3).
struct Refused : std::runtime_error {
  using std::runtime_error::runtime_error;
};

using i128 = __int128;

// An IR type, as the Ruby's ["int", size, signed, bool], ["float", size], ["ptr", nil] and ["void"]. size is -1 where
// the Ruby value is nil (a pointer, void).
struct Ty {
  std::string kind;
  int size = -1;
  bool is_signed = false;
  bool is_bool = false;
};

// scalar_const_array_init's result: [ptype, "{v0,...}", count].
struct ArrInit {
  std::string ptype;
  std::string body;
  i128 count = 0;
};

// byte_const_init's result: [".b8", "{b0,...}", size].
struct ByteInit {
  std::string ptype;
  std::string body;
  i128 size = 0;
};

// The integer value of an atom (decimal, or hexadecimal with 0x, with an optional minus). Throws BadIR otherwise.
i128 as_int(const Node *x);
// The signed 64-bit value with the bit pattern of n.
i128 signed64(i128 n);
// The decimal text of an integer.
std::string i128_text(i128 v);

Ty parse_type(const Node *x);
int type_size(const Ty &t);
std::string reg_class(const Ty &t);
bool asm_operand_ok(const Ty &t);
std::string asm_class(const Ty &t);
std::string ptx_type(const Ty &t);
std::string mem_type(const Ty &t);
std::string bits_type(const Ty &t);
std::string ptx_sym(const std::string &name);
// The PTX symbol of the string constant name (the Ruby's ptx_sym(STRING_PREFIX + name)).
std::string string_const_sym(const std::string &name);
std::string float_lit(const std::string &text, const Ty &t);
std::string bool_const_setp(const std::string &t, const std::string &v);
std::optional<uint64_t> float32_bits(const std::string &text);
// [ptype, literal] of a scalar constant initializer, or nullopt (see the Ruby function).
std::optional<std::vector<std::string>> scalar_const_init(const Node *init, const std::string &name, i128 size);
std::optional<ArrInit> scalar_const_array_init(const Node *ty, const Node *init, const std::string &name, i128 size);
std::optional<ByteInit> byte_const_init(const Node *init, const std::string &name, i128 size);
bool all_zero_init(const Node *init, i128 size);
std::string imm(const Ty &t, i128 v);
