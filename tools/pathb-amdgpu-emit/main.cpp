// pathb-amdgpu-emit: Path B IR (docs/notes/pathb-stage2.md) to LLVM IR for AMD GPUs (amdgcn-amd-amdhsa), the AMD
// counterpart of tools/pathb-ptx-emit. ROCm's clang assembles the output into a code object (hsaco), which the HIP
// runtime loads (hipModuleLoadData). docs/notes/gpu.md, "AMD GPUs (ROCm)".
//
//   pathb-amdgpu-emit [--f2i=convert] [--kernel=NAME]... FILE.ir > FILE.ll
//
// Exit status: 0 emitted, 1 malformed IR, 3 refused (a construct the emitter does not lower; the message names it).
//
// The lowering is plain and leaves the optimization to LLVM (clang -O2 runs mem2reg, instcombine and the rest):
// - Each IR register is an alloca of its type: `let` stores it, `set` stores it again, every use loads it.
// - Each slot is an alloca of its bytes in the private address space, used through its flat (generic) address, as the
//   PTX emitter uses .local through cvta. All pointers in the IR are flat pointers (addrspace 0), as on the GPU's
//   generic space in PTX.
// - Kernels are amdgpu_kernel functions; their arguments are laid out by LLVM in the kernarg segment, and the HIP
//   runtime packs the host's arguments by the code object's metadata. A struct passed by value is a byref kernarg.
// - Device functions are internal. A struct passed by value is passed by the address of the caller's copy (the callee
//   copies it into its frame, so the value semantics hold); a struct result is written through the sret address.
// - The warp is the wave: gfx10 and later run 32 lanes (wave32), the CUDA warp. The shuffles are ds_bpermute.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "../pathb-ptx-emit/ir.hpp"
#include "../pathb-ptx-emit/lower_types.hpp"

namespace {

std::string head_of(const Node &x) {
  if (x.kind != Node::List || x.items.empty() || x.items[0].kind != Node::Atom) return "";
  return x.items[0].text;
}
const Node &at(const Node &x, size_t i) {
  static const Node none;
  if (x.kind != Node::List || i >= x.items.size()) return none;
  return x.items[i];
}
bool is_reg(const Node &x) { return x.kind == Node::Atom && !x.text.empty() && x.text[0] == '%'; }
bool ends_with(const std::string &s, const std::string &suf) {
  return s.size() >= suf.size() && s.compare(s.size() - suf.size(), suf.size(), suf) == 0;
}

// The LLVM name of a global symbol: always quoted, with the bytes LLVM's quoted names cannot hold escaped.
std::string gname(const std::string &name) {
  std::string out = "@\"";
  for (unsigned char c : name) {
    if (c == '"' || c == '\\' || c < 0x20 || c >= 0x7f) {
      char b[4];
      std::snprintf(b, sizeof b, "\\%02X", c);
      out += b;
    } else {
      out += static_cast<char>(c);
    }
  }
  return out + "\"";
}

// The LLVM type of an IR value type (bool is i1 in a register).
std::string lty(const Ty &t) {
  if (t.kind == "ptr") return "ptr";
  if (t.kind == "int" && t.is_bool) return "i1";
  if (t.kind == "int" && (t.size == 1 || t.size == 2 || t.size == 4 || t.size == 8)) return "i" + std::to_string(t.size * 8);
  if (t.kind == "float" && t.size == 4) return "float";
  if (t.kind == "float" && t.size == 8) return "double";
  if (t.kind == "void") return "void";
  throw Refused("value of type " + t.kind + " (" + std::to_string(t.size) + " bytes)");
}
// The LLVM type of an IR type in memory (bool is one byte, 0 or 1).
std::string mty(const Ty &t) { return t.kind == "int" && t.is_bool ? "i8" : lty(t); }
bool is_bool(const Ty &t) { return t.kind == "int" && t.is_bool; }
bool same_class(const Ty &a, const Ty &b) { return lty(a) == lty(b); }

// An LLVM floating-point literal: the hexadecimal form of the double (for float too, which LLVM requires to be exact).
std::string float_hex(const std::string &text, const Ty &t) {
  double d;
  if (text == "Infinity" || text == "+Infinity") d = INFINITY;
  else if (text == "-Infinity") d = -INFINITY;
  else if (text == "NaN") d = NAN;
  else {
    char *end = nullptr;
    d = std::strtod(text.c_str(), &end);
    if (!end || *end) throw Refused("float constant " + text);
  }
  if (t.size == 4) d = static_cast<double>(static_cast<float>(d));
  uint64_t bits;
  std::memcpy(&bits, &d, sizeof bits);
  char b[32];
  std::snprintf(b, sizeof b, "0x%016llX", static_cast<unsigned long long>(bits));
  return b;
}

// An integer constant as LLVM text: the value in the signed range of the type.
std::string int_text(const Ty &t, i128 v) {
  int bits = t.size * 8;
  i128 m = bits >= 128 ? ~static_cast<i128>(0) : ((static_cast<i128>(1) << bits) - 1);
  v &= m;
  if (v >= (static_cast<i128>(1) << (bits - 1))) v -= static_cast<i128>(1) << bits;
  return i128_text(v);
}

struct Val {
  std::string text;  // an SSA value or a constant
  Ty ty;
};

const Ty kPtr{"ptr", -1, false, false};
const Ty kI32{"int", 4, false, false};
const Ty kS32{"int", 4, true, false};
const Ty kI64{"int", 8, false, false};
const Ty kBool{"int", 1, false, true};
const Ty kF32{"float", 4, false, false};

struct AggShape {
  long long size = 0, align = 1;
  bool empty = false;
};

// The module's data symbols: their address space and the LLVM type of their storage.
struct DataSym {
  int as = 1;  // 1 global, 3 shared (LDS), 4 constant
};

struct Module;

class Fn {
 public:
  Fn(Module &m, const Node &form) : m_(m), form_(form) {}
  void setup();
  std::string compile();

  std::string name;
  bool kernel = false;
  std::vector<Ty> params;                       // the IR types (a byval or sret parameter is a ptr)
  std::vector<std::optional<AggShape>> aggs;    // per parameter: the shape of a byval struct (or the sret object)
  std::vector<bool> is_sret;
  std::optional<Ty> ret;

 private:
  Module &m_;
  const Node &form_;
  bool setup_done_ = false;
  std::vector<const Node *> body_;
  std::vector<std::pair<std::string, std::pair<long long, long long>>> slot_decls_;  // name => (size, align)
  std::map<std::string, std::string> slots_;    // slot name => its flat address value
  std::map<std::string, Ty> regs_;              // IR register => its type (its alloca is %r.N)
  std::vector<std::string> entry_;              // the entry block's allocas
  std::vector<std::string> lines_;
  int ntmp_ = 0, nlab_ = 0;
  bool term_ = false;                           // the current block has its terminator
  std::vector<std::pair<std::string, std::string>> loops_;  // [continue label ("" for a switch), break label]
  std::map<std::string, std::string> named_;    // IR label => block label
  std::map<std::string, std::string> fn_values_;  // registers holding a function's address (__cxa_vec_ctor)

  std::string tmp() { return "%t" + std::to_string(ntmp_++); }
  std::string new_label() { return "L" + std::to_string(nlab_++); }
  void ins(const std::string &s) {
    if (term_) {
      lines_.push_back("D" + std::to_string(nlab_++) + ":");
      term_ = false;
    }
    lines_.push_back("  " + s);
  }
  void terminate(const std::string &s) {
    ins(s);
    term_ = true;
  }
  void label(const std::string &l) {
    if (!term_) lines_.push_back("  br label %" + l);
    lines_.push_back(l + ":");
    term_ = false;
  }
  void br(const std::string &l) { terminate("br label %" + l); }
  void trap_if(const std::string &cond) {
    std::string t = new_label(), c = new_label();
    terminate("br i1 " + cond + ", label %" + t + ", label %" + c);
    lines_.push_back(t + ":");
    term_ = false;
    ins("call void @llvm.trap()");
    terminate("unreachable");
    lines_.push_back(c + ":");
    term_ = false;
  }
  std::string named_label(const std::string &n) {
    auto it = named_.find(n);
    if (it != named_.end()) return it->second;
    return named_[n] = new_label();
  }

  std::string reg_alloca(const std::string &r, const Ty &ty) {
    auto it = regs_.find(r);
    if (it == regs_.end()) {
      regs_[r] = ty;
      entry_.push_back("%r." + r.substr(1) + " = alloca " + lty(ty) + ", addrspace(5)");
    } else if (!same_class(it->second, ty)) {
      throw BadIR("register " + r + " of two types");
    }
    return "%r." + r.substr(1);
  }
  void store_reg(const std::string &r, const Val &v) {
    std::string a = reg_alloca(r, v.ty);
    ins("store " + lty(v.ty) + " " + v.text + ", ptr addrspace(5) " + a);
  }

