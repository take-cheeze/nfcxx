// The emission state and the arithmetic, comparison and conversion lowering of scripts/pathb-ptx-emit.rb (class Fn's
// rval branches and their helpers). Each function is the Ruby one of the same name, with the same order of fresh
// registers and emitted lines, so the PTX text is the same.
#include "lower_arith.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <set>

namespace {

// Ruby's head_of: the head atom of a non-empty list, or nullptr.
const std::string *head(const Node &x) {
  if (x.kind != Node::List || x.items.empty() || x.items[0].kind != Node::Atom) return nullptr;
  return &x.items[0].text;
}

// x[i] of a list, or a static empty atom when out of range (the Ruby's nil, which the callers never reach).
const Node &at(const Node &x, size_t i) {
  static const Node none;
  if (x.kind != Node::List || i >= x.items.size()) return none;
  return x.items[i];
}

// The text of an atom (the Ruby's String), or "" for anything else.
std::string text_of(const Node &x) { return x.kind == Node::Atom ? x.text : std::string(); }

bool is_reg(const Node &x) { return x.kind == Node::Atom && !x.text.empty() && x.text[0] == '%'; }
}  // namespace

std::string ruby_float_s(double d) {
  // mruby's Float#to_s: printf's %.15g (15 significant digits, not the shortest round trip), with ".0" added to a
  // mantissa that has no point. The reference runs under mruby, so its text is what the bounds must match.
  if (std::isnan(d)) return "NaN";
  if (std::isinf(d)) return d < 0 ? "-Infinity" : "Infinity";
  char buf[64];
  std::snprintf(buf, sizeof buf, "%.15g", d);
  std::string s(buf);
  size_t e = s.find('e');
  std::string mant = s.substr(0, e);
  std::string ex = e == std::string::npos ? std::string() : s.substr(e);
  if (mant.find('.') == std::string::npos) mant += ".0";
  return mant + ex;
}

void FnCtx::emit(const std::string &s) { lines.push_back("  " + s); }

std::string FnCtx::fresh(const std::string &cls) {
  int n = count[cls];
  count[cls] = n + 1;
  return "%" + cls + std::to_string(n);
}

std::string FnCtx::new_label() {
  int n = nlab;
  nlab = n + 1;
  return "$L" + std::to_string(n);
}

Operand FnCtx::operand(const Node &x) {
  if (is_reg(x)) {
    auto it = regs.find(x.text);
    if (it == regs.end()) throw BadIR("register " + x.text + " is used before it is set");
    return {it->second.ptx, it->second.ty};
  }
  const std::string *h = head(x);
  if (h && *h == "const") {
    Ty ty = parse_type(&at(x, 1));
    if (ty.kind == "float") return {float_lit(text_of(at(x, 2)), ty), ty};
    if (ty.kind == "int" && ty.is_bool) {
      // a bool constant is a predicate: setp of two equal (true) or unequal (false) immediates
      std::string t = fresh("p");
      emit(bool_const_setp(t, text_of(at(x, 2))));
      return {t, ty};
    }
    return {imm(ty, as_int(&at(x, 2))), ty};
  }
  if (h && *h == "null") return {"0", parse_type(&at(x, 1))};
  if (x.kind == Node::Sym && x.sig == '$') {
    auto it = slots.find(x.text);
    if (it == slots.end()) throw BadIR("slot " + x.text + " is not declared");
    std::string t = fresh("rd");
    emit("add.u64 " + t + ", " + sp + ", " + std::to_string(it->second) + ";");
    if (g_local_trace) frame_origin[t] = (trace_scope.empty() ? "" : trace_scope + ":") + x.text;
    return {t, Ty{"ptr", -1, false, false}};
  }
  if (x.kind == Node::Sym && x.sig == '@') return module_operand(x);
  if (x.kind == Node::Sym && x.sig == '&' && functions && functions->count(x.text)) {
    // the address of a device function of this module (a function pointer value): the PTX name of the .func
    if (functions->at(x.text)) throw Refused("address of kernel " + x.text + " (a kernel is not a function pointer)");
    std::string t = fresh("rd");
    emit("mov.u64 " + t + ", " + x.text + ";");
    return {t, Ty{"ptr", -1, false, false}};
  }
  if (x.kind == Node::Sym) throw Refused("operand " + form_text(x));
  throw Refused("operand " + form_text(x));
}

