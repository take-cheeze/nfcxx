// The IR types, the passes on function forms and the static region (scripts/pathb-spirv-emit.rb).
#include "forms.hpp"

#include "spv.hpp"

#include <cstdlib>
#include <functional>
#include <cstring>
#include <variant>

const char *const EH_RUNTIME_STATE[4] = {"__curr_eh_stack_entry", "__eh_curr_region", "__catch_clause_number",
                                         "__caught_object_address"};
const char *const GLIBCXX_ASSERT_FAIL = "_ZSt21__glibcxx_assert_failPKciS0_S0_";

static bool eh_state(const std::string &n) {
  for (const char *e : EH_RUNTIME_STATE)
    if (n == e) return true;
  return false;
}

// ------------------------------------------------------------------ types

Ty parse_type(const Node &x) {
  if (x.kind == Node::Atom) {
    const std::string &s = x.text;
    if (s == "void") return ty_void();
    if (s == "bool") return ty_int(1, false, true);
    if (s == "char" || s == "signed_char") return ty_int(1, true);
    if (s == "unsigned_char") return ty_int(1, false);
    if (s == "short") return ty_int(2, true);
    if (s == "unsigned_short") return ty_int(2, false);
    if (s == "int") return ty_int(4, true);
    if (s == "unsigned_int") return ty_int(4, false);
    if (s == "long" || s == "long_long") return ty_int(8, true);
    if (s == "unsigned_long" || s == "unsigned_long_long") return ty_int(8, false);
    if (s == "float") return ty_float(4);
    if (s == "double") return ty_float(8);
    throw Refused("type " + s);
  }
  if (x.kind != Node::List || x.items.empty()) throw BadIR("bad type form " + form_text(x));
  const Node &h = x.items[0];
  if (h.atom_is("ptr") || h.atom_is("byval") || h.atom_is("sret")) return ty_ptr();
  if (h.atom_is("const") || h.atom_is("volatile")) {
    if (x.items.size() < 2) throw BadIR("bad type form ");
    return parse_type(x.items[1]);
  }
  throw Refused("type form (" + to_s(h) + " ...)");
}

std::optional<Ty> parse_type_safe(const Node &x) {
  try {
    return parse_type(x);
  } catch (Refused &) {
    return std::nullopt;
  }
}

bool scalar_form(const Node &x) {
  try {
    parse_type(x);
    return true;
  } catch (Refused &) {
    return false;
  }
}

// ------------------------------------------------------------------ passes

void collect_calls(const Node &x, std::vector<std::string> &acc) {
  if (x.kind != Node::List) return;
  if (head_is(x, "call") && x.items.size() > 2 && x.items[2].is_sym('&')) acc.push_back(x.items[2].text);
  for (const Node &y : x.items) collect_calls(y, acc);
}

void collect_fn_refs(const Node &x, std::vector<std::string> &acc) {
  if (x.kind == Node::Sym) {
    if (x.sig == '&') acc.push_back(x.text);
    return;
  }
  if (x.kind != Node::List) return;
  for (const Node &y : x.items) collect_fn_refs(y, acc);
}

