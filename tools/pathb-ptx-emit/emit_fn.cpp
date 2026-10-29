// One function of the module: scripts/pathb-ptx-emit.rb's class Fn from setup to text (the statements, the calls of the
// module's functions, printf, the builtins that are not in lower_call.cpp). Each function is the Ruby one of the same
// name, with the same order of fresh registers and emitted lines, so the PTX text is the same.
#include "emit_fn.hpp"

#include <algorithm>
#include <functional>
#include <map>
#include <utility>

#include "tables.inc"

namespace {

// The head atom of a non-empty list, or "" (the Ruby's head_of, which is nil there).
std::string head_of(const Node &x) {
  if (x.kind != Node::List || x.items.empty() || x.items[0].kind != Node::Atom) return "";
  return x.items[0].text;
}

// x[i] of a list, or a static empty atom when out of range (the Ruby's nil).
const Node &at(const Node &x, size_t i) {
  static const Node none;
  return i < x.items.size() ? x.items[i] : none;
}

// Whether x[i] is the atom text (the Ruby's x[i] == "text").
bool atom_is(const Node &x, size_t i, const std::string &text) {
  const Node &a = at(x, i);
  return a.kind == Node::Atom && a.text == text;
}

// The forms of x from index i on (the Ruby's x[i..-1] or []).
std::vector<Node> tail(const Node &x, size_t i) {
  if (i >= x.items.size()) return {};
  return std::vector<Node>(x.items.begin() + static_cast<long>(i), x.items.end());
}

bool same_ty(const Ty &a, const Ty &b) {
  return a.kind == b.kind && a.size == b.size && a.is_signed == b.is_signed && a.is_bool == b.is_bool;
}

template <typename Entry>
const Entry *find_entry(const Entry *table, size_t n, const std::string &key) {
  for (size_t i = 0; i < n; i++)
    if (key == table[i].key) return &table[i];
  return nullptr;
}

// Whether a slot of type slot can live in a register with the value of an access of type t: a 4- or 8-byte integer
// (not a bool), a pointer or a float, the same type on both sides.
bool register_slot_type(const Ty &t) {
  if (t.kind == "ptr") return true;
  if (t.kind == "int") return !t.is_bool && (t.size == 4 || t.size == 8);
  if (t.kind == "float") return t.size == 4 || t.size == 8;
  return false;
}

// The slot operands ($name) in x, and those that are the whole address of a load or store of the slot's type.
void count_slot_uses(const Node &x, std::map<std::string, int> &all, std::map<std::string, int> &whole,
                     const std::map<std::string, Ty> &types) {
  if (x.kind == Node::Sym && x.sig == '$') all[x.text]++;
  std::string h = head_of(x);
  if ((h == "load" || h == "store") && x.items.size() >= 3) {
    const Node &addr = x.items[2];
    auto it = addr.kind == Node::Sym && addr.sig == '$' ? types.find(addr.text) : types.end();
    if (it != types.end()) {
      try {
        Ty t = parse_type(&x.items[1]);
        if (t.kind == it->second.kind && t.size == it->second.size && t.is_bool == it->second.is_bool) whole[addr.text]++;
      } catch (const Refused &) {
        // not the slot's type: the access stays a use of the address, and the slot is not promoted
      }
    }
  }
  for (const Node &c : x.items) count_slot_uses(c, all, whole, types);
}

// The register atoms (%N) of x, not counting the names its lets define.
void count_reg_atoms(const Node &x, std::map<std::string, int> &uses) {
  if (x.kind == Node::Atom && !x.text.empty() && x.text[0] == '%') uses[x.text]++;
  bool let = head_of(x) == "let";
  for (size_t i = 0; i < x.items.size(); i++)
    if (!(let && i == 1)) count_reg_atoms(x.items[i], uses);
}

// The loads whose address is a register, and the offset lets: (let X (ptr T) (offset BASE K)) gives offset_of[X] = BASE.
void count_addr_uses(const Node &x, std::map<std::string, int> &loads, std::map<std::string, std::string> &offset_of) {
  std::string h = head_of(x);
  if (h == "load" && x.items.size() == 3 && x.items[2].kind == Node::Atom) loads[x.items[2].text]++;
  if (h == "let" && x.items.size() == 4 && head_of(x.items[3]) == "offset" && x.items[3].items.size() == 3 &&
      x.items[3].items[1].kind == Node::Atom)
    offset_of[x.items[1].text] = x.items[3].items[1].text;
  for (const Node &c : x.items) count_addr_uses(c, loads, offset_of);
}

// Whether the body only reads through register reg: every use of it is a load's address or the base of an offset whose
// result is itself only a load's address.
bool reads_only(const std::vector<const Node *> &body, const std::string &reg) {
  std::map<std::string, int> uses, loads;
  std::map<std::string, std::string> offset_of;
  for (const Node *s : body) {
    count_reg_atoms(*s, uses);
    count_addr_uses(*s, loads, offset_of);
  }
  int offsets = 0;
  for (const auto &[x, base] : offset_of) {
    if (base != reg) continue;
    if (uses[x] != loads[x]) return false;
    offsets++;
  }
  return uses[reg] == loads[reg] + offsets;
}

// The inlined bodies nested in one another (--inline=device): a call past this depth stays a call.
constexpr int kMaxInlineDepth = 4;

// A special register name of the GPU (tid.x, ctaid.y, ...): the Ruby's special_register?.
bool special_register(const std::string &name) {
  size_t dot = name.find('.');
  if (dot == std::string::npos || name.find('.', dot + 1) != std::string::npos) return false;
  std::string a = name.substr(0, dot), b = name.substr(dot + 1);
  return (a == "tid" || a == "ctaid" || a == "ntid" || a == "nctaid") && (b == "x" || b == "y" || b == "z");
}

// Whether a form has a printf call of the printf symbol anywhere (the Ruby's contains_printf?).
bool contains_printf(const Node &f) {
  if (f.kind != Node::List) return false;
  if (head_of(f) == "call" && f.items.size() > 2 && f.items[2].kind == Node::Sym && f.items[2].sig == '&' &&
      f.items[2].text == "printf")
    return true;
  for (const Node &c : f.items)
    if (contains_printf(c)) return true;
  return false;
}

// The pieces of a copy of an aggregate (a byval parameter or argument, or an sret result): (offset, width) pairs, each as
// wide as the alignment allows (8, 4, 2 or 1 bytes) and at an offset that is a multiple of its width. Each piece is one
// ld and one st, as nvcc's struct parameters are moved (the parameter array is aligned to the struct's alignment).
std::vector<std::pair<long long, int>> agg_pieces(long long size, long long align) {
  std::vector<std::pair<long long, int>> out;
  for (long long off = 0; off < size;) {
    int w = 8;
    while (w > 1 && (w > align || off % w != 0 || off + w > size)) w /= 2;
    out.push_back({off, w});
    off += w;
  }
  return out;
}

// The register class of a copy piece of width w (bytes): a 16-bit piece is a .b16 register, the others .b32 or .b64.
std::string piece_reg(int w) { return w == 8 ? "rd" : w == 2 ? "h" : "r"; }

// The access type of a copy piece of width w: loads are unsigned (zero-extended), stores are untyped bits.
std::string piece_load(int w) { return "u" + std::to_string(w * 8); }
std::string piece_store(int w) { return "b" + std::to_string(w * 8); }

}  // namespace

std::map<std::string, AggShape> abi_shapes(const std::vector<Node> &forms) {
  std::map<std::string, AggShape> out;
  for (const Node &f : forms) {
    if (head_of(f) != "abi-type") continue;
    if (f.items.size() < 4 || f.items[1].kind != Node::Str) throw BadIR("abi-type form " + form_text(f));
    AggShape sh;
    sh.size = static_cast<long long>(as_int(&f.items[2]));
    sh.align = static_cast<long long>(as_int(&f.items[3]));
    sh.empty = f.items.size() == 5 && head_of(f.items[4]) == "empty";
    out[f.items[1].text] = sh;
  }
  return out;
}

