// Squirrel 3.2 bytecode -> Path B IR (sq_lower.hpp; the producer rule is docs/notes/pathb-stage2.md section 1).
//
// Each prototype becomes one IR function `sq_fn_N(SQV *ret, SQV *base)`; N is the prototype's index in pre-order (main is
// 0). A register R is `base + 16*R`; an SQV is { u32 tag (the Squirrel object type word: sqobject.h's OT_NULL, OT_INTEGER,
// OT_BOOL, OT_STRING, OT_TABLE, OT_CLOSURE, OT_NATIVECLOSURE); i64 payload at offset 8 }. A null has payload 0 and a
// boolean 0 or 1; an integer is its value; a string, table or closure is the address of its object. Squirrel's IsFalse is
// "payload == 0" on every value of the subset (a string or table payload is never 0, and IsFalse is never true for one).
//
// Every instruction starts at a label `pcN`, and the jumps are gotos to those labels. Integer fast paths are inline IR
// (wadd, lt.s and friends); everything else calls a helper of the runtime (tests/squirrelbc/runtime/sqbcrt.c) that
// performs the whole operation, raises the error text of the reference, or refuses it. The helpers take the operands as
// SQV pointers and Squirrel's own opcode numbers, so the runtime reads the same tables as the VM.
//
// A call is `sqbc_rt_call(callee, ret, frame, nargs)`: the callee's frame starts at the CALL's `this` register (arg2), so
// its parameters are the caller's registers above it, as in the reference (StartCall). A closure runs through
// `sq_dispatch(N, ret, frame)`, the IR function this module defines with one test per prototype.
//
// A closure runs with its own closure value (the third parameter of sq_fn_N). Its outer variables are SQOuter objects of the
// runtime: a local of the creating frame is bound to its stack value while that frame lives, and CLOSE or the return of the
// frame moves the value into the object (sqvm.cpp FindOuter, CloseOuters). GETOUTER and SETOUTER go through the running
// closure.
//
// Subset: LOAD (integer, boolean, null and string literals), LOADINT, LOADBOOL, LOADNULLS, MOVE, DMOVE, DLOAD, ADD, SUB, MUL,
// DIV, MOD, NEG, NOT, CMP (>, >=, <, <=), EQ, NE, AND, OR, JMP, JZ, JCMP, RETURN, GET, GETK, SET, NEWSLOT, NEWOBJ (a table),
// PREPCALL, PREPCALLK, CALL, CLOSURE, GETOUTER, SETOUTER, CLOSE. A nested prototype with default parameters or varargs is
// refused, and so is anything else by name.
#include "sq_lower.hpp"

#include <cstdint>
#include <cstdio>
#include <map>
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
  kOpCall = 0x06,
  kOpPrepCall = 0x07,
  kOpPrepCallK = 0x08,
  kOpGetK = 0x09,
  kOpMove = 0x0A,
  kOpNewSlot = 0x0B,
  kOpSet = 0x0D,
  kOpGet = 0x0E,
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
  kOpSetOuter = 0x1F,
  kOpGetOuter = 0x20,
  kOpNewObj = 0x21,
  kOpClose = 0x3C,
  kOpClosure = 0x30,
  kOpCmp = 0x28,
  kOpAnd = 0x2B,
  kOpOr = 0x2C,
  kOpNeg = 0x2D,
  kOpNot = 0x2E,
};

// The arithmetic helper's operand is the opcode number (sqvm.cpp's _ARITH_ and ARITH_OP read the same operator).
// CmpOP (sqopcodes.h): CMP_G, CMP_GE, CMP_L, CMP_LE. CMP_3W (5) is not lowered.
enum : int { kCmpG = 0, kCmpGE = 2, kCmpL = 3, kCmpLE = 4 };

