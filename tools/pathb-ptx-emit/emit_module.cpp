// The module level of scripts/pathb-ptx-emit.rb's emit_module (emit_module.cpp): the functions of the module, the ones the
// kernels reach, their order and their text, after the declarations (module_decls.cpp). The Ruby's refusals and exit statuses
// are the same.
//
// The module is read in two passes over its chunks (ModuleText). The first keeps each function's name, its linkage and the
// functions it names, and the non-function forms (a few kilobytes); the second keeps the text of the functions the kernels
// reach. A function's form is parsed from its text when the emitter sets it up or compiles it, and dropped after its compile.
// So the forms of the module are never all in memory, and neither is the text of the dead functions. A module that the chunks
// do not give as parse_forms_chunked gives them is read whole, as before.
#include <cstddef>
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

// Whether x is a list whose head is the atom h.
bool head_is(const Node &x, const char *h) { return head_of(x) == h; }

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

// The names collect_calls gives for a form, in order, without repeats (the filter of a callee set commutes with this).
std::vector<std::string> named_functions(const Node &form) {
  std::vector<std::string> all, out;
  collect_calls(form, all);
  std::set<std::string> seen;
  for (const std::string &c : all)
    if (seen.insert(c).second) out.push_back(c);
  return out;
}

// The callees of a function that are among the names keep accepts, in order, without repeats.
std::vector<std::string> callees_among(const std::vector<std::string> &named, const std::set<std::string> &names) {
  std::vector<std::string> out;
  for (const std::string &c : named)
    if (names.count(c)) out.push_back(c);
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

// A function of the module as the scan records it: its name, its linkage, the function names its form has, its index among
// the module's functions, and where its form is: its chunk (its text is kept by the second pass), or else the whole-text form.
struct FnRec {
  std::string name;
  bool is_static = false;   // static_fn?: a (static) child of the form
  std::vector<std::string> named;   // collect_calls' names, without repeats
  size_t index = 0;
  size_t chunk = 0;                  // the chunk of the form (chunked scans)
  std::shared_ptr<std::string> text; // the chunk's text (set by the second pass)
  const Node *whole_form = nullptr;  // the form (whole-text scans)
};

FnRec record(const Node &form, const std::string &name, size_t index) {
  FnRec r;
  r.name = name;
  r.index = index;
  r.named = named_functions(form);
  for (const Node &x : form.items)
    if (head_is(x, "static")) r.is_static = true;
  return r;
}

// The module's top-level forms, as the scan leaves them: the functions and the other forms, in order.
struct Scan {
  std::vector<FnRec> fns;
  std::vector<Node> nonfn;
};

// The scan of the module chunk by chunk: each chunk is parsed alone and dropped after it. Returns false where the chunks do not
// give the module's forms as parse_forms_chunked does (a chunk that does not parse, a function that is not a chunk of its own,
// a repeated name): the caller then reads the whole text.
bool scan_chunks(const ModuleText &text, Scan &out) {
  std::set<std::string> names;
  bool ok = true;
  text.each_chunk([&](size_t i, const std::string &chunk) {
    if (!ok) return;
    std::vector<Node> forms;
    try {
      forms = parse_text_forms(chunk);
    } catch (const BadIR &) {
      ok = false;
      return;
    }
    const bool is_fn = chunk.compare(0, 9, "(function") == 0;
    if (!is_fn) {
      for (Node &f : forms) {
        if (head_is(f, "function")) {
          ok = false;
          return;
        }
        out.nonfn.push_back(std::move(f));
      }
      return;
    }
    std::string name;
    if (forms.size() != 1 || !head_is(forms[0], "function") || !chunk_function_name(chunk, name) ||
        !names.insert(name).second) {
      ok = false;
      return;
    }
    FnRec r = record(forms[0], name, out.fns.size());
    r.chunk = i;
    out.fns.push_back(std::move(r));
  });
  return ok;
}

// The scan of the whole module's forms (parse_forms_chunked's), where the functions' forms stay in whole.
void scan_whole(std::vector<Node> &whole, Scan &out) {
  for (size_t k = 0; k < whole.size(); k++) {
    if (head_is(whole[k], "function")) {
      const Node &form = whole[k];
      std::string name = form.items.size() > 1 ? form.items[1].text : "";
      FnRec r = record(form, name, out.fns.size());
      r.whole_form = &form;
      out.fns.push_back(std::move(r));
    } else {
      out.nonfn.push_back(std::move(whole[k]));
    }
  }
}

}  // namespace