Operand FnCtx::module_operand(const Node &x) {
  const std::string &name = x.text;
  auto in = [&](const std::set<std::string> ModuleSymbols::*set) { return mod && (mod->*set).count(name) > 0; };
  std::string t = fresh("rd");
  if (in(&ModuleSymbols::shared)) {
    emit("cvta.shared.u64 " + t + ", " + ptx_sym(name) + ";");
  } else if (in(&ModuleSymbols::globals)) {
    emit("cvta.global.u64 " + t + ", " + ptx_sym(name) + ";");
  } else if (in(&ModuleSymbols::consts)) {
    // a constant with a value (see scalar_const_init): read-only memory, its address is generic through .const
    emit("cvta.const.u64 " + t + ", " + ptx_sym(mod->data_name(name)) + ";");
  } else if (in(&ModuleSymbols::externs)) {
    throw Refused("global " + name + " is extern (no definition in this unit)");
  } else if (in(&ModuleSymbols::strings)) {
    emit("cvta.const.u64 " + t + ", " + string_const_sym(mod->data_name(name)) + ";");
  } else {
    throw Refused("static object @\"" + name + "\" (only block-shared and device globals are lowered)");
  }
  return {t, Ty{"ptr", -1, false, false}};
}

std::string FnCtx::reg_of(const std::string &op, const Ty &ty) {
  if (!op.empty() && op[0] == '%') return op;
  std::string t = fresh(reg_class(ty));
  emit("mov." + ptx_type(ty) + " " + t + ", " + op + ";");
  return t;
}

std::string FnCtx::ir_reg(const std::string &name, const Ty &ty) {
  auto it = regs.find(name);
  if (it != regs.end()) return it->second.ptx;
  std::string t = fresh(reg_class(ty));
  regs[name] = RegInfo{t, ty};
  return t;
}

void FnCtx::expect(const Ty &dty, const Ty &ty) {
  if (reg_class(dty) != reg_class(ty))
    throw BadIR("value of type " + ty.kind + " (" + std::to_string(type_size(ty)) + " bytes) stored in a " + dty.kind +
                " (" + std::to_string(type_size(dty)) + " bytes)");
}

static bool int_ok(const Ty &t) { return t.kind == "int" && !t.is_bool && (t.size == 1 || t.size == 2 || t.size == 4 || t.size == 8); }

void FnCtx::checked_div(const std::string &op, const std::string &dest, const Ty &ty, const Node &xa, const Node &xb) {
  if (!(ty.kind == "int" && !ty.is_bool && (ty.size == 1 || ty.size == 2 || ty.size == 4 || ty.size == 8)))
    throw Refused(op + " on " + ty.kind);
  std::string t = ptx_type(ty);
  Operand a = operand(xa);
  Operand b = operand(xb);
  std::string ra = reg_of(a.text, ty);
  std::string min = imm(ty, -(static_cast<i128>(1) << (ty.size * 8 - 1)));
  if (g_int_gpu) {
    // the divisor in a register: ptxas folds a division by the immediate 0
    std::string rb = b.text;
    if (rb.empty() || rb[0] != '%') {
      rb = fresh(reg_class(ty));
      emit("mov." + ptx_type(ty) + " " + rb + ", " + b.text + ";");
    }
    emit((op == "cdiv" ? std::string("div") : std::string("rem")) + "." + t + " " + dest + ", " + ra + ", " + rb + ";");
    return;
  }
  if (b.text == "0") {
    emit("trap;");
  } else if (!b.text.empty() && b.text[0] == '%') {
    std::string p = fresh("p");
    emit("setp.eq." + t + " " + p + ", " + b.text + ", 0;");
    emit("@" + p + " trap;");
    if (ty.is_signed) {
      std::string m = fresh("p");
      std::string q = fresh("p");
      emit("setp.eq." + t + " " + m + ", " + b.text + ", -1;");
      emit("setp.eq." + t + " " + q + ", " + ra + ", " + min + ";");
      emit("and.pred " + m + ", " + m + ", " + q + ";");
      emit("@" + m + " trap;");
    }
  } else if (ty.is_signed && b.text == "-1") {
    std::string q = fresh("p");
    emit("setp.eq." + t + " " + q + ", " + ra + ", " + min + ";");
    emit("@" + q + " trap;");
  }
  emit((op == "cdiv" ? std::string("div") : std::string("rem")) + "." + t + " " + dest + ", " + ra + ", " + b.text + ";");
}

