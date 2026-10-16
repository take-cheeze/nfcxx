// The module level of scripts/pathb-ptx-emit.rb's emit_module: the functions of the module, the ones the kernels reach, their
// order and their text, after the declarations (module_decls.cpp). The Ruby's refusals and exit statuses are the same.
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "emit_fn.hpp"
#include "emit_module.hpp"
#include "ir.hpp"
#include "lower_types.hpp"
#include "module_decls.hpp"

namespace {

std::string head_of(const Node &x) {
  if (x.kind != Node::List || x.items.empty() || x.items[0].kind != Node::Atom) return "";
  return x.items[0].text;
}

// The names of the functions a form calls directly (the `&"name"` callee of every `call`, and the function addresses),
// in order, with repeats (the Ruby's collect_calls).
void collect_calls(const Node &x, std::vector<std::string> &acc) {
  // a function whose address is taken (a function pointer value) is reachable too: it must be emitted
  if (x.kind == Node::Sym && x.sig == '&') {
    acc.push_back(x.text);
    return;
  }
  if (x.kind != Node::List) return;
  if (head_of(x) == "call" && x.items.size() > 2 && x.items[2].kind == Node::Sym && x.items[2].sig == '&')
    acc.push_back(x.items[2].text);
  for (const Node &y : x.items) collect_calls(y, acc);
}

// The callees of a function that are functions of the module, in order, without repeats.
std::vector<std::string> callees_of(const Node &form, const std::map<std::string, Fn *> &by_name) {
  std::vector<std::string> all, out;
  collect_calls(form, all);
  std::set<std::string> seen;
  for (const std::string &c : all)
    if (by_name.count(c) && seen.insert(c).second) out.push_back(c);
  return out;
}

// Raises Refused when a call cycle is reachable from name (PTX has no recursion in our lowering).
void check_recursion(const std::string &name, const std::map<std::string, std::vector<std::string>> &callees,
                     std::map<std::string, int> &state) {
  int s = state.count(name) ? state[name] : 0;  // 0 new, 1 open, 2 done
  if (s == 2) return;
  if (s == 1) throw Refused("recursive call of " + name);
  state[name] = 1;
  auto it = callees.find(name);
  if (it != callees.end())
    for (const std::string &c : it->second) check_recursion(c, callees, state);
  state[name] = 2;
}

// A function whose form has a static linkage member (the Ruby's static_fn?).
bool static_fn(const Fn &fn) {
  for (const Node &x : fn.form().items)
    if (x.kind == Node::List && head_of(x) == "static") return true;
  return false;
}

// Insertion-ordered map from a key to a value, as the Ruby hash that the callers iterate in order.
struct OrderedMap {
  std::vector<std::pair<std::string, std::string>> entries;
  std::map<std::string, size_t> index;
  void set(const std::string &k, const std::string &v) {
    auto it = index.find(k);
    if (it != index.end()) {
      entries[it->second].second = v;
    } else {
      index[k] = entries.size();
      entries.push_back({k, v});
    }
  }
};

}  // namespace

