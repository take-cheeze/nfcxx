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
  std::vector<long long> agg_off_;     // per parameter: the frame offset of its byval copy (or of the sret object)
  int ncall_ = 0;                      // the calls of module functions (their parameter names)
  std::vector<const Node *> body_;     // the statements (the forms that are not the header)
  std::vector<std::string> prologue_;  // the frame address, the parameter loads
  // [continue label (empty for a switch), break label] of the enclosing loops and switches, innermost last
  std::vector<std::pair<std::string, std::string>> loops_;
  std::map<std::string, std::string> named_labels_;  // the IR labels => their PTX labels
};