Fn::Fn(std::string name, size_t index, Loader load) : load_(std::move(load)), index_(index), name_(std::move(name)) {}

AggShape Fn::aggregate(const Node &type) const {
  // A const-qualified struct passes the same bytes: (const (struct NAME)) is the struct.
  const Node &t = head_of(type) == "const" && type.items.size() == 2 ? type.items[1] : type;
  std::string h = head_of(t);
  if (!((h == "struct" || h == "union") && t.items.size() == 2 && t.items[1].kind == Node::Str))
    throw Refused("aggregate form " + form_text(type));
  const std::string &name = t.items[1].text;
  if (!aggs) throw Refused(h + " " + name + " passed by value (the module has no (abi-type) forms)");
  auto it = aggs->find(name);
  if (it == aggs->end()) throw Refused(h + " " + name + " has no (abi-type) form");
  if (it->second.size <= 0 || it->second.align <= 0) throw Refused(h + " " + name + " has no size");
  if (it->second.empty) return it->second;
  return it->second;
}

long long Fn::alloc_frame(long long size, long long align) {
  if (align < 1) align = 1;
  frame_align_ = std::max(frame_align_, align);
  frame_ = (frame_ + align - 1) / align * align;
  long long off = frame_;
  frame_ += size;
  return off;
}

void Fn::release() {
  body_.clear();
  form_.reset();
  lines.clear();
  lines.shrink_to_fit();
  prologue_.clear();
  prologue_.shrink_to_fit();
}

void Fn::label(const std::string &l) { lines.push_back(l + ":"); }

std::string Fn::named_label(const std::string &name) {
  auto it = named_labels_.find(name);
  if (it != named_labels_.end()) return it->second;
  std::string l = new_label();
  named_labels_[name] = l;
  return l;
}

// The PTX name of parameter k: the parameters are numbered as nvcc numbers them, without the sret result.
std::string Fn::param_name(size_t k) const {
  size_t n = 0;  // the PTX parameters before k: not the sret result, not a function's empty object
  for (size_t j = 0; j < k; j++)
    if (is_ptx_param(j)) n++;
  return name_ + "_param_" + std::to_string(n);
}

bool Fn::is_ptx_param(size_t k) const {
  if (sret && k == 0) return false;
  // a kernel's empty object is the host's one byte (the argument layout of the launch); a function's is not passed
  return kernel || !(agg_params[k] && agg_params[k]->empty);
}

std::string Fn::ret_bits(const Ty &t) const {
  return t.kind == "float" ? "f" + std::to_string(t.size * 8) : bits_type(t);
}

void Fn::setup() {
  if (setup_done_) return;
  setup_done_ = true;
  if (!form_) form_ = load_();
  body_.clear();
  bool have_ret = false;
  const Node &form = *form_;
  // Each parameter (and the hidden result) has its entry in agg_params and agg_off_, parallel to params.
  auto add_param = [this](const Ty &t, std::optional<AggShape> agg, long long off) {
    params.push_back(t);
    agg_params.push_back(agg);
    agg_off_.push_back(off);
  };
  for (size_t i = 2; i < form.items.size(); i++) {
    const Node &f = form.items[i];
    std::string h = head_of(f);
    if (h == "ret") {
      Ty t = parse_type(&at(f, 1));
      have_ret = true;
      if (t.kind == "void") {
        ret.reset();
      } else if (kernel) {
        throw Refused("kernel " + name_ + " returns a value");
      } else {
        bool ok = t.kind == "ptr" || (t.kind == "int" && !t.is_bool && (t.size == 1 || t.size == 2 || t.size == 4 || t.size == 8)) ||
                  (t.kind == "float" && (t.size == 4 || t.size == 8));
        if (!ok) throw Refused("function " + name_ + " returns a " + t.kind + " (scalars only)");
        ret = t;
      }
    } else if (h == "params") {
      for (size_t k = 1; k < f.items.size(); k++) {
        const Node &p = f.items[k];
        size_t kk = k - 1;
        std::string ph = head_of(p);
        if (ph == "ellipsis") throw Refused("variadic function");
        if (ph == "sret") {
          // the hidden result of a function returning a struct: a .param array of the device function (nvcc's
          // func_retval0), not a PTX parameter. The IR's register is the address of the result object, which is a
          // frame slot here and copied to func_retval0 at each return.
          if (p.items.size() != 3) throw Refused("sret form " + form_text(p));
          if (!atom_is(p, 1, "%" + std::to_string(kk))) throw BadIR("sret register must be %" + std::to_string(kk));
          if (kernel) throw Refused("kernel " + name_ + " returns a struct");
          AggShape sh = aggregate(p.items[2]);
          sret = sh;
          add_param(Ty{"ptr", -1, false, false}, sh, alloc_frame(sh.size, sh.align));
          continue;
        }
        if (!(ph == "param" && p.items.size() == 4)) throw Refused("parameter form " + form_text(p));
        if (!atom_is(p, 1, "%" + std::to_string(kk))) throw BadIR("parameter register must be %" + std::to_string(kk));
        if (head_of(p.items[3]) == "byval") {
          // a struct or union passed by value: the caller copies its bytes into a .param array (nvcc's convention), and
          // the callee copies them into the frame (compile), so its register is the address of that copy
          if (p.items[3].items.size() != 2) throw Refused("byval form " + form_text(p.items[3]));
          AggShape sh = aggregate(p.items[3].items[1]);
          add_param(Ty{"ptr", -1, false, false}, sh, alloc_frame(sh.size, sh.align));
          continue;
        }
        Ty t = parse_type(&p.items[3]);
        bool ok = t.kind == "ptr" || (t.kind == "int" && !t.is_bool && (t.size == 1 || t.size == 2 || t.size == 4 || t.size == 8)) ||
                  (t.kind == "int" && t.is_bool) || (t.kind == "float" && (t.size == 4 || t.size == 8));
        if (!ok) throw Refused("parameter of type " + t.kind);
        add_param(t, std::nullopt, 0);
      }
    } else if (h == "static" || h == "weak") {
      // linkage of the function: no effect on the PTX (the entry or helper is emitted the same way)
    } else if (h == "slot") {
      // (slot "x" TYPE) or (slot "x" TYPE SIZE ALIGN): the explicit size and alignment are the ones of the IR's layout
      if (!(f.items.size() == 3 || f.items.size() == 5)) throw Refused("slot form " + form_text(f));
      long long size, align;
      if (f.items.size() == 5) {
        size = static_cast<long long>(as_int(&f.items[3]));
        align = static_cast<long long>(as_int(&f.items[4]));
      } else {
        size = type_size(parse_type(&f.items[2]));
        align = size;
      }
      slots[f.items[1].text] = static_cast<int>(alloc_frame(size, align));
      if (g_promote_slots) {
        // a slot of another type (an aggregate, say) is not a candidate, and its uses are not read as its type
        try {
          Ty t = parse_type(&f.items[2]);
          if (register_slot_type(t)) slot_types_[f.items[1].text] = t;
        } catch (const Refused &) {
        }
      }
    } else {
      body_.push_back(&f);
    }
  }
  if (!have_ret) throw BadIR("function without a return type");
  frame_ = (frame_ + 7) / 8 * 8;
}