constexpr std::uint8_t kNoValue = 0xFF;  // RETURN with arg0 0xFF has no value (sqcompiler.cpp); so has a CALL with no target
constexpr std::uint8_t kNoRegister = 0xFF;  // the bound register of a CLOSURE without an environment; so has a NEWSLOT
constexpr int kSlotBytes = 16;
constexpr int kNotTable = 0;  // NEWOBJ's arg3 (sqopcodes.h NOT_TABLE)
constexpr std::uint64_t kOtLocal = 0;  // SQOuterType: an outer variable of the enclosing frame (src is its register)
constexpr std::uint64_t kOtOuter = 1;  // an outer variable of the enclosing closure (src is its outer index)

std::string num(std::int64_t v) { return std::to_string(v); }
std::string c_long(std::int64_t v) { return "(const long " + num(v) + ")"; }
std::string c_int(std::int64_t v) { return "(const int " + num(v) + ")"; }
std::string c_tag(std::uint32_t t) { return "(const unsigned_int " + std::to_string(t) + ")"; }
const std::string kNullSqvPtr = "(null (ptr (struct \"SQV\")))";

// The IR operands of one SQV in the frame: the object pointer, and the pointers to its tag and payload.
struct Addr {
  std::string obj, tag, pay;
};

// The tag and payload of an SQV, loaded into registers of the IR.
struct Val {
  std::string tag, pay;
};

// An immediate SQV, from a literal of the chunk that is not a string.
struct Imm {
  std::uint32_t tag;
  std::int64_t v;
};

// What the whole module shares: the prototypes' indices (for CLOSURE and the dispatcher), and the string literals, one data
// item per distinct text.
class Module {
 public:
  explicit Module(const std::vector<const Proto *> &protos) {
    for (std::size_t n = 0; n < protos.size(); ++n) index[protos[n]] = static_cast<int>(n);
  }

  std::map<const Proto *, int> index;

  // The data item of a string literal's bytes; the name of the item.
  std::string str_name(const std::string &bytes) {
    auto it = names_.find(bytes);
    if (it != names_.end()) return it->second;
    std::string name = "sqs_" + std::to_string(names_.size());
    names_[bytes] = name;
    std::ostringstream esc;
    for (unsigned char c : bytes) {
      char buf[8];
      std::snprintf(buf, sizeof buf, "\\%03o", static_cast<unsigned>(c));
      esc << buf;
    }
    esc << "\\000";  // the NUL of a C string, so the runtime can use the text as is
    data_ << "(data \"" << name << "\" (array " << bytes.size() + 1 << " (const char)) (string \"" << esc.str() << "\"))\n";
    return name;
  }

  std::string data_text() const { return data_.str(); }

  // sq_dispatch(fn, ret, frame, clo): runs prototype `fn` (the index of the function sq_fn_fn) on the frame, for the closure.
  std::string dispatch_text(std::size_t count) const {
    std::ostringstream out;
    out << "(function \"sq_dispatch\" (ret void) (params (param %0 \"fn\" int) (param %1 \"ret\" (ptr (struct \"SQV\")))"
        << " (param %2 \"frame\" (ptr (struct \"SQV\"))) (param %3 \"clo\" (ptr (struct \"SQV\"))))\n";
    for (std::size_t k = 0; k < count; ++k) {
      std::string c = "%" + std::to_string(4 + k);
      out << "  (let " << c << " bool (eq int %0 (const int " << k << ")))\n";
      out << "  (if " << c << " (then (eval (call void &\"sq_fn_" << k << "\" %1 %2 %3))))\n";
    }
    out << "  (return))\n";
    return out.str();
  }

 private:
  std::map<std::string, std::string> names_;
  std::ostringstream data_;
};

class Fn {
 public:
  // `is_main`: the main prototype is always compiled with varparams (its `vargv` is never read by the driver), so only a
  // nested vararg function is refused: its arguments would be packed into an array.
  Fn(const Proto &p, std::string name, Module &mod, bool is_main)
      : p_(p), name_(std::move(name)), mod_(mod), next_(3) {
    if (p_.varparams != 0 && !is_main) throw Refused("refused: a vararg function (" + name_ + ")");
    if (!p_.defaultparams.empty()) throw Refused("refused: default parameters (" + name_ + ")");
  }

