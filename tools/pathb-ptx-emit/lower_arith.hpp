// The per-function emission state of scripts/pathb-ptx-emit.rb's class Fn (the body lines, the register and label
// counters, the IR register map, the slots) and the arithmetic, comparison and conversion lowering that runs against
// it: the Ruby's rval branches for wadd..cf2i and the lt..ne comparisons, and their helpers (checked_div,
// checked_shift, compare, int_convert, float_to_int, canon); the memory forms (lower_mem.cpp) and the @name operands
// (module_operand). Phase 3 of the port; the call, asm, atomic and warp lowering are not here yet and refuse by name.
#pragma once

#include <map>
#include <string>
#include <vector>

#include "ir.hpp"
#include "lower_types.hpp"
#include "module_decls.hpp"

// An operand: its PTX text (a register, or an immediate) and its IR type (the Ruby's [text, ty]).
struct Operand {
  std::string text;
  Ty ty;
};

// An IR register: its PTX register and its IR type (the Ruby's @regs values).
struct RegInfo {
  std::string ptx;
  Ty ty;
};

// Ruby's Float#to_s (shortest round-trip digits; fixed notation for decimal exponents -3..16, else d.ddde+XX).
std::string ruby_float_s(double d);

class FnCtx {
 public:
  std::vector<std::string> lines;               // the body: each line already indented as the Ruby's emit writes it
  std::map<std::string, RegInfo> regs;          // IR register "%N" => its PTX register and type
  std::map<std::string, int> count = {{"p", 0}, {"r", 0}, {"rd", 0}, {"f", 0}, {"fd", 0}, {"h", 0}};
  int nlab = 0;
  std::map<std::string, int> slots;             // slot name => byte offset in the frame
  std::string sp = "%sp";                       // the PTX register holding the frame's generic address
  const ModuleSymbols *mod = nullptr;           // the module's data symbols (the @name operands), null when none

  void emit(const std::string &s);
  std::string fresh(const std::string &cls);
  std::string new_label();

  Operand operand(const Node &x);
  std::string reg_of(const std::string &op, const Ty &ty);
  std::string ir_reg(const std::string &name, const Ty &ty);
  void expect(const Ty &dty, const Ty &ty);

  // The Ruby's rval branches for the arithmetic, comparison and conversion forms: returns false when h is not one of
  // them (the caller then tries the other groups). dest is the PTX register the value is stored in.
  bool arith(const std::string &h, const Node &x, const std::string &dest, const Ty &dty);

  void checked_div(const std::string &op, const std::string &dest, const Ty &ty, const Node &xa, const Node &xb);
  void checked_shift(const std::string &op, const std::string &dest, const Ty &ty, const Node &xa, const Node &xb);
  void compare(const std::string &op, const std::string &dest, const Ty &ty, const Node &xa, const Node &xb);
  void int_convert(const std::string &dest, const Ty &ty, const std::string &a, const Ty &aty);
  void float_to_int(const std::string &dest, const Ty &ty, const std::string &a, const Ty &aty);
  void canon(const std::string &dest, const Ty &t);

  // The Ruby's rval branches for the memory forms: load, load.v, bitcast (to a pointer), offset and index. Returns false
  // when h is not one of them.
  bool memory(const std::string &h, const Node &x, const std::string &dest, const Ty &dty);
  // The Ruby's stmt branches for store and store.v. Returns false when h is not one of them.
  bool store_stmt(const std::string &h, const Node &s);
  // The @name operand: its address through cvta (the Ruby's operand for the module's data symbols).
  Operand module_operand(const Node &x);
};