void Fn::compile() {
  setup();
  bool printf_in_body = false;
  for (const Node *s : body_) printf_in_body = printf_in_body || contains_printf(*s);
  // With --inline=device an inlined call takes its frame in this one (inline_call), so the frame pointer is set up for it.
  sp_set_ = frame_ > 0 || printf_in_body || g_inline_device;
  if (sp_set_) {
    sp = fresh("rd");
    prologue_.push_back("mov.u64 " + sp + ", __local_depot" + std::to_string(index_) + ";");
    prologue_.push_back("cvta.local.u64 " + sp + ", " + sp + ";");
  }
  for (size_t k = 0; k < params.size(); k++) {
    const Ty ty = params[k];
    std::string r = fresh(reg_class(ty));
    regs["%" + std::to_string(k)] = RegInfo{r, ty};
    std::string pk = param_name(k);
    if (agg_params[k]) {
      // the register is the frame address of the object: a byval copy is loaded from the parameter array (its bytes),
      // the sret result is the frame slot that emit_return copies to func_retval0
      const AggShape &sh = *agg_params[k];
      prologue_.push_back("add.u64 " + r + ", " + sp + ", " + std::to_string(agg_off_[k]) + ";");
      if (is_ptx_param(k)) {
        for (auto [off, w] : agg_pieces(sh.size, sh.align)) {
          std::string t = fresh(piece_reg(w));
          prologue_.push_back("ld.param." + piece_load(w) + " " + t + ", [" + pk + "+" + std::to_string(off) + "];");
          prologue_.push_back("st." + piece_store(w) + " [" + r + "+" + std::to_string(off) + "], " + t + ";");
        }
      }
    } else if (ty.kind == "int" && ty.is_bool) {
      // a bool parameter is one byte (PTX has no predicate parameters): load it, then the predicate is value != 0
      std::string b = fresh("r");
      prologue_.push_back(std::string("ld.param.") + (kernel ? "u8" : "u32") + " " + b + ", [" + pk + "];");
      prologue_.push_back("setp.ne.u32 " + r + ", " + b + ", 0;");
    } else {
      prologue_.push_back("ld.param." + ptx_type(ty) + " " + r + ", [" + pk + "];");
    }
  }
  promote_slots(body_, slot_types_);
  for (const Node *s : body_) stmt(*s);
  if (body_.empty() || head_of(*body_.back()) != "return") emit_return();
}

void Fn::emit_return() {
  // the sret result is copied from its frame slot to func_retval0 (a .param array) before the return
  if (sret && !sret->empty) {
    long long base = agg_off_[0];
    for (auto [off, w] : agg_pieces(sret->size, sret->align)) {
      std::string t = fresh(piece_reg(w));
      emit("ld." + piece_load(w) + " " + t + ", [" + sp + "+" + std::to_string(base + off) + "];");
      emit("st.param." + piece_store(w) + " [func_retval0+" + std::to_string(off) + "], " + t + ";");
    }
  }
  emit("ret;");
}

std::string Fn::text() const {
  std::vector<std::string> out;
  if (kernel) {
    out.push_back(".visible .entry " + name_ + "(");
  } else if (ret) {
    out.push_back(".func (.reg ." + ret_bits(*ret) + " %rv) " + name_ + "(");
  } else if (sret && !sret->empty) {
    out.push_back(".func (.param .align " + std::to_string(sret->align) + " .b8 func_retval0[" + std::to_string(sret->size) +
                  "]) " + name_ + "(");
  } else {
    out.push_back(".func " + name_ + "(");
  }
  std::vector<std::string> decls;
  for (size_t k = 0; k < params.size(); k++) {
    if (!is_ptx_param(k)) continue;  // the result, and an empty object, are not parameters
    const Ty &ty = params[k];
    std::string pk = param_name(k);
    if (agg_params[k]) {
      decls.push_back(".param .align " + std::to_string(agg_params[k]->align) + " .b8 " + pk + "[" +
                      std::to_string(agg_params[k]->size) + "]");
      continue;
    }
    // a kernel's bool parameter is the host's one byte; a device function's is 32 bits
    std::string bool_type = kernel ? "u8" : "u32";
    std::string t = (ty.kind == "int" && ty.is_bool) ? bool_type : ptx_type(ty);
    decls.push_back(".param ." + t + " " + pk);
  }
  for (size_t i = 0; i < decls.size(); i++)
    out.push_back("  " + decls[i] + (i + 1 < decls.size() ? "," : ""));
  out.push_back(")");
  out.push_back("{");
  auto count_of = [&](const char *c) { return count.at(c); };
  if (count_of("p") > 0) out.push_back("  .reg .pred %p<" + std::to_string(count_of("p")) + ">;");
  if (count_of("r") > 0) out.push_back("  .reg .b32 %r<" + std::to_string(count_of("r")) + ">;");
  if (count_of("rd") > 0) out.push_back("  .reg .b64 %rd<" + std::to_string(count_of("rd")) + ">;");
  if (count_of("f") > 0) out.push_back("  .reg .f32 %f<" + std::to_string(count_of("f")) + ">;");
  if (count_of("h") > 0) out.push_back("  .reg .b16 %h<" + std::to_string(count_of("h")) + ">;");
  if (count_of("fd") > 0) out.push_back("  .reg .f64 %fd<" + std::to_string(count_of("fd")) + ">;");
  if (frame_ > 0 || sp_set_) {
    out.push_back("  .local .align " + std::to_string(frame_align_) + " .b8 __local_depot" + std::to_string(index_) + "[" +
                  std::to_string(frame_ > 0 ? frame_ : 8) + "];");
  }
  for (const std::string &s : prologue_) out.push_back("  " + s);
  for (const std::string &s : lines) out.push_back(s);
  out.push_back("}");
  std::string text;
  for (const std::string &s : out) text += s + "\n";
  return text;
}