  Val operand(const Node &x);
  Val conv_to(const Val &v, const Ty &t);
  std::string as_type(const Val &v, const Ty &t);
  Val rval(const Node &x, const Ty &dty);
  Val arith(const std::string &h, const Node &x, const Ty &dty, bool &ok);
  Val memory(const std::string &h, const Node &x, const Ty &dty, bool &ok);
  Val call(const Node &x, const Ty *ty);
  std::optional<Val> builtin(const std::string &name, const Node &x, const Ty *ty);
  Val compare(const std::string &op, const Ty &ty, const Node &a, const Node &b);
  void stmt(const Node &s);
  void emit_return(const Node &s);
  Val shuffle(const std::string &mode, const Val &v, const Val &lane);
  Val lane_id();
  Val implicit_load(int offset, int bytes);
  AggShape aggregate(const Node &t) const;
};

struct Module {
  std::vector<Node> forms;
  std::map<std::string, AggShape> abi;
  std::map<std::string, DataSym> data;
  std::map<std::string, std::unique_ptr<Fn>> fns;
  std::vector<std::string> order;      // the functions emitted, in the IR's order
  std::set<std::string> decls;         // intrinsic declarations used
  std::vector<std::string> globals;    // the data definitions
  bool uses_dynshared = false;
  bool uses_flag = false;              // the LDS word of __syncthreads_or
  bool f2i_convert = false;
  void declare(const std::string &d) { decls.insert(d); }
};

AggShape Fn::aggregate(const Node &type) const {
  const Node &t = head_of(type) == "const" && type.items.size() == 2 ? type.items[1] : type;
  std::string h = head_of(t);
  if (!((h == "struct" || h == "union") && t.items.size() == 2 && t.items[1].kind == Node::Str))
    throw Refused("aggregate form " + form_text(type));
  auto it = m_.abi.find(t.items[1].text);
  if (it == m_.abi.end()) throw Refused(h + " " + t.items[1].text + " has no (abi-type) form");
  return it->second;
}

void Fn::setup() {
  if (setup_done_) return;
  setup_done_ = true;
  name = at(form_, 1).text;
  bool have_ret = false;
  for (size_t i = 2; i < form_.items.size(); i++) {
    const Node &f = form_.items[i];
    std::string h = head_of(f);
    if (h == "ret") {
      Ty t = parse_type(&at(f, 1));
      if (t.kind != "void") {
        lty(t);
        ret = t;
      }
      have_ret = true;
    } else if (h == "params") {
      for (size_t k = 1; k < f.items.size(); k++) {
        const Node &p = f.items[k];
        std::string ph = head_of(p);
        if (ph == "ellipsis") throw Refused("variadic function " + name);
        if (ph == "sret") {
          if (p.items.size() != 3) throw Refused("sret form " + form_text(p));
          params.push_back(kPtr);
          aggs.push_back(aggregate(p.items[2]));
          is_sret.push_back(true);
          continue;
        }
        if (!(ph == "param" && p.items.size() == 4)) throw Refused("parameter form " + form_text(p));
        if (head_of(p.items[3]) == "byval") {
          params.push_back(kPtr);
          aggs.push_back(aggregate(p.items[3].items[1]));
          is_sret.push_back(false);
          continue;
        }
        Ty t = parse_type(&p.items[3]);
        lty(t);
        params.push_back(t);
        aggs.push_back(std::nullopt);
        is_sret.push_back(false);
      }
    } else if (h == "static" || h == "weak" || h == "loc") {
    } else if (h == "slot") {
      long long size, align;
      if (f.items.size() == 5) {
        size = static_cast<long long>(as_int(&f.items[3]));
        align = static_cast<long long>(as_int(&f.items[4]));
      } else if (f.items.size() == 3) {
        size = type_size(parse_type(&f.items[2]));
        align = size;
      } else {
        throw Refused("slot form " + form_text(f));
      }
      slot_decls_.push_back({f.items[1].text, {size, align}});
    } else {
      body_.push_back(&f);
    }
  }
  if (!have_ret) throw BadIR("function without a return type");
  if (kernel && ret) throw Refused("kernel " + name + " returns a value");
}

Val Fn::lane_id() {
  m_.declare("declare i32 @llvm.amdgcn.mbcnt.lo(i32, i32)");
  std::string t = tmp();
  ins(t + " = call i32 @llvm.amdgcn.mbcnt.lo(i32 -1, i32 0)");
  return {t, kI32};
}

// A field of the implicit kernel arguments (code object v5): the block counts at 0, 4, 8 (i32), the group sizes at
// 12, 14, 16 (i16). Read as an unsigned 32-bit value.
Val Fn::implicit_load(int offset, int bytes) {
  m_.declare("declare ptr addrspace(4) @llvm.amdgcn.implicitarg.ptr()");
  std::string p = tmp(), q = tmp(), v = tmp();
  ins(p + " = call ptr addrspace(4) @llvm.amdgcn.implicitarg.ptr()");
  ins(q + " = getelementptr i8, ptr addrspace(4) " + p + ", i64 " + std::to_string(offset));
  if (bytes == 2) {
    ins(v + " = load i16, ptr addrspace(4) " + q + ", align 2, !invariant.load !0");
    std::string z = tmp();
    ins(z + " = zext i16 " + v + " to i32");
    return {z, kI32};
  }
  ins(v + " = load i32, ptr addrspace(4) " + q + ", align 4, !invariant.load !0");
  return {v, kI32};
}

Val Fn::operand(const Node &x) {
  if (is_reg(x)) {
    auto it = regs_.find(x.text);
    if (it == regs_.end()) throw BadIR("register " + x.text + " is used before it is set");
    std::string t = tmp();
    ins(t + " = load " + lty(it->second) + ", ptr addrspace(5) %r." + x.text.substr(1));
    return {t, it->second};
  }
  std::string h = head_of(x);
  if (h == "const") {
    Ty ty = parse_type(&at(x, 1));
    const std::string &v = at(x, 2).text;
    if (is_bool(ty)) return {ends_with(v, "1") || v == "true" ? "true" : "false", ty};
    if (ty.kind == "float") return {float_hex(v, ty), ty};
    if (ty.kind == "ptr") return {as_int(&at(x, 2)) == 0 ? "null" : "inttoptr (i64 " + i128_text(as_int(&at(x, 2))) + " to ptr)", ty};
    return {int_text(ty, as_int(&at(x, 2))), ty};
  }
  if (h == "null") {
    Ty ty = parse_type(&at(x, 1));
    if (ty.kind == "ptr") return {"null", ty};
    if (ty.kind == "float") return {"0.0", ty};
    return {is_bool(ty) ? "false" : "0", ty};
  }
  if (x.kind == Node::Sym && x.sig == '$') {
    auto it = slots_.find(x.text);
    if (it == slots_.end()) throw BadIR("slot " + x.text + " is not declared");
    return {it->second, kPtr};
  }
  if (x.kind == Node::Sym && x.sig == '@') {
    auto it = m_.data.find(x.text);
    if (it == m_.data.end()) throw Refused("static object @\"" + x.text + "\" (not a data symbol of this module)");
    return {"addrspacecast (ptr addrspace(" + std::to_string(it->second.as) + ") " + gname(x.text) + " to ptr)", kPtr};
  }
  if (x.kind == Node::Sym && x.sig == '&') {
    auto it = m_.fns.find(x.text);
    if (it == m_.fns.end()) throw Refused("address of " + x.text + " (not a function of this module)");
    return {gname(x.text), kPtr};
  }
  throw Refused("operand " + form_text(x));
}

// The value v as an operand of type t: the IR's operands already have the operation's type (the front end converts
// explicitly), so this only checks the class.
std::string Fn::as_type(const Val &v, const Ty &t) {
  if (!same_class(v.ty, t))
    throw BadIR("value of type " + lty(v.ty) + " used as " + lty(t));
  return v.text;
}

Val Fn::compare(const std::string &op0, const Ty &ty, const Node &xa, const Node &xb) {
  std::string op = op0.substr(0, op0.find('.'));
  std::string suf = op0.find('.') == std::string::npos ? "" : op0.substr(op0.find('.') + 1);
  Val a = operand(xa), b = operand(xb);
  std::string t = tmp();
  if (ty.kind == "float" || suf == "f") {
    // C: != is true on NaN (une), the others are ordered
    std::string p = op == "ne" ? "une" : "o" + op;
    ins(t + " = fcmp " + p + " " + lty(ty) + " " + as_type(a, ty) + ", " + as_type(b, ty));
    return {t, kBool};
  }
  if (is_bool(ty) && !(op == "eq" || op == "ne")) throw Refused("bool comparison " + op);
  std::string p;
  if (op == "eq" || op == "ne") {
    p = op;
  } else {
    bool sgn = suf == "s" ? true : suf == "u" ? false : (ty.kind == "int" && ty.is_signed);
    p = std::string(sgn ? "s" : "u") + op;
  }
  ins(t + " = icmp " + p + " " + lty(ty) + " " + as_type(a, ty) + ", " + as_type(b, ty));
  return {t, kBool};
}

Val Fn::arith(const std::string &h, const Node &x, const Ty &dty, bool &ok) {
  ok = true;
  auto bin = [&](const std::string &op) {
    Ty ty = parse_type(&at(x, 1));
    Val a = operand(at(x, 2)), b = operand(at(x, 3));
    std::string t = tmp();
    ins(t + " = " + op + " " + lty(ty) + " " + as_type(a, ty) + ", " + as_type(b, ty));
    return Val{t, ty};
  };
  if (h == "wadd") return bin("add");
  if (h == "wsub") return bin("sub");
  if (h == "wmul") return bin("mul");
  if (h == "and") return bin("and");
  if (h == "or") return bin("or");
  if (h == "xor") return bin("xor");
  if (h == "fadd") return bin("fadd");
  if (h == "fsub") return bin("fsub");
  if (h == "fmul") return bin("fmul");
  if (h == "fdiv") return bin("fdiv");
  if (h == "wneg") {
    Ty ty = parse_type(&at(x, 1));
    if (is_bool(ty)) throw Refused("negation of bool");
    Val a = operand(at(x, 2));
    std::string t = tmp();
    ins(t + " = sub " + lty(ty) + " 0, " + as_type(a, ty));
    return {t, ty};
  }
  if (h == "fneg") {
    Ty ty = parse_type(&at(x, 1));
    Val a = operand(at(x, 2));
    std::string t = tmp();
    ins(t + " = fneg " + lty(ty) + " " + as_type(a, ty));
    return {t, ty};
  }
  if (h == "not") {
    Ty ty = parse_type(&at(x, 1));
    Val a = operand(at(x, 2));
    std::string t = tmp();
    ins(t + " = xor " + lty(ty) + " " + as_type(a, ty) + ", " + (is_bool(ty) ? "true" : "-1"));
    return {t, ty};
  }
  if (h == "cdiv" || h == "crem") {
    // division traps on a zero divisor and on the signed overflow (MIN / -1), as the PTX emitter's checked_div
    Ty ty = parse_type(&at(x, 1));
    if (!(ty.kind == "int" && !ty.is_bool)) throw Refused(h + " on " + ty.kind);
    Val a = operand(at(x, 2)), b = operand(at(x, 3));
    std::string T = lty(ty);
    std::string z = tmp();
    ins(z + " = icmp eq " + T + " " + b.text + ", 0");
    trap_if(z);
    if (ty.is_signed) {
      std::string m1 = tmp(), mn = tmp(), both = tmp();
      ins(m1 + " = icmp eq " + T + " " + b.text + ", -1");
      ins(mn + " = icmp eq " + T + " " + a.text + ", " + int_text(ty, -(static_cast<i128>(1) << (ty.size * 8 - 1))));
      ins(both + " = and i1 " + m1 + ", " + mn);
      trap_if(both);
    }
    std::string t = tmp();
    std::string op = (h == "cdiv" ? std::string(ty.is_signed ? "sdiv" : "udiv") : std::string(ty.is_signed ? "srem" : "urem"));
    ins(t + " = " + op + " " + T + " " + a.text + ", " + b.text);
    return {t, ty};
  }
  if (h == "cshl" || h == "cshr") {
    // a count out of range traps (checked_shift); the count is converted to the value's width
    Ty ty = parse_type(&at(x, 1));
    if (!(ty.kind == "int" && !ty.is_bool)) throw Refused(h + " on " + ty.kind);
    Val a = operand(at(x, 2)), c = operand(at(x, 3));
    if (!(c.ty.kind == "int" && !c.ty.is_bool)) throw Refused("shift count of type " + c.ty.kind);
    int bits = ty.size * 8;
    std::string oor = tmp();
    ins(oor + " = icmp uge " + lty(c.ty) + " " + c.text + ", " + std::to_string(bits));
    trap_if(oor);
    Val cnt = conv_to(Val{c.text, Ty{"int", c.ty.size, false, false}}, Ty{"int", ty.size, false, false});
    std::string t = tmp();
    std::string op = h == "cshl" ? "shl" : (ty.is_signed ? "ashr" : "lshr");
    ins(t + " = " + op + " " + lty(ty) + " " + a.text + ", " + cnt.text);
    return {t, ty};
  }
  if (h == "iconv" || h == "p2i") {
    Ty ty = parse_type(&at(x, 1));
    if (!(ty.kind == "int" && !ty.is_bool)) throw Refused(h + " to " + ty.kind);
    Val a = operand(at(x, 2));
    if (h == "p2i") {
      if (a.ty.kind != "ptr") throw BadIR("p2i of a " + a.ty.kind);
      std::string t = tmp();
      ins(t + " = ptrtoint ptr " + a.text + " to i64");
      a = {t, kI64};
    }
    if (a.ty.kind != "int") throw BadIR("iconv of a " + a.ty.kind);
    return conv_to(a, ty);
  }
  if (h == "fconv") {
    Ty ty = parse_type(&at(x, 1));
    Val a = operand(at(x, 2));
    if (ty.kind != "float" || a.ty.kind != "float") throw Refused("fconv of " + a.ty.kind + " to " + ty.kind);
    if (ty.size == a.ty.size) return {a.text, ty};
    std::string t = tmp();
    ins(t + " = " + (ty.size > a.ty.size ? "fpext " : "fptrunc ") + lty(a.ty) + " " + a.text + " to " + lty(ty));
    return {t, ty};
  }
  if (h == "i2f" || h == "u2f") {
    Ty ty = parse_type(&at(x, 1));
    Val a = operand(at(x, 2));
    if (ty.kind != "float" || a.ty.kind != "int") throw Refused(h + " of " + a.ty.kind + " to " + ty.kind);
    std::string t = tmp();
    bool sgn = !is_bool(a.ty) && (h == "i2f");
    ins(t + " = " + (sgn ? "sitofp " : "uitofp ") + lty(a.ty) + " " + a.text + " to " + lty(ty));
    return {t, ty};
  }
  if (h == "cf2i") {
    Ty ty = parse_type(&at(x, 1));
    Val a = operand(at(x, 2));
    if (!(ty.kind == "int" && !ty.is_bool) || a.ty.kind != "float") throw Refused("cf2i of " + a.ty.kind + " to " + ty.kind);
    int bits = ty.size * 8;
    std::string F = lty(a.ty);
    if (m_.f2i_convert) {
      // the GPU's conversion (cvt.rzi): saturating, NaN gives 0; a 1- or 2-byte target converts to 32 bits and keeps
      // the low bytes
      int cb = bits < 32 ? 32 : bits;
      std::string I = "i" + std::to_string(cb);
      std::string fn = std::string(ty.is_signed ? "llvm.fptosi.sat." : "llvm.fptoui.sat.") + I + "." + (a.ty.size == 4 ? "f32" : "f64");
      m_.declare("declare " + I + " @" + fn + "(" + F + ")");
      std::string t = tmp();
      ins(t + " = call " + I + " @" + fn + "(" + F + " " + a.text + ")");
      if (cb == bits) return {t, ty};
      std::string u = tmp();
      ins(u + " = trunc " + I + " " + t + " to " + lty(ty));
      return {u, ty};
    }
    // the range check of the IR (pathb-stage2): out of range or NaN traps
    double lo, hi;
    std::string lop;
    if (ty.is_signed) {
      lo = -std::ldexp(1.0, bits - 1);
      hi = std::ldexp(1.0, bits - 1);
      bool exact_below = (a.ty.size == 8 && bits <= 53) || (a.ty.size == 4 && bits <= 24);
      if (exact_below) {
        lop = "ogt";
        lo -= 1;
      } else {
        lop = "oge";
      }
    } else {
      lop = "ogt";
      lo = -1.0;
      hi = std::ldexp(1.0, bits);
    }
    char lb[64], hb[64];
    std::snprintf(lb, sizeof lb, "%.17g", lo);
    std::snprintf(hb, sizeof hb, "%.17g", hi);
    std::string p1 = tmp(), p2 = tmp(), p = tmp(), np = tmp();
    ins(p1 + " = fcmp " + lop + " " + F + " " + a.text + ", " + float_hex(lb, a.ty));
    ins(p2 + " = fcmp olt " + F + " " + a.text + ", " + float_hex(hb, a.ty));
    ins(p + " = and i1 " + p1 + ", " + p2);
    ins(np + " = xor i1 " + p + ", true");
    trap_if(np);
    std::string t = tmp();
    ins(t + " = " + (ty.is_signed ? "fptosi " : "fptoui ") + F + " " + a.text + " to " + lty(ty));
    return {t, ty};
  }
  static const std::set<std::string> cmps = {"lt", "le", "gt", "ge", "eq", "ne"};
  std::string base = h.substr(0, h.find('.'));
  if (cmps.count(base)) {
    Ty ty = parse_type(&at(x, 1));
    if (!is_bool(dty)) throw BadIR("comparison result is not bool");
    return compare(h, ty, at(x, 2), at(x, 3));
  }
  ok = false;
  return {};
}

// Integer conversion: sign or zero extension by the source's signedness (a bool is 0 or 1), or truncation.
Val Fn::conv_to(const Val &a, const Ty &ty) {
  int as = is_bool(a.ty) ? 0 : a.ty.size, ts = ty.size;
  if (!is_bool(a.ty) && as == ts) return {a.text, ty};
  std::string t = tmp();
  if (is_bool(a.ty)) {
    ins(t + " = zext i1 " + a.text + " to " + lty(ty));
  } else if (ts < as) {
    ins(t + " = trunc " + lty(a.ty) + " " + a.text + " to " + lty(ty));
  } else {
    ins(t + " = " + (a.ty.is_signed ? "sext " : "zext ") + lty(a.ty) + " " + a.text + " to " + lty(ty));
  }
  return {t, ty};
}

Val Fn::memory(const std::string &h, const Node &x, const Ty &dty, bool &ok) {
  ok = true;
  if (h == "load" || h == "load.v") {
    Ty ty = parse_type(&at(x, 1));
    Val addr = operand(at(x, 2));
    if (addr.ty.kind != "ptr") throw BadIR("load through a " + addr.ty.kind);
    std::string t = tmp();
    ins(t + " = load " + std::string(h == "load.v" ? "volatile " : "") + mty(ty) + ", ptr " + addr.text + ", align 1");
    if (is_bool(ty)) {
      std::string b = tmp();
      ins(b + " = icmp ne i8 " + t + ", 0");
      return {b, ty};
    }
    return {t, ty};
  }
  if (h == "bitcast") {
    Ty ty = parse_type(&at(x, 1));
    if (ty.kind != "ptr") throw Refused("bitcast to a non-pointer");
    const Node &v = at(x, 2);
    Val o = operand(v);
    if (o.ty.kind != "ptr") throw Refused("bitcast of a non-pointer");
    return {o.text, kPtr};
  }
  if (h == "offset") {
    Val base = operand(at(x, 1));
    if (base.ty.kind != "ptr") throw Refused("offset of a non-pointer");
    std::string t = tmp();
    ins(t + " = getelementptr i8, ptr " + base.text + ", i64 " + i128_text(as_int(&at(x, 2))));
    return {t, kPtr};
  }
  if (h == "index") {
    // (index BASE IDX SIZE): BASE + IDX * SIZE, the index sign-extended as mul.wide.s32 does
    Val base = operand(at(x, 1));
    Val idx = operand(at(x, 2));
    if (base.ty.kind != "ptr" || idx.ty.kind != "int") throw Refused("index of " + base.ty.kind + " by " + idx.ty.kind);
    Val i64 = idx;
    if (is_bool(idx.ty) || idx.ty.size != 8) {
      std::string t = tmp();
      ins(t + " = " + (is_bool(idx.ty) ? "zext " : "sext ") + lty(idx.ty) + " " + idx.text + " to i64");
      i64 = {t, kI64};
    }
    std::string t = tmp();
    ins(t + " = getelementptr [" + i128_text(as_int(&at(x, 3))) + " x i8], ptr " + base.text + ", i64 " + i64.text);
    return {t, kPtr};
  }
  if (h == "pdiff") {
    Val a = operand(at(x, 1)), b = operand(at(x, 2));
    i128 size = as_int(&at(x, 3));
    if (size <= 0) throw Refused("pdiff with element size " + i128_text(size));
    std::string ia = tmp(), ib = tmp(), d = tmp();
    ins(ia + " = ptrtoint ptr " + a.text + " to i64");
    ins(ib + " = ptrtoint ptr " + b.text + " to i64");
    ins(d + " = sub i64 " + ia + ", " + ib);
    if (size == 1) return {d, dty};
    std::string q = tmp();
    ins(q + " = sdiv exact i64 " + d + ", " + i128_text(size));
    return {q, dty};
  }
  ok = false;
  return {};
}

Val Fn::shuffle(const std::string &mode, const Val &v, const Val &lane) {
  // the CUDA shuffle with the full mask and no width (the prelude folds the width into the lane): the source lane, or
  // the lane itself where PTX's shfl gives the own value (down past lane 31, up below lane 0)
  Val me = lane_id();
  std::string src = tmp();
  if (mode == "idx") {
    ins(src + " = and i32 " + lane.text + ", 31");
  } else if (mode == "bfly") {
    std::string x = tmp();
    ins(x + " = xor i32 " + me.text + ", " + lane.text);
    ins(src + " = and i32 " + x + ", 31");
  } else if (mode == "down") {
    std::string s = tmp(), c = tmp();
    ins(s + " = add i32 " + me.text + ", " + lane.text);
    ins(c + " = icmp ugt i32 " + s + ", 31");
    ins(src + " = select i1 " + c + ", i32 " + me.text + ", i32 " + s);
  } else {
    std::string s = tmp(), c = tmp();
    ins(s + " = sub i32 " + me.text + ", " + lane.text);
    ins(c + " = icmp slt i32 " + s + ", 0");
    ins(src + " = select i1 " + c + ", i32 " + me.text + ", i32 " + s);
  }
  std::string addr = tmp(), bits = v.text, out = tmp();
  ins(addr + " = shl i32 " + src + ", 2");
  if (v.ty.kind == "float") {
    bits = tmp();
    ins(bits + " = bitcast float " + v.text + " to i32");
  }
  m_.declare("declare i32 @llvm.amdgcn.ds.bpermute(i32, i32)");
  ins(out + " = call i32 @llvm.amdgcn.ds.bpermute(i32 " + addr + ", i32 " + bits + ")");
  if (v.ty.kind == "float") {
    std::string f = tmp();
    ins(f + " = bitcast i32 " + out + " to float");
    return {f, kF32};
  }
  return {out, v.ty};
}

// The device built-ins of the CUDA flow (the __nfcxx_* names of cuda-rewrite's prelude), as amdgcn intrinsics or
// plain LLVM IR. nullopt when name is not one of them.
std::optional<Val> Fn::builtin(const std::string &name, const Node &x, const Ty *ty) {
  std::vector<const Node *> args;
  for (size_t i = 3; i < x.items.size(); i++) args.push_back(&x.items[i]);
  auto nargs = [&](size_t n) {
    if (args.size() != n) throw Refused(name + " takes " + std::to_string(n) + " argument(s)");
  };
  auto value = [&]() {
    if (!ty) throw Refused(name + " has no value");
  };
  static const std::map<std::string, std::pair<std::string, int>> special = {
      {"tid", {"workitem.id", 0}}, {"ctaid", {"workgroup.id", 0}}, {"ntid", {"", 12}}, {"nctaid", {"", 0}}};
  if (name.compare(0, 8, "__nfcxx_") == 0) {
    std::string rest = name.substr(8);
    size_t us = rest.rfind('_');
    if (us != std::string::npos && rest.size() == us + 2 && special.count(rest.substr(0, us))) {
      std::string what = rest.substr(0, us);
      char d = rest[us + 1];
      if (d != 'x' && d != 'y' && d != 'z') return std::nullopt;
      nargs(0);
      int k = d - 'x';
      if (what == "tid" || what == "ctaid") {
        std::string fn = "llvm.amdgcn." + special.at(what).first + "." + std::string(1, d);
        m_.declare("declare i32 @" + fn + "()");
        std::string t = tmp();
        ins(t + " = call i32 @" + fn + "()");
        return Val{t, kI32};
      }
      if (what == "ntid") return implicit_load(12 + 2 * k, 2);
      return implicit_load(4 * k, 4);
    }
  }
  if (name == "__nfcxx_syncthreads") {
    nargs(0);
    m_.declare("declare void @llvm.amdgcn.s.barrier()");
    ins("fence syncscope(\"workgroup\") release");
    ins("call void @llvm.amdgcn.s.barrier()");
    ins("fence syncscope(\"workgroup\") acquire");
    return Val{"", kI32};
  }
  if (name == "__nfcxx_syncthreads_or") {
    // the block-wide OR of a predicate, through one LDS word: cleared, ORed into, read, with a barrier between each
    nargs(1);
    value();
    m_.uses_flag = true;
    m_.declare("declare void @llvm.amdgcn.s.barrier()");
    m_.declare("declare i32 @llvm.amdgcn.workitem.id.x()");
    m_.declare("declare i32 @llvm.amdgcn.workitem.id.y()");
    m_.declare("declare i32 @llvm.amdgcn.workitem.id.z()");
    Val p = operand(*args[0]);
    const std::string flag = "addrspacecast (ptr addrspace(3) @__nfcxx_or_flag to ptr)";
    auto barrier = [&]() {
      ins("fence syncscope(\"workgroup\") release");
      ins("call void @llvm.amdgcn.s.barrier()");
      ins("fence syncscope(\"workgroup\") acquire");
    };
    std::string tx = tmp(), tyy = tmp(), tz = tmp(), o1 = tmp(), o2 = tmp(), first = tmp();
    ins(tx + " = call i32 @llvm.amdgcn.workitem.id.x()");
    ins(tyy + " = call i32 @llvm.amdgcn.workitem.id.y()");
    ins(tz + " = call i32 @llvm.amdgcn.workitem.id.z()");
    ins(o1 + " = or i32 " + tx + ", " + tyy);
    ins(o2 + " = or i32 " + o1 + ", " + tz);
    ins(first + " = icmp eq i32 " + o2 + ", 0");
    barrier();
    std::string clr = new_label(), j1 = new_label(), set = new_label(), j2 = new_label();
    terminate("br i1 " + first + ", label %" + clr + ", label %" + j1);
    label(clr);
    ins("store i32 0, ptr " + flag + ", align 4");
    label(j1);
    barrier();
    std::string pz = tmp();
    ins(pz + " = icmp ne " + lty(p.ty) + " " + p.text + ", 0");
    terminate("br i1 " + pz + ", label %" + set + ", label %" + j2);
    label(set);
    std::string old = tmp();
    ins(old + " = atomicrmw or ptr " + flag + ", i32 1 syncscope(\"workgroup\") monotonic, align 4");
    label(j2);
    barrier();
    std::string r = tmp();
    ins(r + " = load i32, ptr " + flag + ", align 4");
    barrier();
    return Val{r, *ty};
  }
  if (name == "__nfcxx_syncwarp") {
    nargs(1);
    m_.declare("declare void @llvm.amdgcn.wave.barrier()");
    ins("fence syncscope(\"wavefront\") release");
    ins("call void @llvm.amdgcn.wave.barrier()");
    ins("fence syncscope(\"wavefront\") acquire");
    return Val{"", kI32};
  }
  if (name == "__nfcxx_threadfence_system") {
    nargs(0);
    ins("fence seq_cst");
    return Val{"", kI32};
  }
  if (name == "__nfcxx_nanosleep") {
    nargs(1);
    operand(*args[0]);
    m_.declare("declare void @llvm.amdgcn.s.sleep(i32)");
    ins("call void @llvm.amdgcn.s.sleep(i32 1)");
    return Val{"", kI32};
  }
  if (name == "__nfcxx_dynshared_addr") {
    nargs(0);
    m_.uses_dynshared = true;
    return Val{"addrspacecast (ptr addrspace(3) @__nfcxx_dynshared to ptr)", kPtr};
  }
  static const std::map<std::string, std::string> shuffles = {
      {"__nfcxx_shfl_sync_i", "idx"},      {"__nfcxx_shfl_sync_f", "idx"},      {"__nfcxx_shfl_xor_sync_i", "bfly"},
      {"__nfcxx_shfl_xor_sync_f", "bfly"}, {"__nfcxx_shfl_down_sync_i", "down"}, {"__nfcxx_shfl_down_sync_f", "down"},
      {"__nfcxx_shfl_up_sync_i", "up"},    {"__nfcxx_shfl_up_sync_f", "up"}};
  auto full_mask = [&](const Node &m) {
    Val v = operand(m);
    if (v.text != "-1") throw Refused(name + ": only the full-warp mask 0xffffffff is lowered (mask operand " + v.text + ")");
  };
  if (shuffles.count(name)) {
    nargs(3);
    value();
    full_mask(*args[0]);
    Val v = operand(*args[1]), lane = operand(*args[2]);
    if (type_size(v.ty) != 4 || lane.ty.kind != "int" || lane.ty.size != 4) throw Refused(name + ": operand types");
    return shuffle(shuffles.at(name), v, lane);
  }
  if (name == "__nfcxx_reduce_add_sync") {
    nargs(2);
    value();
    full_mask(*args[0]);
    Val v = operand(*args[1]);
    for (int off : {16, 8, 4, 2, 1}) {
      Val o = shuffle("bfly", v, Val{std::to_string(off), kI32});
      std::string t = tmp();
      ins(t + " = add i32 " + v.text + ", " + o.text);
      v = {t, v.ty};
    }
    return v;
  }
  if (name == "__nfcxx_ballot_sync" || name == "__nfcxx_any_sync" || name == "__nfcxx_all_sync") {
    nargs(2);
    value();
    full_mask(*args[0]);
    Val p = operand(*args[1]);
    std::string c = tmp(), b = tmp();
    ins(c + " = icmp ne " + lty(p.ty) + " " + p.text + ", 0");
    m_.declare("declare i32 @llvm.amdgcn.ballot.i32(i1)");
    ins(b + " = call i32 @llvm.amdgcn.ballot.i32(i1 " + c + ")");
    if (name == "__nfcxx_ballot_sync") return Val{b, *ty};
    std::string r = tmp(), z = tmp();
    if (name == "__nfcxx_any_sync") {
      ins(r + " = icmp ne i32 " + b + ", 0");
    } else {
      std::string all = tmp();
      ins(all + " = call i32 @llvm.amdgcn.ballot.i32(i1 true)");
      ins(r + " = icmp eq i32 " + b + ", " + all);
    }
    ins(z + " = zext i1 " + r + " to i32");
    return Val{z, *ty};
  }
  if (name == "__nfcxx_atomic_add_i" || name == "__nfcxx_atomic_add_f" || name == "__nfcxx_atomic_max_i") {
    nargs(2);
    value();
    Val p = operand(*args[0]), v = operand(*args[1]);
    std::string op = name == "__nfcxx_atomic_add_f" ? "fadd" : (name == "__nfcxx_atomic_max_i" ? "max" : "add");
    std::string t = tmp();
    ins(t + " = atomicrmw " + op + " ptr " + p.text + ", " + lty(v.ty) + " " + v.text + " syncscope(\"agent\") monotonic, align 4");
    return Val{t, *ty};
  }
  if (name == "__nfcxx_atomic_cas_i") {
    nargs(3);
    value();
    Val p = operand(*args[0]), c = operand(*args[1]), v = operand(*args[2]);
    std::string t = tmp(), r = tmp();
    ins(t + " = cmpxchg ptr " + p.text + ", i32 " + c.text + ", i32 " + v.text + " syncscope(\"agent\") monotonic monotonic, align 4");
    ins(r + " = extractvalue { i32, i1 } " + t + ", 0");
    return Val{r, *ty};
  }
  if (name == "__nfcxx_umulhi") {
    nargs(2);
    value();
    Val a = operand(*args[0]), b = operand(*args[1]);
    std::string za = tmp(), zb = tmp(), m = tmp(), s = tmp(), r = tmp();
    ins(za + " = zext i32 " + a.text + " to i64");
    ins(zb + " = zext i32 " + b.text + " to i64");
    ins(m + " = mul i64 " + za + ", " + zb);
    ins(s + " = lshr i64 " + m + ", 32");
    ins(r + " = trunc i64 " + s + " to i32");
    return Val{r, *ty};
  }
  if (name == "__nfcxx_popc") {
    nargs(1);
    value();
    Val a = operand(*args[0]);
    m_.declare("declare i32 @llvm.ctpop.i32(i32)");
    std::string r = tmp();
    ins(r + " = call i32 @llvm.ctpop.i32(i32 " + a.text + ")");
    return Val{r, *ty};
  }
  if (name == "__nfcxx_byte_perm") {
    // CUDA's __byte_perm: byte i of the result is byte (s >> 4i) & 7 of the 8 bytes {y, x}
    nargs(3);
    value();
    Val a = operand(*args[0]), b = operand(*args[1]), s = operand(*args[2]);
    std::string xa = tmp(), xb = tmp(), sh = tmp(), c = tmp();
    ins(xa + " = zext i32 " + a.text + " to i64");
    ins(xb + " = zext i32 " + b.text + " to i64");
    ins(sh + " = shl i64 " + xb + ", 32");
    ins(c + " = or i64 " + sh + ", " + xa);
    std::string acc = "0";
    for (int i = 0; i < 4; i++) {
      std::string sel = tmp(), sel7 = tmp(), sel8 = tmp(), sel64 = tmp(), by = tmp(), by32 = tmp(), m = tmp(), pos = tmp(), o = tmp();
      ins(sel + " = lshr i32 " + s.text + ", " + std::to_string(4 * i));
      ins(sel7 + " = and i32 " + sel + ", 7");
      ins(sel8 + " = shl i32 " + sel7 + ", 3");
      ins(sel64 + " = zext i32 " + sel8 + " to i64");
      ins(by + " = lshr i64 " + c + ", " + sel64);
      ins(by32 + " = trunc i64 " + by + " to i32");
      ins(m + " = and i32 " + by32 + ", 255");
      ins(pos + " = shl i32 " + m + ", " + std::to_string(8 * i));
      ins(o + " = or i32 " + acc + ", " + pos);
      acc = o;
    }
    return Val{acc, *ty};
  }
  if (name == "__nfcxx_dp4a") {
    // the signed 4-way byte dot product plus c
    nargs(3);
    value();
    Val a = operand(*args[0]), b = operand(*args[1]), c = operand(*args[2]);
    std::string va = tmp(), vb = tmp(), ea = tmp(), eb = tmp(), m = tmp(), r = tmp();
    ins(va + " = bitcast i32 " + a.text + " to <4 x i8>");
    ins(vb + " = bitcast i32 " + b.text + " to <4 x i8>");
    ins(ea + " = sext <4 x i8> " + va + " to <4 x i32>");
    ins(eb + " = sext <4 x i8> " + vb + " to <4 x i32>");
    ins(m + " = mul <4 x i32> " + ea + ", " + eb);
    m_.declare("declare i32 @llvm.vector.reduce.add.v4i32(<4 x i32>)");
    std::string s = tmp();
    ins(s + " = call i32 @llvm.vector.reduce.add.v4i32(<4 x i32> " + m + ")");
    ins(r + " = add i32 " + s + ", " + c.text);
    return Val{r, *ty};
  }
  if (name == "__nfcxx_hfma_rn") {
    nargs(3);
    value();
    std::string hs[3];
    for (int i = 0; i < 3; i++) {
      Val v = operand(*args[i]);
      std::string t = v.text;
      if (v.ty.size != 2) {
        t = tmp();
        ins(t + " = trunc " + lty(v.ty) + " " + v.text + " to i16");
      }
      hs[i] = tmp();
      ins(hs[i] + " = bitcast i16 " + t + " to half");
    }
    m_.declare("declare half @llvm.fma.f16(half, half, half)");
    std::string f = tmp(), b = tmp();
    ins(f + " = call half @llvm.fma.f16(half " + hs[0] + ", half " + hs[1] + ", half " + hs[2] + ")");
    ins(b + " = bitcast half " + f + " to i16");
    return Val{b, *ty};
  }
  if (name == "__nfcxx_rni_s32") {
    nargs(1);
    value();
    Val a = operand(*args[0]);
    m_.declare("declare float @llvm.rint.f32(float)");
    m_.declare("declare i32 @llvm.fptosi.sat.i32.f32(float)");
    std::string r = tmp(), i = tmp();
    ins(r + " = call float @llvm.rint.f32(float " + a.text + ")");
    ins(i + " = call i32 @llvm.fptosi.sat.i32.f32(float " + r + ")");
    return Val{i, *ty};
  }
  static const std::map<std::string, std::pair<std::string, int>> f1 = {
      {"__nfcxx_fabsf", {"llvm.fabs.f32", 1}},   {"__nfcxx_sqrtf", {"llvm.sqrt.f32", 1}},
      {"__nfcxx_floorf", {"llvm.floor.f32", 1}}, {"__nfcxx_truncf", {"llvm.trunc.f32", 1}},
      {"__nfcxx_ceilf", {"llvm.ceil.f32", 1}},   {"__nfcxx_log2f", {"llvm.log2.f32", 1}},
      {"__nfcxx_fmaxf", {"llvm.maxnum.f32", 2}}, {"__nfcxx_fminf", {"llvm.minnum.f32", 2}},
      {"__nfcxx_fmaf", {"llvm.fma.f32", 3}}};
  auto fcall = [&](const std::string &fn, const std::vector<std::string> &as) {
    std::string sig, list;
    for (size_t i = 0; i < as.size(); i++) {
      sig += std::string(i ? ", " : "") + "float";
      list += std::string(i ? ", " : "") + "float " + as[i];
    }
    m_.declare("declare float @" + fn + "(" + sig + ")");
    std::string t = tmp();
    ins(t + " = call float @" + fn + "(" + list + ")");
    return t;
  };
  if (f1.count(name)) {
    auto e = f1.at(name);
    nargs(static_cast<size_t>(e.second));
    value();
    std::vector<std::string> as;
    for (const Node *a : args) as.push_back(operand(*a).text);
    return Val{fcall(e.first, as), kF32};
  }
  if (name == "__nfcxx_rsqrtf") {
    nargs(1);
    value();
    std::string s = fcall("llvm.sqrt.f32", {operand(*args[0]).text});
    std::string r = tmp();
    ins(r + " = fdiv afn float 1.0, " + s);
    return Val{r, kF32};
  }
  if (name == "__nfcxx_fdividef") {
    nargs(2);
    value();
    Val a = operand(*args[0]), b = operand(*args[1]);
    std::string r = tmp();
    ins(r + " = fdiv afn float " + a.text + ", " + b.text);
    return Val{r, kF32};
  }
  if (name == "__nfcxx_saturatef") {
    nargs(1);
    value();
    std::string lo = fcall("llvm.maxnum.f32", {operand(*args[0]).text, "0.0"});
    return Val{fcall("llvm.minnum.f32", {lo, "1.0"}), kF32};
  }
  if (name == "__nfcxx_expf") {
    nargs(1);
    value();
    std::string t = tmp();
    ins(t + " = fmul float " + operand(*args[0]).text + ", 0x3FF7154760000000");  // log2(e)
    return Val{fcall("llvm.exp2.f32", {t}), kF32};
  }
  if (name == "__nfcxx_logf") {
    nargs(1);
    value();
    std::string l = fcall("llvm.log2.f32", {operand(*args[0]).text});
    std::string t = tmp();
    ins(t + " = fmul float " + l + ", 0x3FE62E4300000000");  // ln(2)
    return Val{t, kF32};
  }
  return std::nullopt;
}

Val Fn::call(const Node &x, const Ty *ty) {
  const Node &callee = at(x, 2);
  if (!(callee.kind == Node::Sym && callee.sig == '&')) throw Refused("indirect call");
  const std::string &cname = callee.text;
  if (auto b = builtin(cname, x, ty)) return *b;
  if (cname == "printf") throw Refused("printf in device code (not lowered for AMD GPUs yet)");
  if (cname == "memset") {
    if (x.items.size() != 6) throw Refused("memset takes (pointer, value, count)");
    Val p = operand(at(x, 3)), v = operand(at(x, 4)), n = operand(at(x, 5));
    std::string b = tmp();
    ins(b + " = trunc " + lty(v.ty) + " " + v.text + " to i8");
    Val n64 = n.ty.size == 8 ? n : conv_to(Val{n.text, Ty{"int", n.ty.size, false, false}}, kI64);
    m_.declare("declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)");
    ins("call void @llvm.memset.p0.i64(ptr " + p.text + ", i8 " + b + ", i64 " + n64.text + ", i1 false)");
    return p;
  }
  if (cname == "__cxa_vec_ctor") {
    // (call void &"__cxa_vec_ctor" ARRAY COUNT SIZE CTOR DTOR): one call of the constructor per element
    if (x.items.size() != 8) throw Refused("__cxa_vec_ctor takes (array, count, size, constructor, destructor)");
    if (head_of(at(x, 7)) != "null") throw Refused("__cxa_vec_ctor with a destructor");
    long long count = static_cast<long long>(as_int(&at(at(x, 4), 2)));
    long long size = static_cast<long long>(as_int(&at(at(x, 5), 2)));
    const Node &cn = at(x, 6);
    std::string ctor = cn.kind == Node::Sym && cn.sig == '&' ? cn.text : (fn_values_.count(cn.text) ? fn_values_[cn.text] : "");
    if (ctor.empty() || !m_.fns.count(ctor)) throw Refused("__cxa_vec_ctor: the constructor is not a function of this module");
    Val arr = operand(at(x, 3));
    for (long long i = 0; i < count; i++) {
      std::string p = tmp();
      ins(p + " = getelementptr i8, ptr " + arr.text + ", i64 " + std::to_string(i * size));
      ins("call void " + gname(ctor) + "(ptr " + p + ")");
    }
    return Val{"", kI32};
  }
  auto it = m_.fns.find(cname);
  if (it == m_.fns.end()) throw Refused("call of " + cname + " (not a function of this module)");
  Fn &f = *it->second;
  f.setup();
  if (f.kernel) throw Refused("call of kernel " + cname);
  size_t n = x.items.size() - 3;
  if (n != f.params.size())
    throw Refused("call of " + cname + " with " + std::to_string(n) + " arguments, it takes " + std::to_string(f.params.size()));
  std::string list;
  for (size_t k = 0; k < n; k++) {
    const Node *a = &x.items[3 + k];
    if (head_of(*a) == "byval" || head_of(*a) == "sret") a = &at(*a, 2);
    Val v = operand(*a);
    list += std::string(k ? ", " : "") + lty(f.params[k]) + " " + as_type(v, f.params[k]);
  }
  std::string rt = f.ret ? lty(*f.ret) : "void";
  if (f.ret) {
    std::string t = tmp();
    ins(t + " = call " + rt + " " + gname(cname) + "(" + list + ")");
    return Val{t, *f.ret};
  }
  ins("call void " + gname(cname) + "(" + list + ")");
  return Val{"", kI32};
}

Val Fn::rval(const Node &x, const Ty &dty) {
  std::string h = head_of(x);
  if (h == "call") {
    Ty ty = parse_type(&at(x, 1));
    Val v = call(x, &ty);
    if (v.text.empty()) throw Refused("call of " + form_text(at(x, 2)) + " as a value, but it returns nothing");
    return Val{v.text, ty};
  }
  if (h == "gpu") {
    std::string n = at(x, 2).text;
    static const std::map<std::string, std::string> g = {
        {"tid.x", "__nfcxx_tid_x"},     {"tid.y", "__nfcxx_tid_y"},     {"tid.z", "__nfcxx_tid_z"},
        {"ctaid.x", "__nfcxx_ctaid_x"}, {"ctaid.y", "__nfcxx_ctaid_y"}, {"ctaid.z", "__nfcxx_ctaid_z"},
        {"ntid.x", "__nfcxx_ntid_x"},   {"ntid.y", "__nfcxx_ntid_y"},   {"ntid.z", "__nfcxx_ntid_z"},
        {"nctaid.x", "__nfcxx_nctaid_x"}, {"nctaid.y", "__nfcxx_nctaid_y"}, {"nctaid.z", "__nfcxx_nctaid_z"}};
    if (!g.count(n)) throw Refused("special register " + n);
    Node c;
    c.kind = Node::List;
    Ty ty = parse_type(&at(x, 1));
    auto v = builtin(g.at(n), c, &ty);
    return Val{v->text, ty};
  }
  if (h == "const" || h == "null") return operand(x);
  bool ok = false;
  Val v = memory(h, x, dty, ok);
  if (ok) return v;
  v = arith(h, x, dty, ok);
  if (ok) return v;
  throw Refused("expression " + (h.empty() ? form_text(x) : h));
}

void Fn::emit_return(const Node &s) {
  if (!ret) {
    if (s.items.size() > 1) throw Refused("return with a value in a void function");
    terminate("ret void");
    return;
  }
  if (s.items.size() != 2) throw Refused("return without a value in " + name);
  Val v = operand(at(s, 1));
  terminate("ret " + lty(*ret) + " " + as_type(v, *ret));
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
    Val r = rval(v, ty);
    if (!same_class(r.ty, ty)) {
      // an integer of another width or signedness than the let's (the IR's types are the C types): converted
      if (r.ty.kind == "int" && ty.kind == "int" && !is_bool(ty)) r = conv_to(r, ty);
      else throw BadIR("value of type " + lty(r.ty) + " stored in a " + lty(ty));
    }
    store_reg(at(s, 1).text, Val{r.text, ty});
  } else if (h == "set") {
    auto it = regs_.find(at(s, 1).text);
    if (it == regs_.end()) throw BadIR("set of " + at(s, 1).text + " before its let");
    Val o = operand(at(s, 2));
    store_reg(at(s, 1).text, Val{as_type(o, it->second), it->second});
  } else if (h == "store" || h == "store.v") {
    Ty ty = parse_type(&at(s, 1));
    Val addr = operand(at(s, 2));
    Val val = operand(at(s, 3));
    std::string vt = as_type(val, ty);
    if (is_bool(ty)) {
      std::string b = tmp();
      ins(b + " = zext i1 " + vt + " to i8");
      vt = b;
    }
    ins(std::string("store ") + (h == "store.v" ? "volatile " : "") + mty(ty) + " " + vt + ", ptr " + addr.text + ", align 1");
  } else if (h == "copy") {
    long long n = static_cast<long long>(as_int(&at(s, 1)));
    Val d = operand(at(s, 2)), sr = operand(at(s, 3));
    m_.declare("declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)");
    ins("call void @llvm.memcpy.p0.p0.i64(ptr " + d.text + ", ptr " + sr.text + ", i64 " + std::to_string(n) + ", i1 false)");
  } else if (h == "if") {
    Val c = operand(at(s, 1));
    if (!is_bool(c.ty)) throw BadIR("if condition is not a bool");
    const Node *then_f = nullptr, *else_f = nullptr;
    for (size_t i = 2; i < s.items.size(); i++) {
      if (!then_f && head_of(s.items[i]) == "then") then_f = &s.items[i];
      if (!else_f && head_of(s.items[i]) == "else") else_f = &s.items[i];
    }
    if (!then_f) throw BadIR("if without then");
    std::string lt = new_label(), le = new_label(), lend = new_label();
    terminate("br i1 " + c.text + ", label %" + lt + ", label %" + le);
    lines_.push_back(lt + ":");
    term_ = false;
    for (size_t i = 1; i < then_f->items.size(); i++) stmt(then_f->items[i]);
    br(lend);
    lines_.push_back(le + ":");
    term_ = false;
    if (else_f)
      for (size_t i = 1; i < else_f->items.size(); i++) stmt(else_f->items[i]);
    label(lend);
  } else if (h == "loop") {
    const Node *body_f = nullptr, *step_f = nullptr;
    for (size_t i = 1; i < s.items.size(); i++) {
      if (!body_f && head_of(s.items[i]) == "body") body_f = &s.items[i];
      if (!step_f && head_of(s.items[i]) == "step") step_f = &s.items[i];
    }
    if (!body_f || !step_f) throw BadIR("loop without body and step");
    std::string top = new_label(), cont = new_label(), end = new_label();
    label(top);
    loops_.push_back({cont, end});
    for (size_t i = 1; i < body_f->items.size(); i++) stmt(body_f->items[i]);
    label(cont);
    for (size_t i = 1; i < step_f->items.size(); i++) stmt(step_f->items[i]);
    loops_.pop_back();
    br(top);
    lines_.push_back(end + ":");
    term_ = false;
  } else if (h == "switch") {
    const Node *body_f = nullptr;
    for (size_t i = 1; i < s.items.size(); i++)
      if (!body_f && head_of(s.items[i]) == "body") body_f = &s.items[i];
    if (!body_f) throw BadIR("switch without body");
    Val v = operand(at(s, 1));
    if (!(v.ty.kind == "int" && !v.ty.is_bool)) throw Refused("switch on a " + v.ty.kind);
    std::vector<const Node *> items;
    std::function<void(const Node &)> expand = [&](const Node &f) {
      if (head_of(f) == "block") {
        for (size_t i = 1; i < f.items.size(); i++) expand(f.items[i]);
      } else {
        items.push_back(&f);
      }
    };
    for (size_t i = 1; i < body_f->items.size(); i++) expand(body_f->items[i]);
    std::string end = new_label(), deflt;
    std::map<size_t, std::string> arm_labels;
    std::string cases;
    std::set<std::string> seen;
    for (size_t idx = 0; idx < items.size(); idx++) {
      std::string h2 = head_of(*items[idx]);
      if (h2 == "case") {
        const Node &c = at(*items[idx], 1);
        if (head_of(c) != "const") throw BadIR("case value is not a constant");
        std::string val = int_text(v.ty, as_int(&at(c, 2)));
        if (!seen.insert(val).second) throw Refused("duplicate case " + val);
        std::string l = new_label();
        arm_labels[idx] = l;
        cases += " " + lty(v.ty) + " " + val + ", label %" + l;
      } else if (h2 == "default") {
        if (!deflt.empty()) throw Refused("two default labels");
        deflt = new_label();
        arm_labels[idx] = deflt;
      }
    }
    terminate("switch " + lty(v.ty) + " " + v.text + ", label %" + (deflt.empty() ? end : deflt) + " [" + cases + " ]");
    loops_.push_back({"", end});
    for (size_t idx = 0; idx < items.size(); idx++) {
      auto a = arm_labels.find(idx);
      if (a != arm_labels.end()) label(a->second);
      else stmt(*items[idx]);
    }
    loops_.pop_back();
    label(end);
  } else if (h == "label") {
    label(named_label(at(s, 1).text));
  } else if (h == "goto") {
    br(named_label(at(s, 1).text));
  } else if (h == "break") {
    if (loops_.empty()) throw Refused("break outside a loop or switch");
    br(loops_.back().second);
  } else if (h == "continue") {
    for (auto it = loops_.rbegin(); it != loops_.rend(); ++it)
      if (!it->first.empty()) {
        br(it->first);
        return;
      }
    throw BadIR("continue outside a loop");
  } else if (h == "loc" || h == "likely" || h == "unlikely") {
  } else if (h == "trap" || h == "unreachable") {
    ins("call void @llvm.trap()");
    terminate("unreachable");
  } else if (h == "ptx-asm") {
    throw Refused("inline PTX assembly (not lowered for AMD GPUs)");
  } else if (h == "bounds") {
    Val v = operand(at(s, 1));
    if (v.ty.kind != "int") throw Refused("bounds of a non-integer");
    std::string q = tmp();
    ins(q + " = icmp uge " + lty(v.ty) + " " + v.text + ", " + i128_text(as_int(&at(s, 2))));
    trap_if(q);
  } else if (h == "nonnull") {
    Val p = operand(at(s, 1));
    if (p.ty.kind != "ptr") throw Refused("nonnull of " + form_text(at(s, 1)));
    std::string q = tmp();
    ins(q + " = icmp eq ptr " + p.text + ", null");
    trap_if(q);
  } else if (h == "return") {
    emit_return(s);
  } else if (h == "eval") {
    if (!(s.items.size() == 2 && head_of(at(s, 1)) == "call")) throw Refused("eval of " + form_text(at(s, 1)));
    call(at(s, 1), nullptr);
  } else {
    throw Refused("statement " + (h.empty() ? form_text(s) : h));
  }
}

