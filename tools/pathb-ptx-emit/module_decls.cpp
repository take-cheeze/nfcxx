// The module-level declarations of scripts/pathb-ptx-emit.rb (see module_decls.hpp). Each Ruby hash is an insertion-
// ordered map here, so the declarations come out in the Ruby's order, and a key set twice keeps its first position.
#include "module_decls.hpp"

#include <optional>
#include <utility>
#include <vector>

#include "lower_types.hpp"

namespace {

const char *const DYNSHARED_SYM_DECL = "__nfcxx_dynshared";

// Ruby's head_of: the head atom of a non-empty list, or null.
const std::string *head(const Node *x) {
  if (!x || x->kind != Node::List || x->items.empty() || x->items[0].kind != Node::Atom) return nullptr;
  return &x->items[0].text;
}

bool head_is(const Node *x, const char *h) {
  const std::string *s = head(x);
  return s && *s == h;
}

// Ruby's `x[i]` on a form, nil when missing or not a list.
const Node *at(const Node *n, size_t i) {
  if (!n || n->kind != Node::List || i >= n->items.size()) return nullptr;
  return &n->items[i];
}

size_t len(const Node *n) { return n && n->kind == Node::List ? n->items.size() : 0; }

// Ruby's `x.to_s` for a name: an atom's or a string's text, a symbol's name.
std::string name_of(const Node *x) {
  if (!x) return "";
  if (x->kind == Node::Atom || x->kind == Node::Str || x->kind == Node::Sym) return x->text;
  return "";
}

// An insertion-ordered map with Ruby's `h[k] = v` semantics: an existing key keeps its position.
template <class V>
struct OMap {
  std::vector<std::pair<std::string, V>> items;
  bool has(const std::string &k) const {
    for (const auto &p : items)
      if (p.first == k) return true;
    return false;
  }
  void set(const std::string &k, V v) {
    for (auto &p : items)
      if (p.first == k) {
        p.second = std::move(v);
        return;
      }
    items.emplace_back(k, std::move(v));
  }
  const V *get(const std::string &k) const {
    for (const auto &p : items)
      if (p.first == k) return &p.second;
    return nullptr;
  }
};

struct Shared {
  i128 size, align;
};
struct Global {
  i128 size, align;
  std::optional<std::string> lit;
};
struct Const {
  std::string ptype, lit;
  i128 align;
  std::optional<i128> count;
};
struct ByteInitSrc {
  std::string src;
  i128 align, size;
};

}  // namespace

std::string emit_module_decls(const std::string &src, bool uses_dynshared, bool uses_printf, ModuleSymbols *syms) {
  return emit_module_decls(parse_nonfunction_forms(src), uses_dynshared, uses_printf, syms);
}