void Fn::stmt(const Node &s) {
  std::string h = head_of(s);
  if (h == "block") {
    for (size_t i = 1; i < s.items.size(); i++) stmt(s.items[i]);
  } else if (h == "let") {
    const Node &v = at(s, 3);
    if (head_of(v) == "bitcast" && v.items.size() == 3 && v.items[2].kind == Node::Sym && v.items[2].sig == '&')
      fn_values_[at(s, 1).text] = v.items[2].text;
    Ty ty = parse_type(&at(s, 2));
    std::string dest = ir_reg(at(s, 1).text, ty);
    rval(at(s, 3), dest, ty);
    canon(dest, ty);
  } else if (h == "set") {
    auto it = regs.find(at(s, 1).text);
    if (it == regs.end()) throw BadIR("set of " + at(s, 1).text + " before its let");
    Operand o = operand(at(s, 2));
    expect(it->second.ty, o.ty);
    // a bool register is a predicate: its value is copied as a predicate (operand gives one for a bool)
    if (reg_class(it->second.ty) == "p") {
      emit("mov.pred " + it->second.ptx + ", " + o.text + ";");
    } else {
      emit("mov." + ptx_type(it->second.ty) + " " + it->second.ptx + ", " + o.text + ";");
    }
  } else if (h == "copy") {
    // (copy BYTES DST SRC): the bytes of an aggregate, moved through generic addresses, one byte at a time (the IR's
    // copy does not give the alignment of the objects, and a wider access of a struct with alignment 2 is misaligned)
    long long n = static_cast<long long>(as_int(&at(s, 1)));
    Operand d = operand(at(s, 2));
    Operand sr_ = operand(at(s, 3));
    std::string dr = reg_of(d.text, d.ty);
    std::string sr = reg_of(sr_.text, sr_.ty);
    for (long long off = 0; off < n; off++) {
      std::string t = fresh("r");
      emit("ld.u8 " + t + ", [" + sr + "+" + std::to_string(off) + "];");
      emit("st.u8 [" + dr + "+" + std::to_string(off) + "], " + t + ";");
    }
  } else if (h == "if") {
    Operand c = operand(at(s, 1));
    if (!(reg_class(c.ty) == "p" && !c.text.empty() && c.text[0] == '%')) throw BadIR("if condition is not a bool register");
    const Node *then_f = nullptr, *else_f = nullptr;
    for (size_t i = 2; i < s.items.size(); i++) {
      if (!then_f && head_of(s.items[i]) == "then") then_f = &s.items[i];
      if (!else_f && head_of(s.items[i]) == "else") else_f = &s.items[i];
    }
    if (!then_f) throw BadIR("if without then");
    std::string lab_else = new_label();
    std::string lab_end = new_label();
    emit("@!" + c.text + " bra " + lab_else + ";");
    for (size_t i = 1; i < then_f->items.size(); i++) stmt(then_f->items[i]);
    emit("bra " + lab_end + ";");
    label(lab_else);
    if (else_f)
      for (size_t i = 1; i < else_f->items.size(); i++) stmt(else_f->items[i]);
    label(lab_end);
  } else if (h == "loop") {
    // repeat { body; L_cont: step }: break leaves to L_end, continue goes to L_cont (the step), as pathb-stage2 says
    const Node *body_f = nullptr, *step_f = nullptr;
    for (size_t i = 1; i < s.items.size(); i++) {
      if (!body_f && head_of(s.items[i]) == "body") body_f = &s.items[i];
      if (!step_f && head_of(s.items[i]) == "step") step_f = &s.items[i];
    }
    if (!body_f || !step_f) throw BadIR("loop without body and step");
    std::string top = new_label();
    std::string lab_cont = new_label();
    std::string lab_end = new_label();
    label(top);
    loops_.push_back({lab_cont, lab_end});
    for (size_t i = 1; i < body_f->items.size(); i++) stmt(body_f->items[i]);
    label(lab_cont);
    for (size_t i = 1; i < step_f->items.size(); i++) stmt(step_f->items[i]);
    loops_.pop_back();
    emit("bra " + top + ";");
    label(lab_end);
  } else if (h == "switch") {
    // The arms are a flat list with case and default markers (pathb-stage2 section 2). A dispatch chain compares the
    // operand with each case value and branches; the body follows, with C fallthrough between its markers. `break`
    // leaves to the end label (the switch is on the loop stack with no continue label).
    const Node *body_f = nullptr;
    for (size_t i = 1; i < s.items.size(); i++)
      if (!body_f && head_of(s.items[i]) == "body") body_f = &s.items[i];
    if (!body_f) throw BadIR("switch without body");
    Operand v = operand(at(s, 1));
    if (!(v.ty.kind == "int" && !v.ty.is_bool)) throw Refused("switch on a " + v.ty.kind);
    int vsize = type_size(v.ty);
    if (!(vsize == 4 || vsize == 8)) throw Refused("switch on a " + std::to_string(vsize) + "-byte integer (only 32 and 64 bits are lowered)");
    std::string vr = reg_of(v.text, v.ty);
    std::vector<const Node *> items;
    // the body's forms, with the blocks flattened
    std::function<void(const Node &)> expand = [&](const Node &f) {
      if (head_of(f) == "block") {
        for (size_t i = 1; i < f.items.size(); i++) expand(f.items[i]);
      } else {
        items.push_back(&f);
      }
    };
    for (size_t i = 1; i < body_f->items.size(); i++) expand(body_f->items[i]);
    std::string lab_end = new_label();
    struct Arm {
      size_t idx;
      std::string lab;
      bool is_default;
      i128 val;
    };
    std::vector<Arm> arms;
    std::string default_lab;
    for (size_t idx = 0; idx < items.size(); idx++) {
      const Node &it = *items[idx];
      std::string h2 = head_of(it);
      if (h2 == "case") {
        const Node &c = at(it, 1);
        if (head_of(c) != "const") throw BadIR("case value is not a constant");
        Ty cty = parse_type(&at(c, 1));
        if (!same_ty(cty, v.ty)) throw Refused("case of a different type than the switch");
        i128 val = as_int(&at(c, 2));
        for (const Arm &a : arms)
          if (!a.is_default && a.val == val) throw Refused("duplicate case " + i128_text(val));
        arms.push_back(Arm{idx, new_label(), false, val});
      } else if (h2 == "default") {
        if (!default_lab.empty()) throw Refused("two default labels");
        default_lab = new_label();
        arms.push_back(Arm{idx, default_lab, true, 0});
      }
    }
    std::string bits = bits_type(v.ty);
    for (const Arm &a : arms) {
      if (a.is_default) continue;
      std::string q = fresh("p");
      emit("setp.eq." + bits + " " + q + ", " + vr + ", " + imm(v.ty, a.val) + ";");
      emit("@" + q + " bra " + a.lab + ";");
    }
    emit("bra " + (default_lab.empty() ? lab_end : default_lab) + ";");
    loops_.push_back({"", lab_end});
    for (size_t idx = 0; idx < items.size(); idx++) {
      const Arm *hit = nullptr;
      for (const Arm &a : arms)
        if (a.idx == idx) hit = &a;
      if (hit) {
        label(hit->lab);
      } else {
        stmt(*items[idx]);
      }
    }
    loops_.pop_back();
    label(lab_end);
  } else if (h == "label") {
    label(named_label(at(s, 1).text));
  } else if (h == "goto") {
    emit("bra " + named_label(at(s, 1).text) + ";");
  } else if (h == "break") {
    if (loops_.empty()) throw Refused("break outside a loop or switch");
    emit("bra " + loops_.back().second + ";");
  } else if (h == "continue") {
    // the innermost loop: a switch on the stack has no continue label
    const std::pair<std::string, std::string> *enclosing = nullptr;
    for (auto it = loops_.rbegin(); it != loops_.rend(); ++it)
      if (!it->first.empty()) {
        enclosing = &*it;
        break;
      }
    if (!enclosing) throw BadIR("continue outside a loop");
    emit("bra " + enclosing->first + ";");
  } else if (h == "loc" || h == "likely" || h == "unlikely") {
    // source position and branch hints (docs/notes/ubsan.md): no code
  } else if (h == "trap" || h == "unreachable") {
    // (trap) and (unreachable): an illegal instruction on the GPU; the IR spec says unreachable traps
    emit("trap;");
  } else if (h == "ptx-asm") {
    asm_stmt(s);
  } else if (h == "bounds") {
    // (bounds IDX N): traps unless 0 <= IDX < N. One unsigned compare does both ends of a signed index.
    Operand v = operand(at(s, 1));
    if (v.ty.kind != "int") throw Refused("bounds of a non-integer");
    i128 n = as_int(&at(s, 2));
    std::string uty = v.ty.size * 8 == 64 ? "u64" : "u32";
    std::string q = fresh("p");
    emit("setp.ge." + uty + " " + q + ", " + reg_of(v.text, v.ty) + ", " + i128_text(n) + ";");
    emit("@" + q + " trap;");
  } else if (h == "nonnull") {
    // (nonnull P): a null pointer traps (pathb-stage2 section 4). A null constant always traps.
    Operand p = operand(at(s, 1));
    if (p.ty.kind != "ptr") throw Refused("nonnull of " + form_text(at(s, 1)));
    if (p.text == "0") {
      emit("trap;");
    } else {
      std::string q = fresh("p");
      emit("setp.eq.u64 " + q + ", " + reg_of(p.text, p.ty) + ", 0;");
      emit("@" + q + " trap;");
    }
  } else if (h == "return") {
    if (inline_depth_ > 0) {
      // a return of an inlined body: the value is the call's register, and the code after the call comes next
      if (inline_ret_) {
        if (s.items.size() != 2) throw Refused("return without a value in an inlined function");
        Operand v = operand(at(s, 1));
        expect(*inline_ret_, v.ty);
        if (!inline_dest_.empty()) emit("mov." + ret_bits(*inline_ret_) + " " + inline_dest_ + ", " + reg_of(v.text, v.ty) + ";");
      } else if (s.items.size() > 1) {
        throw Refused("return with a value in a void function");
      }
      emit("bra " + inline_end_ + ";");
    } else if (!ret) {
      if (s.items.size() > 1) throw Refused("return with a value in a void function");
      emit_return();
    } else {
      if (s.items.size() != 2) throw Refused("return without a value in " + name_);
      Operand v = operand(at(s, 1));
      expect(*ret, v.ty);
      emit("mov." + ret_bits(*ret) + " %rv, " + reg_of(v.text, v.ty) + ";");
      emit("ret;");
    }
  } else if (h == "eval") {
    // an expression statement: only a call, whose value is discarded
    if (!(s.items.size() == 2 && head_of(at(s, 1)) == "call")) throw Refused("eval of " + form_text(at(s, 1)));
    call_site(at(s, 1), "", nullptr);
  } else if (store_stmt(h, s)) {
    // store and store.v (lower_mem.cpp)
  } else {
    throw Refused("statement " + (h.empty() ? form_text(s) : h));
  }
}