void FnCtx::checked_shift(const std::string &op, const std::string &dest, const Ty &ty, const Node &xa, const Node &xb) {
  if (!int_ok(ty)) throw Refused(op + " on " + ty.kind);
  int bits = ty.size * 8;
  Operand a = operand(xa);
  std::string ra = reg_of(a.text, ty);
  Operand c = operand(xb);
  if (!(c.ty.kind == "int" && !c.ty.is_bool && (c.ty.size == 4 || c.ty.size == 8)))
    throw Refused("shift count of type " + c.ty.kind);
  std::string cnt = c.text;
  if (g_int_gpu) {
    // shl/shr clamp the count to the width (a 64-bit count is truncated to 32 bits, as nvcc converts it)
    if (!c.text.empty() && c.text[0] == '%') {
      if (reg_class(c.ty) == "rd") {
        cnt = fresh("r");
        emit("cvt.u32.u64 " + cnt + ", " + c.text + ";");
      }
    } else {
      cnt = fresh("r");
      emit("mov.u32 " + cnt + ", " + c.text + ";");
    }
  } else if (!c.text.empty() && c.text[0] == '%') {
    std::string p = fresh("p");
    if (reg_class(c.ty) == "rd") {
      emit("setp.hs.u64 " + p + ", " + c.text + ", " + std::to_string(bits) + ";");
      emit("@" + p + " trap;");
      cnt = fresh("r");
      emit("cvt.u32.u64 " + cnt + ", " + c.text + ";");
    } else {
      emit("setp.hs.u32 " + p + ", " + c.text + ", " + std::to_string(bits) + ";");
      emit("@" + p + " trap;");
    }
  } else {
    long long v = std::strtoll(c.text.c_str(), nullptr, 10);  // Ruby's to_i: 0 for text without digits
    if (v < 0 || v >= bits) emit("trap;");
  }
  if (op == "cshl") {
    emit("shl." + bits_type(ty) + " " + dest + ", " + ra + ", " + cnt + ";");
  } else {
    emit("shr." + ptx_type(ty) + " " + dest + ", " + ra + ", " + cnt + ";");
  }
}

void FnCtx::compare(const std::string &op, const std::string &dest, const Ty &ty, const Node &xa, const Node &xb) {
  Operand a = operand(xa);
  Operand b = operand(xb);
  if (ty.kind == "int" && ty.is_bool) {
    if (!(op == "eq" || op == "ne")) throw Refused("bool comparison " + op);
    if (op == "ne") {
      emit("xor.pred " + dest + ", " + a.text + ", " + b.text + ";");
    } else {
      std::string t = fresh("p");
      emit("xor.pred " + t + ", " + a.text + ", " + b.text + ";");
      emit("not.pred " + dest + ", " + t + ";");
    }
    return;
  }
  std::string cmp = op;
  if (ty.kind == "float" && op == "ne") cmp = "neu";
  std::string ra = reg_of(a.text, a.ty);
  emit("setp." + cmp + "." + ptx_type(ty) + " " + dest + ", " + ra + ", " + b.text + ";");
}

void FnCtx::int_convert(const std::string &dest, const Ty &ty, const std::string &a, const Ty &aty) {
  if (!(ty.kind == "int" && !ty.is_bool && (ty.size == 1 || ty.size == 2 || ty.size == 4 || ty.size == 8)))
    throw Refused("iconv to " + ty.kind);
  if (aty.kind != "int") throw BadIR("iconv of a " + aty.kind);
  if (aty.is_bool) {
    std::string b = fresh("r");
    emit("selp.u32 " + b + ", 1, 0, " + a + ";");
    if (type_size(ty) == 4) {
      emit("mov.b32 " + dest + ", " + b + ";");
    } else {
      emit("cvt." + ptx_type(ty) + ".u32 " + dest + ", " + b + ";");
    }
    return;
  }
  if (type_size(ty) == type_size(aty) || (type_size(ty) < 4 && type_size(aty) == 4)) {
    emit("mov." + ptx_type(ty) + " " + dest + ", " + a + ";");
  } else if (type_size(ty) < 4) {
    emit("cvt.u32." + ptx_type(aty) + " " + dest + ", " + reg_of(a, aty) + ";");
  } else {
    emit("cvt." + ptx_type(ty) + "." + ptx_type(aty) + " " + dest + ", " + reg_of(a, aty) + ";");
  }
}

bool g_f2i_convert = false;
bool g_int_gpu = false;
bool g_inline_device = true;
bool g_promote_slots = true;
bool g_unroll_loops = true;
bool g_local_trace = std::getenv("LOCAL_TRACE") != nullptr;
bool g_struct_slots = true;

