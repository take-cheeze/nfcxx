// The memory lowering of scripts/pathb-ptx-emit.rb (class Fn's rval branches load, load.v, bitcast, offset and index,
// and the stmt branches store and store.v). Each function is the Ruby's branch, with the same order of fresh registers
// and emitted lines, so the PTX text is the same.
#include "lower_arith.hpp"

namespace {

// x[i] of a list, or a static empty atom when out of range (the Ruby's nil, which the callers never reach).
const Node &at(const Node &x, size_t i) {
  static const Node none;
  if (x.kind != Node::List || i >= x.items.size()) return none;
  return x.items[i];
}

}  // namespace

const RegInfo *FnCtx::promoted_slot(const Node &addr) const {
  if (!(addr.kind == Node::Sym && addr.sig == '$')) return nullptr;
  auto it = promoted.find(addr.text);
  return it == promoted.end() ? nullptr : &it->second;
}

// The move that copies a value of type ty between two registers. A narrow integer's register holds its canonical 32-bit
// value, so it moves as 32 bits.
static std::string field_mov(const Ty &ty) { return reg_class(ty) == "r" ? "mov.u32" : "mov." + ptx_type(ty); }

std::string FnCtx::token_value(const Node &x) const {
  if (x.kind == Node::Sym && x.sig == '$')
    return sra_slots.count(x.text) ? "@" + std::to_string(sra_scope) + ":" + x.text + "+0" : "";
  if (x.kind == Node::Atom) {
    auto it = regs.find(x.text);
    if (it != regs.end() && !it->second.ptx.empty() && it->second.ptx[0] == '@') return it->second.ptx;
  }
  return "";
}

std::string FnCtx::token_rhs(const Node &v) const {
  if (v.kind != Node::List || v.items.empty() || v.items[0].kind != Node::Atom) return "";
  const std::string &h = v.items[0].text;
  if (h == "bitcast" && v.items.size() == 3) return token_value(v.items[2]);
  if (h == "offset" && v.items.size() == 3) {
    std::string base = token_value(v.items[1]);
    if (base.empty()) return "";
    size_t plus = base.rfind('+');
    long long off = std::stoll(base.substr(plus + 1)) + static_cast<long long>(as_int(&v.items[2]));
    return base.substr(0, plus + 1) + std::to_string(off);
  }
  if (h == "index" && v.items.size() == 4) {
    // an element of an object at a constant index (the index is a counter of an unrolled copy)
    std::string base = token_value(v.items[1]);
    if (base.empty() || v.items[2].kind != Node::Atom || !regs.count(v.items[2].text)) return "";
    auto c = const_regs.find(regs.at(v.items[2].text).ptx);
    if (c == const_regs.end()) return "";
    size_t plus = base.rfind('+');
    long long off = std::stoll(base.substr(plus + 1)) + c->second * static_cast<long long>(as_int(&v.items[3]));
    return base.substr(0, plus + 1) + std::to_string(off);
  }
  if (h == "load" && v.items.size() == 3 && v.items[2].kind == Node::Sym && v.items[2].sig == '$' &&
      carrier_slots.count(v.items[2].text)) {
    auto it = carrier_val.find(v.items[2].text);
    if (it == carrier_val.end()) throw BadIR("pointer slot " + v.items[2].text + " is loaded before it is stored");
    return it->second;
  }
  return "";
}

const RegInfo *FnCtx::sra_field(const Node &addr, const Ty &ty) const {
  std::string t = token_value(addr);
  if (t.empty()) return nullptr;
  size_t plus = t.rfind('+');
  std::string key = t.substr(0, plus) + "|" + t.substr(plus + 1) + "|" + ptx_type(ty);
  auto it = sra_fields.find(key);
  if (it == sra_fields.end()) throw BadIR("access through " + t + " has no field register (" + ptx_type(ty) + ")");
  return &it->second;
}

