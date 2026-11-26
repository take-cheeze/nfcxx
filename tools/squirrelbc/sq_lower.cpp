// Squirrel 3.2 bytecode -> Path B IR (sq_lower.hpp; the producer rule is docs/notes/pathb-stage2.md section 1).
//
// Each prototype becomes one IR function `sq_fn_N(SQV *ret, SQV *base)`. A register R is `base + 16*R`; an SQV is
// { u32 tag (the Squirrel object type word: sqobject.h's OT_NULL, OT_INTEGER, OT_BOOL); i64 payload at offset 8 }.
// A null has payload 0 and a boolean 0 or 1, so Squirrel's IsFalse is "payload == 0" on every value of the subset.
//
// Every instruction starts at a label `pcN`, and the jumps are gotos to those labels. Integer fast paths are inline IR
// (wadd, lt.s and friends); everything else calls a helper of the runtime (tests/squirrelbc/runtime/sqbcrt.c) that
// performs the whole operation, raises the error text of sqvm.cpp, or refuses it. The helpers' operands are Squirrel's
// own opcode numbers, so the runtime reads the same tables as the VM.
//
// Subset: _OP_LINE, LOAD (integer, boolean and null literals), LOADINT, LOADBOOL, LOADNULLS, MOVE, DMOVE, DLOAD,
// ADD, SUB, MUL, DIV, MOD, NEG, NOT, CMP (>, >=, <, <=), EQ, NE, AND, OR, JMP, JZ, JCMP (the fused CMP and JZ that the
// compiler's peephole makes), RETURN. Anything else is refused by name.
#include "sq_lower.hpp"

#include <cstdint>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace squirrel {

namespace {

// sqopcodes.h values this producer lowers.
enum : std::uint8_t {
  kOpLine = 0x00,
  kOpLoad = 0x01,
  kOpLoadInt = 0x02,
  kOpDLoad = 0x04,
  kOpMove = 0x0A,
  kOpEq = 0x0F,
  kOpNe = 0x10,
  kOpAdd = 0x11,
  kOpSub = 0x12,
  kOpMul = 0x13,
  kOpDiv = 0x14,
  kOpMod = 0x15,
  kOpReturn = 0x17,
  kOpLoadNulls = 0x18,
  kOpLoadBool = 0x1A,
  kOpDMove = 0x1B,
  kOpJmp = 0x1C,
  kOpJCmp = 0x1D,
  kOpJz = 0x1E,
  kOpCmp = 0x28,
  kOpAnd = 0x2B,
  kOpOr = 0x2C,
  kOpNeg = 0x2D,
  kOpNot = 0x2E,
};

// The arithmetic helper's operand is the opcode number (sqvm.cpp's _ARITH_ and ARITH_OP read the same operator).
// CmpOP (sqopcodes.h): CMP_G, CMP_GE, CMP_L, CMP_LE. CMP_3W (5) is not lowered.
enum : int { kCmpG = 0, kCmpGE = 2, kCmpL = 3, kCmpLE = 4 };

constexpr std::uint8_t kNoValue = 0xFF;  // RETURN with arg0 0xFF has no value (sqcompiler.cpp)
constexpr int kSlotBytes = 16;

std::string num(std::int64_t v) { return std::to_string(v); }
std::string c_long(std::int64_t v) { return "(const long " + num(v) + ")"; }
std::string c_tag(std::uint32_t t) { return "(const unsigned_int " + std::to_string(t) + ")"; }

// The IR operands of one SQV in the frame: the object pointer, and the pointers to its tag and payload.
struct Addr {
  std::string obj, tag, pay;
};

// The tag and payload of an SQV, loaded into registers of the IR.
struct Val {
  std::string tag, pay;
};

// An immediate SQV, from a literal of the chunk.
struct Imm {
  std::uint32_t tag;
  std::int64_t v;
};

class Fn {
 public:
  Fn(const Proto &p, std::string name) : p_(p), name_(std::move(name)) {}

  std::string lower() {
    const std::vector<Instruction> &ins = p_.instructions;
    for (std::size_t pc = 0; pc < ins.size(); ++pc) {
      pc_ = pc;
      line("(label " + label(pc) + ")");
      step(ins[pc]);
    }
    std::ostringstream out;
    out << "(function \"" << name_ << "\" (ret void) (params (param %0 \"ret\" (ptr (struct \"SQV\")))"
        << " (param %1 \"base\" (ptr (struct \"SQV\"))))\n";
    out << body_.str() << ")\n";
    return out.str();
  }

 private:
  const Proto &p_;
  std::string name_;
  std::ostringstream body_;
  int next_ = 2;  // %0 is ret, %1 is base
  std::size_t pc_ = 0;