namespace {

int cxa_count(const Node &x, const std::string &name) {
  if (x.kind == Node::Atom) return x.text == name ? 1 : 0;
  if (x.kind != Node::List) return 0;
  int n = 0;
  for (const Node &y : x.items) n += cxa_count(y, name);
  return n;
}

int cxa_ctor_refs(const Node &x, const std::string &name) {
  if (x.kind != Node::List) return 0;
  int n = 0;
  if (head_is(x, "call") && x.items.size() > 2 && x.items[2].kind == Node::Sym && x.items[2].text == "__cxa_vec_ctor" &&
      x.items.size() > 6 && x.items[6].atom_is(name.c_str()))
    n += 1;
  for (const Node &y : x.items) n += cxa_ctor_refs(y, name);
  return n;
}

const std::string *cxa_resolve(const Node *a, const std::unordered_map<std::string, std::string> &regs) {
  if (!a) return nullptr;
  if (a->is_sym('&')) return &a->text;
  if (a->kind == Node::Atom) {
    auto it = regs.find(a->text);
    if (it != regs.end()) return &it->second;
  }
  return nullptr;
}

const Node *at(const Node &x, size_t i) { return i < x.items.size() ? &x.items[i] : nullptr; }

struct CxaState {
  Node *body;
  int counter = 0;
  std::unordered_map<std::string, std::string> regs;
};

// The Ruby builds the new list of each level and replaces the level at its end; the walk of the whole body (cxa_count)
// during the level sees the old list. Here the level is rebuilt only when it drops or expands something.
void cxa_expand(Node &x, CxaState &st) {
  std::vector<std::variant<size_t, Node>> out;
  bool changed = false;
  for (size_t k = 0; k < x.items.size(); k++) {
    Node &c = x.items[k];
    if (head_is(c, "let") && c.items.size() == 4 && c.items[3].kind == Node::List && head_is(c.items[3], "bitcast") &&
        c.items[3].items.size() > 2 && c.items[3].items[2].is_sym('&')) {
      std::string reg = to_s(c.items[1]);
      st.regs[reg] = c.items[3].items[2].text;
      // dropped when its address is used only as a constructor argument
      if (c.items[1].kind == Node::Atom && cxa_count(*st.body, reg) == 1 + cxa_ctor_refs(*st.body, reg)) {
        changed = true;
        continue;
      }
      out.emplace_back(k);
      continue;
    }
    if (head_is(c, "eval") && c.items.size() > 1 && c.items[1].kind == Node::List && head_is(c.items[1], "call") &&
        c.items[1].items.size() > 2 && c.items[1].items[2].is_sym('&') && c.items[1].items[2].text == "__cxa_vec_ctor") {
      const Node &call = c.items[1];
      const std::string *ctor = cxa_resolve(at(call, 6), st.regs);
      if (!ctor) throw Refused("__cxa_vec_ctor with an unknown constructor");
      if (!(at(call, 7) && head_is(call.items[7], "null"))) throw Refused("__cxa_vec_ctor with a destructor");
      if (!(at(call, 4) && head_is(call.items[4], "const") && at(call, 3) && call.items[3].kind == Node::Atom))
        throw Refused("__cxa_vec_ctor with a non-constant count");
      if (call.items[4].items.size() < 3) throw BadIR("expected an integer, got ");
      int64_t n = as_int(call.items[4].items[2]);
      Node size = at(call, 5) && call.items[5].items.size() > 2 ? call.items[5].items[2] : make_atom("");
      std::string ctor_name = *ctor;
      for (int64_t i = 0; i < n; i++) {
        st.counter += 1;
        std::string r = "%cxa" + std::to_string(st.counter);
        out.emplace_back(make_list({make_atom("let"), make_atom(r), make_list({make_atom("ptr"), make_atom("void")}),
                                    make_list({make_atom("index"), call.items[3],
                                               make_list({make_atom("const"), make_atom("unsigned_long"),
                                                          make_atom(std::to_string(i))}),
                                               size})}));
        out.emplace_back(make_list({make_atom("eval"), make_list({make_atom("call"), make_atom("void"),
                                                                  make_sym('&', ctor_name), make_atom(r)})}));
      }
      changed = true;
      continue;
    }
    if (c.kind == Node::List) cxa_expand(c, st);
    out.emplace_back(k);
  }
  if (!changed) return;
  std::vector<Node> items;
  items.reserve(out.size());
  for (auto &o : out) {
    if (o.index() == 0) items.push_back(std::move(x.items[std::get<0>(o)]));
    else items.push_back(std::move(std::get<1>(o)));
  }
  x.items = std::move(items);
}

bool fnptr_slot(const Node *t) {
  if (t && head_is(*t, "const")) t = at(*t, 1);
  return t && head_is(*t, "ptr") && t->items.size() > 1 && head_is(t->items[1], "fn");
}

struct FnptrState {
  std::unordered_set<std::string> names, bad;
  std::unordered_map<std::string, std::string> target;
  std::unordered_map<uint32_t, std::string> drop, calls;
};

void fnptr_scan(const Node &x, FnptrState &st) {
  if (x.kind == Node::Sym) {
    if (x.sig == '$' && st.names.count(x.text)) st.bad.insert(x.text);
    return;
  }
  if (x.kind != Node::List) return;
  if (head_is(x, "store") && x.items.size() > 2 && x.items[2].is_sym('$') && st.names.count(x.items[2].text)) {
    const std::string &n = x.items[2].text;
    const Node *v = at(x, 3);
    auto t = st.target.find(n);
    if (v && v->is_sym('&') && (t == st.target.end() || t->second == v->text)) {
      st.target[n] = v->text;
      st.drop[x.uid] = n;
    } else {
      st.bad.insert(n);
    }
    return;
  }
  if (head_is(x, "call") && x.items.size() > 2 && x.items[2].kind == Node::List && head_is(x.items[2], "load") &&
      x.items[2].items.size() > 2 && x.items[2].items[2].is_sym('$') && st.names.count(x.items[2].items[2].text)) {
    st.calls[x.items[2].uid] = x.items[2].items[2].text;
    for (size_t i = 3; i < x.items.size(); i++) fnptr_scan(x.items[i], st);
    return;
  }
  if (head_is(x, "load") && x.items.size() > 2 && x.items[2].is_sym('$') && st.names.count(x.items[2].text)) {
    st.bad.insert(x.items[2].text);
    return;
  }
  for (const Node &y : x.items) fnptr_scan(y, st);
}

void fnptr_rewrite(Node &x, FnptrState &st) {
  if (x.kind != Node::List) return;
  std::vector<Node> keep;
  bool dropped = false;
  for (Node &c : x.items)
    if (c.kind == Node::List && st.drop.count(c.uid)) dropped = true;
  if (dropped) {
    for (Node &c : x.items)
      if (!(c.kind == Node::List && st.drop.count(c.uid))) keep.push_back(std::move(c));
    x.items = std::move(keep);
  }
  if (head_is(x, "call") && x.items.size() > 2 && x.items[2].kind == Node::List) {
    auto it = st.calls.find(x.items[2].uid);
    if (it != st.calls.end()) x.items[2] = make_sym('&', st.target[it->second]);
  }
  for (Node &c : x.items) fnptr_rewrite(c, st);
}

}  // namespace