void Fn::rval(const Node &x, const std::string &dest, const Ty &dty) {
  std::string h = head_of(x);
  if (h == "call") {
    // The device intrinsics of a kernel are special-register reads and the builtins of lower_call.cpp. Any other callee is
    // a function of the module (call_site).
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    call_value(x, dest, ty);
    return;
  }
  if (h == "null") {
    // a null pointer (or integer zero) as the value of a let: the same 0 the operand gives (lower_arith.cpp)
    Ty ty = parse_type(&at(x, 1));
    if (ty.is_bool) throw Refused("null of bool");
    expect(dty, ty);
    emit("mov." + ptx_type(ty) + " " + dest + ", 0;");
    return;
  }
  if (h == "gpu") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    std::string n = at(x, 2).text;
    if (!special_register(n)) throw Refused("special register " + n);
    emit("mov.u32 " + dest + ", %" + n + ";");
    return;
  }
  if (h == "const") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    if (ty.kind == "int" && ty.is_bool) {
      emit(bool_const_setp(dest, at(x, 2).text));
    } else {
      Operand o = operand(x);
      emit("mov." + ptx_type(ty) + " " + dest + ", " + o.text + ";");
    }
    return;
  }
  if (memory(h, x, dest, dty)) return;
  if (arith(h, x, dest, dty)) return;
  throw Refused("expression " + (h.empty() ? form_text(x) : h));
}

void Fn::call_value(const Node &x, const std::string &dest, const Ty &ty) {
  const Node &callee = at(x, 2);
  std::string name = (callee.kind == Node::Sym && callee.sig == '&') ? callee.text : "";
  if (name == "__nfcxx_dynshared_addr") {
    // The dynamic shared memory of the launch (`extern __shared__ T buf[]`, rewritten by cuda-rewrite.rb): one
    // module-level extern .shared symbol, whose generic address is taken with cvta.shared (see emit_module).
    if (x.items.size() != 3) throw Refused("intrinsic " + name + " takes no arguments");
    if (ty.kind != "ptr") throw Refused("intrinsic " + name + " returns " + ty.kind + ", not a pointer");
    emit(std::string("cvta.shared.u64 ") + dest + ", " + DYNSHARED_SYM + ";");
    uses_dynshared = true;
    return;
  }
  if (!name.empty() && FnCtx::call(x, dest, ty)) return;
  if (name == "memset") {
    // (call (ptr void) &"memset" P V N), N a constant: EDG's zeroing of an object before its constructor runs (the
    // value-initialization of llama.cpp's mma tiles). Byte stores (the alignment of P is not known, as for copy); the
    // value is P.
    if (x.items.size() != 6) throw Refused("memset takes (pointer, value, count)");
    const Node &nn = at(x, 5);
    if (head_of(nn) != "const" || nn.items.size() != 3) throw Refused("memset of a size that is not a constant");
    const long long count = static_cast<long long>(as_int(&nn.items[2]));
    if (count < 0 || count > 4096) throw Refused("memset of " + std::to_string(count) + " bytes");
    Operand p = operand(at(x, 3)), v = operand(at(x, 4));
    if (p.ty.kind != "ptr") throw Refused("memset of a non-pointer");
    if (!(v.ty.kind == "int" && type_size(v.ty) == 4)) throw Refused("memset with a value of type " + v.ty.kind);
    const std::string base = reg_of(p.text, p.ty);
    const std::string b = reg_of(v.text, v.ty);  // st.u8 stores the low byte of a 32-bit register, as copy's do
    for (long long i = 0; i < count; i++) emit("st.u8 [" + base + "+" + std::to_string(i) + "], " + b + ";");
    if (ty.kind != "ptr") throw Refused("memset returns a pointer");
    emit("mov.u64 " + dest + ", " + base + ";");
    return;
  }
  if (name == "printf") {
    printf_call(x, dest, ty);
  } else if (find_entry(SCALAR_U32, SCALAR_U32_N, name)) {
    scalar_u32(name, x, dest, ty);
  } else if (find_entry(FLOAT_BUILTINS, FLOAT_BUILTINS_N, name)) {
    float_builtin(name, x, dest, ty);
  } else if (find_entry(FLOAT_TO_INT_BUILTINS, FLOAT_TO_INT_BUILTINS_N, name)) {
    float_to_int_builtin(name, x, dest, ty);
  } else if (find_entry(HALF_BUILTINS, HALF_BUILTINS_N, name)) {
    half_builtin(name, x, dest, ty);
  } else {
    call_site(x, dest, &ty);
  }
}

void Fn::scalar_u32(const std::string &name, const Node &x, const std::string &dest, const Ty &ty) {
  const KvOp *e = find_entry(SCALAR_U32, SCALAR_U32_N, name);
  std::vector<Node> args = tail(x, 3);
  if (dest.empty()) throw Refused(name + " has no value");
  if (static_cast<int>(args.size()) != e->n) throw Refused(name + " takes " + std::to_string(e->n) + " argument(s)");
  if (!(ty.kind == "int" && type_size(ty) == 4)) throw Refused(name + " returns " + ty.kind);
  std::vector<std::string> regs_;
  for (const Node &a : args) {
    Operand o = operand(a);
    if (!(o.ty.kind == "int" && o.ty.size == 4)) throw Refused(name + ": argument of type " + o.ty.kind);
    regs_.push_back(reg_of(o.text, o.ty));
  }
  std::string list;
  for (size_t i = 0; i < regs_.size(); i++) list += (i ? ", " : "") + regs_[i];
  emit(std::string(e->op) + " " + dest + ", " + list + ";");
}

void Fn::float_builtin(const std::string &name, const Node &x, const std::string &dest, const Ty &ty) {
  const KvFloatOp *e = find_entry(FLOAT_BUILTINS, FLOAT_BUILTINS_N, name);
  std::vector<Node> args = tail(x, 3);
  if (dest.empty()) throw Refused(name + " has no value");
  if (static_cast<int>(args.size()) != e->n) throw Refused(name + " takes " + std::to_string(e->n) + " argument(s)");
  if (!(ty.kind == "float" && type_size(ty) == 4)) throw Refused(name + " returns " + ty.kind + ", not a 32-bit float");
  std::vector<std::string> regs_;
  for (const Node &a : args) {
    Operand o = operand(a);
    if (!(o.ty.kind == "float" && o.ty.size == 4)) throw Refused(name + ": argument of type " + o.ty.kind);
    regs_.push_back(reg_of(o.text, o.ty));
  }
  // exp and log are two instructions: expf(x) = 2^(x * log2(e)) and logf(x) = log2(x) * ln(2), with the scale in the f32
  // hex form (exact constants)
  std::string op = e->op;
  if (e->is_symbol && op == "exp") {
    std::string t = fresh("f");
    emit("mul.rn.f32 " + t + ", " + regs_[0] + ", 0f3FB8AA3B;");  // log2(e)
    emit("ex2.approx.f32 " + dest + ", " + t + ";");
  } else if (e->is_symbol && op == "log") {
    std::string t = fresh("f");
    emit("lg2.approx.f32 " + t + ", " + regs_[0] + ";");
    emit("mul.rn.f32 " + dest + ", " + t + ", 0f3F317218;");  // ln(2)
  } else {
    std::string list;
    for (size_t i = 0; i < regs_.size(); i++) list += (i ? ", " : "") + regs_[i];
    emit(op + " " + dest + ", " + list + ";");
  }
}