std::string emit_module(const std::string &src, const std::string &sm, const std::vector<std::string> &kernels_in) {
  // With kernels, only the functions they reach are parsed (parse_module_forms); the fn-indices give the position of each
  // parsed function among the module's functions.
  ModuleForms split;
  bool have_idx = parse_module_forms(src, kernels_in, split);
  std::vector<Node> forms = have_idx ? std::move(split.forms) : parse_forms_chunked(src);
  std::vector<size_t> fn_indices = have_idx ? split.fn_indices : std::vector<size_t>();

  // The module's declarations first: they name the data symbols the functions look their @name operands up in. (The
  // declarations' text is written after the functions are lowered, when the flags are known.)
  ModuleSymbols syms;
  emit_module_decls(src, false, false, &syms);

  std::vector<std::unique_ptr<Fn>> fns;
  size_t fn_next = 0;
  for (const Node &f : forms) {
    std::string h = head_of(f);
    if (h == "ir-module") continue;
    if (h == "function") {
      size_t idx = have_idx ? fn_indices[fn_next] : fns.size();
      fns.push_back(std::make_unique<Fn>(f, idx));
      fn_next++;
    } else if (h == "data" || h == "abi-type" || h == "global") {
      // data, aggregate and global forms: the declarations (emit_module_decls)
      continue;
    } else {
      throw Refused("top-level form " + (h.empty() ? form_text(f) : h));
    }
  }
  if (fns.empty()) throw BadIR("no function in the IR");

  // A listed kernel is named as the source names it (cuda-rewrite.rb --kernels writes plain names). A C++ function's IR
  // name is its Itanium mangled name, so a plain name matches by the rule scripts/cuda-embed.rb uses.
  std::vector<std::string> kernels;
  for (const std::string &k : kernels_in) {
    std::vector<std::string> hits;
    for (const auto &fn : fns) {
      const std::string &n = fn->name();
      if (n == k || n.rfind("_Z" + std::to_string(k.size()) + k, 0) == 0) hits.push_back(n);
    }
    if (hits.empty()) throw BadIR("no function named " + k + " in the IR");
    if (hits.size() > 1) throw BadIR(std::to_string(hits.size()) + " functions named " + k + " in the IR");
    kernels.push_back(hits[0]);
  }

  // Keep the functions reachable from the kernels: the listed kernels, or else the functions that are not static and
  // not called. A static function that nothing reaches is dead code (a C++ header's unused inline helper): it is not
  // emitted, rather than taken for a kernel (which could not return its value).
  std::map<std::string, Fn *> pre_by;
  for (const auto &fn : fns) pre_by[fn->name()] = fn.get();
  std::map<std::string, std::vector<std::string>> pre_callees;
  for (const auto &fn : fns) pre_callees[fn->name()] = callees_of(fn->form(), pre_by);
  std::set<std::string> pre_called;
  for (const auto &fn : fns)
    for (const std::string &c : pre_callees[fn->name()]) pre_called.insert(c);
  std::vector<std::string> roots;
  if (kernels.empty()) {
    for (const auto &fn : fns)
      if (!static_fn(*fn) && !pre_called.count(fn->name())) roots.push_back(fn->name());
  } else {
    roots = kernels;
  }
  std::set<std::string> live;
  std::vector<std::string> stack = roots;
  while (!stack.empty()) {
    std::string n = stack.back();
    stack.pop_back();
    if (live.count(n) || !pre_by.count(n)) continue;
    live.insert(n);
    for (const std::string &c : pre_callees[n]) stack.push_back(c);
  }
  std::vector<std::unique_ptr<Fn>> kept;
  for (auto &fn : fns)
    if (live.count(fn->name())) kept.push_back(std::move(fn));
  fns = std::move(kept);

  std::map<std::string, Fn *> by_name;
  for (const auto &fn : fns) by_name[fn->name()] = fn.get();
  std::map<std::string, std::vector<std::string>> callees;
  for (const auto &fn : fns) callees[fn->name()] = callees_of(fn->form(), by_name);
  OrderedMap called;  // callee => its caller (the last caller in order)
  for (const auto &fn : fns)
    for (const std::string &c : callees[fn->name()]) called.set(c, fn->name());
  if (kernels.empty()) {
    for (const auto &fn : fns) fn->kernel = called.index.count(fn->name()) == 0;
  } else {
    for (const std::string &k : kernels)
      if (!by_name.count(k)) throw BadIR("no function named " + k + " in the IR");
    for (const auto &fn : fns) {
      fn->kernel = false;
      for (const std::string &k : kernels)
        if (k == fn->name()) fn->kernel = true;
    }
    for (const auto &[c, caller] : called.entries)
      if (by_name[c]->kernel) throw Refused("kernel " + c + " is called by " + caller);
  }

  std::map<std::string, int> state;
  for (const auto &fn : fns) check_recursion(fn->name(), callees, state);

  // The functions of the module, for the calls and the function addresses: their kernel flags are final now.
  std::map<std::string, bool> functions;
  for (const auto &fn : fns) functions[fn->name()] = fn->kernel;
  for (const auto &fn : fns) {
    fn->module_fns = &by_name;
    fn->mod = &syms;
    fn->functions = &functions;
  }
  for (const auto &fn : fns) fn->compile();

  bool uses_dynshared = false, uses_printf = false;
  for (const auto &fn : fns) {
    uses_dynshared = uses_dynshared || fn->uses_dynshared;
    uses_printf = uses_printf || fn->uses_printf;
  }
  std::string out = "// Generated by scripts/pathb-ptx-emit.rb from the Path B IR; do not edit.\n";
  out += ".version 8.0\n.target " + sm + "\n.address_size 64\n\n";
  out += emit_module_decls(src, uses_dynshared, uses_printf, nullptr);

  // PTX needs a callee declared before its first call: emit the functions callee first (depth-first post-order).
  std::vector<const Fn *> ordered;
  std::set<std::string> seen;
  std::function<void(const std::string &)> visit = [&](const std::string &name) {
    if (!seen.insert(name).second) return;
    auto it = callees.find(name);
    if (it != callees.end())
      for (const std::string &c : it->second) visit(c);
    ordered.push_back(by_name[name]);
  };
  for (const auto &fn : fns) visit(fn->name());
  for (const Fn *fn : ordered) out += fn->text() + "\n";
  return out;
}
