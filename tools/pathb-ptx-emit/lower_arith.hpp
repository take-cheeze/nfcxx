// The per-function emission state of scripts/pathb-ptx-emit.rb's class Fn (the body lines, the register and label
// counters, the IR register map, the slots) and the arithmetic, comparison and conversion lowering that runs against
// it: the Ruby's rval branches for wadd..cf2i and the lt..ne comparisons, and their helpers (checked_div,
// checked_shift, compare, int_convert, float_to_int, canon); the memory forms (lower_mem.cpp) and the @name operands
// (module_operand); and (lower_call.cpp) the device-intrinsic, warp and atomic calls and the ptx-asm statement. Phase 3
// of the port; the module-function call and printf lowering are not here yet and refuse by name.
#pragma once

#include <map>
#include <set>
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

// --f2i=convert (the .cu device path): cf2i is the GPU's conversion, as nvcc emits it (cvt.rzi saturates, NaN gives 0
// up to 32 bits; a 1- or 2-byte target converts to 32 bits and keeps the low bytes), not the range check that traps. CUDA
// code relies on it (llama.cpp's quantize_mmq_q8_1 converts NaN for an all-zero block).
extern bool g_f2i_convert;

// --int=gpu (the .cu device path): integer division and remainder by zero, INT_MIN / -1, and shift counts of the width
// or more are what the GPU does with them, as nvcc emits them (div/rem: an unspecified value; shl/shr: the count is
// clamped to the width), not the checks that trap. CUDA code relies on it (llama.cpp's flash_attn_ext_vec computes
// `sequence % ne33` with ne33 == 0 when there is no mask, and does not use the result).
extern bool g_int_gpu;

// --inline=device (the default; --inline=off turns it off): a call of a function of the module is compiled into the caller, its body at the
// call (Fn::inline_call), as nvcc inlines the __device__ helpers of a kernel. A callee the inliner does not take (a
// struct argument, a bool, a printf, a call inside the inlined body) is still a call.
extern bool g_inline_device;

// --promote=slots (the default; --promote=off turns it off): a frame slot whose every use is a whole load or store of its
// scalar type (a 4- or 8-byte integer, a pointer, a float) lives in a register (Fn::promote_slots); the frame keeps its
// bytes, the accesses are movs.
extern bool g_promote_slots;

// --unroll=loops (the default; --unroll=off turns it off): a loop that a `#pragma unroll` marks (the rewrite's __nfcxx_unroll() call) with a constant trip count is
// compiled once per iteration, the counter a constant in each copy (Fn::unroll_loop). Opt-in until it is measured.
extern bool g_unroll_loops;

// --struct-slots (default; --struct-slots=off turns it off): a struct slot whose every use is a field access, possibly
// through the address of the slot handed to an inlined function, has a register per field (Fn::plan_struct_slots).
extern bool g_struct_slots;

// Ruby's Float#to_s (shortest round-trip digits; fixed notation for decimal exponents -3..16, else d.ddde+XX).
std::string ruby_float_s(double d);

class FnCtx {
 public:
  std::vector<std::string> lines;               // the body: each line already indented as the Ruby's emit writes it
  std::map<std::string, RegInfo> regs;          // IR register "%N" => its PTX register and type
  std::map<std::string, int> count = {{"p", 0}, {"r", 0}, {"rd", 0}, {"f", 0}, {"fd", 0}, {"h", 0}};
  int nlab = 0;
  std::map<std::string, int> slots;             // slot name => byte offset in the frame
  std::map<std::string, RegInfo> promoted;      // slot name => the register its scalar lives in (--promote=slots)
  std::map<std::string, long long> const_slots; // slot name => its value in an unrolled copy of a loop (Fn::unroll_loop)
  // Struct slots in registers (--struct-slots): sra_slots are the slots whose fields are registers (sra_fields, keyed
  // "@SCOPE:SLOT|OFF|PTX"); a pointer slot that holds the address of one is a carrier (carrier_slots, its value in
  // carrier_val). An alias token "@SCOPE:SLOT+OFF" names an address in one of those slots: it is a value with no register.
  std::set<std::string> sra_slots;
  int sra_scope = 0;
  std::map<std::string, RegInfo> sra_fields;
  std::set<std::string> carrier_slots;
  std::map<std::string, std::string> carrier_val;
  // The alias token of x (a slot in sra_slots, or a register holding a token), or "" when x is not one.
  std::string token_value(const Node &x) const;
  // The alias token of a let's value (the address of a field, a copy of a token, a load of a carrier), or "".
  std::string token_rhs(const Node &v) const;
  // The field register that an access of type ty through addr reaches, or null when addr is not an alias token.
  const RegInfo *sra_field(const Node &addr, const Ty &ty) const;
  std::string sp = "%sp";                       // the PTX register holding the frame's generic address
  const ModuleSymbols *mod = nullptr;           // the module's data symbols (the @name operands), null when none
  // The module's functions by PTX name: true for a kernel (the `&name` operands are the functions' addresses), null when none.
  const std::map<std::string, bool> *functions = nullptr;

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
  // The register of a promoted slot, when addr is the slot's operand ($name); null otherwise.
  const RegInfo *promoted_slot(const Node &addr) const;
  // The Ruby's stmt branches for store and store.v. Returns false when h is not one of them.
  bool store_stmt(const std::string &h, const Node &s);
  // The @name operand: its address through cvta (the Ruby's operand for the module's data symbols).
  Operand module_operand(const Node &x);

  // The Ruby's rval "call" branch for the device intrinsics (special-register reads), the warp shuffles, votes and
  // reduce, and the atomics (device_builtin). Returns false for any other callee (the module's call_site, printf and
  // the dynamic shared address are not ported): the caller then falls through, as the Ruby does.
  bool call(const Node &x, const std::string &dest, const Ty &dty);
  // The Ruby's stmt branch for ptx-asm (ptx_asm): an inline PTX statement.
  void asm_stmt(const Node &s);

 private:
  void device_builtin(const std::string &name, const Node &x, const std::string &dest, const Ty &ty);
  void full_mask(const Node &op, const std::string &name);
};