void Fn::float_to_int_builtin(const std::string &name, const Node &x, const std::string &dest, const Ty &ty) {
  const KvStr *e = find_entry(FLOAT_TO_INT_BUILTINS, FLOAT_TO_INT_BUILTINS_N, name);
  std::vector<Node> args = tail(x, 3);
  if (dest.empty()) throw Refused(name + " has no value");
  if (args.size() != 1) throw Refused(name + " takes 1 argument(s)");
  if (!(ty.kind == "int" && ty.is_signed && type_size(ty) == 4))
    throw Refused(name + " returns " + ty.kind + ", not a 32-bit signed integer");
  Operand v = operand(args[0]);
  if (!(v.ty.kind == "float" && v.ty.size == 4)) throw Refused(name + ": argument of type " + v.ty.kind);
  emit(std::string(e->value) + " " + dest + ", " + reg_of(v.text, v.ty) + ";");
}

void Fn::half_builtin(const std::string &name, const Node &x, const std::string &dest, const Ty &ty) {
  const KvOp *e = find_entry(HALF_BUILTINS, HALF_BUILTINS_N, name);
  std::vector<Node> args = tail(x, 3);
  if (dest.empty()) throw Refused(name + " has no value");
  if (static_cast<int>(args.size()) != e->n) throw Refused(name + " takes " + std::to_string(e->n) + " argument(s)");
  if (!(ty.kind == "int" && !ty.is_signed && type_size(ty) == 2))
    throw Refused(name + " returns " + ty.kind + ", not a 16-bit unsigned integer");
  std::vector<std::string> regs_;
  for (const Node &a : args) {
    Operand o = operand(a);
    if (!(o.ty.kind == "int" && o.ty.size == 2)) throw Refused(name + ": argument of type " + o.ty.kind);
    std::string t = fresh("h");
    emit("cvt.u16.u32 " + t + ", " + reg_of(o.text, o.ty) + ";");
    regs_.push_back(t);
  }
  std::string r = fresh("h");
  std::string list;
  for (size_t i = 0; i < regs_.size(); i++) list += (i ? ", " : "") + regs_[i];
  emit(std::string(e->op) + " " + r + ", " + list + ";");
  emit("cvt.u32.u16 " + dest + ", " + r + ";");
}

void Fn::printf_call(const Node &x, const std::string &dest, const Ty &ty) {
  if (!(ty.kind == "int" && type_size(ty) == 4)) throw Refused("printf returns " + ty.kind + ", not int");
  if (!(head_of(at(x, 3)) == "variadic" && x.items.size() >= 5 && as_int(&at(at(x, 3), 1)) == 1))
    throw Refused("printf is not a variadic call of one fixed argument");
  const Node &fmt = at(x, 4);
  if (!(fmt.kind == Node::Sym && fmt.sig == '@' && mod && mod->strings.count(fmt.text)))
    throw Refused("printf format must be a string constant");
  std::vector<Node> vargs = tail(x, 5);
  // the operands first (they may emit code), then the layout: each argument at its own size, naturally aligned
  std::vector<Operand> ops;
  for (const Node &a : vargs) ops.push_back(operand(a));
  struct Slot {
    Operand op;
    long long off;
  };
  std::vector<Slot> layout;
  long long off = 0;
  for (const Operand &o : ops) {
    const Ty &t = o.ty;
    if (!((t.kind == "int" && (t.size == 4 || t.size == 8)) || (t.kind == "float" && t.size == 8) || t.kind == "ptr"))
      throw Refused("printf argument of type " + t.kind + " " + std::to_string(t.size) +
                    " bytes (an int of 4 or 8 bytes, a double or a pointer)");
    long long size = t.kind == "ptr" ? 8 : t.size;
    off = (off + size - 1) / size * size;
    layout.push_back(Slot{o, off});
    off += size;
  }
  long long buf = (frame_ + 7) / 8 * 8;
  frame_ = buf + (off + 7) / 8 * 8;
  std::string base = fresh("rd");
  emit("add.u64 " + base + ", " + sp + ", " + std::to_string(buf) + ";");
  for (const Slot &sl : layout) {
    std::string value = reg_of(sl.op.text, sl.op.ty);
    std::string addr = fresh("rd");
    emit("add.u64 " + addr + ", " + base + ", " + std::to_string(sl.off) + ";");
    emit("st." + ptx_type(sl.op.ty) + " [" + addr + "], " + value + ";");
  }
  std::string fmt_reg = fresh("rd");
  emit("cvta.const.u64 " + fmt_reg + ", " + string_const_sym(mod->data_name(fmt.text)) + ";");
  int n = ++nlab;
  std::string N = std::to_string(n);
  emit("{");
  emit("  .param .b64 __pf_fmt_" + N + ";");
  emit("  .param .b64 __pf_buf_" + N + ";");
  emit("  .param .b32 __pf_rv_" + N + ";");
  emit("  st.param.b64 [__pf_fmt_" + N + "], " + fmt_reg + ";");
  emit("  st.param.b64 [__pf_buf_" + N + "], " + base + ";");
  emit("  call (__pf_rv_" + N + "), vprintf, (__pf_fmt_" + N + ", __pf_buf_" + N + ");");
  if (!dest.empty()) emit("  ld.param.b32 " + dest + ", [__pf_rv_" + N + "];");
  emit("}");
  uses_printf = true;
}

