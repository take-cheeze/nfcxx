// The module level of scripts/pathb-ptx-emit.rb's emit_module: see module.hpp. Each step is the Ruby's, in the Ruby's
// order, so the first error is the same one. Ruby hashes keep their insertion order, and so do the OrderedMaps here (a
// key assigned again keeps its place, as in Ruby).
#include "module.hpp"

#include <algorithm>
#include <functional>
#include <map>
#include <optional>
#include <set>
#include <utility>

#include "ir.hpp"
#include "lower_types.hpp"

namespace {

// STRING_PREFIX of the Ruby script: the prefix of a string constant's symbol.
const char *const kStringPrefix = "__nfcxx_str_";

// head_of: the atom at the head of a list (the Ruby's head_of: nil for anything else).
std::optional<std::string> head_of(const Node *x) {
  if (!x || x->kind != Node::List || x->items.empty() || x->items[0].kind != Node::Atom) return std::nullopt;
  return x->items[0].text;
}

bool head_is(const Node *x, const char *h) {
  std::optional<std::string> head = head_of(x);
  return head && *head == h;
}

// x[i] of a list, or nullptr (the Ruby's nil).
const Node *at(const Node *x, size_t i) {
  return x && x->kind == Node::List && i < x->items.size() ? &x->items[i] : nullptr;
}

size_t len(const Node *x) { return x && x->kind == Node::List ? x->items.size() : 0; }

// The Ruby's `x.to_s` for a name: an atom or a string literal is its text, nil is "". Another node has no Ruby text
// that could name a symbol (an object's inspect), so the module is refused.
std::string to_s(const Node *x) {
  if (!x) return "";
  if (x->kind == Node::Atom || x->kind == Node::Str) return x->text;
  throw Refused("a name is not an atom or a string: " + form_text(*x));
}

// A hash in insertion order: a key assigned again keeps its first place, with its new value.
template <class V>
class OrderedMap {
 public:
  bool has(const std::string &k) const { return index_.count(k) != 0; }

  V *find(const std::string &k) {
    auto it = index_.find(k);
    return it == index_.end() ? nullptr : &items_[it->second].second;
  }

  const V *find(const std::string &k) const {
    auto it = index_.find(k);
    return it == index_.end() ? nullptr : &items_[it->second].second;
  }

  V &operator[](const std::string &k) {
    auto it = index_.find(k);
    if (it != index_.end()) return items_[it->second].second;
    index_[k] = items_.size();
    items_.emplace_back(k, V());
    return items_.back().second;
  }

  const std::vector<std::pair<std::string, V>> &items() const { return items_; }

 private:
  std::vector<std::pair<std::string, V>> items_;
  std::map<std::string, size_t> index_;
};

// A function of the module (the Ruby's Fn): its form, its name, its linkage, and whether it is a kernel.
struct FnRec {
  std::string name;
  const Node *form = nullptr;
  bool is_static = false;   // static_fn?: a (static) child of the form
  bool kernel = true;
};

// The names of the functions a form calls directly: each &"name" that is a callee of a call, and each &"name" in the form
// (collect_calls). The names are in the order of the form.
void collect_calls(const Node *x, std::vector<std::string> &acc) {
  // a function whose address is taken (a function pointer value) is reachable too: it must be emitted
  if (x->kind == Node::Sym && x->sig == '&') {
    acc.push_back(x->text);
    return;
  }
  if (x->kind != Node::List) return;
  if (head_is(x, "call") && x->items.size() > 2 && x->items[2].kind == Node::Sym && x->items[2].sig == '&') {
    acc.push_back(x->items[2].text);
  }
  for (const Node &y : x->items) collect_calls(&y, acc);
}

std::vector<std::string> callees_in(const Node *form, const std::function<bool(const std::string &)> &keep) {
  std::vector<std::string> all;
  collect_calls(form, all);
  std::vector<std::string> out;
  for (const std::string &c : all) {
    if (keep(c) && std::find(out.begin(), out.end(), c) == out.end()) out.push_back(c);
  }
  return out;
}

// Raises Refused when a call cycle is reachable from name (PTX has no recursion in our lowering).
void check_recursion(const std::string &name, const OrderedMap<std::vector<std::string>> &callees,
                     std::map<std::string, int> &state) {
  constexpr int kOpen = 1, kDone = 2;
  auto it = state.find(name);
  if (it != state.end() && it->second == kDone) return;
  if (it != state.end() && it->second == kOpen) throw Refused("recursive call of " + name);
  state[name] = kOpen;
  if (const std::vector<std::string> *cs = callees.find(name)) {
    for (const std::string &c : *cs) check_recursion(c, callees, state);
  }
  state[name] = kDone;
}

struct GlobalRec {
  i128 size = 0;
  i128 align = 0;
  std::optional<std::string> lit;   // the initializer, when the global has one
};

struct ConstRec {
  std::string ptype;
  std::string lit;
  i128 align = 0;
  std::optional<i128> count;   // an array's element count; a scalar has none
};

struct ByteInitRec {
  std::string src;   // the data constant the bytes come from
  i128 align = 0;
  i128 size = 0;
};

std::string join_ints(const std::string &bytes) {
  std::string out;
  for (size_t i = 0; i < bytes.size(); i++) {
    if (i) out += ",";
    out += std::to_string(static_cast<unsigned char>(bytes[i]));
  }
  return out;
}

}  // namespace