bool FnCtx::memory(const std::string &h, const Node &x, const std::string &dest, const Ty &dty) {
  const Ty ptr{"ptr", -1, false, false};
  if (h == "load") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    if (at(x, 2).kind == Node::Sym && at(x, 2).sig == '$' && const_slots.count(at(x, 2).text)) {
      emit("mov." + ptx_type(ty) + " " + dest + ", " + imm(ty, const_slots.at(at(x, 2).text)) + ";");
      const_regs[dest] = const_slots.at(at(x, 2).text);
      return true;
    }
    if (const RegInfo *f = sra_field(at(x, 2), ty)) {
      emit(field_mov(ty) + " " + dest + ", " + f->ptx + ";");
      return true;
    }
    if (const RegInfo *p = promoted_slot(at(x, 2))) {
      emit(field_mov(ty) + " " + dest + ", " + p->ptx + ";");
      return true;
    }
    Operand addr = operand(at(x, 2));
    if (g_local_trace && frame_origin.count(reg_of(addr.text, addr.ty))) emit("// frame " + frame_origin[reg_of(addr.text, addr.ty)] + " load");
    if (ty.kind == "int" && ty.is_bool) {
      std::string b = fresh("r");
      emit("ld.u8 " + b + ", [" + reg_of(addr.text, addr.ty) + "];");
      emit("setp.ne.u32 " + dest + ", " + b + ", 0;");
    } else {
      std::string areg = reg_of(addr.text, addr.ty);
      if (g_local_trace && frame_origin.count(areg)) emit("// frame " + frame_origin[areg] + " load");
      emit("ld." + mem_type(ty) + " " + dest + ", [" + areg + "];");
    }
    return true;
  }
  if (h == "load.v") {
    // (load.v TYPE PTR): a volatile load of a 4- or 8-byte integer or a float (the mirror of store.v)
    Ty ty = parse_type(&at(x, 1));
    if (!((ty.kind == "int" && !ty.is_bool && (ty.size == 4 || ty.size == 8)) || ty.kind == "float"))
      throw Refused("volatile load of " + ty.kind);
    expect(dty, ty);
    Operand addr = operand(at(x, 2));
    emit("ld.volatile." + mem_type(ty) + " " + dest + ", [" + reg_of(addr.text, addr.ty) + "];");
    return true;
  }
  if (h == "bitcast") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    if (!(ty.kind == "ptr" && dty.kind == "ptr")) throw Refused("bitcast to a non-pointer");
    Operand v = operand(at(x, 2));
    if (v.ty.kind != "ptr") throw Refused("bitcast of a non-pointer");
    emit("mov.u64 " + dest + ", " + reg_of(v.text, v.ty) + ";");
    return true;
  }
  if (h == "offset") {
    // (offset ADDR N): the address of a field, N bytes past ADDR (pathb-stage2 section 5)
    expect(dty, ptr);
    Operand base = operand(at(x, 1));
    i128 n = as_int(&at(x, 2));
    if (base.ty.kind != "ptr") throw Refused("offset of a non-pointer");
    std::string breg0 = reg_of(base.text, base.ty);
    emit("add.s64 " + dest + ", " + breg0 + ", " + i128_text(n) + ";");
    if (g_local_trace && frame_origin.count(breg0)) frame_origin[dest] = frame_origin[breg0];
    return true;
  }
  if (h == "index") {
    expect(dty, ptr);
    Operand base = operand(at(x, 1));
    std::string breg = reg_of(base.text, base.ty);
    Operand idx = operand(at(x, 2));
    std::string ireg = reg_of(idx.text, idx.ty);
    i128 size = as_int(&at(x, 3));
    std::string off = fresh("rd");
    if (reg_class(idx.ty) == "r") {
      emit("mul.wide.s32 " + off + ", " + ireg + ", " + i128_text(size) + ";");
    } else {
      emit("mul.lo.s64 " + off + ", " + ireg + ", " + i128_text(size) + ";");
    }
    emit("add.s64 " + dest + ", " + breg + ", " + off + ";");
    if (g_local_trace && frame_origin.count(breg)) frame_origin[dest] = frame_origin[breg];
    return true;
  }
  if (h == "pdiff") {
    // (pdiff A B SIZE): (A - B) / SIZE, the difference of two pointers in elements of SIZE bytes (a constant, as for
    // index); the result is the 8-byte pointer difference type
    if (!(dty.kind == "int" && type_size(dty) == 8)) throw Refused("pdiff of type " + dty.kind);
    Operand a = operand(at(x, 1)), b = operand(at(x, 2));
    if (a.ty.kind != "ptr" || b.ty.kind != "ptr") throw Refused("pdiff of a non-pointer");
    i128 size = as_int(&at(x, 3));
    if (size <= 0) throw Refused("pdiff with element size " + i128_text(size));
    if (size == 1) {
      emit("sub.s64 " + dest + ", " + reg_of(a.text, a.ty) + ", " + reg_of(b.text, b.ty) + ";");
    } else {
      std::string d = fresh("rd");
      emit("sub.s64 " + d + ", " + reg_of(a.text, a.ty) + ", " + reg_of(b.text, b.ty) + ";");
      emit("div.s64 " + dest + ", " + d + ", " + i128_text(size) + ";");
    }
    return true;
  }
  return false;
}