void Fn::call_site(const Node &x, const std::string &dest, const Ty *ty) {
  const Node &callee_sym = at(x, 2);
  if (!(callee_sym.kind == Node::Sym && callee_sym.sig == '&')) throw Refused("indirect call");
  const std::string cname = callee_sym.text;
  size_t n = x.items.size();
  if (cname == "__nfcxx_syncthreads") {
    // the block barrier: every thread of the block waits here, and shared memory is visible after it
    if (n != 3) throw Refused("__nfcxx_syncthreads takes no arguments");
    if (!dest.empty()) throw Refused("__nfcxx_syncthreads has no value");
    emit("bar.sync 0;");
    return;
  }
  if (cname == "__nfcxx_threadfence_system") {
    // a memory fence visible to the whole system (membar.sys); no operands, no value
    if (n != 3) throw Refused("__nfcxx_threadfence_system takes no arguments");
    if (!dest.empty()) throw Refused("__nfcxx_threadfence_system has no value");
    emit("membar.sys;");
    return;
  }
  if (cname == "__nfcxx_nanosleep") {
    // nanosleep.u32: suspend the thread for about the given number of nanoseconds (a hint)
    if (n != 4) throw Refused("__nfcxx_nanosleep takes (ns)");
    if (!dest.empty()) throw Refused("__nfcxx_nanosleep has no value");
    Operand nv = operand(at(x, 3));
    if (!(nv.ty.kind == "int" && nv.ty.size == 4)) throw Refused("__nfcxx_nanosleep: argument of type " + nv.ty.kind);
    emit("nanosleep.u32 " + reg_of(nv.text, nv.ty) + ";");
    return;
  }
  if (cname == "__nfcxx_syncthreads_or") {
    // the block barrier that also ORs a predicate over the block: bar.red.or.pred, then 1 or 0 in the result
    if (n != 4) throw Refused("__nfcxx_syncthreads_or takes (predicate)");
    if (dest.empty()) throw Refused("__nfcxx_syncthreads_or has no value");
    if (!(ty && ty->kind == "int" && type_size(*ty) == 4))
      throw Refused("__nfcxx_syncthreads_or returns " + (ty ? ty->kind : std::string()) + ", not a 32-bit integer");
    Operand pv = operand(at(x, 3));
    if (!(pv.ty.kind == "int" && pv.ty.size == 4)) throw Refused("__nfcxx_syncthreads_or: predicate of type " + pv.ty.kind);
    std::string pr = fresh("p");
    std::string q = fresh("p");
    emit("setp.ne.s32 " + pr + ", " + reg_of(pv.text, pv.ty) + ", 0;");
    emit("bar.red.or.pred " + q + ", 0, " + pr + ";");
    emit("selp.s32 " + dest + ", 1, 0, " + q + ";");
    return;
  }
  if (cname == "__nfcxx_syncwarp") {
    // the warp barrier of the mask: bar.warp.sync takes the mask (32 bits) as its operand
    if (n != 4) throw Refused("__nfcxx_syncwarp takes one mask argument");
    if (!dest.empty()) throw Refused("__nfcxx_syncwarp has no value");
    Operand mop = operand(at(x, 3));
    if (!(mop.ty.kind == "int" && type_size(mop.ty) == 4)) throw Refused("__nfcxx_syncwarp mask is not a 32-bit integer");
    emit("bar.warp.sync " + reg_of(mop.text, mop.ty) + ";");
    return;
  }
  if (cname == "__cxa_vec_ctor") {
    if (!dest.empty()) throw Refused("__cxa_vec_ctor has no value");
    vec_ctor(x);
    return;
  }
  if (find_entry(DEVICE_INTRINSICS, DEVICE_INTRINSICS_N, cname)) throw Refused("call of intrinsic " + cname + " as a statement");
  Fn *callee = nullptr;
  if (module_fns) {
    auto it = module_fns->find(cname);
    if (it != module_fns->end()) callee = it->second;
  }
  if (!callee) throw Refused("call of " + cname + " (not a function of this module)");
  if (callee->kernel) throw Refused("call of kernel " + cname);
  callee->setup();
  std::vector<Node> args = tail(x, 3);
  if (args.size() != callee->params.size())
    throw Refused("call of " + cname + " with " + std::to_string(args.size()) + " arguments, it takes " +
                  std::to_string(callee->params.size()));
  if (!dest.empty()) {
    if (!callee->ret) throw Refused("call of " + cname + " as a value, but it returns nothing");
    expect(*ty, *callee->ret);
  }
  if (callee->sret && head_of(args[0]) != "sret") throw BadIR("call of " + cname + " without its sret argument");
  if (g_inline_device && inline_depth_ < kMaxInlineDepth && inline_ok(callee)) {
    inline_call(callee, x, dest);
    return;
  }
  int nc = ++ncall_;
  std::string c = "$call" + std::to_string(nc);
  emit("{");
  std::vector<std::string> regs_;  // the address of each object argument, or the register of a scalar
  for (size_t k = 0; k < args.size(); k++) {
    // (byval (struct ...) OBJ) and (sret (struct ...) OBJ): the object's address is the argument
    const Node *a = &args[k];
    if (head_of(*a) == "byval" || head_of(*a) == "sret") a = &at(*a, 2);
    Operand o = operand(*a);
    expect(callee->params[k], o.ty);
    regs_.push_back(reg_of(o.text, o.ty));
  }
  // The PTX parameters: a scalar is one .param, a byval struct or union a .param array of its bytes (nvcc's convention).
  // The sret object is not one: the callee's result array is copied into it after the call.
  std::vector<size_t> ps;  // the argument indices that are PTX parameters
  for (size_t k = 0; k < args.size(); k++)
    if (callee->is_ptx_param(k)) ps.push_back(k);
  for (size_t i = 0; i < ps.size(); i++) {
    const size_t k = ps[i];
    std::string K = std::to_string(i);
    const std::optional<AggShape> &agg = callee->agg_params[k];
    if (agg) {
      emit("  .param .align " + std::to_string(agg->align) + " .b8 " + c + "_p" + K + "[" + std::to_string(agg->size) + "];");
      for (auto [off, w] : agg_pieces(agg->size, agg->align)) {
        std::string t = fresh(piece_reg(w));
        emit("  ld." + piece_load(w) + " " + t + ", [" + regs_[k] + "+" + std::to_string(off) + "];");
        emit("  st.param." + piece_store(w) + " [" + c + "_p" + K + "+" + std::to_string(off) + "], " + t + ";");
      }
      continue;
    }
    const Ty &pty = callee->params[k];
    if (pty.kind == "int" && pty.is_bool) {
      // a bool argument is one byte, 0 or 1 (the callee's bool parameter convention); ptxas does not take 8-bit
      // parameters of device functions, so it is 32 bits
      std::string b = fresh("r");
      emit("selp.u32 " + b + ", 1, 0, " + regs_[k] + ";");
      emit("  .param .u32 " + c + "_p" + K + ";");
      emit("  st.param.u32 [" + c + "_p" + K + "], " + b + ";");
    } else {
      emit("  .param ." + ptx_type(pty) + " " + c + "_p" + K + ";");
      emit("  st.param." + ptx_type(pty) + " [" + c + "_p" + K + "], " + regs_[k] + ";");
    }
  }
  std::string list;
  for (size_t i = 0; i < ps.size(); i++) list += (i ? ", " : "") + c + "_p" + std::to_string(i);
  if (callee->sret && !callee->sret->empty) {
    // the result array (func_retval0's shape), read after the call into the object's bytes
    const AggShape &sh = *callee->sret;
    emit("  .param .align " + std::to_string(sh.align) + " .b8 " + c + "_ret[" + std::to_string(sh.size) + "];");
    emit("  call (" + c + "_ret), " + cname + ", (" + list + ");");
    for (auto [off, w] : agg_pieces(sh.size, sh.align)) {
      std::string t = fresh(piece_reg(w));
      emit("  ld.param." + piece_load(w) + " " + t + ", [" + c + "_ret+" + std::to_string(off) + "];");
      emit("  st." + piece_store(w) + " [" + regs_[0] + "+" + std::to_string(off) + "], " + t + ";");
    }
  } else if (!dest.empty()) {
    emit("  call (" + dest + "), " + cname + ", (" + list + ");");
  } else {
    emit("  call " + cname + ", (" + list + ");");
  }
  emit("}");
}

// (call void &"__cxa_vec_ctor" ARRAY COUNT SIZE CTOR DTOR): the default construction of an array of class objects (EDG's
// lowering of `T a[N];` when T's default constructor does something, as llama.cpp's mma tiles of half2 do). The count and
// the element size are constants, the constructor is a function of the module, and the destructor is null (device code
// has no exceptions to unwind): one direct call of the constructor per element, at ARRAY + i * SIZE.
bool Fn::inline_ok(const Fn *callee) const {
  if (callee->kernel) return false;
  for (size_t k = 0; k < callee->params.size(); k++)
    if (callee->params[k].kind == "int" && callee->params[k].is_bool) return false;
  const Node *form = callee->form_.get();
  std::unique_ptr<Node> loaded;
  if (!form) {
    loaded = callee->load_();
    form = loaded.get();
  }
  for (const Node &f : form->items)
    if (contains_printf(f)) return false;
  return true;
}

bool Fn::writes_only_slots(const Node &x, int depth) const {
  std::string h = head_of(x);
  if (h == "copy" || h == "store.v" || h == "ptx-asm") return false;
  if (h == "store" && !(x.items.size() == 4 && x.items[2].kind == Node::Sym && x.items[2].sig == '$')) return false;
  if (h == "call") {
    const Node &sym = at(x, 2);
    if (depth == 0 || !module_fns || !(sym.kind == Node::Sym && sym.sig == '&')) return false;
    auto it = module_fns->find(sym.text);
    if (it == module_fns->end() || it->second->kernel) return false;
    if (!body_writes_only_slots(it->second, depth - 1)) return false;
  }
  for (const Node &c : x.items)
    if (!writes_only_slots(c, depth)) return false;
  return true;
}