void expand_cxa_vec_ctor(Node &body) {
  CxaState st;
  st.body = &body;
  cxa_expand(body, st);
}

void fold_fnptr_slots(std::vector<Node *> &body, const std::vector<const Node *> &slots) {
  FnptrState st;
  for (const Node *f : slots)
    if (fnptr_slot(at(*f, 2))) st.names.insert(to_s(f->items[1]));
  if (st.names.empty()) return;
  for (Node *s : body) fnptr_scan(*s, st);
  std::unordered_set<std::string> ok;
  for (auto &n : st.names)
    if (st.target.count(n) && !st.bad.count(n)) ok.insert(n);
  if (ok.empty()) return;
  for (auto it = st.drop.begin(); it != st.drop.end();) it = ok.count(it->second) ? std::next(it) : st.drop.erase(it);
  for (auto it = st.calls.begin(); it != st.calls.end();) it = ok.count(it->second) ? std::next(it) : st.calls.erase(it);
  std::vector<Node *> kept;
  for (Node *s : body)
    if (!(s->kind == Node::List && st.drop.count(s->uid))) kept.push_back(s);
  body = std::move(kept);
  for (Node *s : body) fnptr_rewrite(*s, st);
}

void scan_slots(const Node &x, std::unordered_map<std::string, std::vector<std::optional<Ty>>> &direct,
                std::unordered_set<std::string> &escaped) {
  if (x.kind == Node::Sym) {
    if (x.sig == '$') escaped.insert(x.text);
    return;
  }
  if (x.kind != Node::List) return;
  const std::string *h = head_of(x);
  if (h && (*h == "load" || *h == "store" || *h == "load.v" || *h == "store.v") && x.items.size() > 2 &&
      x.items[2].is_sym('$')) {
    if (x.items.size() < 2) throw BadIR("bad type form ");
    direct[x.items[2].text].push_back(parse_type_safe(x.items[1]));
    if ((*h == "store" || *h == "store.v") && x.items.size() > 3) scan_slots(x.items[3], direct, escaped);
    return;
  }
  for (const Node &y : x.items) scan_slots(y, direct, escaped);
}

bool mentions_wgs(const Node &t) {
  if (t.kind == Node::Atom || t.kind == Node::Str) return t.text.find("work_group_static") != std::string::npos;
  if (t.kind != Node::List) return false;
  for (const Node &y : t.items)
    if (mentions_wgs(y)) return true;
  return false;
}