std::string plan_module(const std::string &src, const std::string &sm, const std::vector<std::string> &kernels_in) {
  std::vector<Node> forms = parse_forms_chunked(src);
  std::vector<FnRec> fns;
  OrderedMap<std::pair<i128, i128>> shared;   // name => size, align
  OrderedMap<GlobalRec> globals;
  OrderedMap<ConstRec> consts;
  OrderedMap<bool> externs;
  OrderedMap<std::string> strings;            // name => bytes
  OrderedMap<ByteInitRec> byte_inits;

  for (const Node &f : forms) {
    std::optional<std::string> h = head_of(&f);
    if (h && *h == "ir-module") {
      continue;
    } else if (h && *h == "function") {
      FnRec fn;
      fn.name = to_s(at(&f, 1));
      fn.form = &f;
      fn.is_static = false;
      for (const Node &x : f.items) {
        if (head_is(&x, "static")) fn.is_static = true;
      }
      fns.push_back(fn);
    } else if (h && *h == "data") {
      // a string constant (a printf format): its bytes, as a .const array in the module
      std::string name = to_s(at(&f, 1));
      const Node *payload = at(&f, 3);
      if (!(head_is(payload, "string") && len(payload) == 2)) {
        throw Refused("data " + name + " (only string constants are lowered)");
      }
      if (strings.has(name)) throw Refused("data " + name + " is defined twice");
      strings[name] = to_s(at(payload, 1));
    } else if (h && *h == "abi-type") {
      // the ABI class of a struct (for the host calling convention): the device code passes such values by address
      // (byval and sret), so the record needs no code
      continue;
    } else if (h && *h == "global") {
      // A file-scope static array of the device unit is block-shared memory (CUDA's __shared__): its name and size come
      // from the IR, and it must be zero-initialized. Any other global is refused. Function-local __shared__ (a template
      // instance's, mangled _ZZ..., linkage weak) and file-scope static objects are block-shared memory; any other
      // zero-initialized global is device memory (__device__), .global.
      std::string name = to_s(at(&f, 1));
      const Node *ty = at(&f, 2);
      i128 size = as_int(at(&f, 3));
      i128 align = as_int(at(&f, 4));
      // the optional linkage (static, weak, extern) and the initializer come after the size and alignment, in any case
      std::optional<std::string> linkage;
      const Node *init = nullptr;
      for (size_t i = 5; i < f.items.size(); i++) {
        const Node *x = &f.items[i];
        std::optional<std::string> xh = head_of(x);
        if (!linkage && xh && (*xh == "static" || *xh == "weak" || *xh == "extern")) linkage = xh;
        if (!init && xh && *xh == "init") init = x;
      }
      // An extern global has no definition in this unit: refused where code reads it (see the @ operand), not here
      // (an unused static member of a template instance is declared and never read).
      if (linkage && *linkage == "extern") {
        externs[name] = true;
        continue;
      }
      // A constant with a value (a static constexpr data member): the front end folds its uses, so the global is read
      // only where its address is taken, and it is emitted as a typed .const symbol with its value.
      bool ty_const = head_is(ty, "const");
      std::optional<std::vector<std::string>> cinit = ty_const ? scalar_const_init(init, name, size) : std::nullopt;
      if (cinit) {
        consts[name] = ConstRec{(*cinit)[0], (*cinit)[1], align, std::nullopt};
        continue;
      }
      // a const char array initialized from a string constant (`static const char t[N] = "..."`): the string's bytes,
      // once the module's data is known (the IR lists data after the globals)
      if (ty_const && init && len(init) == 2 && head_is(at(init, 1), "bytes") && len(at(init, 1)) == 4 &&
          at(at(init, 1), 3)->kind == Node::Sym && at(at(init, 1), 3)->sig == '@' &&
          as_int(at(at(init, 1), 1)) == 0 && as_int(at(at(init, 1), 2)) == size) {
        byte_inits[name] = ByteInitRec{at(at(init, 1), 3)->text, align, size};
        continue;
      }
      // a const array of scalars with its values (a lookup table): a typed .const array with the same values
      std::optional<ArrInit> carr = ty_const ? scalar_const_array_init(ty, init, name, size) : std::nullopt;
      if (carr) {
        consts[name] = ConstRec{carr->ptype, carr->body, align, carr->count};
        continue;
      }
      // integer scalars and zero runs at byte offsets (see byte_const_init). A static one is block-private in this emitter
      // (a zero static is block-shared memory, and shared memory has no initializer), so its bytes are a read-only .const:
      // a store to it is rejected by ptxas rather than corrupting other blocks. A global one is a writable .global with
      // its bytes as the initializer, so each program sees one object with the initial values.
      std::optional<ByteInit> binit = byte_const_init(init, name, size);
      if (binit && linkage && *linkage == "static") {
        consts[name] = ConstRec{"b8", binit->body, align, binit->size};
        continue;
      }
      if (binit) {
        globals[name] = GlobalRec{size, align, binit->body};
        continue;
      }
      // a zero initializer: the zero form, or explicit zero scalars covering the object (all zero data is zero)
      bool zero_form = init && len(init) == 2 && head_is(at(init, 1), "zero");
      if (!(zero_form || all_zero_init(init, size))) {
        throw Refused("global " + name + ": only zero initializers are lowered");
      }
      if (zero_form && !(as_int(at(at(init, 1), 1)) == 0 && as_int(at(at(init, 1), 2)) == size)) {
        throw Refused("global " + name + ": partial zero initializer");
      }
      if ((linkage && *linkage == "static") || ((linkage && *linkage == "weak") && name.rfind("_ZZ", 0) == 0)) {
        shared[name] = {size, align};
      } else {
        globals[name] = GlobalRec{size, align, std::nullopt};
      }
    } else {
      throw Refused("top-level form " + (h ? *h : form_text(f)));
    }
  }
  if (fns.empty()) throw BadIR("no function in the IR");

  // A listed kernel is named as the source names it (cuda-rewrite.rb --kernels writes plain names). A C++ function's IR
  // name is its Itanium mangled name, so a plain name matches by the rule --embed uses (embed.cpp).
  std::vector<std::string> kernels;
  for (const std::string &k : kernels_in) {
    std::vector<std::string> hits;
    for (const FnRec &fn : fns) {
      if (fn.name == k || fn.name.rfind("_Z" + std::to_string(k.size()) + k, 0) == 0) hits.push_back(fn.name);
    }
    if (hits.empty()) throw BadIR("no function named " + k + " in the IR");
    if (hits.size() > 1) throw BadIR(std::to_string(hits.size()) + " functions named " + k + " in the IR");
    kernels.push_back(hits[0]);
  }

  // Keep the functions reachable from the kernels: the listed kernels, or else the functions that are not static and
  // not called. A static function that nothing reaches is dead code (a C++ header's unused inline helper): it is not
  // emitted, rather than taken for a kernel (which could not return its value).
  std::set<std::string> pre_names;
  for (const FnRec &fn : fns) pre_names.insert(fn.name);
  OrderedMap<std::vector<std::string>> pre_callees;
  for (const FnRec &fn : fns) {
    pre_callees[fn.name] = callees_in(fn.form, [&](const std::string &c) { return pre_names.count(c) != 0; });
  }
  std::set<std::string> pre_called;
  for (const auto &entry : pre_callees.items()) {
    for (const std::string &c : entry.second) pre_called.insert(c);
  }
  std::vector<std::string> roots;
  if (kernels.empty()) {
    for (const FnRec &fn : fns) {
      if (!fn.is_static && pre_called.count(fn.name) == 0) roots.push_back(fn.name);
    }
  } else {
    roots = kernels;
  }
  std::set<std::string> live;
  std::vector<std::string> stack = roots;
  while (!stack.empty()) {
    std::string n = stack.back();
    stack.pop_back();
    if (live.count(n) || pre_names.count(n) == 0) continue;
    live.insert(n);
    for (const std::string &c : *pre_callees.find(n)) stack.push_back(c);
  }
  std::vector<FnRec> live_fns;
  for (const FnRec &fn : fns) {
    if (live.count(fn.name)) live_fns.push_back(fn);
  }
  // by_name: the last function of a name, as the Ruby hash keeps it
  OrderedMap<size_t> by_name;
  for (size_t i = 0; i < live_fns.size(); i++) by_name[live_fns[i].name] = i;
  OrderedMap<std::vector<std::string>> callees;
  for (const FnRec &fn : live_fns) {
    callees[fn.name] = callees_in(fn.form, [&](const std::string &c) { return by_name.has(c); });
  }
  OrderedMap<std::string> called;   // callee => its last caller
  for (const auto &entry : callees.items()) {
    for (const std::string &c : entry.second) called[c] = entry.first;
  }
  if (kernels.empty()) {
    for (FnRec &fn : live_fns) fn.kernel = !called.has(fn.name);
  } else {
    for (const std::string &k : kernels) {
      if (!by_name.has(k)) throw BadIR("no function named " + k + " in the IR");
    }
    for (FnRec &fn : live_fns) {
      fn.kernel = std::find(kernels.begin(), kernels.end(), fn.name) != kernels.end();
    }
    for (const auto &entry : called.items()) {
      if (live_fns[*by_name.find(entry.first)].kernel) {
        throw Refused("kernel " + entry.first + " is called by " + entry.second);
      }
    }
  }
  std::map<std::string, int> state;
  for (const FnRec &fn : live_fns) check_recursion(fn.name, callees, state);

  for (const auto &entry : byte_inits.items()) {
    const ByteInitRec &bi = entry.second;
    if (!strings.has(bi.src)) {
      throw Refused("global " + entry.first + ": its string " + bi.src + " is not a data constant of this module");
    }
    const std::string &bytes = *strings.find(bi.src);
    if (static_cast<i128>(bytes.size()) != bi.size) {
      throw Refused("global " + entry.first + ": string " + bi.src + " is " + std::to_string(bytes.size()) +
                    " bytes, the global is " + i128_text(bi.size));
    }
    consts[entry.first] = ConstRec{"u8", "{" + join_ints(bytes) + "}", bi.align, bi.size};
  }

  // The module text. The dynamic shared extern and the vprintf extern depend on what the functions use, which is known
  // once they are lowered (Fn#compile), so a plan omits them.
  std::string out = "// Generated by scripts/pathb-ptx-emit.rb from the Path B IR; do not edit.\n";
  out += ".version 8.0\n.target " + sm + "\n.address_size 64\n\n";
  for (const auto &entry : strings.items()) {
    out += ".const .align 1 .b8 " + ptx_sym(kStringPrefix + entry.first) + "[" + std::to_string(entry.second.size()) +
           "] = {" + join_ints(entry.second) + "};\n";
  }
  for (const auto &entry : shared.items()) {
    out += ".shared .align " + i128_text(entry.second.second) + " .b8 " + ptx_sym(entry.first) + "[" +
           i128_text(entry.second.first) + "];\n";
  }
  for (const auto &entry : globals.items()) {
    const GlobalRec &g = entry.second;
    std::string init = g.lit ? " = " + *g.lit : "";
    out += ".global .align " + i128_text(g.align) + " .b8 " + ptx_sym(entry.first) + "[" + i128_text(g.size) + "]" +
           init + ";\n";
  }
  for (const auto &entry : consts.items()) {
    const ConstRec &c = entry.second;
    std::string dims = c.count ? "[" + i128_text(*c.count) + "]" : "";
    out += ".const .align " + i128_text(c.align) + " ." + c.ptype + " " + ptx_sym(entry.first) + dims + " = " + c.lit +
           ";\n";
  }
  if (!shared.items().empty() || !globals.items().empty()) out += "\n";

  // PTX needs a callee declared before its first call: emit the functions callee first (depth-first post-order).
  std::vector<std::string> ordered;
  std::set<std::string> seen;
  std::function<void(const std::string &)> visit = [&](const std::string &name) {
    if (seen.count(name)) return;
    seen.insert(name);
    if (const std::vector<std::string> *cs = callees.find(name)) {
      for (const std::string &c : *cs) visit(c);
    }
    ordered.push_back(name);
  };
  for (const FnRec &fn : live_fns) visit(fn.name);
  for (const std::string &name : ordered) out += "// body " + name + "\n";
  return out;
}
