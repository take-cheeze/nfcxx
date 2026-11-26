// mruby 4.0 root irep -> Path B IR (docs/notes/mrbbc-pathb.md, section "The lowering").
//
// The main program becomes one IR function `mrb_irep_0(MV *ret)`. A register R(i) is a 16-byte slot `r<i>` of type
// MV: a tag byte at offset 0 and an int64 at offset 8 (the tags are the runtime's, tests/mrbbc/runtime/mrbrt.h). The
// value the program returns is written to *ret.
//
// Integer operators have an inline fast path: when both operands hold integers, the operation is one IR statement
// (checked add, subtract and multiply, which trap on overflow, and a signed compare). Everything else calls a runtime
// helper (mrbbc_binop for operators, mrbbc_getidx and friends for indexing, mrbbc_send0 for the methods of SEND0),
// which does the rest of mruby's rules. Strings and symbols are data items of the IR module; arrays are built by the
// runtime. The opcodes not handled here are refused by name, as the other producers refuse them.
#include "mrb_lower.hpp"

#include <cstdint>
#include <cstdio>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace mrbbc {

namespace {

// Tags and operator numbers of the runtime (tests/mrbbc/runtime/mrbrt.h; the string, array and symbol tags are 4, 5, 6).
constexpr int kTagNil = 0, kTagFalse = 1, kTagTrue = 2, kTagInt = 3;
constexpr int kOpAdd = 0, kOpSub = 1, kOpMul = 2, kOpDiv = 3, kOpLt = 4, kOpLe = 5, kOpGt = 6, kOpGe = 7, kOpEq = 8,
              kOpNeq = 9;
// The methods of SEND0 (enum mrbbc_method).
constexpr int kMToS = 0, kMSize = 1, kMLength = 2, kMNot = 3;

std::string num(long long v) { return std::to_string(v); }

// A label of an instruction, by its byte offset in the iseq.
std::string lbl(std::size_t pc) { return "\"pc" + std::to_string(pc) + "\""; }

// The state of one lowering: the fresh IR register numbers, the body, the MV slots beyond the registers, and the data
// items (string literals and symbol names).
struct Ctx {
  const mrb::Irep &irep;
  std::size_t pc = 0;   // the instruction being lowered
  int next = 1;         // %0 is the ret parameter; fresh registers count from 1
  std::ostringstream body;
  std::ostringstream data;                      // (data ...) items, written before the functions
  std::vector<std::string> slots;               // MV slots: immediates of the slow paths, temporaries
  std::map<std::string, std::string> symbols;   // symbol name -> the data item holding its name

  explicit Ctx(const mrb::Irep &i) : irep(i) {}

  std::string fresh() { return "%" + std::to_string(next++); }
  void line(const std::string &s) { body << "  " << s << "\n"; }

