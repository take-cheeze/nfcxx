// mruby 4.0 RITE -> Path B IR (docs/notes/mrbbc-pathb.md, section "The lowering").
//
// The main program becomes one IR function `mrb_irep_0(MV *ret)`. A function keeps its registers in one frame, a
// contiguous array of MV (16-byte slots: a tag byte at offset 0 and an int64 at offset 8; the tags are the runtime's,
// tests/mrbbc/runtime/mrbrt.h); R(i) is the address %r<i>, the frame plus 16 i. The value the program returns is written
// to *ret.
//
// A method (a child irep that a TDEF defines) is `mrb_m<N>(MV *ret, MV *argv, MV *blk, long argc)`: argv[0] is self and
// argv[1..argc] the arguments the call gave, which the prologue copies into R(1)..R(n) (n = its required and optional
// parameters; the ones not given are set by their defaults, entered at the jump OP_ENTER picks for argc). blk is the block
// the call gave (nil if none). A
// self call (SSEND, SSEND0, SSENDB) copies R(0) and the arguments into a vector of its own, asks the runtime for the
// method's number (mrbbc_find: the latest definition of the name, and the count is checked there), and calls the
// function of that number. The method table is filled when the TDEF runs (mrbbc_def), as mruby defines the method then.
//
// A block (a child irep that a BLOCK names) is `mrb_b<N>(MV *ret, MV *argv, long argc, MV *frame, MV *home)`: argv[0] is
// the self the block was made in, argv[1..argc] the arguments the yield gave, frame is the frame of the function that made
// the block (its registers are the block's outer locals, GETUPVAR and SETUPVAR at level 0), and home is the frame of the
// method a `return` in the block leaves. BLOCK makes a closure in a slot of the caller (block number, a copy of self, the
// frame, the home), and the value is the closure's address with the BLK tag. A yield (BLKPUSH to get the method's block,
// BLKCALL to call it) dispatches on the block number, as a self call does on the method number. A closure is only used
// while its frame is alive: a block is passed to a method and yielded there, and the program has no way to keep it (a
// block parameter is refused). A RETURN_BLK sets the pending return of its home, and each call on the way passes it up
// (emit_unwind_check) until the home's function takes it.
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
#include <utility>
#include <vector>

namespace mrbbc {

namespace {

// Tags and operator numbers of the runtime (tests/mrbbc/runtime/mrbrt.h; the string, array, symbol and block tags are
// 4, 5, 6 and 7).
constexpr int kTagNil = 0, kTagFalse = 1, kTagTrue = 2, kTagInt = 3;
constexpr int kOpAdd = 0, kOpSub = 1, kOpMul = 2, kOpDiv = 3, kOpLt = 4, kOpLe = 5, kOpGt = 6, kOpGe = 7, kOpEq = 8,
              kOpNeq = 9;
// The methods of SEND0 (enum mrbbc_method).
constexpr int kMToS = 0, kMSize = 1, kMLength = 2, kMNot = 3, kMInspect = 4;

// What a function lowers: the main program, a method body (its argv and blk parameters) or a block body (its argv, argc
// and the frame it was made in).
enum class Kind { Main, Method, Block, Class };

std::string num(long long v) { return std::to_string(v); }

// A label of an instruction, by its byte offset in the iseq.
std::string lbl(std::size_t pc) { return "\"pc" + std::to_string(pc) + "\""; }

// The state shared by the functions of a module: the data items (string literals and symbol names), the methods (the
// child ireps that a TDEF defines) and the blocks (the child ireps that a BLOCK makes), numbered in the order they are
// found, the names the program defines, and the function definitions written so far.
struct Shared {
  std::ostringstream data;                       // (data ...) items, written before the functions
  std::map<std::string, std::string> symbols;    // symbol name -> the data item holding its name
  std::map<const mrb::Irep *, int> method_ids;   // a method body -> its number (the function mrb_m<number>)
  std::vector<const mrb::Irep *> methods;        // the method bodies by number
  std::map<const mrb::Irep *, std::string> method_names;  // a method body -> the name its TDEF gives (SUPER has no name operand)
  std::map<const mrb::Irep *, int> block_ids;    // a block body -> its number (the function mrb_b<number>)
  std::vector<const mrb::Irep *> blocks;         // the block bodies by number
  std::vector<const mrb::Irep *> classes;        // the class bodies (the children an EXEC runs) by number (mrb_k<number>)
  std::map<const mrb::Irep *, int> class_ids;    // a class body -> its number
  std::set<const mrb::Irep *> top_blocks;        // the block bodies whose home is not a method (the main program or a class body)
  std::map<const mrb::Irep *, const mrb::Irep *> block_method;  // a block body -> the method body it is made in (at any depth)
  std::set<const mrb::Irep *> method_blocks;     // the block bodies a method makes directly (their creator is the method)
  std::map<const mrb::Irep *, int> depth;        // a block body -> the number of blocks it is in (1: made by a non-block)
  std::map<const mrb::Irep *, const mrb::Irep *> frame_owner;  // a block body -> the body whose frame is its %4 (the home: the
                                                 // method, main program or class body its chain of blocks starts in)
  std::set<std::string> defined;                 // the names a TDEF of the program defines
  std::set<std::string> in_class;                // the names a TDEF defines in a class body (a method of a class)
  std::set<std::string> top;                     // the names a TDEF defines at the top level (methods of Object)
  std::string functions;                         // the function definitions, the main program first
  int serial = 0;                                // makes the names of the string data items unique
};

// The state of one function's lowering: the fresh IR register numbers, the body, and the MV slots beyond the frame (their
// names and sizes in bytes). %0 is the ret parameter; a method has %1 the argument vector and %2 the block; a block has
// %1 the argument vector, %2 the argument count, %3 the frame it was made in and %4 its home (the frame of the method a
// `return` in it leaves). The registers are numbered from kFirstReg.
constexpr int kFirstReg = 5;
// The registers past an irep's nregs that a frame keeps (see lower_irep).
constexpr unsigned kRegSlack = 3;

struct Ctx {
  Shared &sh;
  const mrb::Irep &irep;
  Kind kind;
  unsigned nregs;      // the frame's registers: the irep's, and any a TDEF writes past them (see lower_irep)
  std::size_t pc = 0;  // the instruction being lowered
  std::string argc;    // the IR name of the count of arguments a method or a block was given (empty for the others)
  int next;            // the next fresh register number, past the frame's registers (set by the constructor)
  std::ostringstream body;
  std::vector<std::pair<std::string, std::size_t>> slots;

  Ctx(Shared &s, const mrb::Irep &i, Kind k, unsigned frame_regs)
      : sh(s), irep(i), kind(k), nregs(frame_regs), next(kFirstReg + static_cast<int>(frame_regs)) {}

  void add_slot(const std::string &name, std::size_t bytes) { slots.emplace_back(name, bytes); }
  std::string fresh() { return "%" + std::to_string(next++); }
  void line(const std::string &s) { body << "  " << s << "\n"; }