std::string Fn::compile() {
  setup();
  // the slots: allocas of their bytes in the private address space, used through their flat addresses
  int k = 0;
  for (auto &sd : slot_decls_) {
    std::string a = "%s" + std::to_string(k), f = "%sp" + std::to_string(k);
    k++;
    entry_.push_back(a + " = alloca [" + std::to_string(std::max(1LL, sd.second.first)) + " x i8], align " +
                     std::to_string(std::max(1LL, sd.second.second)) + ", addrspace(5)");
    entry_.push_back(f + " = addrspacecast ptr addrspace(5) " + a + " to ptr");
    slots_[sd.first] = f;
  }
  std::string sig;
  for (size_t i = 0; i < params.size(); i++) {
    std::string pn = "%p" + std::to_string(i);
    std::string reg = "%" + std::to_string(i);
    if (aggs[i]) {
      const AggShape &sh = *aggs[i];
      if (is_sret[i]) {
        // the result object: the caller's address
        sig += std::string(i ? ", " : "") + "ptr " + pn;
        store_reg(reg, Val{pn, kPtr});
        continue;
      }
      // a byval struct: copied into this frame (a kernel's from its kernarg bytes)
      std::string a = "%bv" + std::to_string(i), f = "%bvp" + std::to_string(i);
      long long size = std::max(1LL, sh.size), align = std::max(1LL, sh.align);
      entry_.push_back(a + " = alloca [" + std::to_string(size) + " x i8], align " + std::to_string(align) + ", addrspace(5)");
      entry_.push_back(f + " = addrspacecast ptr addrspace(5) " + a + " to ptr");
      m_.declare("declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)");
      if (kernel) {
        if (sh.empty) throw Refused("kernel " + name + " takes an empty struct by value");
        m_.declare("declare void @llvm.memcpy.p0.p4.i64(ptr, ptr addrspace(4), i64, i1)");
        sig += std::string(i ? ", " : "") + "ptr addrspace(4) byref([" + std::to_string(size) + " x i8]) align " +
               std::to_string(align) + " " + pn;
        ins("call void @llvm.memcpy.p0.p4.i64(ptr " + f + ", ptr addrspace(4) " + pn + ", i64 " + std::to_string(size) + ", i1 false)");
      } else {
        sig += std::string(i ? ", " : "") + "ptr " + pn;
        ins("call void @llvm.memcpy.p0.p0.i64(ptr " + f + ", ptr " + pn + ", i64 " + std::to_string(size) + ", i1 false)");
      }
      store_reg(reg, Val{f, kPtr});
      continue;
    }
    const Ty &t = params[i];
    if (kernel && is_bool(t)) {
      // a kernel's bool argument is the host's one byte
      sig += std::string(i ? ", " : "") + "i8 " + pn;
      std::string b = tmp();
      ins(b + " = icmp ne i8 " + pn + ", 0");
      store_reg(reg, Val{b, t});
      continue;
    }
    sig += std::string(i ? ", " : "") + lty(t) + " " + pn;
    store_reg(reg, Val{pn, t});
  }
  for (const Node *s : body_) stmt(*s);
  if (!term_) {
    if (ret) {
      // falling off the end of a function with a value: undefined in C++, a trap here
      ins("call void @llvm.trap()");
      terminate("unreachable");
    } else {
      terminate("ret void");
    }
  }
  std::string out;
  if (kernel) {
    out = "define amdgpu_kernel void " + gname(name) + "(" + sig + ") #0 {\n";
  } else {
    out = "define internal " + (ret ? lty(*ret) : std::string("void")) + " " + gname(name) + "(" + sig + ") #1 {\n";
  }
  out += "entry:\n";
  for (const std::string &e : entry_) out += "  " + e + "\n";
  out += "  br label %body\nbody:\n";
  for (const std::string &l : lines_) out += l + "\n";
  out += "}\n\n";
  return out;
}