  // The address of R(i): the slot of a register, checked against the irep's register count.
  std::string reg(unsigned i) const {
    if (i >= irep.nregs) {
      throw std::runtime_error("malformed: register R(" + std::to_string(i) + ") at pc " + std::to_string(pc) +
                               " is past the irep's " + std::to_string(irep.nregs) + " registers");
    }
    return "$\"r" + std::to_string(i) + "\"";
  }
};

// The tag byte of an address, loaded into a fresh register.
std::string load_tag(Ctx &c, const std::string &addr) {
  std::string p = c.fresh(), t = c.fresh();
  c.line("(let " + p + " (ptr unsigned_char) (offset " + addr + " 0))");
  c.line("(let " + t + " unsigned_char (load unsigned_char " + p + "))");
  return t;
}

// A bool register: the tag register equals `tag`.
std::string tag_is(Ctx &c, const std::string &tag_reg, int tag) {
  std::string b = c.fresh();
  c.line("(let " + b + " bool (eq unsigned_char " + tag_reg + " (const unsigned_char " + num(tag) + ")))");
  return b;
}

// A bool register that is true when the value is falsy (nil or false: tags 0 and 1).
std::string falsy(Ctx &c, const std::string &addr) {
  std::string t = load_tag(c, addr), f = c.fresh();
  c.line("(let " + f + " bool (lt.u unsigned_char " + t + " (const unsigned_char 2)))");
  return f;
}

// A bool register that is true when the value is truthy (every other tag).
std::string truthy(Ctx &c, const std::string &addr) {
  std::string t = load_tag(c, addr), f = c.fresh();
  c.line("(let " + f + " bool (le.u unsigned_char (const unsigned_char 2) " + t + "))");
  return f;
}

void store_tag(Ctx &c, const std::string &dst, int tag) {
  std::string p = c.fresh();
  c.line("(let " + p + " (ptr unsigned_char) (offset " + dst + " 0))");
  c.line("(store unsigned_char " + p + " (const unsigned_char " + num(tag) + "))");
}

// The int64 of a value: its address plus 8, loaded.
std::string load_int(Ctx &c, const std::string &addr) {
  std::string p = c.fresh(), v = c.fresh();
  c.line("(let " + p + " (ptr long) (offset " + addr + " 8))");
  c.line("(let " + v + " long (load long " + p + "))");
  return v;
}

void store_int(Ctx &c, const std::string &dst, const std::string &value) {
  store_tag(c, dst, kTagInt);
  std::string p = c.fresh();
  c.line("(let " + p + " (ptr long) (offset " + dst + " 8))");
  c.line("(store long " + p + " " + value + ")");
}

// The slow path: the runtime does the whole operation.
void call_binop(Ctx &c, int op, const std::string &dst, const std::string &lhs, const std::string &rhs) {
  c.line("(eval (call void &\"mrbbc_binop\" (const int " + num(op) + ") " + dst + " " + lhs + " " + rhs + "))");
}

// The integer fast path of a binary operator on R[a] and an operand. `rhs_reg` is the address of the right operand
// (empty for an immediate). The fast path runs when every operand holds an integer.
void emit_int_op(Ctx &c, int op, const std::string &dst, const std::string &lhs, const std::string &rhs_reg,
                 long long imm) {
  const bool is_imm = rhs_reg.empty();
  std::string ok;
  if (is_imm) {
    ok = tag_is(c, load_tag(c, lhs), kTagInt);
  } else {
    std::string ta = load_tag(c, lhs), tb = load_tag(c, rhs_reg);
    std::string ba = tag_is(c, ta, kTagInt), bb = tag_is(c, tb, kTagInt);
    ok = c.fresh();
    c.line("(let " + ok + " bool (const bool 0))");
    c.line("(if " + ba + " (then (set " + ok + " " + bb + ")))");
  }
  std::string rhs_addr = rhs_reg;
  std::string imm_slot;
  if (is_imm) {
    imm_slot = "$\"imm" + std::to_string(c.pc) + "\"";
    c.slots.push_back("imm" + std::to_string(c.pc));
    rhs_addr = imm_slot;
  }

  // fast: x OP y on the integers; the result goes to dst (for comparisons, as a bool tag)
  c.line("(if " + ok + " (then");
  {
    std::string x = load_int(c, lhs);
    std::string y = is_imm ? "(const long " + num(imm) + ")" : load_int(c, rhs_addr);
    if (op == kOpAdd || op == kOpSub || op == kOpMul) {
      const char *cop = op == kOpAdd ? "cadd" : op == kOpSub ? "csub" : "cmul";
      std::string r = c.fresh();
      c.line("(let " + r + " long (" + cop + " long " + x + " " + y + "))");
      store_int(c, dst, r);
    } else {
      // comparisons: GT and GE swap the operands of LT and LE (the emitter has signed lt.s and le.s only)
      const bool swap = op == kOpGt || op == kOpGe;
      const char *cop = (op == kOpLt || op == kOpGt) ? "lt.s" : "le.s";
      std::string r = c.fresh();
      c.line("(let " + r + " bool (" + cop + " long " + (swap ? y : x) + " " + (swap ? x : y) + "))");
      c.line("(if " + r + " (then");
      store_tag(c, dst, kTagTrue);
      c.line(") (else");
      store_tag(c, dst, kTagFalse);
      c.line("))");
    }
  }
  c.line(") (else");
  if (is_imm) {
    // the slow path needs the immediate as a value: an integer slot
    std::string p = c.fresh();
    c.line("(let " + p + " (ptr unsigned_char) (offset " + imm_slot + " 0))");
    c.line("(store unsigned_char " + p + " (const unsigned_char " + num(kTagInt) + "))");
    std::string q = c.fresh();
    c.line("(let " + q + " (ptr long) (offset " + imm_slot + " 8))");
    c.line("(store long " + q + " (const long " + num(imm) + "))");
  }
  call_binop(c, op, dst, lhs, rhs_addr);
  c.line("))");
}

// R[a] = R[a] OP R[b]. + - * and the four comparisons have the integer fast path of emit_int_op; the others always call
// the runtime (EQ and NEQ are identity or content equality there, DIV floors and raises ZeroDivisionError).
void emit_binary(Ctx &c, int op, unsigned a, unsigned b) {
  std::string dst = c.reg(a), lhs = c.reg(a), rhs = c.reg(b);
  if (op == kOpDiv || op == kOpEq || op == kOpNeq) {
    call_binop(c, op, dst, lhs, rhs);
    return;
  }
  emit_int_op(c, op, dst, lhs, rhs, 0);
}

// R[a] = R[a] OP imm, with the immediate as the right operand.
void emit_immediate(Ctx &c, int op, unsigned a, long long imm) {
  std::string dst = c.reg(a), lhs = c.reg(a);
  emit_int_op(c, op, dst, lhs, "", imm);
}

// The target of a jump: the offset is relative to the end of the instruction, as the VM computes it.
std::size_t jump_target(const mrb::Insn &in, long long offset) {
  return in.pc + in.len + static_cast<std::size_t>(offset);
}

std::int16_t s16(std::uint32_t v) { return static_cast<std::int16_t>(static_cast<std::uint16_t>(v)); }

// The value of a bigint pool entry (codegen.c's new_litbint): the length byte, the base byte (negative for a negative
// number, so -10 is "-2147483648", which mruby writes for the INT32_MIN literal), then the digits in that base. Returns
// false when the value does not fit in 64 bits; the producer refuses those constants.
bool bigint_value(const mrb::Pool &k, std::int64_t &out) {
  if (k.s.size() < 2) return false;
  const std::size_t len = static_cast<unsigned char>(k.s[0]);
  const int signed_base = static_cast<signed char>(k.s[1]);
  const int radix = signed_base < 0 ? -signed_base : signed_base;
  if (radix < 2 || radix > 36 || k.s.size() != len + 2) return false;
  std::uint64_t mag = 0;
  for (std::size_t i = 2; i < k.s.size(); ++i) {
    const char ch = k.s[i];
    int d;
    if (ch >= '0' && ch <= '9') d = ch - '0';
    else if (ch >= 'a' && ch <= 'z') d = ch - 'a' + 10;
    else if (ch >= 'A' && ch <= 'Z') d = ch - 'A' + 10;
    else return false;
    if (d >= radix) return false;
    if (mag > (UINT64_MAX - static_cast<std::uint64_t>(d)) / static_cast<std::uint64_t>(radix)) return false;
    mag = mag * static_cast<std::uint64_t>(radix) + static_cast<std::uint64_t>(d);
  }
  if (signed_base < 0) {
    if (mag > static_cast<std::uint64_t>(INT64_MAX) + 1) return false;
    out = mag == static_cast<std::uint64_t>(INT64_MAX) + 1 ? INT64_MIN : -static_cast<std::int64_t>(mag);
  } else {
    if (mag > static_cast<std::uint64_t>(INT64_MAX)) return false;
    out = static_cast<std::int64_t>(mag);
  }
  return true;
}

// The bytes of a string in the IR text form the emitter reads: printable ASCII as it is, \" and \\, and any other byte
// as three octal digits (the emitter's read_string takes exactly those escapes).
std::string ir_bytes(const std::string &s) {
  std::string out;
  for (unsigned char ch : s) {
    if (ch == '"' || ch == '\\') {
      out += '\\';
      out += static_cast<char>(ch);
    } else if (ch >= 0x20 && ch < 0x7f) {
      out += static_cast<char>(ch);
    } else {
      char buf[8];
      std::snprintf(buf, sizeof buf, "\\%03o", static_cast<unsigned>(ch));
      out += buf;
    }
  }
  return out;
}

// A data item holding the bytes of s and a NUL: (data "NAME" (const (array N (const char))) (string "...")).
void add_data(Ctx &c, const std::string &name, const std::string &bytes) {
  c.data << "(data \"" << name << "\" (const (array " << bytes.size() + 1 << " (const char))) (string \"" << ir_bytes(bytes)
         << "\\000\"))\n";
}

// A symbol's name, as a static string shared by every use of the symbol in the module.
std::string symbol_data(Ctx &c, const std::string &name) {
  auto it = c.symbols.find(name);
  if (it != c.symbols.end()) return it->second;
  std::string item = "mrbbc_sym" + std::to_string(c.symbols.size());
  c.symbols[name] = item;
  add_data(c, item, name);
  return item;
}

// A symbol that prints as :NAME with no quotes: an identifier, optionally ending in ?, ! or =.
bool plain_symbol(const std::string &s) {
  auto alpha = [](char ch) { return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'; };
  auto digit = [](char ch) { return ch >= '0' && ch <= '9'; };
  if (s.empty() || !alpha(s[0])) return false;
  std::size_t i = 1;
  while (i < s.size() && (alpha(s[i]) || digit(s[i]))) ++i;
  if (i < s.size() && (s[i] == '?' || s[i] == '!' || s[i] == '=')) ++i;
  return i == s.size();
}

// The method of a SEND0 (no argument) the runtime implements, by its name (enum mrbbc_method); false for any other.
bool zero_arg_method(const std::string &name, int &code) {
  if (name == "to_s") code = kMToS;
  else if (name == "size") code = kMSize;
  else if (name == "length") code = kMLength;
  else if (name == "!") code = kMNot;
  else return false;
  return true;
}

// The operator of a SEND with one argument (`a.+(b)`, which is the same as the opcode ADD when a is an integer).
bool binary_method(const std::string &name, int &op) {
  if (name == "+") op = kOpAdd;
  else if (name == "-") op = kOpSub;
  else if (name == "*") op = kOpMul;
  else if (name == "/") op = kOpDiv;
  else if (name == "==") op = kOpEq;
  else if (name == "!=") op = kOpNeq;
  else if (name == "<") op = kOpLt;
  else if (name == "<=") op = kOpLe;
  else if (name == ">") op = kOpGt;
  else if (name == ">=") op = kOpGe;
  else return false;
  return true;
}

// R[a] = a new array of the n registers from src (ARRAY, ARRAY2). The array is built in a temporary, because the first
// element may be R[a] itself.
void lower_array(Ctx &c, unsigned dst, unsigned src, unsigned n) {
  const std::string tmp = "tmp" + std::to_string(c.pc);
  c.slots.push_back(tmp);
  c.line("(eval (call void &\"mrbbc_ary_new\" $\"" + tmp + "\" (const long " + num(n) + ")))");
  for (unsigned i = 0; i < n; ++i) {
    c.line("(eval (call void &\"mrbbc_ary_push\" $\"" + tmp + "\" " + c.reg(src + i) + "))");
  }
  c.line("(copy 16 " + c.reg(dst) + " $\"" + tmp + "\")");
}

const mrb::Pool &pool_at(const mrb::Irep &irep, std::uint32_t i, std::size_t pc) {
  if (i >= irep.pool.size()) {
    throw std::runtime_error("malformed: pool entry " + std::to_string(i) + " at pc " + std::to_string(pc) + " of " +
                             std::to_string(irep.pool.size()));
  }
  return irep.pool[i];
}

const std::string &sym_at(const mrb::Irep &irep, std::uint32_t i, std::size_t pc) {
  if (i >= irep.syms.size()) {
    throw std::runtime_error("malformed: symbol " + std::to_string(i) + " at pc " + std::to_string(pc) + " of " +
                             std::to_string(irep.syms.size()));
  }
  return irep.syms[i];
}

}  // namespace

std::string lower_module(const mrb::Module &module, const std::string &source_name) {
  const mrb::Irep &root = module.root;
  if (!root.catches.empty()) throw Refused("refused: the main program has a catch table");
  std::vector<mrb::Insn> insns = mrb::decode_iseq(root);

  std::set<std::size_t> starts;
  for (const mrb::Insn &in : insns) starts.insert(in.pc);
  std::set<std::size_t> ends;  // a jump may go to the end of the iseq (a fall-off return)
  ends.insert(root.iseq.size());

  Ctx c(root);
  for (const mrb::Insn &in : insns) {
    c.pc = in.pc;
    c.line("");
    c.body << "  (label " << lbl(in.pc) << ")\n";
    if (in.ext != 0 || in.op == mrb::OP_EXT1 || in.op == mrb::OP_EXT2 || in.op == mrb::OP_EXT3) {
      throw Refused("refused: opcode " + std::string(in.name) + " (wide operands, EXT prefix) is not lowered yet (pc " +
                    std::to_string(in.pc) + ")");
    }
    const std::vector<std::uint32_t> &x = in.args;
    auto jump_to = [&](std::size_t target) {
      if (!starts.count(target) && !ends.count(target)) {
        throw std::runtime_error("malformed: jump at pc " + std::to_string(in.pc) + " to " + std::to_string(target) +
                                 ", not an instruction");
      }
      return lbl(target);
    };
    // The method name of a SEND-family instruction (its symbol operand, index b).
    auto method_name = [&](std::uint32_t sym) { return sym_at(root, sym, in.pc); };
    auto refuse_method = [&](const std::string &name, const std::string &why) {
      throw Refused("refused: " + std::string(in.name) + " of method '" + name + "' " + why + " (pc " +
                    std::to_string(in.pc) + ")");
    };
    switch (in.op) {
      case mrb::OP_NOP: break;
      case mrb::OP_MOVE:
        c.line("(copy 16 " + c.reg(x[0]) + " " + c.reg(x[1]) + ")");
        break;
      case mrb::OP_LOADI__1: store_int(c, c.reg(x[0]), "(const long -1)"); break;
      case mrb::OP_LOADI_0:
      case mrb::OP_LOADI_1:
      case mrb::OP_LOADI_2:
      case mrb::OP_LOADI_3:
      case mrb::OP_LOADI_4:
      case mrb::OP_LOADI_5:
      case mrb::OP_LOADI_6:
      case mrb::OP_LOADI_7:
        store_int(c, c.reg(x[0]), "(const long " + num(in.op - mrb::OP_LOADI_0) + ")");
        break;
      case mrb::OP_LOADI8: store_int(c, c.reg(x[0]), "(const long " + num(x[1]) + ")"); break;
      case mrb::OP_LOADINEG: store_int(c, c.reg(x[0]), "(const long " + num(-static_cast<long long>(x[1])) + ")"); break;
      case mrb::OP_LOADI16: store_int(c, c.reg(x[0]), "(const long " + num(s16(x[1])) + ")"); break;
      case mrb::OP_LOADI32: {
        // (int32_t)(((uint32_t)b << 16) + c), as vm.c computes it
        std::uint32_t v = (x[1] << 16) + x[2];
        store_int(c, c.reg(x[0]), "(const long " + num(static_cast<std::int32_t>(v)) + ")");
        break;
      }
      case mrb::OP_LOADSYM: {
        // R[a] = Syms[b]: a symbol with a plain name (the others are quoted in inspect, which is not lowered)
        const std::string &name = sym_at(root, x[1], in.pc);
        if (!plain_symbol(name)) {
          throw Refused("refused: LOADSYM of the symbol :" + name + " (not a plain name) is not lowered yet (pc " +
                        std::to_string(in.pc) + ")");
        }
        c.line("(eval (call void &\"mrbbc_sym\" " + c.reg(x[0]) + " @\"" + symbol_data(c, name) + "\"))");
        break;
      }
      case mrb::OP_STRING: {
        // R[a] = a new string of the pool entry b
        const mrb::Pool &k = pool_at(root, x[1], in.pc);
        if (k.kind != mrb::Pool::Kind::Str) {
          throw std::runtime_error("malformed: STRING at pc " + std::to_string(in.pc) + " reads a pool entry that is not a string");
        }
        const std::string item = "mrbbc_str" + std::to_string(in.pc);
        add_data(c, item, k.s);
        c.line("(eval (call void &\"mrbbc_str_new\" " + c.reg(x[0]) + " @\"" + item + "\" (const long " +
               num(static_cast<long long>(k.s.size())) + ")))");
        break;
      }
      case mrb::OP_STRCAT:
        // str_cat(R[a], R[a+1]): R[a] is a string; the operand is appended as its to_s (mrb_obj_as_string)
        c.line("(eval (call void &\"mrbbc_strcat\" " + c.reg(x[0]) + " " + c.reg(x[0] + 1) + "))");
        break;
      case mrb::OP_LOADNIL: store_tag(c, c.reg(x[0]), kTagNil); break;
      case mrb::OP_LOADTRUE: store_tag(c, c.reg(x[0]), kTagTrue); break;    // OP_LOADT in ops.h's spelling
      case mrb::OP_LOADFALSE: store_tag(c, c.reg(x[0]), kTagFalse); break;  // OP_LOADF
      case mrb::OP_ADD: emit_binary(c, kOpAdd, x[0], x[0] + 1); break;
      case mrb::OP_SUB: emit_binary(c, kOpSub, x[0], x[0] + 1); break;
      case mrb::OP_MUL: emit_binary(c, kOpMul, x[0], x[0] + 1); break;
      case mrb::OP_DIV: emit_binary(c, kOpDiv, x[0], x[0] + 1); break;
      case mrb::OP_EQ: emit_binary(c, kOpEq, x[0], x[0] + 1); break;
      case mrb::OP_LT: emit_binary(c, kOpLt, x[0], x[0] + 1); break;
      case mrb::OP_LE: emit_binary(c, kOpLe, x[0], x[0] + 1); break;
      case mrb::OP_GT: emit_binary(c, kOpGt, x[0], x[0] + 1); break;
      case mrb::OP_GE: emit_binary(c, kOpGe, x[0], x[0] + 1); break;
      case mrb::OP_ADDI: emit_immediate(c, kOpAdd, x[0], x[1]); break;
      case mrb::OP_SUBI: emit_immediate(c, kOpSub, x[0], x[1]); break;
      // ADDILV a b c: a is a local, b is working space, c the immediate (vm.c's OP_MATHILV)
      case mrb::OP_ADDILV: emit_immediate(c, kOpAdd, x[0], x[2]); break;
      case mrb::OP_SUBILV: emit_immediate(c, kOpSub, x[0], x[2]); break;
      case mrb::OP_LOADL: {
        // an integer constant of the pool (LOADI32's range or wider); other constants are refused
        if (x[1] >= root.pool.size()) {
          throw std::runtime_error("malformed: LOADL at pc " + std::to_string(in.pc) + " reads pool entry " +
                                   std::to_string(x[1]) + " of " + std::to_string(root.pool.size()));
        }
        const mrb::Pool &k = root.pool[x[1]];
        std::int64_t value = k.i;
        if (k.kind == mrb::Pool::Kind::BigInt) {
          if (!bigint_value(k, value)) {
            throw Refused("refused: LOADL of a bigint beyond 64 bits is not lowered yet (pc " +
                          std::to_string(in.pc) + ")");
          }
        } else if (k.kind != mrb::Pool::Kind::Int) {
          throw Refused("refused: LOADL of a non-integer constant is not lowered yet (pc " + std::to_string(in.pc) +
                        ")");
        }
        store_int(c, c.reg(x[0]), "(const long " + num(value) + ")");
        break;
      }
      case mrb::OP_ARRAY: lower_array(c, x[0], x[0], x[1]); break;   // R[a] = [R[a] .. R[a+b-1]]
      case mrb::OP_ARRAY2: lower_array(c, x[0], x[1], x[2]); break;  // R[a] = [R[b] .. R[b+c-1]]
      case mrb::OP_ARYPUSH:
        // push R[a+1] .. R[a+b] onto the array in R[a]
        for (std::uint32_t i = 0; i < x[1]; ++i) {
          c.line("(eval (call void &\"mrbbc_ary_push\" " + c.reg(x[0]) + " " + c.reg(x[0] + 1 + i) + "))");
        }
        break;
      case mrb::OP_GETIDX:
        // R[a] = R[a][R[a+1]]
        c.line("(eval (call void &\"mrbbc_getidx\" " + c.reg(x[0]) + " " + c.reg(x[0]) + " " + c.reg(x[0] + 1) + "))");
        break;
      case mrb::OP_GETIDX0:
        // R[a] = R[b][0]; the scratch register a+1 of the VM's fallback is not needed by the runtime
        c.line("(eval (call void &\"mrbbc_getidx0\" " + c.reg(x[0]) + " " + c.reg(x[1]) + "))");
        break;
      case mrb::OP_SETIDX:
        // R[a][R[a+1]] = R[a+2]; the value of the assignment is left in R[a] (vm.c)
        c.line("(eval (call void &\"mrbbc_setidx\" " + c.reg(x[0]) + " " + c.reg(x[0] + 1) + " " + c.reg(x[0] + 2) +
               "))");
        c.line("(copy 16 " + c.reg(x[0]) + " " + c.reg(x[0] + 2) + ")");
        break;
      case mrb::OP_SEND0:
      case mrb::OP_SEND: {
        // R[a] = R[a].send(Syms[b], R[a+1] .. R[a+n]) with c = n | k<<4 (k keyword arguments, refused)
        const bool is_send = in.op == mrb::OP_SEND;
        const unsigned n = is_send ? (x[2] & 0x0f) : 0;
        const unsigned k = is_send ? (x[2] >> 4) : 0;
        const std::string name = method_name(x[1]);
        if (k != 0) refuse_method(name, "with keyword arguments");
        if (n == 0) {
          int code = 0;
          if (!zero_arg_method(name, code)) refuse_method(name, "is not lowered yet");
          c.line("(eval (call void &\"mrbbc_send0\" " + c.reg(x[0]) + " " + c.reg(x[0]) + " (const int " + num(code) +
                 ")))");
        } else if (n == 1) {
          int op = 0;
          if (!binary_method(name, op)) refuse_method(name, "is not lowered yet");
          call_binop(c, op, c.reg(x[0]), c.reg(x[0]), c.reg(x[0] + 1));
        } else {
          refuse_method(name, "with " + std::to_string(n) + " arguments is not lowered yet");
        }
        break;
      }
      case mrb::OP_JMP:
      case mrb::OP_JMPUW:  // unwinds to the same place when the irep has no catch table (checked above), as JMP
        c.line("(goto " + jump_to(jump_target(in, s16(x[0]))) + ")");
        break;
      case mrb::OP_JMPIF:
        c.line("(if " + truthy(c, c.reg(x[0])) + " (then (goto " + jump_to(jump_target(in, s16(x[1]))) + ")))");
        break;
      case mrb::OP_JMPNOT:
        c.line("(if " + falsy(c, c.reg(x[0])) + " (then (goto " + jump_to(jump_target(in, s16(x[1]))) + ")))");
        break;
      case mrb::OP_JMPNIL: {
        std::string t = load_tag(c, c.reg(x[0]));
        std::string isnil = tag_is(c, t, kTagNil);
        c.line("(if " + isnil + " (then (goto " + jump_to(jump_target(in, s16(x[1]))) + ")))");
        break;
      }
      case mrb::OP_RETURN:
        c.line("(copy 16 %0 " + c.reg(x[0]) + ")");
        c.line("(return)");
        break;
      case mrb::OP_RETNIL:
        store_tag(c, "%0", kTagNil);
        c.line("(return)");
        break;
      case mrb::OP_RETFALSE:
        store_tag(c, "%0", kTagFalse);
        c.line("(return)");
        break;
      case mrb::OP_RETTRUE:
        store_tag(c, "%0", kTagTrue);
        c.line("(return)");
        break;
      case mrb::OP_STOP:
        // vm.c: STOP returns nil unless an exception is pending (none is in this subset)
        store_tag(c, "%0", kTagNil);
        c.line("(return)");
        break;
      default:
        throw Refused("refused: opcode " + std::string(in.name) + " is not lowered yet (pc " + std::to_string(in.pc) +
                      ")");
    }
  }
  // A jump to the end of the iseq returns; the ret slot keeps the nil the driver put there.
  c.body << "  (label " << lbl(root.iseq.size()) << ")\n";
  c.line("(return)");

  std::ostringstream fn;
  fn << "(function \"mrb_irep_0\" (ret void) (params (param %0 \"ret\" (ptr (struct \"MV\"))))\n";
  for (std::uint16_t i = 0; i < root.nregs; ++i) fn << "  (slot \"r" << i << "\" (struct \"MV\") 16 8)\n";
  for (const std::string &s : c.slots) fn << "  (slot \"" << s << "\" (struct \"MV\") 16 8)\n";
  fn << c.body.str() << ")\n";

  std::ostringstream out;
  out << "(ir-module \"" << source_name
      << "\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4) (double 8) (long_double 16)))\n";
  out << "(producer \"mruby-4.0\")\n";
  out << "(abi-type \"MV\" 16 8 (memory))\n";
  out << c.data.str();
  out << fn.str();
  return out.str();
}

}  // namespace mrbbc