void emit_module(const ModuleText &text, const std::string &sm, const std::vector<std::string> &kernels_in,
                 const std::function<void(const std::string &)> &sink) {
  Scan scan;
  std::vector<Node> whole;
  const bool chunked = scan_chunks(text, scan);
  if (!chunked) {
    scan = Scan();
    whole = parse_forms_chunked(text.whole());
    scan_whole(whole, scan);
  }

  // The module's declarations first: they name the data symbols the functions look their @name operands up in. (The
  // declarations' text is written after the functions are lowered, when the flags are known.)
  ModuleSymbols syms;
  emit_module_decls(scan.nonfn, false, false, &syms);
  if (scan.fns.empty()) throw BadIR("no function in the IR");

  // A listed kernel is named as the source names it (cuda-rewrite.rb --kernels writes plain names). A C++ function's IR
  // name is its Itanium mangled name, so a plain name matches by the rule scripts/cuda-embed.rb uses.
  std::vector<std::string> kernels;
  for (const std::string &k : kernels_in) {
    std::vector<std::string> hits;
    for (const FnRec &fn : scan.fns) {
      const std::string &n = fn.name;
      if (n == k || n.rfind("_Z" + std::to_string(k.size()) + k, 0) == 0) hits.push_back(n);
    }
    if (hits.empty()) throw BadIR("no function named " + k + " in the IR");
    if (hits.size() > 1) throw BadIR(std::to_string(hits.size()) + " functions named " + k + " in the IR");
    kernels.push_back(hits[0]);
  }

  // Keep the functions reachable from the kernels: the listed kernels, or else the functions that are not static and
  // not called. A static function that nothing reaches is dead code (a C++ header's unused inline helper): it is not
  // emitted, rather than taken for a kernel (which could not return its value).
  std::set<std::string> all_names;
  for (const FnRec &fn : scan.fns) all_names.insert(fn.name);
  std::map<std::string, std::vector<std::string>> pre_callees;
  for (const FnRec &fn : scan.fns) pre_callees[fn.name] = callees_among(fn.named, all_names);
  std::set<std::string> pre_called;
  for (const auto &entry : pre_callees)
    for (const std::string &c : entry.second) pre_called.insert(c);
  std::vector<std::string> roots;
  if (kernels.empty()) {
    for (const FnRec &fn : scan.fns)
      if (!fn.is_static && !pre_called.count(fn.name)) roots.push_back(fn.name);
  } else {
    roots = kernels;
  }
  std::set<std::string> live;
  std::vector<std::string> stack = roots;
  while (!stack.empty()) {
    std::string n = stack.back();
    stack.pop_back();
    if (live.count(n) || !all_names.count(n)) continue;
    live.insert(n);
    for (const std::string &c : pre_callees[n]) stack.push_back(c);
  }
  std::vector<const FnRec *> kept;
  for (FnRec &fn : scan.fns) {
    if (live.count(fn.name)) {
      kept.push_back(&fn);
    } else {
      std::vector<std::string>().swap(fn.named);  // a dead function's names are not needed again
    }
  }
  std::map<std::string, std::vector<std::string>>().swap(pre_callees);

  // The text of the kept functions (the second pass over the chunks): the others are not read again.
  if (chunked) {
    std::map<size_t, std::shared_ptr<std::string>> wanted;
    for (const FnRec *r : kept) wanted[r->chunk] = nullptr;
    text.each_chunk([&](size_t i, const std::string &chunk) {
      auto it = wanted.find(i);
      if (it != wanted.end()) it->second = std::make_shared<std::string>(chunk);
    });
    for (FnRec &r : scan.fns) {
      auto it = wanted.find(r.chunk);
      if (it != wanted.end() && live.count(r.name)) r.text = it->second;
    }
  }

  // The functions of the module: each is parsed from its text when it is set up or compiled (Fn::setup).
  std::vector<std::unique_ptr<Fn>> fns;
  for (const FnRec *r : kept) {
    Fn::Loader load;
    if (r->whole_form) {
      const Node *form = r->whole_form;
      load = [form]() { return std::make_unique<Node>(*form); };
    } else {
      std::shared_ptr<std::string> chunk = r->text;
      load = [chunk]() {
        std::vector<Node> fs = parse_text_forms(*chunk);
        return std::make_unique<Node>(std::move(fs[0]));
      };
    }
    fns.push_back(std::make_unique<Fn>(r->name, r->index, std::move(load)));
  }

  std::map<std::string, Fn *> by_name;
  for (const auto &fn : fns) by_name[fn->name()] = fn.get();
  std::map<std::string, std::vector<std::string>> callees;
  std::set<std::string> kept_names;
  for (const auto &fn : fns) kept_names.insert(fn->name());
  for (const FnRec *r : kept) callees[r->name] = callees_among(r->named, kept_names);
  OrderedMap called;  // callee => its caller (the last caller in order)
  for (const FnRec *r : kept)
    for (const std::string &c : callees[r->name]) called.set(c, r->name);
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
  // Each function is compiled and its text is taken; the text is kept until it is written (in the call order below).
  std::vector<std::string> texts(fns.size());
  std::map<std::string, size_t> text_of;  // the function of a name: the last one, as by_name has it
  for (size_t k = 0; k < fns.size(); k++) {
    fns[k]->compile();
    texts[k] = fns[k]->text();
    fns[k]->release();
    text_of[fns[k]->name()] = k;
  }

  bool uses_dynshared = false, uses_printf = false;
  for (const auto &fn : fns) {
    uses_dynshared = uses_dynshared || fn->uses_dynshared;
    uses_printf = uses_printf || fn->uses_printf;
  }
  // Nothing is written until the whole module is compiled, so a refusal leaves the output empty, as before.
  std::string head = "// Generated by scripts/pathb-ptx-emit.rb from the Path B IR; do not edit.\n";
  head += ".version 8.0\n.target " + sm + "\n.address_size 64\n\n";
  head += emit_module_decls(scan.nonfn, uses_dynshared, uses_printf, nullptr);
  sink(head);

  // PTX needs a callee declared before its first call: emit the functions callee first (depth-first post-order).
  std::vector<std::string> ordered;
  std::set<std::string> seen;
  std::function<void(const std::string &)> visit = [&](const std::string &name) {
    if (!seen.insert(name).second) return;
    auto it = callees.find(name);
    if (it != callees.end())
      for (const std::string &c : it->second) visit(c);
    ordered.push_back(name);
  };
  for (const auto &fn : fns) visit(fn->name());
  for (const std::string &name : ordered) {
    std::string &t = texts[text_of[name]];
    sink(t);
    sink("\n");
    std::string().swap(t);
  }
}