  void line(const std::string &s) { body_ << "  " << s << "\n"; }
  std::string fresh() { return "%" + std::to_string(next_++); }
  static std::string label(std::size_t pc) { return "\"pc" + std::to_string(pc) + "\""; }
  std::string goto_pc(std::int64_t target) const {
    if (target < 0 || static_cast<std::size_t>(target) >= p_.instructions.size())
      throw std::runtime_error("jump target outside the function (pc " + std::to_string(pc_) + ")");
    return "(goto \"pc" + std::to_string(target) + "\")";
  }

  [[noreturn]] void refuse(const std::string &what) const {
    throw Refused("refused: " + what + " (pc " + std::to_string(pc_) + ")");
  }

  std::string opname(std::uint8_t op) const { return op_name(op) ? op_name(op) : "unknown opcode"; }

  // The fields of the SQV at `obj` (an IR pointer to a 16-byte SQV).
  Addr fields(const std::string &obj) {
    Addr a;
    a.obj = obj;
    a.tag = fresh();
    line("(let " + a.tag + " (ptr unsigned_int) (offset " + obj + " 0))");
    a.pay = fresh();
    line("(let " + a.pay + " (ptr long) (offset " + obj + " 8))");
    return a;
  }

  Addr reg(std::int64_t r) {
    if (r < 0 || static_cast<std::size_t>(r) >= static_cast<std::size_t>(p_.stacksize))
      throw std::runtime_error("register " + num(r) + " is outside the frame (pc " + std::to_string(pc_) + ")");
    std::string o = fresh();
    line("(let " + o + " (ptr (struct \"SQV\")) (offset %1 " + num(r * kSlotBytes) + "))");
    return fields(o);
  }

  Addr ret() { return fields("%0"); }

  Val load(const Addr &a) {
    Val v;
    v.tag = fresh();
    line("(let " + v.tag + " unsigned_int (load unsigned_int " + a.tag + "))");
    v.pay = fresh();
    line("(let " + v.pay + " long (load long " + a.pay + "))");
    return v;
  }

  void store(const Addr &d, std::uint32_t tag, const std::string &payload) {
    line("(store unsigned_int " + d.tag + " " + c_tag(tag) + ")");
    line("(store long " + d.pay + " " + payload + ")");
  }

  void store_val(const Addr &d, const Val &v) {
    line("(store unsigned_int " + d.tag + " " + v.tag + ")");
    line("(store long " + d.pay + " " + v.pay + ")");
  }

  // A boolean result: `cond` is a bool operand.
  void store_bool(const Addr &d, const std::string &cond) {
    line("(if " + cond + " (then");
    store(d, kOtBool, c_long(1));
    line(") (else");
    store(d, kOtBool, c_long(0));
    line("))");
  }

  const Object &literal(std::int64_t k, const char *op) {
    if (k < 0 || static_cast<std::size_t>(k) >= p_.literals.size())
      throw std::runtime_error(std::string("literal index outside the chunk in ") + op + " (pc " +
                               std::to_string(pc_) + ")");
    return p_.literals[static_cast<std::size_t>(k)];
  }

  // The immediate of a literal the subset loads; a string or float literal is refused.
  Imm imm(std::int64_t k, std::uint8_t op) {
    const Object &o = literal(k, opname(op).c_str());
    switch (o.type) {
      case kOtInteger: return Imm{kOtInteger, o.integer};
      case kOtBool: return Imm{kOtBool, o.integer ? 1 : 0};
      case kOtNull: return Imm{kOtNull, 0};
      case kOtString: refuse(opname(op) + " of a string literal");
      case kOtFloat: refuse(opname(op) + " of a float literal");
      default: refuse(opname(op) + " of an unknown literal type");
    }
  }

  void load_literal(const Addr &d, std::int64_t k, std::uint8_t op) {
    Imm m = imm(k, op);
    store(d, m.tag, c_long(m.v));
  }

  // A bool register holding the value of `rvalue` (an IF takes an operand, not an rvalue).
  std::string test(const std::string &rvalue) {
    std::string t = fresh();
    line("(let " + t + " bool " + rvalue + ")");
    return t;
  }

  // flag := 1 when both values are integers.
  void int_guard(const Val &lv, const Val &rv, const std::string &flag) {
    std::string a = test("(eq unsigned_int " + lv.tag + " " + c_tag(kOtInteger) + ")");
    line("(if " + a + " (then");
    std::string b = test("(eq unsigned_int " + rv.tag + " " + c_tag(kOtInteger) + ")");
    line("(if " + b + " (then (set " + flag + " (const bool 1))))");
    line("))");
  }