void collect_calls(const Node &x, std::vector<std::string> &acc) {
  if (x.kind == Node::Sym && x.sig == '&') acc.push_back(x.text);
  if (x.kind == Node::List)
    for (const Node &c : x.items) collect_calls(c, acc);
}

// The bytes of a global's initializer: scalars and zero runs at byte offsets, (bytes OFF N @"data") from a string
// constant. nullopt when the form has other pieces.
std::optional<std::vector<uint8_t>> init_bytes(const Node *init, long long size, const std::map<std::string, std::string> &strings) {
  std::vector<uint8_t> b(static_cast<size_t>(std::max(0LL, size)), 0);
  if (!init) return b;
  for (size_t i = 1; i < init->items.size(); i++) {
    const Node &f = init->items[i];
    std::string h = head_of(f);
    if (h == "zero") continue;
    if (h == "scalar") {
      long long off = static_cast<long long>(as_int(&at(f, 1)));
      Ty t = parse_type(&at(f, 2));
      const Node &c = at(f, 3);
      if (head_of(c) != "const") return std::nullopt;
      if (off < 0 || off + type_size(t) > size) return std::nullopt;
      uint64_t v = 0;
      if (t.kind == "float") {
        std::string hx = float_hex(at(c, 2).text, t);
        double d;
        uint64_t bits = std::strtoull(hx.c_str() + 2, nullptr, 16);
        std::memcpy(&d, &bits, 8);
        if (t.size == 4) {
          float fl = static_cast<float>(d);
          uint32_t u;
          std::memcpy(&u, &fl, 4);
          v = u;
        } else {
          v = bits;
        }
      } else if (is_bool(t)) {
        v = ends_with(at(c, 2).text, "1") ? 1 : 0;
      } else if (t.kind == "int") {
        v = static_cast<uint64_t>(as_int(&at(c, 2)));
      } else {
        return std::nullopt;
      }
      for (int k = 0; k < type_size(t); k++) b[static_cast<size_t>(off + k)] = static_cast<uint8_t>(v >> (8 * k));
      continue;
    }
    if (h == "bytes" && f.items.size() == 4 && f.items[3].kind == Node::Sym) {
      long long off = static_cast<long long>(as_int(&at(f, 1))), n = static_cast<long long>(as_int(&at(f, 2)));
      auto it = strings.find(f.items[3].text);
      if (it == strings.end() || off < 0 || off + n > size) return std::nullopt;
      for (long long k = 0; k < n && k < static_cast<long long>(it->second.size()); k++)
        b[static_cast<size_t>(off + k)] = static_cast<uint8_t>(it->second[static_cast<size_t>(k)]);
      continue;
    }
    return std::nullopt;
  }
  return b;
}