  // The address of R(i): the frame's slot i, defined by the prologue as the register kFirstReg + i (the emitter names
  // registers by number only), checked against the irep's register count.
  std::string reg(unsigned i) const {
    if (i >= nregs) {
      throw std::runtime_error("malformed: register R(" + std::to_string(i) + ") at pc " + std::to_string(pc) +
                               " is past the frame's " + std::to_string(nregs) + " registers");
    }
    return "%" + std::to_string(kFirstReg + static_cast<int>(i));
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
    c.add_slot("imm" + std::to_string(c.pc), 16);
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
void add_data(Shared &sh, const std::string &name, const std::string &bytes) {
  sh.data << "(data \"" << name << "\" (const (array " << bytes.size() + 1 << " (const char))) (string \"" << ir_bytes(bytes)
          << "\\000\"))\n";
}

// A symbol's name, as a static string shared by every use of the symbol in the module.
std::string symbol_data(Shared &sh, const std::string &name) {
  auto it = sh.symbols.find(name);
  if (it != sh.symbols.end()) return it->second;
  std::string item = "mrbbc_sym" + std::to_string(sh.symbols.size());
  sh.symbols[name] = item;
  add_data(sh, item, name);
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

// The name of an operator method that a def may give (`def +(o)`): it prints as :+ with no quotes, as mruby's inspect does.
bool operator_symbol(const std::string &s) {
  static const char *const names[] = {"+", "-", "*", "/", "==", "!=", "<", "<=", ">", ">=", "!"};
  for (const char *n : names) {
    if (s == n) return true;
  }
  return false;
}

// The method of a SEND0 (no argument) the runtime implements, by its name (enum mrbbc_method); false for any other.
bool zero_arg_method(const std::string &name, int &code) {
  if (name == "to_s") code = kMToS;
  else if (name == "size") code = kMSize;
  else if (name == "length") code = kMLength;
  else if (name == "!") code = kMNot;
  else if (name == "inspect") code = kMInspect;
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

// Methods of Object and Kernel that a self call may name. A self call to one of these is refused even when the program
// defines the name too: mruby calls the program's method only once its TDEF has run, and the call before it reaches the
// inherited one, which the runtime does not have.
bool object_method(const std::string &name) {
  static const char *const names[] = {
      "to_s",  "inspect", "class", "size",  "length", "p",         "puts",      "print",     "raise",  "new",
      "send",  "hash",    "freeze", "dup", "clone",  "method",    "methods",   "is_a?",     "kind_of?", "nil?",
      "respond_to?", "format", "sprintf", "loop", "lambda", "proc", "block_given?", "require", "initialize",
      "!",     "object_id", "instance_of?", "frozen?", "equal?", "eql?"};
  for (const char *n : names) {
    if (name == n) return true;
  }
  return false;
}

// R[a] = a new array of the n registers from src (ARRAY, ARRAY2). The array is built in a temporary, because the first
// element may be R[a] itself.
void lower_array(Ctx &c, unsigned dst, unsigned src, unsigned n) {
  const std::string tmp = "tmp" + std::to_string(c.pc);
  c.add_slot(tmp, 16);
  c.line("(eval (call void &\"mrbbc_ary_new\" $\"" + tmp + "\" (const long " + num(n) + ")))");
  for (unsigned i = 0; i < n; ++i) {
    c.line("(eval (call void &\"mrbbc_ary_push\" $\"" + tmp + "\" " + c.reg(src + i) + "))");
  }
  c.line("(copy 16 " + c.reg(dst) + " $\"" + tmp + "\")");
}

// The number of a method body or a block body (the TDEF or BLOCK that names it has been collected).
int number_of(const std::map<const mrb::Irep *, int> &ids, const mrb::Irep &body, const char *what) {
  auto it = ids.find(&body);
  if (it == ids.end()) throw std::runtime_error(std::string("malformed: a ") + what + " body that is not collected");
  return it->second;
}

// The parameters of a function body, from its ENTER (vm.c's MRB_ASPEC_*): the body starts with ENTER and has only required
// and optional parameters, so its aspec has the required count in bits 18..22 and the optional count in bits 13..17, and
// no rest, post, keyword or block parameter (bits 0..12) and no &nil (bit 23). Returns false for any other body.
bool body_params(const mrb::Irep &body, long &req, long &opt) {
  std::vector<mrb::Insn> insns = mrb::decode_iseq(body);
  if (insns.empty() || insns[0].pc != 0 || insns[0].op != mrb::OP_ENTER || insns[0].ext != 0) return false;
  const std::uint32_t aspec = insns[0].args[0];
  if ((aspec & 0x1fffu) != 0 || (aspec >> 23) != 0) return false;
  req = static_cast<long>((aspec >> 18) & 0x1f);
  opt = static_cast<long>((aspec >> 13) & 0x1f);
  return true;
}

// The number of parameters a method or block body has (required and optional): the registers 1..n that its arguments fill,
// and the block slot is R(n+1). Throws when the body's parameters are not lowered (the caller has checked them already).
long slot_count(const mrb::Irep &body) {
  long req = 0, opt = 0;
  if (!body_params(body, req, opt)) throw std::runtime_error("malformed: a function body with parameters that are not lowered");
  return req + opt;
}

// The pool and symbol operands, checked against the irep.
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

// The child irep an operand names (a TDEF's body or a BLOCK's), checked against the irep.
const mrb::Irep &child_at(const mrb::Irep &irep, std::uint32_t i, std::size_t pc) {
  if (i >= irep.reps.size()) {
    throw std::runtime_error("malformed: child " + std::to_string(i) + " at pc " + std::to_string(pc) + " of " +
                             std::to_string(irep.reps.size()));
  }
  return irep.reps[i];
}

// Finds the functions of the module: every TDEF's body is a method and every BLOCK's body a block, each numbered in the
// order found (the main program first, then the children in order), and the names the program defines are recorded.
// `kind` is what irep lowers to, and `home_main` says that its home (the function a `return` from it leaves; for a block)
// is the main program.
// `method` is the method body that this irep is made in (for a block: the method its chain of blocks starts in; nullptr
// for the main program and a class body). A block child records it, so that a SUPER in the block finds the method's owner.
void collect(Shared &sh, const mrb::Irep &irep, Kind kind, bool home_main, const mrb::Irep *method) {
  // what each child is: a method body (TDEF), a block body (BLOCK) or a class body (EXEC), and for a block whether its home
  // is not a method (the block is made by the main program, a class body, or a block of one of those)
  const bool child_home_main = kind == Kind::Main || kind == Kind::Class || (kind == Kind::Block && home_main);
  const mrb::Irep *own = kind == Kind::Method ? &irep : method;  // the method the blocks of this irep are made in
  std::vector<std::pair<Kind, bool>> child_kind(irep.reps.size(), std::make_pair(Kind::Method, false));
  for (const mrb::Insn &in : mrb::decode_iseq(irep)) {
    if (in.op == mrb::OP_TDEF) {
      const mrb::Irep *body = &child_at(irep, in.args[2], in.pc);
      if (sh.method_ids.count(body) == 0) {
        sh.method_ids[body] = static_cast<int>(sh.methods.size());
        sh.methods.push_back(body);
      }
      const std::string name = sym_at(irep, in.args[1], in.pc);
      sh.defined.insert(name);
      sh.method_names[body] = name;
      if (kind == Kind::Class) sh.in_class.insert(name);
      if (kind == Kind::Main) sh.top.insert(name);
      child_kind[in.args[2]] = std::make_pair(Kind::Method, false);
    } else if (in.op == mrb::OP_BLOCK) {
      const mrb::Irep *body = &child_at(irep, in.args[1], in.pc);
      if (sh.block_ids.count(body) == 0) {
        sh.block_ids[body] = static_cast<int>(sh.blocks.size());
        sh.blocks.push_back(body);
      }
      if (child_home_main) sh.top_blocks.insert(body);
      if (own != nullptr) sh.block_method[body] = own;
      if (kind == Kind::Method) sh.method_blocks.insert(body);
      // a block made by a block takes the frame of its creator's home (BLOCK passes %4 on), so its depth and that frame
      // are the creator's: the frame of the body the chain starts in
      sh.depth[body] = kind == Kind::Block ? sh.depth.at(&irep) + 1 : 1;
      sh.frame_owner[body] = kind == Kind::Block ? sh.frame_owner.at(&irep) : &irep;
      child_kind[in.args[1]] = std::make_pair(Kind::Block, child_home_main);
    } else if (in.op == mrb::OP_EXEC) {
      const mrb::Irep *body = &child_at(irep, in.args[1], in.pc);
      if (sh.class_ids.count(body) == 0) {
        sh.class_ids[body] = static_cast<int>(sh.classes.size());
        sh.classes.push_back(body);
      }
      child_kind[in.args[1]] = std::make_pair(Kind::Class, false);
    }
  }
  for (std::size_t i = 0; i < irep.reps.size(); ++i) {
    const Kind ck = child_kind[i].first;
    const mrb::Irep *cm = ck == Kind::Method ? &irep.reps[i] : ck == Kind::Block ? own : nullptr;
    collect(sh, irep.reps[i], ck, child_kind[i].second, cm);
  }
}

// Whether the value of a call's result must be checked for a `return` leaving a block: the calls of a method or a block
// may run a block that returns out of the method, and the check (mrbbc_unwinding) passes the pending return on.
void emit_unwind_check(Ctx &c) {
  if (c.kind == Kind::Main) return;  // a return out of a block always stops at a method on the stack (a home is never main)
  std::string p = c.fresh();
  c.line("(let " + p + " bool (call bool &\"mrbbc_unwinding\"))");
  c.line("(if " + p + " (then (eval (call void &\"mrbbc_unwind_take\" %0 $\"frame\")) (return)))");
}

// argv[i] = R[a+i] for i in 1..n (argv[0] is the caller's).
void emit_args(Ctx &c, const std::string &argv, unsigned a, unsigned n) {
  for (unsigned i = 1; i <= n; ++i) {
    std::string p = c.fresh();
    c.line("(let " + p + " (ptr unsigned_char) (offset $\"" + argv + "\" " + num(16 * i) + "))");
    c.line("(copy 16 " + p + " " + c.reg(a + i) + ")");
  }
}

// The argument vector of a call with a receiver: argv[0] is the receiver (self of the method), then the arguments.
void emit_arg_vector(Ctx &c, const std::string &argv, const std::string &self, unsigned a, unsigned n) {
  c.line("(copy 16 $\"" + argv + "\" " + self + ")");
  emit_args(c, argv, a, n);
}

// The block of a call that has none: a slot of this frame holding nil, named `name`.
std::string nil_block(Ctx &c, const std::string &name) {
  c.add_slot(name, 16);
  store_tag(c, "$\"" + name + "\"", kTagNil);
  return "$\"" + name + "\"";
}

// One branch per method of the module: when id is N, the function of method N runs with (ret, argv, blk, argc), where
// argc is the count of arguments the call gives (an IR expression: the call site's count is known, and the callee's
// optional parameters depend on it).
void emit_method_branches(Ctx &c, const Shared &sh, const std::string &id, const std::string &ret, const std::string &argv,
                          const std::string &blk, const std::string &argc) {
  for (std::size_t m = 0; m < sh.methods.size(); ++m) {
    std::string hit = c.fresh();
    c.line("(let " + hit + " bool (eq int " + id + " (const int " + num(static_cast<long long>(m)) + ")))");
    c.line("(if " + hit + " (then (eval (call void &\"mrb_m" + std::to_string(m) + "\" " + ret + " $\"" + argv + "\" " + blk +
           " " + argc + "))))");
  }
}

// After a call that passes a block (SENDB, SSENDB): a break out of the block makes the call return its value, to dst, and
// the code goes on after the call. Any other pending exit passes through this frame as in emit_unwind_check.
void emit_block_site(Ctx &c, const std::string &dst, std::size_t next_pc) {
  std::string p = c.fresh(), b = c.fresh();
  c.line("(let " + p + " bool (call bool &\"mrbbc_unwinding\"))");
  c.line("(if " + p + " (then");
  c.line("(let " + b + " bool (call bool &\"mrbbc_break_take\" " + dst + " $\"frame\"))");
  c.line("(if " + b + " (then (goto " + lbl(next_pc) + ")))");
  if (c.kind != Kind::Main) c.line("(eval (call void &\"mrbbc_unwind_take\" %0 $\"frame\"))");
  c.line("(return)");
  c.line("))");
}

// R[a] = R[a].new(R[a+1] .. R[a+n]) for a class: the instance is made (mrbbc_alloc, which raises for another receiver), its
// initialize runs with the arguments (mrbbc_find_init: none when the class has no initialize, and then no argument is
// allowed), and the instance is the value.
void emit_new(Ctx &c, const Shared &sh, unsigned a, unsigned n, std::size_t pc) {
  const std::string argv = "newargv" + std::to_string(pc);
  c.add_slot(argv, 16 * (static_cast<std::size_t>(n) + 1));
  c.line("(eval (call void &\"mrbbc_alloc\" $\"" + argv + "\" " + c.reg(a) + "))");
  emit_args(c, argv, a, n);
  std::string id = c.fresh();
  c.line("(let " + id + " int (call int &\"mrbbc_find_init\" $\"" + argv + "\" (const long " + num(n) + ")))");
  emit_method_branches(c, sh, id, c.reg(a), argv, nil_block(c, "newnil" + std::to_string(pc)), "(const long " + num(n) + ")");
  emit_unwind_check(c);
  c.line("(copy 16 " + c.reg(a) + " $\"" + argv + "\")");
}

// R[a] = R[a].name(R[a+1] .. R[a+n]) with an explicit receiver (SEND0, SEND, and SENDB with the block in R[a+n+1]). The
// program's methods of the name are looked up on the receiver's class (mrbbc_find_send), one branch per method; when the
// receiver has none of them, the builtin of the name runs (new, and the SEND0 and binary methods), or else NoMethodError.
// A name that only a top-level def defines is refused: it is private, and that error is not reproduced here.
void lower_send(Ctx &c, Shared &sh, const mrb::Insn &in, const std::string &name, unsigned a, unsigned n, bool has_blk) {
  auto refuse = [&](const std::string &why) {
    throw Refused("refused: " + std::string(in.name) + " of method '" + name + "' " + why + " (pc " +
                  std::to_string(in.pc) + ")");
  };
  const bool dispatch = sh.in_class.count(name) != 0;
  if (!dispatch && sh.top.count(name) != 0) refuse("is a method of the program (not lowered yet)");
  int code = 0, op = 0;
  const bool is_new = name == "new" && !has_blk;
  const bool zero = !has_blk && n == 0 && zero_arg_method(name, code);
  const bool binary = !has_blk && n == 1 && binary_method(name, op);
  if (!dispatch && !is_new && !zero && !binary) refuse(has_blk ? "with a block is not lowered yet" : "is not lowered yet");

  const std::string pc = std::to_string(in.pc);
  if (dispatch) {
    const std::string argv = "argv" + pc;
    c.add_slot(argv, 16 * (static_cast<std::size_t>(n) + 1));
    emit_arg_vector(c, argv, c.reg(a), a, n);
    const std::string id = c.fresh();
    c.line("(let " + id + " int (call int &\"mrbbc_find_send\" " + c.reg(a) + " @\"" + symbol_data(sh, name) +
           "\" (const long " + num(n) + ")))");
    const std::string blk = has_blk ? c.reg(a + n + 1) : nil_block(c, "nil" + pc);
    emit_method_branches(c, sh, id, c.reg(a), argv, blk, "(const long " + num(n) + ")");
    if (has_blk) {
      emit_block_site(c, c.reg(a), in.pc + in.len);
    } else {
      emit_unwind_check(c);
    }
    const std::string neg = c.fresh();
    c.line("(let " + neg + " bool (lt.s int " + id + " (const int 0)))");
    c.line("(if " + neg + " (then");
  }
  if (is_new) {
    emit_new(c, sh, a, n, in.pc);
  } else if (zero) {
    c.line("(eval (call void &\"mrbbc_send0\" " + c.reg(a) + " " + c.reg(a) + " (const int " + num(code) + ")))");
  } else if (binary) {
    call_binop(c, op, c.reg(a), c.reg(a), c.reg(a + 1));
  } else {
    c.line("(eval (call void &\"mrbbc_no_method\" " + c.reg(a) + " @\"" + symbol_data(sh, name) + "\"))");
  }
  if (dispatch) c.line("))");
}

// The operator method an opcode calls on its fast path, for the operators whose redefinition is refused (nullptr otherwise).
const char *operator_method(int op) {
  switch (op) {
    case mrb::OP_ADD:
    case mrb::OP_ADDI:
    case mrb::OP_ADDILV: return "+";
    case mrb::OP_SUB:
    case mrb::OP_SUBI:
    case mrb::OP_SUBILV: return "-";
    case mrb::OP_MUL: return "*";
    case mrb::OP_DIV: return "/";
    case mrb::OP_EQ: return "==";
    case mrb::OP_LT: return "<";
    case mrb::OP_LE: return "<=";
    case mrb::OP_GT: return ">";
    case mrb::OP_GE: return ">=";
    default: return nullptr;
  }
}

// Lowers one irep to the function `fname` and appends it to sh.functions.
void lower_irep(Shared &sh, const mrb::Irep &irep, const std::string &fname, Kind kind) {
  if (!irep.catches.empty()) {
    const char *what = kind == Kind::Main ? "the main program" : kind == Kind::Method ? "a method" : kind == Kind::Class ? "a class body" : "a block";
    throw Refused(std::string("refused: ") + what + " has a catch table");
  }
  // the parameters of the body: a method or a block takes its required and optional ones (a block with two or more splats a
  // single array argument, see the prologue); a class body takes none and has no ENTER
  long req = 0, opt = 0;
  if (kind == Kind::Method || kind == Kind::Block) {
    if (!body_params(irep, req, opt)) {
      throw Refused("refused: " + fname + " has parameters other than required and optional ones (not lowered yet)");
    }
  }
  const long nslots = req + opt;  // the registers 1..nslots take the parameters; the block slot is R(nslots+1)
  std::vector<mrb::Insn> insns = mrb::decode_iseq(irep);

  std::set<std::size_t> starts;
  for (const mrb::Insn &in : insns) starts.insert(in.pc);
  std::set<std::size_t> ends;  // a jump may go to the end of the iseq (a fall-off return)
  ends.insert(irep.iseq.size());

  // The frame: the irep's registers, and the register a TDEF writes (mruby's VM has room past nregs for it, as the class
  // bodies that define methods show, where TDEF writes R(1) with nregs 1).
  // mruby's codegen does not count every register a call names: a zsuper in a class body is `LOADNIL 2` and `SUPER 1 0` with
  // nregs 2 (vm.c's stack has room past nregs), so the frame has a few registers past the irep's count.
  unsigned frame_regs = irep.nregs + kRegSlack;
  for (const mrb::Insn &in : insns) {
    if (in.op == mrb::OP_TDEF && in.args[0] + 1u > frame_regs) frame_regs = in.args[0] + 1u;
  }
  // a method keeps its block in R(nslots+1), where the VM's caller leaves it (a zsuper or a super reads it from there)
  if (kind == Kind::Method && frame_regs < static_cast<unsigned>(nslots) + 2u) frame_regs = static_cast<unsigned>(nslots) + 2u;

  Ctx c(sh, irep, kind, frame_regs);
  for (unsigned i = 0; i < frame_regs; ++i) {
    c.line("(let " + c.reg(i) + " (ptr unsigned_char) (offset $\"frame\" " + num(16 * i) + "))");
  }
  if (kind == Kind::Method) {
    // R(0) is self and R(1..nslots) the arguments the call gave (argv[1..argc], %3); the others start as nil. The optional
    // parameters that were not given stay nil here: the default code of each sets them (the ENTER jumps there).
    c.argc = "%3";
    c.line("(copy 16 " + c.reg(0) + " %1)");
    for (long i = 1; i <= nslots; ++i) {
      std::string p = c.fresh(), given = c.fresh();
      c.line("(let " + p + " (ptr unsigned_char) (offset %1 " + num(16 * i) + "))");
      c.line("(let " + given + " bool (le.s long (const long " + num(i) + ") %3))");
      c.line("(if " + given + " (then (copy 16 " + c.reg(static_cast<unsigned>(i)) + " " + p + ")) (else");
      store_tag(c, c.reg(static_cast<unsigned>(i)), kTagNil);
      c.line("))");
    }
    for (long i = nslots + 1; i < static_cast<long>(frame_regs); ++i) {
      store_tag(c, c.reg(static_cast<unsigned>(i)), kTagNil);
    }
    c.line("(copy 16 " + c.reg(static_cast<unsigned>(nslots + 1)) + " %2)");
  } else if (kind == Kind::Class) {
    // R(0) is self; a class body takes no parameters
    c.line("(copy 16 " + c.reg(0) + " %1)");
    for (long i = 1; i < static_cast<long>(frame_regs); ++i) {
      store_tag(c, c.reg(static_cast<unsigned>(i)), kTagNil);
    }
  } else if (kind == Kind::Block) {
    // R(0) is self. The parameters are the arguments the yield gave, nil past their count (mrbbc_block_arg); with two or more
    // parameters one array argument is splatted instead (mrbbc_block_argc gives the count then). The count is kept in a
    // register for the choice of the optional parameters' defaults (OP_ENTER).
    c.line("(copy 16 " + c.reg(0) + " %1)");
    c.argc = c.fresh();
    c.line("(let " + c.argc + " long (call long &\"mrbbc_block_argc\" %1 %2 (const long " + num(nslots) + ")))");
    for (long i = 1; i <= nslots; ++i) {
      c.line("(eval (call void &\"mrbbc_block_arg\" " + c.reg(static_cast<unsigned>(i)) + " %1 %2 (const long " + num(nslots) +
             ") (const long " + num(i) + ")))");
    }
    for (long i = nslots + 1; i < static_cast<long>(frame_regs); ++i) {
      store_tag(c, c.reg(static_cast<unsigned>(i)), kTagNil);
    }
  }
  std::size_t argary_end = static_cast<std::size_t>(-1);  // the pc after the last ARGARY (a zsuper's SUPER follows it)
  unsigned argary_m1 = 0;                                 // the parameter count the last ARGARY gave (the zsuper's count)
  for (const mrb::Insn &in : insns) {
    c.pc = in.pc;
    c.line("");
    c.body << "  (label " << lbl(in.pc) << ")\n";
    // an operator the program defines at the top level is an Object method that every value inherits (and mruby calls
    // for a nil or a Symbol operand too): the runtime's operators do not reach it, so it is refused. A class's operator
    // is found by the runtime from the receiver's class (mrbbc_binop, see "Operators" in the notes).
    if (const char *op_name = operator_method(in.op)) {
      if (sh.top.count(op_name) != 0) {
        throw Refused("refused: " + std::string(in.name) + " of the operator '" + op_name +
                      "', which the program defines at the top level, is not lowered yet (pc " + std::to_string(in.pc) + ")");
      }
    }
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
    auto method_name = [&](std::uint32_t sym) { return sym_at(irep, sym, in.pc); };
    auto refuse_method = [&](const std::string &name, const std::string &why) {
      throw Refused("refused: " + std::string(in.name) + " of method '" + name + "' " + why + " (pc " +
                    std::to_string(in.pc) + ")");
    };
    switch (in.op) {
      case mrb::OP_NOP: break;
      case mrb::OP_ENTER:
        if ((kind == Kind::Method || kind == Kind::Block) && in.pc == 0) {
          // The prologue copied the parameters the call gave. With optional parameters, mruby's VM enters the body at the
          // jump for the count of optional arguments given: after ENTER there are opt+1 JMPs, the one at index k for k
          // given (k = argc - required, clamped to 0..opt), and the one at index opt jumps past all the defaults (vm.c's
          // `ci->pc += ...`). The JMP at index k is lowered as any JMP: it goes to the default of optional k.
          for (long j = 0; j < opt; ++j) {
            if (insns.size() < 2u + static_cast<std::size_t>(opt) || insns[1 + j].op != mrb::OP_JMP) {
              throw std::runtime_error("malformed: the optional parameters of " + fname + " are not followed by their jumps");
            }
          }
          if (opt > 0) {
            if (insns.size() < 2u + static_cast<std::size_t>(opt) || insns[1 + opt].op != mrb::OP_JMP) {
              throw std::runtime_error("malformed: the optional parameters of " + fname + " are not followed by their jumps");
            }
            for (long j = 0; j < opt; ++j) {
              const std::string taken = c.fresh();
              c.line("(let " + taken + " bool (lt.s long " + c.argc + " (const long " + num(req + j + 1) + ")))");
              c.line("(if " + taken + " (then (goto " + lbl(insns[1 + j].pc) + ")))");
            }
            c.line("(goto " + lbl(insns[1 + opt].pc) + ")");
          }
        } else if (!(kind != Kind::Main && in.pc == 0) && x[0] != 0) {
          throw Refused("refused: ENTER with parameters is not lowered yet (pc " + std::to_string(in.pc) + ")");
        }
        break;
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
        const std::string &name = sym_at(irep, x[1], in.pc);
        if (!plain_symbol(name)) {
          throw Refused("refused: LOADSYM of the symbol :" + name + " (not a plain name) is not lowered yet (pc " +
                        std::to_string(in.pc) + ")");
        }
        c.line("(eval (call void &\"mrbbc_sym\" " + c.reg(x[0]) + " @\"" + symbol_data(sh, name) + "\"))");
        break;
      }
      case mrb::OP_STRING: {
        // R[a] = a new string of the pool entry b
        const mrb::Pool &k = pool_at(irep, x[1], in.pc);
        if (k.kind != mrb::Pool::Kind::Str) {
          throw std::runtime_error("malformed: STRING at pc " + std::to_string(in.pc) + " reads a pool entry that is not a string");
        }
        const std::string item = "mrbbc_str" + std::to_string(sh.serial++);
        add_data(sh, item, k.s);
        c.line("(eval (call void &\"mrbbc_str_new\" " + c.reg(x[0]) + " @\"" + item + "\" (const long " +
               num(static_cast<long long>(k.s.size())) + ")))");
        break;
      }
      case mrb::OP_STRCAT:
        // str_cat(R[a], R[a+1]): R[a] is a string; the operand is appended as its to_s (mrb_obj_as_string). The runtime
        // calls a to_s the program defines in the operand's class (mrbbc_strcat)
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
        if (x[1] >= irep.pool.size()) {
          throw std::runtime_error("malformed: LOADL at pc " + std::to_string(in.pc) + " reads pool entry " +
                                   std::to_string(x[1]) + " of " + std::to_string(irep.pool.size()));
        }
        const mrb::Pool &k = irep.pool[x[1]];
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
      case mrb::OP_AREF:
        // R[a] = R[b][c] as vm.c gives it (the destructuring `a, b = x`): an array's element c, and for a value that is not
        // an array, the value itself at c = 0 and nil otherwise
        c.line("(eval (call void &\"mrbbc_aref\" " + c.reg(x[0]) + " " + c.reg(x[1]) + " (const long " + num(x[2]) + ")))");
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
      case mrb::OP_TDEF: {
        // R[a] = the symbol of the method Syms[b], defined as the body of child c on the target class (Object here, the
        // only class a program of this subset defines methods on); the body is a function of its own (mrb_m<number>)
        const mrb::Irep &body = child_at(irep, x[2], in.pc);
        const std::string name = method_name(x[1]);
        // a def goes to Object at the top level, and to the class body's own class (self) in a class body
        if (kind != Kind::Main && kind != Kind::Class) refuse_method(name, "is defined in a method or a block (not lowered yet)");
        if (!plain_symbol(name) && !operator_symbol(name)) refuse_method(name, "has a name that is not plain (not lowered yet)");
        long req = 0, opt = 0;
        if (!body_params(body, req, opt)) refuse_method(name, "has parameters other than required and optional ones (not lowered yet)");
        const std::string id = "(const int " + num(number_of(sh.method_ids, body, "method")) + ") (const long " + num(req) +
                               ") (const long " + num(req + opt) + ")";
        if (kind == Kind::Class) {
          c.line("(eval (call void &\"mrbbc_def_in\" " + c.reg(0) + " @\"" + symbol_data(sh, name) + "\" " + id + "))");
        } else {
          c.line("(eval (call void &\"mrbbc_def\" @\"" + symbol_data(sh, name) + "\" " + id + "))");
        }
        c.line("(eval (call void &\"mrbbc_sym\" " + c.reg(x[0]) + " @\"" + symbol_data(sh, name) + "\"))");
        break;
      }
      case mrb::OP_BLOCK: {
        // R[a] = a block made from child b: the closure is a slot of this frame (mrbbc_block fills it: the block's number,
        // a copy of R(0), and the frame), and the value is its address with the BLK tag
        const mrb::Irep &body = child_at(irep, x[1], in.pc);
        const std::string clo = "clo" + std::to_string(in.pc);
        c.add_slot(clo, 40);  // the runtime's Clo: id, self, frame, home
        // the home of the block: this frame for a method or the main program, the block's own home for a block
        const std::string home = kind == Kind::Block ? "%4" : "$\"frame\"";
        c.line("(eval (call void &\"mrbbc_block\" " + c.reg(x[0]) + " $\"" + clo + "\" (const long " +
               num(number_of(sh.block_ids, body, "block")) + ") " + c.reg(0) + " $\"frame\" " + home + "))");
        break;
      }
      case mrb::OP_BLKPUSH: {
        // R[a] = the block of this method (vm.c: a nil block is "unexpected yield"); only the method's own block (level 0)
        if (kind != Kind::Method || (x[1] & 0xf) != 0) {
          throw Refused("refused: BLKPUSH of a block other than the method's own is not lowered yet (pc " +
                        std::to_string(in.pc) + ")");
        }
        c.line("(eval (call void &\"mrbbc_blk_load\" " + c.reg(x[0]) + " %2))");
        break;
      }
      case mrb::OP_BLKCALL: {
        // R[a] = R[a].call(R[a+1] .. R[a+b]): the block's number picks the function, as a self call's method does
        const unsigned n = x[1];
        const std::string argv = "argv" + std::to_string(in.pc);
        c.add_slot(argv, 16 * (static_cast<std::size_t>(n) + 1));
        c.line("(eval (call void &\"mrbbc_blk_args\" $\"" + argv + "\" " + c.reg(x[0]) + "))");
        for (unsigned i = 1; i <= n; ++i) {
          std::string p = c.fresh();
          c.line("(let " + p + " (ptr unsigned_char) (offset $\"" + argv + "\" " + num(16 * i) + "))");
          c.line("(copy 16 " + p + " " + c.reg(x[0] + i) + ")");
        }
        std::string id = c.fresh(), fr = c.fresh(), hm = c.fresh();
        c.line("(let " + id + " long (call long &\"mrbbc_blk_id\" " + c.reg(x[0]) + "))");
        c.line("(let " + fr + " (ptr unsigned_char) (call (ptr unsigned_char) &\"mrbbc_blk_frame\" " + c.reg(x[0]) + "))");
        c.line("(let " + hm + " (ptr unsigned_char) (call (ptr unsigned_char) &\"mrbbc_blk_home\" " + c.reg(x[0]) + "))");
        for (std::size_t m = 0; m < sh.blocks.size(); ++m) {
          std::string hit = c.fresh();
          c.line("(let " + hit + " bool (eq long " + id + " (const long " + num(static_cast<long long>(m)) + ")))");
          c.line("(if " + hit + " (then (eval (call void &\"mrb_b" + std::to_string(m) + "\" " + c.reg(x[0]) + " $\"" + argv +
                 "\" (const long " + num(n) + ") " + fr + " " + hm + "))))");
        }
        emit_unwind_check(c);
        break;
      }
      case mrb::OP_GETUPVAR:
      case mrb::OP_SETUPVAR: {
        // GETUPVAR a b c: R[a] = the register b of the frame c levels out; SETUPVAR: the other way. Level 0 is the frame
        // the block was made in (%3); a deeper level would need the frame's own link, which is not lowered yet.
        // Level 1 from a block that a method makes directly is the method's own block slot (R(arity+1)), which mruby's
        // `super` reads when it passes the method's block to a call in the block (gen_blkmove). That read is nil in mruby
        // 4.0.0 (the method's proc has no environment, so the upvar of its level is nil): this is lowered as nil, and
        // only for that register.
        if (kind == Kind::Block && x[2] == 1 && in.op == mrb::OP_GETUPVAR && sh.method_blocks.count(&irep) != 0) {
          const mrb::Irep *method = sh.block_method.at(&irep);
          if (static_cast<long>(x[1]) == slot_count(*method) + 1) {
            store_tag(c, c.reg(x[0]), kTagNil);
            break;
          }
        }
        // In a block that a block makes (depth 2), level 1 is the frame the chain starts in (%4, the BLOCK passes it on), and
        // level 2 is past the method's env: the implicit block of a super there is nil, as mruby's level-2 upvar is (the
        // method's proc has no environment above it). Only the frame's own registers (its locals) are read.
        if (kind == Kind::Block && sh.depth.at(&irep) == 2 && x[2] == 2 && in.op == mrb::OP_GETUPVAR &&
            sh.block_method.count(&irep) != 0 && static_cast<long>(x[1]) == slot_count(*sh.block_method.at(&irep)) + 1) {
          store_tag(c, c.reg(x[0]), kTagNil);
          break;
        }
        if (kind == Kind::Block && sh.depth.at(&irep) == 2 && x[2] == 1) {
          const mrb::Irep *owner = sh.frame_owner.at(&irep);
          if (x[1] >= owner->nlocals) {
            throw Refused("refused: " + std::string(in.name) + " of a register past the locals of the frame it reads is not lowered yet (pc " +
                          std::to_string(in.pc) + ")");
          }
          std::string p = c.fresh();
          c.line("(let " + p + " (ptr unsigned_char) (offset %4 " + num(16 * static_cast<long long>(x[1])) + "))");
          if (in.op == mrb::OP_GETUPVAR) c.line("(copy 16 " + c.reg(x[0]) + " " + p + ")");
          else c.line("(copy 16 " + p + " " + c.reg(x[0]) + ")");
          break;
        }
        if (kind != Kind::Block || x[2] != 0) {
          throw Refused("refused: " + std::string(in.name) + " of a level other than the block's own frame is not lowered yet (pc " +
                        std::to_string(in.pc) + ")");
        }
        std::string p = c.fresh();
        c.line("(let " + p + " (ptr unsigned_char) (offset %3 " + num(16 * static_cast<long long>(x[1])) + "))");
        if (in.op == mrb::OP_GETUPVAR) c.line("(copy 16 " + c.reg(x[0]) + " " + p + ")");
        else c.line("(copy 16 " + p + " " + c.reg(x[0]) + ")");
        break;
      }
      case mrb::OP_ARGARY: {
        // ARGARY a b: the arguments of a zsuper (`super` with no arguments), as vm.c builds them: R[a] = the array of the
        // parameters and R[a+1] = the block. The count m1 is the method's parameters, required and optional (codegen puts
        // both in it). The values are the parameters' current values: in a method, its registers 1..m1; in a block that a
        // method makes directly (level 1, the method's frame is %3), the method's registers, which the block shares. The
        // block is the method's R(m1+1), where its caller leaves it. Rest, post and keyword parameters are refused.
        const unsigned m1 = (x[1] >> 11) & 0x3f, r = (x[1] >> 10) & 1, m2 = (x[1] >> 5) & 0x1f, kd = (x[1] >> 4) & 1,
                       lv = x[1] & 0xf;
        // The method is read at level 1 from a block that a method makes (its frame is %3) and at level 2 from a block that a
        // block of a method makes (its frame is %4, the home): vm.c's uvenv(lv-1) is the method's env in both.
        if (kind != Kind::Method && (kind != Kind::Block || sh.block_method.count(&irep) == 0)) {
          // outside a method: vm.c's ARGARY raises like SUPER does, at run time
          c.line("(eval (call void &\"mrbbc_no_super\"))");
          break;
        }
        const bool in_method = kind == Kind::Method && lv == 0;
        const bool in_block = kind == Kind::Block && lv == 1 && sh.depth.at(&irep) == 1 && sh.method_blocks.count(&irep) != 0;
        const bool in_block2 = kind == Kind::Block && lv == 2 && sh.depth.at(&irep) == 2 && sh.block_method.count(&irep) != 0;
        if (!(in_method || in_block || in_block2) || r != 0 || m2 != 0 || kd != 0 ||
            static_cast<long>(m1) != slot_count(in_method ? irep : *sh.block_method.at(&irep))) {
          throw Refused("refused: ARGARY other than the parameters of a method (or of a block that a method makes) is not "
                        "lowered yet (pc " + std::to_string(in.pc) + ")");
        }
        // the register i of the method whose parameters are read
        auto param = [&](unsigned i) -> std::string {
          if (in_method) return c.reg(i);
          std::string p = c.fresh();
          c.line("(let " + p + " (ptr unsigned_char) (offset " + (in_block ? "%3" : "%4") + " " +
                 num(16 * static_cast<long long>(i)) + "))");
          return p;
        };
        c.line("(eval (call void &\"mrbbc_ary_new\" " + c.reg(x[0]) + " (const long " + num(m1) + ")))");
        for (unsigned i = 1; i <= m1; ++i) {
          c.line("(eval (call void &\"mrbbc_ary_push\" " + c.reg(x[0]) + " " + param(i) + "))");
        }
        c.line("(copy 16 " + c.reg(x[0] + 1) + " " + param(m1 + 1) + ")");
        argary_end = in.pc + in.len;
        argary_m1 = m1;
        break;
      }
      case mrb::OP_SUPER: {
        // SUPER a b: R[a] = the method of the superclass of the class the current method is defined in (mrbbc_find_super),
        // called on self R(0). b = n | k<<4: the arguments are R[a+1..a+n] and the block R[a+n+1] (nil or the block; the
        // SUPER takes the block from that register, as vm.c does). n = 15 is the zsuper of a method with parameters: the
        // array of ARGARY is in R[a+1] (its elements are the method's arity many) and the block in R[a+2].
        // in a block, the method is the one the block is made in (its owner is the superclass's start); a block of the main
        // program or a class body has no method
        const mrb::Irep *home = kind == Kind::Method ? &irep : nullptr;
        if (kind == Kind::Block) {
          auto it = sh.block_method.find(&irep);
          if (it != sh.block_method.end()) home = it->second;
        }
        if (home == nullptr) {
          // outside a method (the main program, a class body, or a block of one) mruby's SUPER raises at run time
          c.line("(eval (call void &\"mrbbc_no_super\"))");
          break;
        }
        const unsigned n = x[1] & 0x0f, k = x[1] >> 4;
        if (k != 0) throw Refused("refused: SUPER with keyword arguments is not lowered yet (pc " + std::to_string(in.pc) + ")");
        // n = 15 is a splat (an array of any length) unless the ARGARY of a zsuper comes just before it: only that one has
        // the method's parameter count many elements (ARGARY's m1)
        const bool zparams = n == 15;
        if (zparams && in.pc != argary_end) {
          throw Refused("refused: SUPER with a splat of arguments is not lowered yet (pc " + std::to_string(in.pc) + ")");
        }
        const unsigned nargs = zparams ? argary_m1 : n;
        const unsigned blk = zparams ? x[0] + 2 : x[0] + n + 1;
        const std::string name = sh.method_names.at(home);
        const std::string argv = "argv" + std::to_string(in.pc);
        c.add_slot(argv, 16 * (static_cast<std::size_t>(nargs) + 1));
        c.line("(copy 16 $\"" + argv + "\" " + c.reg(0) + ")");
        if (zparams) {
          for (unsigned i = 0; i < nargs; ++i) {
            std::string p = c.fresh();
            c.line("(let " + p + " (ptr unsigned_char) (offset $\"" + argv + "\" " + num(16 * (i + 1)) + "))");
            c.line("(eval (call void &\"mrbbc_ary_elt\" " + p + " " + c.reg(x[0] + 1) + " (const long " + num(i) + ")))");
          }
        } else {
          emit_args(c, argv, x[0], n);
        }
        // the superclass method's number, or -1 for the builtin initialize (BasicObject#initialize, which gives nil)
        const std::string id = c.fresh();
        c.line("(let " + id + " int (call int &\"mrbbc_find_super\" " + c.reg(0) + " (const int " +
               num(number_of(sh.method_ids, *home, "method")) + ") @\"" + symbol_data(sh, name) + "\" (const long " +
               num(nargs) + ")))");
        emit_method_branches(c, sh, id, c.reg(x[0]), argv, c.reg(blk), "(const long " + num(nargs) + ")");
        const std::string neg = c.fresh();
        c.line("(let " + neg + " bool (lt.s int " + id + " (const int 0)))");
        c.line("(if " + neg + " (then (eval (call void &\"mrbbc_super_nil\" " + c.reg(x[0]) + "))))");
        emit_block_site(c, c.reg(x[0]), in.pc + in.len);
        break;
      }
      case mrb::OP_SSEND0:
      case mrb::OP_SSEND:
      case mrb::OP_SSENDB: {
        // R[a] = self.Syms[b](R[a+1] .. R[a+n]) with self = R[0] and c = n | k<<4 (SSEND0 has no arguments); SSENDB has
        // the block in R[a+n+1]. The arguments go to a vector of their own (self first), so the method's function reads
        // them from one array. The method is found on self's class, then on Object (mrbbc_find).
        const bool has_c = in.op != mrb::OP_SSEND0;
        const unsigned n = has_c ? (x[2] & 0x0f) : 0;
        const unsigned k = has_c ? (x[2] >> 4) : 0;
        const std::string name = method_name(x[1]);
        if (k != 0) refuse_method(name, "with keyword arguments");
        // block_given? is the Kernel method that reads the frame's block: the frame's own block, or none at the top level
        if (name == "block_given?" && n == 0 && in.op != mrb::OP_SSENDB && sh.defined.count(name) == 0) {
          if (kind == Kind::Main) {
            store_tag(c, c.reg(x[0]), kTagFalse);
          } else if (kind == Kind::Method) {
            c.line("(eval (call void &\"mrbbc_blk_given\" " + c.reg(x[0]) + " %2))");
          } else {
            refuse_method(name, "in a block is not lowered yet");
          }
          break;
        }
        if (sh.defined.count(name) == 0) {
          refuse_method(name, "is not defined by the program (only the program's methods are lowered)");
        }
        if (object_method(name)) refuse_method(name, "is an Object method, which a self call is not lowered for");
        const std::string argv = "argv" + std::to_string(in.pc);
        c.add_slot(argv, 16 * (static_cast<std::size_t>(n) + 1));
        emit_arg_vector(c, argv, c.reg(0), x[0], n);
        // the block: the one the instruction passes, or nil
        const std::string blk = in.op == mrb::OP_SSENDB ? c.reg(x[0] + n + 1) : nil_block(c, "nil" + std::to_string(in.pc));
        // the runtime checks the count and gives the method's number; the call is one branch per method of the program
        const std::string id = c.fresh();
        c.line("(let " + id + " int (call int &\"mrbbc_find\" " + c.reg(0) + " @\"" + symbol_data(sh, name) + "\" (const long " +
               num(n) + ")))");
        emit_method_branches(c, sh, id, c.reg(x[0]), argv, blk, "(const long " + num(n) + ")");
        if (in.op == mrb::OP_SSENDB) {
          emit_block_site(c, c.reg(x[0]), in.pc + in.len);
        } else {
          emit_unwind_check(c);
        }
        break;
      }
      case mrb::OP_SEND0:
      case mrb::OP_SEND:
      case mrb::OP_SENDB: {
        // R[a] = R[a].Syms[b](R[a+1] .. R[a+n]) with c = n | k<<4 (k keyword arguments, refused); SENDB has the block in
        // R[a+n+1]. See lower_send.
        const bool has_c = in.op != mrb::OP_SEND0;
        const unsigned n = has_c ? (x[2] & 0x0f) : 0;
        const unsigned k = has_c ? (x[2] >> 4) : 0;
        const std::string name = method_name(x[1]);
        if (k != 0) refuse_method(name, "with keyword arguments");
        lower_send(c, sh, in, name, x[0], n, in.op == mrb::OP_SENDB);
        break;
      }
      case mrb::OP_GETIV:
      case mrb::OP_SETIV: {
        // R[a] = self.@Syms[b] (GETIV), or self.@Syms[b] = R[a] (SETIV); self is R(0) in a method, a block or a class body
        if (kind == Kind::Main) {
          throw Refused("refused: an instance variable of the main program is not lowered yet (pc " + std::to_string(in.pc) + ")");
        }
        const std::string sym = "@\"" + symbol_data(sh, sym_at(irep, x[1], in.pc)) + "\"";
        if (in.op == mrb::OP_GETIV) {
          c.line("(eval (call void &\"mrbbc_getiv\" " + c.reg(x[0]) + " " + c.reg(0) + " " + sym + "))");
        } else {
          c.line("(eval (call void &\"mrbbc_setiv\" " + c.reg(0) + " " + sym + " " + c.reg(x[0]) + "))");
        }
        break;
      }
      case mrb::OP_GETCONST:
        // R[a] = the class Syms[b] (a constant that names a class the program defines; mrbbc_getconst)
        c.line("(eval (call void &\"mrbbc_getconst\" " + c.reg(x[0]) + " @\"" + symbol_data(sh, sym_at(irep, x[1], in.pc)) +
               "\"))");
        break;
      case mrb::OP_CLASS: {
        // R[a] = the class Syms[b] with superclass R[a+1] (nil: Object). It is defined under the class its cbase R[a] names,
        // else under the class body's own class (self), else at the top level; an existing class of the name is reopened.
        if (kind != Kind::Main && kind != Kind::Class) {
          throw Refused("refused: CLASS in a method or a block is not lowered yet (pc " + std::to_string(in.pc) + ")");
        }
        const std::string target = kind == Kind::Class ? c.reg(0) : c.reg(x[0]);
        c.line("(eval (call void &\"mrbbc_class\" " + c.reg(x[0]) + " " + c.reg(x[0]) + " " + c.reg(x[0] + 1) + " @\"" +
               symbol_data(sh, sym_at(irep, x[1], in.pc)) + "\" " + target + "))");
        break;
      }
      case mrb::OP_TCLASS:
        // R[a] = the class a method definition goes to: Object at the top level, the class body's own class in a class body
        if (kind == Kind::Main) {
          c.line("(eval (call void &\"mrbbc_object_class\" " + c.reg(x[0]) + "))");
        } else if (kind == Kind::Class) {
          c.line("(copy 16 " + c.reg(x[0]) + " " + c.reg(0) + ")");
        } else {
          throw Refused("refused: TCLASS in a method or a block is not lowered yet (pc " + std::to_string(in.pc) + ")");
        }
        break;
      case mrb::OP_EXEC: {
        // R[a] = the class body Bx run with self R[a] (the function mrb_k<number>; its argument vector holds self)
        const mrb::Irep &body = child_at(irep, x[1], in.pc);
        const std::string argv = "argv" + std::to_string(in.pc);
        c.add_slot(argv, 16);
        c.line("(copy 16 $\"" + argv + "\" " + c.reg(x[0]) + ")");
        const std::string nil = nil_block(c, "nil" + std::to_string(in.pc));
        c.line("(eval (call void &\"mrb_k" + std::to_string(number_of(sh.class_ids, body, "class")) + "\" " + c.reg(x[0]) +
               " $\"" + argv + "\" " + nil + "))");
        break;
      }
      case mrb::OP_BREAK:
        // a break out of a block: the call the block was passed to returns the value (mrbbc_break; home is the frame that
        // made the block, which is where that call is). The block returns at once.
        if (kind != Kind::Block) {
          throw Refused("refused: BREAK outside a block is not lowered yet (pc " + std::to_string(in.pc) + ")");
        }
        c.line("(eval (call void &\"mrbbc_break\" " + c.reg(x[0]) + " %3))");
        c.line("(return)");
        break;
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
        // a block's RETURN is local to the block (next); the return out of a block is RETURN_BLK
        c.line("(copy 16 %0 " + c.reg(x[0]) + ")");
        c.line("(return)");
        break;
      case mrb::OP_RETURN_BLK:
        // return from a block: the value becomes the pending return of the block's home (the method it was made in), and
        // this block returns; each call on the way passes it on (emit_unwind_check) until the home takes it
        if (kind != Kind::Block) {
          throw Refused("refused: RETURN_BLK outside a block is not lowered yet (pc " + std::to_string(in.pc) + ")");
        }
        if (sh.top_blocks.count(&irep) != 0) {
          throw Refused("refused: a return from a block of the top level is not lowered yet (pc " + std::to_string(in.pc) +
                        ")");
        }
        c.line("(eval (call void &\"mrbbc_return_block\" " + c.reg(x[0]) + " %4))");
        c.line("(return)");
        break;
      case mrb::OP_RETSELF:
        // self is R(0) in a method, a block or a class body; the top level's self is the main object, which is not modelled
        if (kind == Kind::Main) throw Refused("refused: RETSELF of the main program is not lowered yet (pc " + std::to_string(in.pc) + ")");
        c.line("(copy 16 %0 " + c.reg(0) + ")");
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
  c.body << "  (label " << lbl(irep.iseq.size()) << ")\n";
  c.line("(return)");

  std::ostringstream fn;
  fn << "(function \"" << fname << "\" (ret void) (params (param %0 \"ret\" (ptr (struct \"MV\")))";
  if (kind == Kind::Method) {
    fn << " (param %1 \"argv\" (ptr (struct \"MV\"))) (param %2 \"blk\" (ptr (struct \"MV\"))) (param %3 \"argc\" long)";
  } else if (kind == Kind::Class) {
    fn << " (param %1 \"argv\" (ptr (struct \"MV\"))) (param %2 \"blk\" (ptr (struct \"MV\")))";
  } else if (kind == Kind::Block) {
    fn << " (param %1 \"argv\" (ptr (struct \"MV\"))) (param %2 \"argc\" long) (param %3 \"frame\" (ptr (struct \"MV\")))"
       << " (param %4 \"home\" (ptr (struct \"MV\")))";
  }
  fn << ")\n";
  fn << "  (slot \"frame\" (struct \"MV\") " << 16 * static_cast<std::size_t>(frame_regs) << " 8)\n";
  for (const auto &s : c.slots) fn << "  (slot \"" << s.first << "\" (struct \"MV\") " << s.second << " 8)\n";
  fn << c.body.str() << ")\n";
  sh.functions += fn.str();
}

}  // namespace

std::string lower_module(const mrb::Module &module, const std::string &source_name) {
  const mrb::Irep &root = module.root;
  Shared sh;
  collect(sh, root, Kind::Main, true, nullptr);
  lower_irep(sh, root, "mrb_irep_0", Kind::Main);
  for (std::size_t m = 0; m < sh.methods.size(); ++m) {
    lower_irep(sh, *sh.methods[m], "mrb_m" + std::to_string(m), Kind::Method);
  }
  for (std::size_t k = 0; k < sh.classes.size(); ++k) {
    lower_irep(sh, *sh.classes[k], "mrb_k" + std::to_string(k), Kind::Class);
  }
  for (std::size_t b = 0; b < sh.blocks.size(); ++b) {
    lower_irep(sh, *sh.blocks[b], "mrb_b" + std::to_string(b), Kind::Block);
  }
  // mrbbc_user_call(id, ret, argv, blk, argc): the runtime calls the program's method number id (an operator, to_s or inspect
  // of an instance of a program class, found on the receiver's class by mrbbc_find_send's rule). One branch per method.
  {
    std::ostringstream uc;
    uc << "(function \"mrbbc_user_call\" (ret void) (params (param %0 \"id\" int)"
       << " (param %1 \"ret\" (ptr (struct \"MV\"))) (param %2 \"argv\" (ptr (struct \"MV\")))"
       << " (param %3 \"blk\" (ptr (struct \"MV\"))) (param %4 \"argc\" long))\n";
    for (std::size_t m = 0; m < sh.methods.size(); ++m) {
      const std::string hit = "%" + std::to_string(5 + 2 * m);
      uc << "  (let " << hit << " bool (eq int %0 (const int " << m << ")))\n";
      uc << "  (if " << hit << " (then (eval (call void &\"mrb_m" << m << "\" %1 %2 %3 %4))))\n";
    }
    uc << "  (return))\n";
    sh.functions += uc.str();
  }

  std::ostringstream out;
  out << "(ir-module \"" << source_name
      << "\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4) (double 8) (long_double 16)))\n";
  out << "(producer \"mruby-4.0\")\n";
  out << "(abi-type \"MV\" 16 8 (memory))\n";
  out << sh.data.str();
  out << sh.functions;
  return out.str();
}

}  // namespace mrbbc