  std::string lower() {
    const std::vector<Instruction> &ins = p_.instructions;
    for (std::size_t pc = 0; pc < ins.size(); ++pc) {
      pc_ = pc;
      line("(label " + label(pc) + ")");
      step(ins[pc]);
    }
    std::ostringstream out;
    out << "(function \"" << name_ << "\" (ret void) (params (param %0 \"ret\" (ptr (struct \"SQV\")))"
        << " (param %1 \"base\" (ptr (struct \"SQV\"))) (param %2 \"clo\" (ptr (struct \"SQV\"))))\n";
    // The scratch values of the helpers: a literal key (kv) and the result of a Get (rv).
    out << "  (slot \"kv\" (struct \"SQV\") 16 8)\n";
    out << "  (slot \"rv\" (struct \"SQV\") 16 8)\n";
    out << body_.str() << ")\n";
    return out.str();
  }

 private:
  const Proto &p_;
  std::string name_;
  Module &mod_;
  std::ostringstream body_;
  int next_;  // %0 is ret, %1 is base, %2 is the running closure
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

  // One of the function's scratch values (see lower()).
  Addr slot(const char *name) {
    std::string o = fresh();
    line("(let " + o + " (ptr (struct \"SQV\")) (offset $\"" + name + "\" 0))");
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

  // The immediate of a literal that is an integer, a boolean or null (a string is in the object, see load_literal).
  Imm imm(std::int64_t k, std::uint8_t op) {
    const Object &o = literal(k, opname(op).c_str());
    switch (o.type) {
      case kOtInteger: return Imm{kOtInteger, o.integer};
      case kOtBool: return Imm{kOtBool, o.integer ? 1 : 0};
      case kOtNull: return Imm{kOtNull, 0};
      case kOtString: refuse(opname(op) + " of a string literal as an immediate");
      case kOtFloat: refuse(opname(op) + " of a float literal");
      default: refuse(opname(op) + " of an unknown literal type");
    }
  }

  // The literal K as the SQV at d: an integer, a boolean, null, or a string (sqbc_rt_loadstr interns it).
  void load_literal(const Addr &d, std::int64_t k, std::uint8_t op) {
    const Object &o = literal(k, opname(op).c_str());
    if (o.type == kOtString) {
      line("(eval (call void &\"sqbc_rt_loadstr\" " + d.obj + " @\"" + mod_.str_name(o.text) + "\" " +
           c_long(static_cast<std::int64_t>(o.text.size())) + "))");
      return;
    }
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

  // ADD, SUB, MUL: both operands integers inline, else the helper (which also concatenates strings for ADD).
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
    line("(eval (call void &\"sqbc_rt_arith\" " + c_int(opnum) + " " + d.obj + " " + l.obj + " " + r.obj + "))");
    line("))");
  }

  // DIV, MOD: always the helper. A zero divisor raises in DIV and is silent in MOD (sqbc_rt_arith, sqvm.cpp).
  void arith_helper(const Instruction &in, int opnum) {
    Addr d = reg(in.arg0);
    Addr r = reg(in.arg1);
    Addr l = reg(in.arg2);
    line("(eval (call void &\"sqbc_rt_arith\" " + c_int(opnum) + " " + d.obj + " " + l.obj + " " + r.obj + "))");
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
    line("(let " + r0 + " int (call int &\"sqbc_rt_compare\" " + c_int(op) + " " + l.obj + " " + r.obj + "))");
    std::string b = fresh();
    line("(let " + b + " bool (ne int " + r0 + " (const int 0)))");
    line("(set " + res + " " + b + ")");
    line("))");
    return res;
  }

  // The Get of sqvm.cpp (GET, GETK, PREPCALL, PREPCALLK): the value of self[key] goes to the rv scratch value. The
  // register `self` is 0 when the lookup may fall back to the root table (Get's selfidx == 0).
  Addr get_into_rv(const Addr &self, const std::string &key_obj, std::int64_t selfidx) {
    Addr rv = slot("rv");
    line("(eval (call void &\"sqbc_rt_get\" " + rv.obj + " " + self.obj + " " + key_obj + " " +
         c_int(selfidx == 0 ? 1 : 0) + "))");
    return rv;
  }

  // The key of a GETK or PREPCALLK: the literal in the kv scratch value.
  Addr literal_key(std::int64_t k, std::uint8_t op) {
    Addr kv = slot("kv");
    load_literal(kv, k, op);
    return kv;
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
          if (literal(in.arg1, opname(in.op).c_str()).type == kOtString) {
            // A string literal is interned, so its object is the one a equal string value holds.
            Addr kv = literal_key(in.arg1, in.op);
            Val kval = load(kv);
            rtag = kval.tag;
            rpay = kval.pay;
          } else {
            Imm m = imm(in.arg1, in.op);
            rtag = c_tag(m.tag);
            rpay = c_long(m.v);
          }
        } else {
          Addr r = reg(in.arg1);
          Val rv = load(r);
          rtag = rv.tag;
          rpay = rv.pay;
        }
        // IsEqual: the same type and the same raw value (a string or table is its object). Two different types are never
        // equal here (no float).
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
      case kOpGet: {
        // GET: TARGET = STK(arg1)[STK(arg2)], selfidx arg1.
        Addr self = reg(in.arg1);
        Addr key = reg(in.arg2);
        Addr rv = get_into_rv(self, key.obj, in.arg1);
        Addr d = reg(in.arg0);
        store_val(d, load(rv));
        break;
      }
      case kOpGetK: {
        // GETK: TARGET = STK(arg2)[KST(arg1)], selfidx arg2.
        Addr self = reg(in.arg2);
        Addr key = literal_key(in.arg1, in.op);
        Addr rv = get_into_rv(self, key.obj, in.arg2);
        Addr d = reg(in.arg0);
        store_val(d, load(rv));
        break;
      }
      case kOpPrepCall:
      case kOpPrepCallK: {
        // The callee is STK(arg0) = o[key] and the receiver STK(arg3) = o, with o = STK(arg2) (sqvm.cpp _OP_PREPCALL).
        const bool is_k = in.op == kOpPrepCallK;
        Addr self = reg(in.arg2);
        Addr key = is_k ? literal_key(in.arg1, in.op) : reg(in.arg1);
        Addr rv = get_into_rv(self, key.obj, in.arg2);
        Addr recv = reg(in.arg3);
        store_val(recv, load(self));
        Addr d = reg(in.arg0);
        store_val(d, load(rv));
        break;
      }
      case kOpSet: {
        // SET: STK(arg1)[STK(arg2)] = STK(arg3); TARGET = STK(arg3) when arg0 is a register.
        Addr self = reg(in.arg1);
        Addr key = reg(in.arg2);
        Addr val = reg(in.arg3);
        line("(eval (call void &\"sqbc_rt_set\" " + self.obj + " " + key.obj + " " + val.obj + " " +
             c_int(in.arg1 == 0 ? 1 : 0) + "))");
        if (in.arg0 != kNoRegister) {
          Addr d = reg(in.arg0);
          store_val(d, load(val));
        }
        break;
      }
      case kOpNewSlot: {
        // NEWSLOT: STK(arg1)[STK(arg2)] := STK(arg3); TARGET = STK(arg3) when arg0 is a register.
        Addr self = reg(in.arg1);
        Addr key = reg(in.arg2);
        Addr val = reg(in.arg3);
        line("(eval (call void &\"sqbc_rt_newslot\" " + self.obj + " " + key.obj + " " + val.obj + "))");
        if (in.arg0 != kNoRegister) {
          Addr d = reg(in.arg0);
          store_val(d, load(val));
        }
        break;
      }
      case kOpNewObj: {
        if (in.arg3 != kNotTable) refuse("_OP_NEWOBJ of an array or a class");
        Addr d = reg(in.arg0);
        line("(eval (call void &\"sqbc_rt_newtable\" " + d.obj + "))");
        break;
      }
      case kOpClosure: {
        // CLOSURE: a closure of prototype arg1 (its index in the module is the dispatch index); the environment is STK(arg2)
        // when arg2 is a register (CLOSURE_OP's boundtarget).
        if (in.arg1 < 0 || static_cast<std::size_t>(in.arg1) >= p_.functions.size())
          throw std::runtime_error("prototype index outside the function (pc " + std::to_string(pc_) + ")");
        const Proto &child = p_.functions[static_cast<std::size_t>(in.arg1)];
        auto it = mod_.index.find(&child);
        if (it == mod_.index.end()) throw std::runtime_error("prototype not in the module");
        std::string env = kNullSqvPtr;
        if (in.arg2 != kNoRegister) env = reg(in.arg2).obj;
        Addr d = reg(in.arg0);
        line("(eval (call void &\"sqbc_rt_closure\" " + d.obj + " " + c_int(it->second) + " " +
             c_int(static_cast<std::int64_t>(child.parameters.size())) + " " + c_int(child.stacksize) + " " + env + " " +
             c_int(static_cast<std::int64_t>(child.outers.size())) + "))");
        // Each outer variable is bound when the closure is made (FindOuter, or the running closure's own outer).
        for (std::size_t i = 0; i < child.outers.size(); ++i) {
          const OuterVar &ov = child.outers[i];
          if (ov.src.type != kOtInteger) throw std::runtime_error("outer variable source is not an integer");
          const std::int64_t src = ov.src.integer;
          if (ov.type == kOtLocal) {
            Addr slot = reg(src);
            line("(eval (call void &\"sqbc_rt_outer_local\" " + d.obj + " " + c_int(static_cast<std::int64_t>(i)) +
                 " " + slot.obj + "))");
          } else if (ov.type == kOtOuter) {
            line("(eval (call void &\"sqbc_rt_outer_outer\" " + d.obj + " " + c_int(static_cast<std::int64_t>(i)) +
                 " %2 " + c_int(src) + "))");
          } else {
            throw std::runtime_error("outer variable of an unknown type");
          }
        }
        break;
      }
      case kOpGetOuter: {
        // GETOUTER: TARGET = the value of outer variable arg1 of the running closure.
        Addr d = reg(in.arg0);
        line("(eval (call void &\"sqbc_rt_getouter\" " + d.obj + " %2 " + c_int(in.arg1) + "))");
        break;
      }
      case kOpSetOuter: {
        // SETOUTER: outer variable arg1 = STK(arg2); TARGET = STK(arg2) when arg0 is a register.
        Addr val = reg(in.arg2);
        line("(eval (call void &\"sqbc_rt_setouter\" %2 " + c_int(in.arg1) + " " + val.obj + "))");
        if (in.arg0 != kNoRegister) {
          Addr d = reg(in.arg0);
          store_val(d, load(val));
        }
        break;
      }
      case kOpClose: {
        // CLOSE: the outer variables of the registers from arg1 on are closed.
        Addr from = reg(in.arg1);
        line("(eval (call void &\"sqbc_rt_close\" " + from.obj + "))");
        break;
      }
      case kOpCall: {
        // CALL: the callee is STK(arg1), its frame starts at STK(arg2) (this, then the arguments), arg3 values in all; the
        // result goes to STK(arg0) when arg0 is a register.
        Addr clo = reg(in.arg1);
        Addr frame = reg(in.arg2);
        std::string res = kNullSqvPtr;
        if (in.arg0 != kNoValue) res = reg(in.arg0).obj;
        line("(eval (call void &\"sqbc_rt_call\" " + clo.obj + " " + res + " " + frame.obj + " " + c_int(in.arg3) +
             "))");
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
  Module mod(protos);
  std::ostringstream fns;
  for (std::size_t n = 0; n < protos.size(); ++n) {
    Fn f(*protos[n], "sq_fn_" + std::to_string(n), mod, n == 0);
    fns << "\n" << f.lower();
  }
  fns << "\n" << mod.dispatch_text(protos.size());
  std::ostringstream out;
  out << "(ir-module \"" << source_name << "\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4)"
      << " (double 8) (long_double 16)))\n";
  out << "(producer \"squirrel-3.2\")\n";
  out << "(abi-type \"SQV\" 16 8 (memory))\n";
  out << mod.data_text();
  out << fns.str();
  return out.str();
}

}  // namespace squirrel