std::string bytes_init(const std::vector<uint8_t> &b) {
  bool zero = std::all_of(b.begin(), b.end(), [](uint8_t c) { return c == 0; });
  if (zero) return "zeroinitializer";
  std::string s = "c\"";
  for (uint8_t c : b) {
    char t[4];
    std::snprintf(t, sizeof t, "\\%02X", c);
    s += t;
  }
  return s + "\"";
}

int run(const std::string &src, const std::vector<std::string> &kernels, bool f2i, std::ostream &out) {
  Module m;
  m.f2i_convert = f2i;
  m.forms = parse_forms_chunked(src);
  std::map<std::string, std::string> strings;
  std::vector<const Node *> fn_forms;
  for (const Node &f : m.forms) {
    std::string h = head_of(f);
    if (h == "abi-type") {
      AggShape sh;
      sh.size = static_cast<long long>(as_int(&at(f, 2)));
      sh.align = static_cast<long long>(as_int(&at(f, 3)));
      sh.empty = f.items.size() > 4 && head_of(f.items[4]) == "empty";
      m.abi[at(f, 1).text] = sh;
    } else if (h == "data") {
      const Node &payload = at(f, 3);
      if (!(head_of(payload) == "string" && payload.items.size() == 2)) throw Refused("data " + at(f, 1).text + " (only string constants are lowered)");
      strings[at(f, 1).text] = payload.items[1].text;
    } else if (h == "function") {
      fn_forms.push_back(&f);
    }
  }
  // the data symbols (pathb-ptx-emit's classification): a string constant and a static initialized object are
  // constant memory, a zero-initialized static (a __shared__ object) is LDS, other objects are global memory
  for (auto &s : strings) {
    m.data[s.first].as = 4;
    std::vector<uint8_t> b(s.second.begin(), s.second.end());
    if (b.empty()) b.push_back(0);
    m.globals.push_back(gname(s.first) + " = internal addrspace(4) constant [" + std::to_string(b.size()) + " x i8] " +
                        bytes_init(b) + ", align 1");
  }
  for (const Node &f : m.forms) {
    if (head_of(f) != "global") continue;
    std::string name = at(f, 1).text;
    long long size = static_cast<long long>(as_int(&at(f, 3))), align = static_cast<long long>(as_int(&at(f, 4)));
    std::string linkage;
    const Node *init = nullptr;
    for (size_t i = 5; i < f.items.size(); i++) {
      std::string xh = head_of(f.items[i]);
      if (linkage.empty() && (xh == "static" || xh == "weak" || xh == "extern")) linkage = xh;
      if (!init && xh == "init") init = &f.items[i];
    }
    if (linkage == "extern") throw Refused("global " + name + " is extern (no definition in this unit)");
    auto bytes = init_bytes(init, size, strings);
    if (!bytes) throw Refused("global " + name + ": initializer form");
    bool zero = std::all_of(bytes->begin(), bytes->end(), [](uint8_t c) { return c == 0; });
    std::string ty = "[" + std::to_string(std::max(1LL, size)) + " x i8]";
    if (bytes->empty()) bytes->push_back(0);
    std::string al = ", align " + std::to_string(std::max(1LL, align));
    bool is_const = head_of(at(f, 2)) == "const";
    if (zero && (linkage == "static" || (linkage == "weak" && name.rfind("_ZZ", 0) == 0)) && !is_const) {
      m.data[name].as = 3;
      m.globals.push_back(gname(name) + " = internal addrspace(3) global " + ty + " poison" + al);
    } else if (linkage == "static" && !zero) {
      m.data[name].as = 4;
      m.globals.push_back(gname(name) + " = internal addrspace(4) constant " + ty + " " + bytes_init(*bytes) + al);
    } else {
      m.data[name].as = 1;
      std::string link = linkage == "static" ? "internal " : (linkage == "weak" ? "linkonce_odr " : "");
      m.globals.push_back(gname(name) + " = " + link + "addrspace(1) global " + ty + " " + bytes_init(*bytes) + al);
    }
  }
  // the functions: those the kernels reach (the kernels given, or every non-static function that no function calls)
  std::map<std::string, const Node *> by_name;
  std::map<std::string, std::vector<std::string>> callees;
  std::set<std::string> called, is_static;
  for (const Node *f : fn_forms) {
    std::string n = at(*f, 1).text;
    by_name[n] = f;
    for (const Node &it : f->items)
      if (head_of(it) == "static") is_static.insert(n);
  }
  for (const Node *f : fn_forms) {
    std::vector<std::string> acc;
    collect_calls(*f, acc);
    std::vector<std::string> cs;
    for (const std::string &c : acc)
      if (by_name.count(c) && c != at(*f, 1).text) cs.push_back(c);
    for (const std::string &c : cs) called.insert(c);
    callees[at(*f, 1).text] = cs;
  }
  std::vector<std::string> roots = kernels;
  if (roots.empty())
    for (const Node *f : fn_forms) {
      std::string n = at(*f, 1).text;
      if (!is_static.count(n) && !called.count(n)) roots.push_back(n);
    }
  for (const std::string &k : roots)
    if (!by_name.count(k)) throw BadIR("no function named " + k + " in the IR");
  std::set<std::string> live;
  std::vector<std::string> stack = roots;
  while (!stack.empty()) {
    std::string n = stack.back();
    stack.pop_back();
    if (!live.insert(n).second) continue;
    for (const std::string &c : callees[n]) stack.push_back(c);
  }
  for (const Node *f : fn_forms) {
    std::string n = at(*f, 1).text;
    if (!live.count(n)) continue;
    auto fn = std::make_unique<Fn>(m, *f);
    fn->kernel = std::find(roots.begin(), roots.end(), n) != roots.end();
    m.fns[n] = std::move(fn);
    m.order.push_back(n);
  }
  std::string body;
  for (const std::string &n : m.order) body += m.fns[n]->compile();
  out << "; generated by pathb-amdgpu-emit\n";
  out << "target datalayout = \"e-m:e-p:64:64-p1:64:64-p2:32:32-p3:32:32-p4:64:64-p5:32:32-p6:32:32-p7:160:256:256:32-"
         "p8:128:128:128:48-p9:192:256:256:32-i64:64-v16:16-v24:32-v32:32-v48:64-v96:128-v192:256-v256:256-v512:512-"
         "v1024:1024-v2048:2048-n32:64-S32-A5-G1-ni:7:8:9\"\n";
  out << "target triple = \"amdgcn-amd-amdhsa\"\n\n";
  for (const std::string &g : m.globals) out << g << "\n";
  if (m.uses_dynshared) out << "@__nfcxx_dynshared = external addrspace(3) global [0 x i8], align 16\n";
  if (m.uses_flag) out << "@__nfcxx_or_flag = internal addrspace(3) global i32 poison, align 4\n";
  out << "\n";
  m.declare("declare void @llvm.trap()");
  for (const std::string &d : m.decls) out << d << "\n";
  out << "\n" << body;
  out << "attributes #0 = { nounwind \"amdgpu-flat-work-group-size\"=\"1,1024\" \"uniform-work-group-size\"=\"false\" }\n";
  out << "attributes #1 = { nounwind }\n";
  out << "!0 = !{}\n";
  out << "!llvm.module.flags = !{!1}\n";
  out << "!1 = !{i32 1, !\"amdhsa_code_object_version\", i32 500}\n";
  return 0;
}