void FnCtx::float_to_int(const std::string &dest, const Ty &ty, const std::string &a0, const Ty &aty) {
  if (!(ty.kind == "int" && !ty.is_bool && (ty.size == 1 || ty.size == 2 || ty.size == 4 || ty.size == 8)))
    throw Refused("cf2i to " + ty.kind + " of " + std::to_string(ty.size) + " bytes");
  if (aty.kind != "float") throw BadIR("cf2i of a " + aty.kind);
  int bits = ty.size * 8;
  int fsz = aty.size;
  std::string ft = ptx_type(aty);
  std::string a = reg_of(a0, aty);
  if (g_f2i_convert) {
    if (bits >= 32) {
      emit("cvt.rzi." + ptx_type(ty) + "." + ft + " " + dest + ", " + a + ";");
    } else {
      emit(std::string("cvt.rzi.") + (ty.is_signed ? "s32." : "u32.") + ft + " " + dest + ", " + a + ";");
      canon(dest, ty);
    }
    return;
  }
  i128 lo, hi;
  std::string lo_op;
  double lo_v;
  if (ty.is_signed) {
    lo = -(static_cast<i128>(1) << (bits - 1));
    hi = static_cast<i128>(1) << (bits - 1);
    bool exact_below = (fsz == 8 && bits <= 53) || (fsz == 4 && bits <= 24);
    if (exact_below) {
      lo_op = "gt";
      lo_v = static_cast<double>(lo - 1);
    } else {
      lo_op = "ge";
      lo_v = static_cast<double>(lo);
    }
  } else {
    lo_op = "gt";
    lo_v = -1.0;
    hi = static_cast<i128>(1) << bits;
  }
  std::string p1 = fresh("p");
  std::string p2 = fresh("p");
  emit("setp." + lo_op + "." + ft + " " + p1 + ", " + a + ", " + ruby_float_s(lo_v) + ";");
  emit("setp.lt." + ft + " " + p2 + ", " + a + ", " + ruby_float_s(static_cast<double>(hi)) + ";");
  emit("and.pred " + p1 + ", " + p1 + ", " + p2 + ";");
  emit("@!" + p1 + " trap;");
  emit("cvt.rzi." + ptx_type(ty) + "." + ft + " " + dest + ", " + a + ";");
  canon(dest, ty);
}

void FnCtx::canon(const std::string &dest, const Ty &t) {
  if (!(t.kind == "int" && (t.size == 1 || t.size == 2) && !t.is_bool)) return;
  int bits = t.size * 8;
  if (t.is_signed) {
    std::string tmp = fresh("r");
    emit("shl.b32 " + tmp + ", " + dest + ", " + std::to_string(32 - bits) + ";");
    emit("shr.s32 " + dest + ", " + tmp + ", " + std::to_string(32 - bits) + ";");
  } else {
    emit("and.b32 " + dest + ", " + dest + ", " + std::to_string((1 << bits) - 1) + ";");
  }
}