bool kernel_key(const Node &form, std::string &key, std::string &found_out) {
  const Node *reg = nullptr;
  bool found = false;
  std::string fname;
  std::function<void(const Node &)> walk;
  walk = [&](const Node &x) {
    if (x.kind != Node::List) return;
    if (head_is(x, "let") && x.items.size() == 4 && head_is(x.items[3], "call") && x.items[3].items.size() > 2 &&
        x.items[3].items[2].kind == Node::Sym && x.items[3].items[2].text == "__nfcxx_sycl_closure") {
      reg = &x.items[1];
    } else if (!found && reg && head_is(x, "let") && x.items.size() == 4 && head_is(x.items[3], "bitcast") &&
               x.items[3].items.size() > 2 && x.items[3].items[2].kind == Node::Atom && reg->kind == Node::Atom &&
               x.items[3].items[2].text == reg->text) {
      const Node *t = x.items[3].items.size() > 1 ? &x.items[3].items[1] : nullptr;
      while (t && t->kind == Node::List && !t->items.empty() &&
             (t->items[0].atom_is("ptr") || t->items[0].atom_is("const") || t->items[0].atom_is("volatile")))
        t = t->items.size() > 1 ? &t->items[1] : nullptr;
      if (t && head_is(*t, "struct") && t->items.size() > 1) {
        fname = to_s(t->items[1]);
        found = true;
      }
    }
    for (const Node &y : x.items) walk(y);
  };
  walk(form);
  if (!found) return false;
  found_out = fname;
  key = fname.compare(0, 2, "_Z") == 0 ? fname.substr(2) : std::to_string(fname.size()) + fname;
  return true;
}

double ruby_to_f(const std::string &text) {
  // String#to_f: leading blanks, a sign, digits, a '.' only when a digit follows it, an exponent only with its digits
  size_t i = 0, n = text.size();
  while (i < n && (text[i] == ' ' || (text[i] >= 9 && text[i] <= 13))) i++;
  std::string s;
  if (i < n && (text[i] == '+' || text[i] == '-')) s += text[i++];
  size_t d0 = s.size();
  while (i < n && text[i] >= '0' && text[i] <= '9') s += text[i++];
  bool digits = s.size() > d0;
  if (i + 1 < n && text[i] == '.' && text[i + 1] >= '0' && text[i + 1] <= '9') {
    s += text[i++];
    while (i < n && text[i] >= '0' && text[i] <= '9') s += text[i++];
    digits = true;
  }
  if (!digits) return 0.0;
  if (i < n && (text[i] == 'e' || text[i] == 'E')) {
    size_t j = i + 1;
    std::string e = "e";
    if (j < n && (text[j] == '+' || text[j] == '-')) e += text[j++];
    size_t e0 = e.size();
    while (j < n && text[j] >= '0' && text[j] <= '9') e += text[j++];
    if (e.size() > e0) s += e;
  }
  return std::strtod(s.c_str(), nullptr);
}

// ------------------------------------------------------------------ the static region

static uint32_t float_bits(const std::string &text) {
  if (text == "+Infinity" || text == "Infinity") return 0x7f800000;
  if (text == "-Infinity") return 0xff800000;
  float f = ruby_float(ruby_to_f(text));
  uint32_t w;
  std::memcpy(&w, &f, 4);
  return w;
}

int64_t Mod::static_offset(const std::string &name) {
  if (!statics.has(name)) {
    Node **fp = globals.get(name);
    Node **dp = datas.get(name);
    Node *f = fp ? *fp : nullptr;
    Node *d = dp ? *dp : nullptr;
    if (!f && !d) throw Refused("static object @\"" + name + "\" has no definition in the device unit");
    int64_t size, align;
    if (f) {
      bool ext = false;
      for (size_t k = 5; k < f->items.size(); k++)
        if (head_is(f->items[k], "extern")) ext = true;
      if (ext && !eh_state(name)) throw Refused("static object @\"" + name + "\" is extern");
      size = as_int(f->items.at(3));
      align = as_int(f->items.at(4));
    } else {
      size = (int64_t)static_bytes(*d).size();
      align = 1;
    }
    if (align < 4) align = 4;
    int64_t off = (static_size + align - 1) / align * align;
    statics.set(name, off);
    static_order.push_back(name);
    static_size = off + size;
    // objects this one points to are laid out too
    if (f) {
      for (size_t k = 5; k < f->items.size(); k++) {
        if (!head_is(f->items[k], "init")) continue;
        const Node &init = f->items[k];
        for (size_t j = 1; j < init.items.size(); j++) {
          const Node &it = init.items[j];
          if (head_is(it, "addr") && it.items.size() > 3 && it.items[3].is_sym('@')) static_offset(it.items[3].text);
        }
        break;
      }
    }
  }
  return *statics.get(name);
}