bool Fn::body_writes_only_slots(const Fn *f, int depth) const {
  const Node *form = f->form_.get();
  std::unique_ptr<Node> loaded;
  if (!form) {
    loaded = f->load_();
    form = loaded.get();
  }
  for (size_t i = 2; i < form->items.size(); i++) {
    std::string h = head_of(form->items[i]);
    if (h == "ret" || h == "params" || h == "static" || h == "weak" || h == "slot") continue;
    if (!writes_only_slots(form->items[i], depth)) return false;
  }
  return true;
}

void Fn::inline_call(Fn *callee, const Node &x, const std::string &dest) {
  // The callee's body is read from its form here, since a callee compiled before this one has released its own.
  const Node *form = callee->form_.get();
  std::unique_ptr<Node> loaded;
  if (!form) {
    loaded = callee->load_();
    form = loaded.get();
  }
  std::vector<const Node *> body;
  for (size_t i = 2; i < form->items.size(); i++) {
    std::string h = head_of(form->items[i]);
    if (h != "ret" && h != "params" && h != "static" && h != "weak" && h != "slot") body.push_back(&form->items[i]);
  }
  // The callee's frame is part of this one: its slots are rebased to the frame made here for the call.
  const int base = callee->frame_ > 0 ? static_cast<int>(alloc_frame(callee->frame_, callee->frame_align_)) : 0;
  bool pure = true;
  for (const Node *s : body) pure = pure && writes_only_slots(*s, 6);
  // The parameters are registers of the callee's own. A scalar is the argument's register. A struct passed by value is
  // copied into the callee's frame, as a call copies it into its parameter (its bytes are the callee's to change). The
  // sret result is the object the caller gives: the callee writes it where the call would have, so its register is it.
  std::map<std::string, RegInfo> callee_regs;
  std::vector<Node> args = tail(x, 3);
  for (size_t k = 0; k < args.size(); k++) {
    if (callee->sret && k == 0) {
      Operand o = operand(at(args[k], 2));
      callee_regs["%0"] = RegInfo{reg_of(o.text, o.ty), Ty{"ptr", -1, false, false}};
    } else if (callee->agg_params[k] && pure && reads_only(body, "%" + std::to_string(k))) {
      // read-only, in a body that writes nothing else: the struct is read where the caller has it, with no copy
      Operand o = operand(at(args[k], 2));
      callee_regs["%" + std::to_string(k)] = RegInfo{reg_of(o.text, o.ty), callee->params[k]};
    } else if (callee->agg_params[k]) {
      const AggShape &sh = *callee->agg_params[k];
      Operand o = operand(at(args[k], 2));
      const std::string src = reg_of(o.text, o.ty);
      const long long at_off = base + callee->agg_off_[k];
      for (auto [off, w] : agg_pieces(sh.size, sh.align)) {
        std::string t = fresh(piece_reg(w));
        emit("ld." + piece_load(w) + " " + t + ", [" + src + "+" + std::to_string(off) + "];");
        emit("st." + piece_store(w) + " [" + sp + "+" + std::to_string(at_off + off) + "], " + t + ";");
      }
      std::string r = fresh("rd");
      emit("add.u64 " + r + ", " + sp + ", " + std::to_string(at_off) + ";");
      callee_regs["%" + std::to_string(k)] = RegInfo{r, callee->params[k]};
    } else {
      Operand o = operand(args[k]);
      expect(callee->params[k], o.ty);
      callee_regs["%" + std::to_string(k)] = RegInfo{reg_of(o.text, o.ty), callee->params[k]};
    }
  }
  std::map<std::string, int> callee_slots;
  for (const auto &[name, off] : callee->slots) callee_slots[name] = off + base;
  // This function's registers, slots and labels are set aside while the body is compiled.
  std::map<std::string, RegInfo> caller_regs = std::exchange(regs, std::move(callee_regs));
  std::map<std::string, int> caller_slots = std::exchange(slots, std::move(callee_slots));
  std::map<std::string, RegInfo> caller_promoted = std::exchange(promoted, {});
  promote_slots(body, callee->slot_types_);
  std::map<std::string, std::string> caller_labels = std::exchange(named_labels_, {});
  std::vector<std::pair<std::string, std::string>> caller_loops = std::exchange(loops_, {});
  std::map<std::string, std::string> caller_fn_values = std::exchange(fn_values_, {});
  std::string caller_dest = std::exchange(inline_dest_, dest);
  std::string caller_end = std::exchange(inline_end_, new_label());
  std::optional<Ty> caller_ret = std::exchange(inline_ret_, callee->ret);
  inline_depth_++;
  for (const Node *s : body) stmt(*s);
  inline_depth_--;
  label(inline_end_);
  regs = std::move(caller_regs);
  slots = std::move(caller_slots);
  promoted = std::move(caller_promoted);
  named_labels_ = std::move(caller_labels);
  loops_ = std::move(caller_loops);
  fn_values_ = std::move(caller_fn_values);
  inline_dest_ = std::move(caller_dest);
  inline_end_ = std::move(caller_end);
  inline_ret_ = caller_ret;
}

void Fn::promote_slots(const std::vector<const Node *> &body, const std::map<std::string, Ty> &types) {
  promoted.clear();
  if (!g_promote_slots) return;
  std::map<std::string, int> all, whole;
  for (const Node *s : body) count_slot_uses(*s, all, whole, types);
  for (const auto &[name, ty] : types) {
    // every use of the slot is a whole load or store of its type: no address is taken, nothing is a part of it
    if (!register_slot_type(ty) || whole[name] == 0 || all[name] != whole[name]) continue;
    promoted[name] = RegInfo{fresh(reg_class(ty)), ty};
  }
}

void Fn::vec_ctor(const Node &x) {
  if (x.items.size() != 8) throw Refused("__cxa_vec_ctor takes (array, count, size, constructor, destructor)");
  auto constant = [&](const Node &c, const char *what) {
    if (head_of(c) != "const" || c.items.size() != 3) throw Refused(std::string("__cxa_vec_ctor: the ") + what + " is not a constant");
    return static_cast<long long>(as_int(&c.items[2]));
  };
  const long long count = constant(at(x, 4), "count"), size = constant(at(x, 5), "element size");
  if (count < 0 || count > 4096) throw Refused("__cxa_vec_ctor of " + std::to_string(count) + " elements");
  if (head_of(at(x, 7)) != "null") throw Refused("__cxa_vec_ctor with a destructor");
  const Node &cn = at(x, 6);
  std::string ctor;
  if (cn.kind == Node::Sym && cn.sig == '&') ctor = cn.text;
  else if (fn_values_.count(cn.text)) ctor = fn_values_[cn.text];
  else throw Refused("__cxa_vec_ctor: the constructor is not a known function");
  Fn *callee = nullptr;
  if (module_fns) {
    auto it = module_fns->find(ctor);
    if (it != module_fns->end()) callee = it->second;
  }
  if (!callee) throw Refused("__cxa_vec_ctor: constructor " + ctor + " is not a function of this module");
  callee->setup();
  if (callee->params.size() != 1 || callee->params[0].kind != "ptr" || callee->ret)
    throw Refused("__cxa_vec_ctor: constructor " + ctor + " does not take (this)");
  Operand arr = operand(at(x, 3));
  if (arr.ty.kind != "ptr") throw Refused("__cxa_vec_ctor of a non-pointer");
  const std::string base = reg_of(arr.text, arr.ty);
  for (long long i = 0; i < count; i++) {
    std::string p = fresh("rd");
    emit("add.u64 " + p + ", " + base + ", " + std::to_string(i * size) + ";");
    const std::string c = "$call" + std::to_string(++ncall_);
    emit("{");
    emit("  .param ." + ptx_type(callee->params[0]) + " " + c + "_p0;");
    emit("  st.param." + ptx_type(callee->params[0]) + " [" + c + "_p0], " + p + ";");
    emit("  call " + ctor + ", (" + c + "_p0);");
    emit("}");
  }
}
