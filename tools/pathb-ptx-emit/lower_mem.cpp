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

bool FnCtx::memory(const std::string &h, const Node &x, const std::string &dest, const Ty &dty) {
  const Ty ptr{"ptr", -1, false, false};
  if (h == "load") {
    Ty ty = parse_type(&at(x, 1));
    expect(dty, ty);
    Operand addr = operand(at(x, 2));
    if (ty.kind == "int" && ty.is_bool) {
      std::string b = fresh("r");
      emit("ld.u8 " + b + ", [" + reg_of(addr.text, addr.ty) + "];");
      emit("setp.ne.u32 " + dest + ", " + b + ", 0;");
    } else {
      emit("ld." + mem_type(ty) + " " + dest + ", [" + reg_of(addr.text, addr.ty) + "];");
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
    emit("add.s64 " + dest + ", " + reg_of(base.text, base.ty) + ", " + i128_text(n) + ";");
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
    return true;
  }
  return false;
}

bool FnCtx::store_stmt(const std::string &h, const Node &s) {
  if (h == "store") {
    Ty ty = parse_type(&at(s, 1));
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