  // ADD, SUB, MUL: both operands integers inline, else the helper.
  void arith(const Instruction &in, int opnum, const char *wop) {
    Addr d = reg(in.arg0);
    Addr r = reg(in.arg1);
    Addr l = reg(in.arg2);
    Val lv = load(l);
    Val rv = load(r);
    std::string fast = fresh();
    line("(let " + fast + " bool (const bool 0))");
    int_guard(lv, rv, fast);
    line("(if " + fast + " (then");
    std::string v = fresh();
    line("(let " + v + " long (" + wop + " long " + lv.pay + " " + rv.pay + "))");
    store(d, kOtInteger, v);
    line(") (else");
    line("(eval (call void &\"sqbc_rt_arith\" (const int " + num(opnum) + ") " + d.obj + " " + l.obj + " " + r.obj +
         "))");
    line("))");
  }

  // DIV, MOD: always the helper. A zero divisor raises in DIV and is silent in MOD (sqbc_rt_arith, sqvm.cpp).
  void arith_helper(const Instruction &in, int opnum) {
    Addr d = reg(in.arg0);
    Addr r = reg(in.arg1);
    Addr l = reg(in.arg2);
    line("(eval (call void &\"sqbc_rt_arith\" (const int " + num(opnum) + ") " + d.obj + " " + l.obj + " " + r.obj +
         "))");
  }

  // The bool operand of Squirrel's comparison `l OP r` (CmpOP of sqopcodes.h). Integers inline, else the helper, which
  // returns 0 or 1 or raises the error of ObjCmp / Raise_CompareError.
  std::string compare(const Addr &l, const Addr &r, int op) {
    Val lv = load(l);
    Val rv = load(r);
    std::string fast = fresh();
    line("(let " + fast + " bool (const bool 0))");
    int_guard(lv, rv, fast);
    std::string res = fresh();
    line("(let " + res + " bool (const bool 0))");
    line("(if " + fast + " (then");
    std::string c = fresh();
    switch (op) {
      case kCmpL: line("(let " + c + " bool (lt.s long " + lv.pay + " " + rv.pay + "))"); break;
      case kCmpLE: line("(let " + c + " bool (le.s long " + lv.pay + " " + rv.pay + "))"); break;
      case kCmpG: line("(let " + c + " bool (lt.s long " + rv.pay + " " + lv.pay + "))"); break;
      case kCmpGE: line("(let " + c + " bool (le.s long " + rv.pay + " " + lv.pay + "))"); break;
    }
    line("(set " + res + " " + c + ")");
    line(") (else");
    std::string r0 = fresh();
    line("(let " + r0 + " int (call int &\"sqbc_rt_compare\" (const int " + num(op) + ") " + l.obj + " " + r.obj + "))");
    std::string b = fresh();
    line("(let " + b + " bool (ne int " + r0 + " (const int 0)))");
    line("(set " + res + " " + b + ")");
    line("))");
    return res;
  }

