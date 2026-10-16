// One function of the module: class Fn of scripts/pathb-ptx-emit.rb (the header and parameters, the statements, the calls
// to the module's functions, printf, the function's text). It is a FnCtx, so the expression lowering (arith, memory,
// call, asm) is the same code the --eval-arith differentials check.
#pragma once

#include <map>
#include <optional>
#include <string>
#include <vector>

#include "ir.hpp"
#include "lower_arith.hpp"
#include "lower_types.hpp"

class Fn : public FnCtx {
 public:
  // form is the function's form in the module's forms (it must outlive the Fn); index is its position among the module's
  // functions (the frame's name, __local_depot<index>).
  Fn(const Node &form, size_t index);

  const std::string &name() const { return name_; }
  const Node &form() const { return *form_; }

  bool kernel = true;                  // an entry point (the module's kernels), else a .func
  std::vector<Ty> params;              // the IR types of the parameters, in order
  std::optional<Ty> ret;               // the return type, nullopt for void
  bool uses_dynshared = false;         // the dynamic shared symbol is used (the module declares it)
  bool uses_printf = false;            // vprintf is called (the module declares it)
  const std::map<std::string, Fn *> *module_fns = nullptr;  // the module's functions by name (the calls)

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
  void scalar_u32(const std::string &name, const Node &x, const std::string &dest, const Ty &ty);
  void float_builtin(const std::string &name, const Node &x, const std::string &dest, const Ty &ty);
  void float_to_int_builtin(const std::string &name, const Node &x, const std::string &dest, const Ty &ty);
  void half_builtin(const std::string &name, const Node &x, const std::string &dest, const Ty &ty);
  std::string ret_bits(const Ty &t) const;
  void label(const std::string &l);
  std::string named_label(const std::string &name);

  const Node *form_;
  size_t index_;
  std::string name_;
  bool setup_done_ = false;
  long long frame_ = 0;                // the frame's size in bytes (the slots, the printf buffers)
  int ncall_ = 0;                      // the calls of module functions (their parameter names)
  std::vector<const Node *> body_;     // the statements (the forms that are not the header)
  std::vector<std::string> prologue_;  // the frame address, the parameter loads
  // [continue label (empty for a switch), break label] of the enclosing loops and switches, innermost last
  std::vector<std::pair<std::string, std::string>> loops_;
  std::map<std::string, std::string> named_labels_;  // the IR labels => their PTX labels
};