bool FnCtx::store_stmt(const std::string &h, const Node &s) {
  if (h == "store") {
    Ty ty = parse_type(&at(s, 1));
    if (at(s, 2).kind == Node::Sym && at(s, 2).sig == '$' && carrier_slots.count(at(s, 2).text)) {
      std::string v = token_value(at(s, 3));
      if (v.empty()) throw Refused("a pointer slot holds an address that is not an alias");
      carrier_val[at(s, 2).text] = v;
      return true;
    }
    if (const RegInfo *f = sra_field(at(s, 2), ty)) {
      Operand val = operand(at(s, 3));
      expect(ty, val.ty);
      emit(field_mov(ty) + " " + f->ptx + ", " + reg_of(val.text, ty) + ";");
      return true;
    }
    if (const RegInfo *p = promoted_slot(at(s, 2))) {
      Operand val = operand(at(s, 3));
      expect(ty, val.ty);
      emit(field_mov(ty) + " " + p->ptx + ", " + reg_of(val.text, ty) + ";");
      return true;
    }
    Operand addr = operand(at(s, 2));
    Operand val = operand(at(s, 3));
    if (ty.kind == "int" && ty.is_bool) {
      // a bool is one byte in memory, 0 or 1 (the IR's bool layout); the value is a predicate here
      expect(ty, val.ty);
      std::string b = fresh("r");
      emit("selp.u32 " + b + ", 1, 0, " + val.text + ";");
      emit("st.u8 [" + reg_of(addr.text, addr.ty) + "], " + b + ";");
    } else {
      std::string areg = reg_of(addr.text, addr.ty);
      if (g_local_trace && frame_origin.count(areg)) emit("// frame " + frame_origin[areg] + " store");
      emit("st." + mem_type(ty) + " [" + areg + "], " + reg_of(val.text, ty) + ";");
    }
    return true;
  }
  if (h == "store.v") {
    // (store.v TYPE PTR VALUE): a volatile store of a 4- or 8-byte integer or a float, through a generic pointer
    Ty ty = parse_type(&at(s, 1));
    if (!((ty.kind == "int" && !ty.is_bool && (ty.size == 4 || ty.size == 8)) || ty.kind == "float"))
      throw Refused("volatile store of " + ty.kind);
    Operand addr = operand(at(s, 2));
    Operand val = operand(at(s, 3));
    expect(ty, val.ty);
    std::string areg = reg_of(addr.text, addr.ty);
    emit("st.volatile." + mem_type(ty) + " [" + areg + "], " + reg_of(val.text, ty) + ";");
    return true;
  }
  return false;
}
