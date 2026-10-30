// One function of the module: class Fn of scripts/pathb-ptx-emit.rb (the header and parameters, the statements, the calls
// to the module's functions, printf, the function's text). It is a FnCtx, so the expression lowering (arith, memory,
// call, asm) is the same code the --eval-arith differentials check.
#pragma once

#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "ir.hpp"
#include "lower_arith.hpp"
#include "lower_types.hpp"

// The size and alignment of a struct or union passed or returned by value: its (abi-type) form of the module.
struct AggShape {
  long long size = 0;
  long long align = 1;
  bool empty = false;  // (empty): no data, so it is not passed at all (no PTX parameter or result), as nvcc does
};

// The module's (abi-type NAME SIZE ALIGN SHAPE) forms by name (the shape is not needed: the value is copied by bytes).
// Throws BadIR when a form is malformed.
std::map<std::string, AggShape> abi_shapes(const std::vector<Node> &forms);

// What the uses of an alias do (Fn::scan_aliases): the fields it reaches (offset and PTX type => type), the pointer slots
// that hold it, and whether every use is one the pass takes (ok).
struct AliasFields {
  bool ok = true;
  std::map<std::pair<long long, std::string>, Ty> fields;
  std::set<std::string> carriers;
};

class Fn : public FnCtx {
 public:
  // name is the function's IR name; index is its position among the module's functions (the frame's name,
  // __local_depot<index>); load parses the function's form. The form is parsed when the function is set up (by its own
  // compile, or by a call to it from a function being compiled) and kept until release().
  using Loader = std::function<std::unique_ptr<Node>()>;
  Fn(std::string name, size_t index, Loader load);

  const std::string &name() const { return name_; }
  // Drops the form and the body once the function is compiled and its text is taken: neither is needed again.
  void release();

  bool kernel = true;                  // an entry point (the module's kernels), else a .func
  std::vector<Ty> params;              // the IR types of the parameters, in order
  std::optional<Ty> ret;               // the return type, nullopt for void
  bool uses_dynshared = false;         // the dynamic shared symbol is used (the module declares it)
  bool uses_printf = false;            // vprintf is called (the module declares it)
  const std::map<std::string, Fn *> *module_fns = nullptr;  // the module's functions by name (the calls)
  // The module's aggregates by name (its (abi-type) forms): the shapes of the struct and union parameters and results.
  const std::map<std::string, AggShape> *aggs = nullptr;
  // Per parameter: the shape of a struct or union passed by value (the byval parameters), set for the hidden result too.
  std::vector<std::optional<AggShape>> agg_params;
  // The shape of the struct the function returns through its hidden result (sret), which is its first parameter: the
  // result is a .param array of the device function (nvcc's func_retval0), set when the function returns a struct.
  std::optional<AggShape> sret;

  // The header: the return type, the parameters and the frame slots. Idempotent.
  void setup();
  // The body, after the prologue: the registers of the parameters and the statements.
  void compile();
  // The function's PTX text (the .entry or .func, with its declarations and body).
  std::string text() const;

 private:
  void stmt(const Node &s);
  void rval(const Node &x, const std::string &dest, const Ty &dty);
  void call_value(const Node &x, const std::string &dest, const Ty &ty);
  void call_site(const Node &x, const std::string &dest, const Ty *ty);
  // --inline=device: whether the callee's body is compiled at its calls (not a kernel, no struct or bool parameter, no
  // printf in its body).
  bool inline_ok(const Fn *callee) const;
  // Whether x writes memory only through the function's own slots, directly or in the module functions it calls (to a
  // depth). body_writes_only_slots: the same for a whole function body.
  bool writes_only_slots(const Node &x, int depth) const;
  bool body_writes_only_slots(const Fn *f, int depth) const;
  // The body of the callee at the call x, with this function's state for its own registers, slots and labels; its
  // returns write dest (the call's register, or "" for a statement) and branch to the end of the inlined body.
  void inline_call(Fn *callee, const Node &x, const std::string &dest);
  void printf_call(const Node &x, const std::string &dest, const Ty &ty);
  AggShape aggregate(const Node &t) const;
  long long alloc_frame(long long size, long long align);
  std::string param_name(size_t k) const;
  // Whether parameter k is a PTX .param of the function: not the sret result and not an empty object.
  bool is_ptx_param(size_t k) const;
  void emit_return();
  void scalar_u32(const std::string &name, const Node &x, const std::string &dest, const Ty &ty);
  void float_builtin(const std::string &name, const Node &x, const std::string &dest, const Ty &ty);
  void float_to_int_builtin(const std::string &name, const Node &x, const std::string &dest, const Ty &ty);
  void half_builtin(const std::string &name, const Node &x, const std::string &dest, const Ty &ty);
  std::string ret_bits(const Ty &t) const;
  void label(const std::string &l);
  std::string named_label(const std::string &name);