bool read_all(const std::string &path, std::string &out) {
  if (path == "-") {
    std::ostringstream ss;
    ss << std::cin.rdbuf();
    out = ss.str();
    return true;
  }
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  std::ostringstream ss;
  ss << f.rdbuf();
  out = ss.str();
  return true;
}

}  // namespace

int main(int argc, char **argv) {
  std::vector<std::string> kernels;
  std::string file = "-";
  bool f2i = false;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a.rfind("--kernel=", 0) == 0) kernels.push_back(a.substr(9));
    else if (a == "--f2i=convert") f2i = true;
    else if (a == "--emit") {
    } else if (!a.empty() && a[0] == '-' && a != "-") {
      std::fprintf(stderr, "pathb-amdgpu-emit: unknown option %s\n", a.c_str());
      return 2;
    } else {
      file = a;
    }
  }
  std::string src;
  if (!read_all(file, src)) {
    std::fprintf(stderr, "pathb-amdgpu-emit: cannot read %s\n", file.c_str());
    return 2;
  }
  std::ostringstream out;
  try {
    run(src, kernels, f2i, out);
  } catch (const Refused &e) {
    std::fprintf(stderr, "refused: %s\n", e.text.c_str());
    return 3;
  } catch (const BadIR &e) {
    std::fprintf(stderr, "bad IR: %s\n", e.text.c_str());
    return 1;
  }
  std::cout << out.str();
  return 0;
}