bool FnCtx::arith(const std::string &h, const Node &x, const std::string &dest, const Ty &dty) {
  if (h == "wadd" || h == "wsub" || h == "wmul") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    Operand a = operand(at(x, 2));
    Operand b = operand(at(x, 3));
    std::string op = h == "wadd" ? "add" : (h == "wsub" ? "sub" : "mul.lo");
    std::string ra = reg_of(a.text, ty);
    emit(op + "." + ptx_type(ty) + " " + dest + ", " + ra + ", " + b.text + ";");
    return true;
  }
  if (h == "wneg") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    if (ty.kind == "int" && ty.is_bool) throw Refused("negation of bool");
    Operand a = operand(at(x, 2));
    std::string ra = reg_of(a.text, ty);
    emit("neg.s" + std::to_string(type_size(ty) * 8) + " " + dest + ", " + ra + ";");
    return true;
  }
  if (h == "cdiv" || h == "crem") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    checked_div(h, dest, ty, at(x, 2), at(x, 3));
    return true;
  }
  if (h == "cshl" || h == "cshr") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    checked_shift(h, dest, ty, at(x, 2), at(x, 3));
    return true;
  }
  if (h == "and" || h == "or" || h == "xor") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    Operand a = operand(at(x, 2));
    Operand b = operand(at(x, 3));
    std::string ra = reg_of(a.text, ty);
    if (ty.kind == "int" && ty.is_bool) {
      emit(h + ".pred " + dest + ", " + ra + ", " + b.text + ";");
    } else {
      emit(h + "." + bits_type(ty) + " " + dest + ", " + ra + ", " + b.text + ";");
    }
    return true;
  }
  if (h == "not") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    Operand a = operand(at(x, 2));
    if (ty.kind == "int" && ty.is_bool) {
      emit("not.pred " + dest + ", " + reg_of(a.text, ty) + ";");
    } else {
      emit("not." + bits_type(ty) + " " + dest + ", " + reg_of(a.text, ty) + ";");
    }
    return true;
  }
  if (h == "fadd" || h == "fsub" || h == "fmul" || h == "fdiv") {
    Ty ty = parse_type(&at(x, 1));
    if (ty.kind != "float") throw Refused(h + " on " + ty.kind);
    expect(dty, ty);
    Operand a = operand(at(x, 2));
    Operand b = operand(at(x, 3));
    std::string op = h == "fadd" ? "add" : (h == "fsub" ? "sub" : (h == "fmul" ? "mul" : "div"));
    std::string ra = reg_of(a.text, ty);
    emit(op + ".rn." + ptx_type(ty) + " " + dest + ", " + ra + ", " + b.text + ";");
    return true;
  }
  if (h == "fneg") {
    Ty ty = parse_type(&at(x, 1));
    if (ty.kind != "float") throw Refused("fneg on " + ty.kind);
    expect(dty, ty);
    Operand a = operand(at(x, 2));
    emit("neg." + ptx_type(ty) + " " + dest + ", " + reg_of(a.text, ty) + ";");
    return true;
  }
  if (h == "iconv") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    Operand a = operand(at(x, 2));
    int_convert(dest, ty, a.text, a.ty);
    return true;
  }
  if (h == "p2i") {
    // a pointer as an integer: its 8-byte generic address, kept or truncated like an unsigned 8-byte integer
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    Operand a = operand(at(x, 2));
    if (a.ty.kind != "ptr") throw BadIR("p2i of a " + a.ty.kind);
    int_convert(dest, ty, a.text, Ty{"int", 8, false, false});
    return true;
  }
  if (h == "fconv") {
    Ty ty = parse_type(&at(x, 1));
    if (ty.kind != "float") throw Refused("fconv to " + ty.kind);
    expect(dty, ty);
    Operand a = operand(at(x, 2));
    if (a.ty.kind != "float") throw BadIR("fconv of a " + a.ty.kind);
    if (type_size(ty) == type_size(a.ty)) {
      emit("mov." + ptx_type(ty) + " " + dest + ", " + a.text + ";");
    } else {
      // widening is exact; narrowing rounds to nearest even
      std::string rnd = type_size(ty) < type_size(a.ty) ? ".rn" : "";
      std::string ra = reg_of(a.text, a.ty);
      emit("cvt" + rnd + "." + ptx_type(ty) + "." + ptx_type(a.ty) + " " + dest + ", " + ra + ";");
    }
    return true;
  }
  if (h == "i2f" || h == "u2f") {
    Ty ty = parse_type(&at(x, 1));
    if (ty.kind != "float") throw Refused(h + " to " + ty.kind);
    expect(dty, ty);
    Operand a = operand(at(x, 2));
    if (a.ty.kind == "int" && a.ty.is_bool) {
      // a bool is 0 or 1: the predicate selects 1.0 or 0.0 (the float immediates of the destination's width)
      std::string one = ty.size == 8 ? "0d3FF0000000000000" : "1.0";
      std::string zero = ty.size == 8 ? "0d0000000000000000" : "0.0";
      emit("selp." + ptx_type(ty) + " " + dest + ", " + one + ", " + zero + ", " + reg_of(a.text, a.ty) + ";");
    } else {
      emit("cvt.rn." + ptx_type(ty) + "." + ptx_type(a.ty) + " " + dest + ", " + reg_of(a.text, a.ty) + ";");
    }
    return true;
  }
  if (h == "cf2i") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    Operand a = operand(at(x, 2));
    float_to_int(dest, ty, a.text, a.ty);
    return true;
  }
  if (h == "lt" || h == "le" || h == "gt" || h == "ge" || h == "eq" || h == "ne" || h == "lt.s" || h == "le.s" ||
      h == "gt.s" || h == "ge.s" || h == "eq.s" || h == "ne.s" || h == "lt.u" || h == "le.u" || h == "gt.u" ||
      h == "ge.u" || h == "eq.u" || h == "ne.u" || h == "lt.f" || h == "le.f" || h == "gt.f" || h == "ge.f" ||
      h == "eq.f" || h == "ne.f") {
    Ty ty = parse_type(&at(x, 1));
    if (dty.kind != "int" || !dty.is_bool) throw BadIR("comparison result is not bool");
    compare(h.substr(0, h.find('.')), dest, ty, at(x, 2), at(x, 3));
    return true;
  }
  return false;
}