  Loader load_;
  std::unique_ptr<Node> form_;
  size_t index_;
  std::string name_;
  bool setup_done_ = false;
  long long frame_ = 0;                // the frame's size in bytes (the slots, the printf buffers)
  long long frame_align_ = 8;          // the frame's alignment (the largest slot alignment, at least 8)
  bool sp_set_ = false;                // the frame pointer is set up (compile): the frame is declared even when it is empty
  std::map<std::string, Ty> slot_types_;  // slot name => its type (the slot form's TYPE)
  std::map<std::string, long long> slot_sizes_;  // slot name => its size in bytes
  std::map<std::string, long long> slot_aligns_;  // slot name => its alignment (the frame keeps the offset aligned to it)
  std::vector<long long> agg_off_;     // per parameter: the frame offset of its byval copy (or of the sret object)
  int ncall_ = 0;                      // the calls of module functions (their parameter names)
  std::vector<const Node *> body_;     // the statements (the forms that are not the header)
  std::vector<std::string> prologue_;  // the frame address, the parameter loads
  // [continue label (empty for a switch), break label] of the enclosing loops and switches, innermost last
  std::vector<std::pair<std::string, std::string>> loops_;
  std::map<std::string, std::string> named_labels_;  // the IR labels => their PTX labels
  std::map<const Fn *, int> inline_base_;  // the callee => its frame region in this function (inline_call shares it)
  int inline_depth_ = 0;                             // the inlined bodies being compiled (their calls inline too, to a depth)
  std::string inline_dest_;                          // the register of the inlined call's value ("" for a statement)
  std::string inline_end_;                           // the label after the inlined body
  std::optional<Ty> inline_ret_;                     // the inlined function's return type
  // The registers whose value is the address of a function of the module ((let %N T (bitcast T &"f"))): the
  // constructor argument of __cxa_vec_ctor, which is called directly (the emitter has no indirect calls).
  std::map<std::string, std::string> fn_values_;
  void vec_ctor(const Node &x);
  // --promote=slots: the slots of body (with their types) that live in registers, and their registers in promoted.
  void promote_slots(const std::vector<const Node *> &body, const std::map<std::string, Ty> &types);
  // --unroll=loops: the loop after the init store `store T $name START` is compiled once per iteration when its trip
  // count is a constant (the shape the front end gives a for loop). False, with nothing emitted, when it is not.
  bool unroll_loop(const Node &init, const Node &loop);
  bool unroll_next_ = false;  // the statement that follows a __nfcxx_unroll() marker (--unroll=loops)
  // --struct-slots: the struct slots of this function whose fields live in registers (sra_slots, sra_fields), and the
  // pointer slots that carry their addresses (carrier_slots).
  void plan_struct_slots();
  // The uses of the aliases (the slots of seed_slots, or the registers of seed_regs, at offset 0) in body: the fields
  // they reach, the pointer slots they are stored in, and ok when every use is one of the forms the pass takes.
  void scan_aliases(const std::vector<const Node *> &body, const std::set<std::string> &seed_slots,
                    const std::set<std::string> &seed_regs, int depth, AliasFields &out) const;
  // The body of a function's form (its statements, without the header), read from f's form or a fresh load into holder.
  std::vector<const Node *> body_forms(const Fn *f, std::unique_ptr<Node> &holder) const;
};
