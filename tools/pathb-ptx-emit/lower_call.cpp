// The device-intrinsic, warp and atomic calls and the inline PTX statement of scripts/pathb-ptx-emit.rb (class Fn's
// rval "call" branch, device_builtin, full_mask! and ptx_asm). Each function is the Ruby one of the same name, with the
// same order of fresh registers and emitted lines, so the PTX text is the same.
#include "lower_arith.hpp"

#include <vector>

#include "tables.inc"

namespace {

// x[i] of a list, or a static empty atom when out of range (the Ruby's nil).
const Node &at(const Node &x, size_t i) {
  static const Node none;
  if (x.kind != Node::List || i >= x.items.size()) return none;
  return x.items[i];
}

// The head atom of a non-empty list, or nullptr (the Ruby's head_of).
const std::string *head(const Node &x) {
  if (x.kind != Node::List || x.items.empty() || x.items[0].kind != Node::Atom) return nullptr;
  return &x.items[0].text;
}

// The text of an atom (the Ruby's String), or "" for anything else.
std::string text_of(const Node &x) { return x.kind == Node::Atom ? x.text : std::string(); }

bool ends_with(const std::string &s, const std::string &suffix) {
  return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// The value of the table entry for key, or nullptr.
const KvStr *find_str(const KvStr *table, size_t n, const std::string &key) {
  for (size_t i = 0; i < n; i++)
    if (key == table[i].key) return &table[i];
  return nullptr;
}

const KvAtomic *find_atomic(const std::string &key) {
  for (size_t i = 0; i < ATOMICS_N; i++)
    if (key == ATOMICS[i].key) return &ATOMICS[i];
  return nullptr;
}

// Ruby's String#strip: the whitespace and NUL at both ends.
std::string strip(const std::string &s) {
  const char *ws = " \t\n\v\f\r";
  size_t b = s.find_first_not_of(std::string(ws) + '\0');
  if (b == std::string::npos) return std::string();
  size_t e = s.find_last_not_of(std::string(ws) + '\0');
  return s.substr(b, e - b + 1);
}

}  // namespace

bool FnCtx::call(const Node &x, const std::string &dest, const Ty &dty) {
  Ty ty = parse_type(&at(x, 1));
  expect(dty, ty);
  const Node &callee = at(x, 2);
  if (callee.kind != Node::Sym || callee.sig != '&') return false;
  const std::string &name = callee.text;
  if (name == "__nfcxx_dynshared_addr" || name == "printf") return false;
  if (const KvStr *reg = find_str(DEVICE_INTRINSICS, DEVICE_INTRINSICS_N, name)) {
    if (x.items.size() != 3) throw Refused("intrinsic " + name + " takes no arguments");
    if (!(ty.kind == "int" && type_size(ty) == 4))
      throw Refused("intrinsic " + name + " returns " + ty.kind + ", not a 32-bit unsigned");
    emit("mov.u32 " + dest + ", %" + reg->value + ";");
    return true;
  }
  if (find_str(WARP_SHUFFLES, WARP_SHUFFLES_N, name) || find_str(WARP_VOTES, WARP_VOTES_N, name) ||
      find_atomic(name) || name == "__nfcxx_reduce_add_sync") {
    device_builtin(name, x, dest, ty);
    return true;
  }
  return false;
}

void FnCtx::full_mask(const Node &op, const std::string &name) {
  Operand m = operand(op);
  if (m.text != "4294967295" && m.text != "-1")
    throw Refused(name + ": only the full-warp mask 0xffffffff is lowered (mask operand " + m.text + ")");
}

void FnCtx::device_builtin(const std::string &name, const Node &x, const std::string &dest, const Ty &ty) {
  size_t nargs = x.items.size() > 3 ? x.items.size() - 3 : 0;
  auto arg = [&x](size_t i) -> const Node & { return at(x, 3 + i); };
  if (dest.empty()) throw Refused(name + " has no value");
  if (const KvStr *sh = find_str(WARP_SHUFFLES, WARP_SHUFFLES_N, name)) {
    if (nargs != 3) throw Refused(name + " takes (mask, value, lane)");
    full_mask(arg(0), name);
    bool isf = ends_with(name, "_f");
    if (!((isf ? ty.kind == "float" : ty.kind == "int") && type_size(ty) == 4))
      throw Refused(name + " returns " + ty.kind);
    Operand v = operand(arg(1));
    if (!((isf ? v.ty.kind == "float" : v.ty.kind == "int") && v.ty.size == 4))
      throw Refused(name + ": value of type " + v.ty.kind);
    Operand lane = operand(arg(2));
    if (!(lane.ty.kind == "int" && lane.ty.size == 4)) throw Refused(name + ": lane of type " + lane.ty.kind);
    std::string src = reg_of(v.text, v.ty);
    std::string lr = reg_of(lane.text, lane.ty);
    std::string mode = sh->value;
    std::string clamp = mode == "up" ? "0" : "31";
    if (isf) {
      std::string bits = fresh("r");
      std::string out = fresh("r");
      emit("mov.b32 " + bits + ", " + src + ";");
      emit("shfl.sync." + mode + ".b32 " + out + ", " + bits + ", " + lr + ", " + clamp + ", 0xffffffff;");
      emit("mov.b32 " + dest + ", " + out + ";");
    } else {
      emit("shfl.sync." + mode + ".b32 " + dest + ", " + src + ", " + lr + ", " + clamp + ", 0xffffffff;");
    }
  } else if (name == "__nfcxx_reduce_add_sync") {
    // __reduce_add_sync(mask, value) for the full warp: a butterfly sum over the five lane offsets, so every lane gets
    // the sum of the 32 values (unsigned addition wraps, as the CUDA intrinsic). redux.sync needs sm_80; this is sm_75.
    if (nargs != 2) throw Refused(name + " takes (mask, value)");
    full_mask(arg(0), name);
    if (!(ty.kind == "int" && type_size(ty) == 4)) throw Refused(name + " returns " + ty.kind + ", not a 32-bit integer");
    Operand v = operand(arg(1));
    if (!(v.ty.kind == "int" && v.ty.size == 4)) throw Refused(name + ": value of type " + v.ty.kind);
    std::string src = reg_of(v.text, v.ty);
    emit("mov.b32 " + dest + ", " + src + ";");
    for (int off : {16, 8, 4, 2, 1}) {
      std::string t = fresh("r");
      emit("shfl.sync.bfly.b32 " + t + ", " + dest + ", " + std::to_string(off) + ", 31, 0xffffffff;");
      emit("add.s32 " + dest + ", " + dest + ", " + t + ";");
    }
  } else if (const KvStr *vote = find_str(WARP_VOTES, WARP_VOTES_N, name)) {
    if (nargs != 2) throw Refused(name + " takes (mask, predicate)");
    full_mask(arg(0), name);
    if (!(ty.kind == "int" && type_size(ty) == 4)) throw Refused(name + " returns " + ty.kind);
    Operand pv = operand(arg(1));
    if (!(pv.ty.kind == "int" && pv.ty.size == 4)) throw Refused(name + ": predicate of type " + pv.ty.kind);
    std::string pr = fresh("p");
    std::string r = reg_of(pv.text, pv.ty);
    emit("setp.ne.s32 " + pr + ", " + r + ", 0;");
    if (std::string(vote->value) == "ballot") {
      emit("vote.sync.ballot.b32 " + dest + ", " + pr + ", 0xffffffff;");
    } else {
      std::string q = fresh("p");
      emit("vote.sync." + std::string(vote->value) + ".pred " + q + ", " + pr + ", 0xffffffff;");
      emit("selp.s32 " + dest + ", 1, 0, " + q + ";");
    }
  } else {
    const KvAtomic *at_ = find_atomic(name);
    std::string want = ends_with(name, "_f") ? "float" : "int";
    if (nargs != (name == "__nfcxx_atomic_cas_i" ? 3u : 2u)) throw Refused(name + " takes (pointer, value)");
    Operand pv = operand(arg(0));
    if (pv.ty.kind != "ptr") throw Refused(name + ": first operand is a " + pv.ty.kind + ", not a pointer");
    if (!(ty.kind == want && type_size(ty) == 4)) throw Refused(name + " returns " + ty.kind);
    std::vector<std::string> vals;
    for (size_t i = 1; i < nargs; i++) {
      Operand v = operand(arg(i));
      if (!(v.ty.kind == want && v.ty.size == 4)) throw Refused(name + ": operand of type " + v.ty.kind);
      vals.push_back(reg_of(v.text, v.ty));
    }
    std::string addr = reg_of(pv.text, pv.ty);
    std::string list;
    for (size_t i = 0; i < vals.size(); i++) list += (i ? ", " : "") + vals[i];
    emit("atom." + std::string(at_->op) + "." + at_->type + " " + dest + ", [" + addr + "], " + list + ";");
  }
}

void FnCtx::asm_stmt(const Node &s) {
  // (ptx-asm "TEMPLATE" (opnd KIND ARG TYPE)...): the operands take registers in order, the template's %N is operand N
  // (outputs first, as gcc numbers them), and the outputs are stored back after the instruction.
  std::string tmpl = at(s, 1).text;   // the template is a string literal (Node::Str); the Ruby s[1].to_s
  std::vector<std::string> regs;
  struct Store {
    std::string addr;
    std::string reg;
    Ty ty;
  };
  std::vector<Store> stores;
  for (size_t i = 2; i < s.items.size(); i++) {
    const Node &o = s.items[i];
    const std::string *h = head(o);
    if (!h || *h != "opnd") throw BadIR("asm operand " + form_text(o));
    std::string kind = text_of(at(o, 1));
    const Node &arg = at(o, 2);
    // a missing type is nil in the Ruby, which parse_type rejects as bad IR
    Ty ty = parse_type(o.items.size() > 3 ? &o.items[3] : nullptr);
    if (!asm_operand_ok(ty)) throw Refused("asm operand of type " + ty.kind + " (2-, 4- and 8-byte integers, 4- and 8-byte floats, pointers)");
    if (kind == "in") {
      Operand v = operand(arg);
      std::string r = fresh(asm_class(ty));
      if (asm_class(ty) == "h") {
        emit("cvt." + mem_type(ty) + "." + ptx_type(ty) + " " + r + ", " + v.text + ";");
      } else {
        emit("mov." + ptx_type(ty) + " " + r + ", " + v.text + ";");
      }
      regs.push_back(r);
    } else {
      Operand a = operand(arg);
      std::string r = fresh(asm_class(ty));
      if (kind == "inout") emit("ld." + mem_type(ty) + " " + r + ", [" + a.text + "];");
      regs.push_back(r);
      stores.push_back(Store{a.text, r, ty});
    }
  }
  std::string text;
  for (size_t i = 0; i < tmpl.size();) {
    if (tmpl[i] == '%' && i + 1 < tmpl.size() && tmpl[i + 1] >= '0' && tmpl[i + 1] <= '9') {
      size_t j = i + 1;
      size_t n = 0;
      while (j < tmpl.size() && tmpl[j] >= '0' && tmpl[j] <= '9') {
        // saturates past the operand count, which is all the check below needs
        if (n <= regs.size()) n = n * 10 + static_cast<size_t>(tmpl[j] - '0');
        j++;
      }
      if (n >= regs.size()) throw BadIR("asm operand %" + std::to_string(n) + " of " + std::to_string(regs.size()));
      text += regs[n];
      i = j;
    } else {
      text += tmpl[i];
      i++;
    }
  }
  // each line of the text is one PTX statement, stripped; blank lines are dropped
  for (size_t p = 0; p <= text.size();) {
    size_t q = text.find('\n', p);
    if (q == std::string::npos) q = text.size();
    std::string line = strip(text.substr(p, q - p));
    if (!line.empty()) emit(line);
    p = q + 1;
  }
  for (const Store &st : stores) emit("st." + mem_type(st.ty) + " [" + st.addr + "], " + st.reg + ";");
}