  void step(const Instruction &in) {
    switch (in.op) {
      case kOpLine:
        break;
      case kOpLoadInt:
        store(reg(in.arg0), kOtInteger, c_long(in.arg1));
        break;
      case kOpLoad:
        load_literal(reg(in.arg0), in.arg1, in.op);
        break;
      case kOpDLoad:
        load_literal(reg(in.arg0), in.arg1, in.op);
        load_literal(reg(in.arg2), in.arg3, in.op);
        break;
      case kOpLoadBool:
        store(reg(in.arg0), kOtBool, c_long(in.arg1 != 0 ? 1 : 0));
        break;
      case kOpLoadNulls:
        for (std::int32_t n = 0; n < in.arg1; ++n) store(reg(in.arg0 + n), kOtNull, c_long(0));
        break;
      case kOpMove: {
        Addr d = reg(in.arg0);
        Addr s = reg(in.arg1);
        store_val(d, load(s));
        break;
      }
      case kOpDMove: {
        Addr d0 = reg(in.arg0);
        Addr s0 = reg(in.arg1);
        store_val(d0, load(s0));
        Addr d1 = reg(in.arg2);
        Addr s1 = reg(in.arg3);
        store_val(d1, load(s1));
        break;
      }
      case kOpAdd: arith(in, kOpAdd, "wadd"); break;
      case kOpSub: arith(in, kOpSub, "wsub"); break;
      case kOpMul: arith(in, kOpMul, "wmul"); break;
      case kOpDiv: arith_helper(in, kOpDiv); break;
      case kOpMod: arith_helper(in, kOpMod); break;
      case kOpNeg: {
        Addr d = reg(in.arg0);
        Addr s = reg(in.arg1);
        line("(eval (call void &\"sqbc_rt_neg\" " + d.obj + " " + s.obj + "))");
        break;
      }
      case kOpNot: {
        Addr d = reg(in.arg0);
        Addr s = reg(in.arg1);
        Val v = load(s);
        std::string z = fresh();
        line("(let " + z + " bool (eq long " + v.pay + " (const long 0)))");
        store_bool(d, z);
        break;
      }
      case kOpCmp: {
        if (in.arg3 != kCmpG && in.arg3 != kCmpGE && in.arg3 != kCmpL && in.arg3 != kCmpLE)
          refuse("_OP_CMP with operator " + num(in.arg3) + " (the three-way compare)");
        Addr d = reg(in.arg0);
        Addr r = reg(in.arg1);
        Addr l = reg(in.arg2);
        store_bool(d, compare(l, r, in.arg3));
        break;
      }
      case kOpEq:
      case kOpNe: {
        const bool is_ne = in.op == kOpNe;
        Addr d = reg(in.arg0);
        Addr l = reg(in.arg2);
        Val lv = load(l);
        std::string rtag, rpay;
        if (in.arg3 != 0) {
          Imm m = imm(in.arg1, in.op);
          rtag = c_tag(m.tag);
          rpay = c_long(m.v);
        } else {
          Addr r = reg(in.arg1);
          Val rv = load(r);
          rtag = rv.tag;
          rpay = rv.pay;
        }
        // IsEqual: the same type and the same raw value. Two different types are never equal here (no float).
        std::string res = fresh();
        line("(let " + res + " bool (const bool " + (is_ne ? "1" : "0") + "))");
        std::string same_tag = test("(eq unsigned_int " + lv.tag + " " + rtag + ")");
        line("(if " + same_tag + " (then");
        std::string same_pay = test("(eq long " + lv.pay + " " + rpay + ")");
        line("(if " + same_pay + " (then (set " + res + " (const bool " + (is_ne ? "0" : "1") + "))))");
        line("))");
        store_bool(d, res);
        break;
      }
      case kOpJmp:
        line(goto_pc(static_cast<std::int64_t>(pc_) + 1 + in.arg1));
        break;
      case kOpAnd:
      case kOpOr: {
        // AND (OR): when STK(arg2) is false (true), TARGET = STK(arg2) and jump; else fall through.
        Addr d = reg(in.arg0);
        Addr s = reg(in.arg2);
        Val v = load(s);
        std::string take = test(in.op == kOpAnd ? "(eq long " + v.pay + " (const long 0))"
                                                : "(ne long " + v.pay + " (const long 0))");
        line("(if " + take + " (then");
        store_val(d, v);
        line(goto_pc(static_cast<std::int64_t>(pc_) + 1 + in.arg1));
        line("))");
        break;
      }
      case kOpJz: {
        Addr s = reg(in.arg0);
        Val v = load(s);
        std::string z = fresh();
        line("(let " + z + " bool (eq long " + v.pay + " (const long 0)))");
        line("(if " + z + " (then " + goto_pc(static_cast<std::int64_t>(pc_) + 1 + in.arg1) + "))");
        break;
      }
      case kOpJCmp: {
        // JCMP: left = arg2, right = arg0, operator arg3; jump when the comparison is false (JZ of its result).
        if (in.arg3 != kCmpG && in.arg3 != kCmpGE && in.arg3 != kCmpL && in.arg3 != kCmpLE)
          refuse("_OP_JCMP with operator " + num(in.arg3) + " (the three-way compare)");
        Addr l = reg(in.arg2);
        Addr r = reg(in.arg0);
        std::string res = compare(l, r, in.arg3);
        line("(if " + res + " (then " + goto_pc(static_cast<std::int64_t>(pc_) + 1) + ") (else " +
             goto_pc(static_cast<std::int64_t>(pc_) + 1 + in.arg1) + "))");
        break;
      }
      case kOpReturn: {
        Addr d = ret();
        if (in.arg0 == kNoValue) {
          store(d, kOtNull, c_long(0));
        } else {
          Addr s = reg(in.arg1);
          store_val(d, load(s));
        }
        line("(return)");
        break;
      }
      default:
        refuse(opname(in.op) + " is not lowered yet");
    }
  }
};

void collect(const Proto &p, std::vector<const Proto *> &out) {
  out.push_back(&p);
  for (const Proto &child : p.functions) collect(child, out);
}

}  // namespace

std::string lower_module(const Chunk &chunk, const std::string &source_name) {
  std::vector<const Proto *> protos;
  collect(chunk.main, protos);
  std::ostringstream fns;
  for (std::size_t n = 0; n < protos.size(); ++n) {
    Fn f(*protos[n], "sq_fn_" + std::to_string(n));
    fns << "\n" << f.lower();
  }
  std::ostringstream out;
  out << "(ir-module \"" << source_name << "\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4)"
      << " (double 8) (long_double 16)))\n";
  out << "(producer \"squirrel-3.2\")\n";
  out << "(abi-type \"SQV\" 16 8 (memory))\n";
  out << fns.str();
  return out.str();
}

}  // namespace squirrel