std::vector<uint8_t> Mod::static_bytes(const Node &d) const {
  const Node *str = d.items.size() > 3 ? &d.items[3] : nullptr;
  if (!(str && head_is(*str, "string")))
    throw Refused("data " + (d.items.size() > 1 ? to_s(d.items[1]) : std::string()) + ": form " +
                  (str ? form_text(*str) : std::string()));
  std::string b = str->items.size() > 1 ? to_s(str->items[1]) : std::string();
  return std::vector<uint8_t>(b.begin(), b.end());
}

void Mod::static_image(std::vector<uint8_t> &bytes, std::vector<std::pair<int64_t, int64_t>> &relocs) {
  bytes.assign(static_size, 0);
  auto put = [&](int64_t at, uint8_t b) {
    if (at >= (int64_t)bytes.size()) bytes.resize(at + 1, 0);
    bytes[at] = b;
  };
  for (const std::string &name : static_order) {
    int64_t base = *statics.get(name);
    if (datas.has(name)) {
      auto sb = static_bytes(**datas.get(name));
      for (size_t i = 0; i < sb.size(); i++) put(base + i, sb[i]);
      continue;
    }
    Node *f = *globals.get(name);
    const Node *init = nullptr;
    for (size_t k = 5; k < f->items.size(); k++)
      if (head_is(f->items[k], "init")) {
        init = &f->items[k];
        break;
      }
    if (!init && eh_state(name)) continue;   // the EH state starts zeroed, as an extern cell would be
    if (!init) throw Refused("static object " + name + " has no initializer");
    bool nonzero = false;
    for (size_t j = 1; j < init->items.size(); j++) {
      const Node &it = init->items[j];
      const std::string *h = head_of(it);
      int64_t off = base + as_int(it.items.at(1));
      if (h && *h == "scalar") {
        Ty ty = parse_type(it.items.at(2));
        const Node &v = it.items.at(3);
        int64_t n;
        if (head_is(v, "null")) {
          n = 0;
        } else if (ty.k == Ty::Float) {
          if (ty.size != 4) throw Refused("static " + name + ": double");
          n = float_bits(to_s(v.items.at(2)));
        } else {
          n = as_int(v.items.at(2));
        }
        if (n != 0) nonzero = true;
        int size = ty.k == Ty::Ptr ? 8 : ty.size;
        for (int i = 0; i < size; i++) put(off + i, (uint8_t)((n >> (8 * i)) & 255));
      } else if (h && *h == "bytes") {
        Node **src = datas.get(it.items.at(3).text);
        if (!src) throw Refused("static " + name + ": bytes of " + it.items.at(3).text);
        auto sb = static_bytes(**src);
        int64_t cnt = as_int(it.items.at(2));
        for (int64_t i = 0; i < cnt; i++) put(off + i, i < (int64_t)sb.size() ? sb[i] : 0);
        nonzero = true;
      } else if (h && *h == "zero") {
      } else if (h && *h == "addr") {
        if (!(it.items.size() > 3 && it.items[3].is_sym('@'))) throw Refused("static " + name + ": address of a function");
        relocs.push_back({off, *statics.get(it.items[3].text) + as_int(it.items.at(4))});
        nonzero = true;
      } else {
        throw Refused("static " + name + ": initializer item " + (h ? *h : std::string()));
      }
    }
    // An object of an empty ABI type has no members: its zero bytes are its whole value (see the Ruby)
    std::string cname = f->items.size() > 2 && head_is(f->items[2], "struct") ? to_s(f->items[2].items.at(1)) : "";
    bool empty_obj = empty_types.count(cname) != 0;
    if (!nonzero && !empty_obj)
      throw Refused("static object " + name +
                    " is zero-initialized (a dynamic initializer would look the same in the IR, so it is not trusted)");
  }
}