std::string emit_module_decls(const std::vector<Node> &forms, bool uses_dynshared, bool uses_printf, ModuleSymbols *syms) {
  OMap<Shared> shared;
  OMap<Global> globals;
  OMap<Const> consts;
  OMap<bool> externs;
  OMap<std::vector<uint8_t>> strings;
  OMap<ByteInitSrc> byte_inits;

  for (const Node &f : forms) {
    const std::string *h = head(&f);
    if (h && *h == "ir-module") {
      continue;
    } else if (h && *h == "function") {
      continue;  // the function bodies are emitted by the Ruby until the lowering phases are ported
    } else if (h && *h == "data") {
      // a string constant (a printf format): its bytes, as a .const array in the module
      std::string name = name_of(at(&f, 1));
      const Node *payload = at(&f, 3);
      if (!(head_is(payload, "string") && len(payload) == 2))
        throw Refused("data " + name + " (only string constants are lowered)");
      if (strings.has(name)) throw Refused("data " + name + " is defined twice");
      std::vector<uint8_t> bytes;
      for (char c : name_of(at(payload, 1))) bytes.push_back(static_cast<uint8_t>(c));
      strings.set(name, bytes);
    } else if (h && *h == "abi-type") {
      continue;
    } else if (h && *h == "global") {
      std::string name = name_of(at(&f, 1));
      const Node *ty = at(&f, 2);
      i128 size = as_int(at(&f, 3));
      i128 align = as_int(at(&f, 4));
      // The linkage (static, weak, extern) comes after the size and alignment; the initializer is the `init` form.
      std::string linkage;
      const Node *init = nullptr;
      for (size_t i = 5; i < len(&f); i++) {
        const Node *x = at(&f, i);
        const std::string *xh = head(x);
        if (!xh) continue;
        if (linkage.empty() && (*xh == "static" || *xh == "weak" || *xh == "extern")) linkage = *xh;
        if (!init && *xh == "init") init = x;
      }
      if (linkage == "extern") {
        externs.set(name, true);
        continue;
      }
      // A constant with a value: a typed .const symbol with its value (scalar_const_init).
      if (head_is(ty, "const")) {
        if (auto c = scalar_const_init(init, name, size)) {
          consts.set(name, Const{(*c)[0], (*c)[1], align, std::nullopt});
          continue;
        }
      }
      // a const char array initialized from a string constant: its bytes, once the module's data is known
      if (head_is(ty, "const") && init && len(init) == 2 && head_is(at(init, 1), "bytes") && len(at(init, 1)) == 4) {
        const Node *sym = at(at(init, 1), 3);
        if (sym && sym->kind == Node::Sym && sym->sig == '@' && as_int(at(at(init, 1), 1)) == 0 &&
            as_int(at(at(init, 1), 2)) == size) {
          byte_inits.set(name, ByteInitSrc{sym->text, align, size});
          continue;
        }
      }
      // a const array of scalars with its values
      if (head_is(ty, "const")) {
        if (auto ca = scalar_const_array_init(ty, init, name, size)) {
          consts.set(name, Const{ca->ptype, ca->body, align, ca->count});
          continue;
        }
      }
      // integer scalars and zero runs at byte offsets: a static one is a read-only .const, a global one a .global
      if (auto bi = byte_const_init(init, name, size)) {
        if (linkage == "static") {
          consts.set(name, Const{"b8", bi->body, align, size});
          continue;
        }
        globals.set(name, Global{size, align, bi->body});
        continue;
      }
      // a zero initializer: the zero form, or explicit zero scalars covering the object
      bool zero_form = init && len(init) == 2 && head_is(at(init, 1), "zero");
      if (!(zero_form || all_zero_init(init, size)))
        throw Refused("global " + name + ": only zero initializers are lowered");
      if (zero_form && !(as_int(at(at(init, 1), 1)) == 0 && as_int(at(at(init, 1), 2)) == size))
        throw Refused("global " + name + ": partial zero initializer");
      if (linkage == "static" || (linkage == "weak" && name.rfind("_ZZ", 0) == 0)) {
        shared.set(name, Shared{size, align});
      } else {
        globals.set(name, Global{size, align, std::nullopt});
      }
    } else {
      throw Refused("top-level form " + (h ? *h : form_text(f)));
    }
  }

  // the byte initializers that name a string constant of this module take its bytes
  for (const auto &p : byte_inits.items) {
    const std::string &name = p.first;
    const ByteInitSrc &b = p.second;
    if (!strings.has(b.src))
      throw Refused("global " + name + ": its string " + b.src + " is not a data constant of this module");
    const auto *bytes = strings.get(b.src);
    if (static_cast<i128>(bytes->size()) != b.size)
      throw Refused("global " + name + ": string " + b.src + " is " + std::to_string(bytes->size()) +
                    " bytes, the global is " + i128_text(b.size));
    std::string body = "{";
    for (size_t i = 0; i < bytes->size(); i++) {
      if (i) body += ",";
      body += std::to_string((*bytes)[i]);
    }
    body += "}";
    consts.set(name, Const{"u8", body, b.align, b.size});
  }

  if (syms) {
    for (const auto &s : shared.items) syms->shared.insert(s.first);
    for (const auto &g : globals.items) syms->globals.insert(g.first);
    for (const auto &c : consts.items) syms->consts.insert(c.first);
    for (const auto &e : externs.items) syms->externs.insert(e.first);
    for (const auto &s : strings.items) syms->strings.insert(s.first);
  }

  std::string out;
  if (uses_dynshared) out += std::string(".extern .shared .align 16 .b8 ") + DYNSHARED_SYM_DECL + "[];\n";
  for (const auto &s : strings.items) {
    std::string body;
    for (size_t i = 0; i < s.second.size(); i++) {
      if (i) body += ",";
      body += std::to_string(s.second[i]);
    }
    out += ".const .align 1 .b8 " + string_const_sym(s.first) + "[" + std::to_string(s.second.size()) +
           "] = {" + body + "};\n";
  }
  if (uses_printf)
    out += ".extern .func (.param .b32 __vprintf_rv) vprintf (.param .b64 __vprintf_fmt, .param .b64 __vprintf_buf);\n";
  for (const auto &s : shared.items)
    out += ".shared .align " + i128_text(s.second.align) + " .b8 " + ptx_sym(s.first) + "[" +
           i128_text(s.second.size) + "];\n";
  for (const auto &g : globals.items) {
    std::string init = g.second.lit ? " = " + *g.second.lit : "";
    out += ".global .align " + i128_text(g.second.align) + " .b8 " + ptx_sym(g.first) + "[" +
           i128_text(g.second.size) + "]" + init + ";\n";
  }
  for (const auto &c : consts.items) {
    std::string dims = c.second.count ? "[" + i128_text(*c.second.count) + "]" : "";
    out += ".const .align " + i128_text(c.second.align) + " ." + c.second.ptype + " " + ptx_sym(c.first) + dims +
           " = " + c.second.lit + ";\n";
  }
  if (!(shared.items.empty() && globals.items.empty())) out += "\n";
  return out;
}
