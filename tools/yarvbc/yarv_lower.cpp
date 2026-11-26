// Ruby 3.3 YARV bytecode -> Path B IR text (tools/yarvbc/yarv_lower.hpp). The first subset: integers, nil, true and false,
// local variables of the top level and of a method, the integer operators and comparisons, branches and while loops, and
// calls of the methods the program defines at the top level with def (positional arguments, recursion). Everything else is
// refused with a named message (yarv::Refused).
//
// The shape of the IR is the one tools/mrbbc lowers mruby bytecode to (docs/notes/mrbbc-pathb.md), and the same runtime runs
// it (tests/mrbbc/runtime: the MV tags, the integer helpers mrbbc_binop, mrbbc_find for the arity and the method number,
// mrbbc_def for the definitions, mrbbc_print and the driver tests/mrbbc/runtime/driver.c, which calls the entry named
// mrb_irep_0). A value is a 16-byte MV in a frame slot. The frame of a function holds the locals first (slot i is local
// i of the iseq's local table) and then the operand stack: the stack depth at each instruction is a static fact of the
// bytecode, found by analyze() below, so a stack position is a frame slot.
//
// Analysis (analyze): a dataflow over the instructions from the first one. The state is the stack, and each stack slot
// records whether it holds a value or the receiver `self` (putself). self is only lowered as the receiver of a call with
// no explicit receiver (FCALL or VCALL), whose receiver the runtime looks up on Object; any other use of self as a value is
// refused, since the lowering has no self to give it (the value of self at the top level is nil here, where Ruby's is main).
// A method's self is the same.
//
// Calls: a call with no explicit receiver names a method the program defines (the names of its definemethod instructions).
// It is lowered the way the mruby producer lowers a self call: the argument vector is self then the arguments, mrbbc_find
// checks the count and returns the method's number, and one branch per method calls its function. A definemethod calls
// mrbbc_def with the method's number and its required count. The methods are functions mrb_m<N>(ret, argv, blk, argc, kw).
//
// Operators: the integer fast path of each operator is one IR operation when both operands are integers (checked add,
// subtract and multiply, and signed comparisons); everything else calls mrbbc_binop, which does the rest of Ruby's rules
// and raises the errors. An integer overflow traps instead of becoming a Bignum, as in the mruby producer, so a program
// whose integers leave 64 bits is not lowered faithfully. `%` is the floor modulo of the quotient the runtime divides (q =
// a / b by mrbbc_binop, then a - q * b), so it has no helper of its own.
#include "yarv_lower.hpp"

#include <cstdint>
#include <cstdio>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace yarvbc {

namespace {

using yarv::CallInfo;
using yarv::Insn;
using yarv::Iseq;
using yarv::IseqType;
using yarv::Module;
using yarv::ReadError;
using yarv::Refused;
using yarv::Value;

// The tags and operator numbers of the runtime (tests/mrbbc/runtime/mrbrt.h).
constexpr int kTagNil = 0, kTagFalse = 1, kTagTrue = 2, kTagInt = 3;
constexpr int kOpAdd = 0, kOpSub = 1, kOpMul = 2, kOpDiv = 3, kOpLt = 4, kOpLe = 5, kOpGt = 6, kOpGe = 7, kOpEq = 8,
              kOpNeq = 9;

// The IR register of frame slot 0 (the emitter names registers by number; %0 is the ret parameter, and a method has %1..%4).
constexpr int kFirstReg = 6;

// vm_callinfo.h's call flags: FCALL (a call with no receiver), VCALL (a bare name), ARGS_SIMPLE and TAILCALL are the only ones
// lowered; any other bit (splat, block argument, keywords, super, ...) is refused.
constexpr std::uint64_t kCallArgsSplat = 1u << 0, kCallArgsBlockarg = 1u << 1;
constexpr std::uint64_t kCallFcall = 1u << 2, kCallVcall = 1u << 3, kCallArgsSimple = 1u << 4, kCallTailcall = 1u << 7;
constexpr std::uint64_t kCallKnown = kCallFcall | kCallVcall | kCallArgsSimple | kCallTailcall;

// The iseq's param flags (compile.c's ibf_dump_iseq_each): bit 0 is has_lead, the only parameter kind lowered.
constexpr std::uint64_t kParamHasLead = 1;

enum class Origin : std::uint8_t { Value, Self };
using Stack = std::vector<Origin>;

[[noreturn]] void refuse(const std::string &what, const Insn &in) {
  throw Refused("refused: " + what + " (" + in.name + " at pc " + std::to_string(in.pc) + ")");
}

std::string num(long long v) { return std::to_string(v); }

// A label of an instruction, by its word offset.
std::string lbl(std::size_t pc) { return "\"pc" + std::to_string(pc) + "\""; }

// The bytes of a string in the IR text form the emitter reads (see tools/mrbbc/mrb_lower.cpp: ir_bytes).
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

// What a constant of the object table is, for a refusal message (the T_xxx types of ruby's value_type.h).
std::string kind_name(const Value &v) {
  switch (v.kind) {
    case Value::Kind::Float: return "a Float";
    case Value::Kind::Symbol: return "a Symbol";
    case Value::Kind::String: return "a String";
    default: break;
  }
  if (v.type == 0x0a) return "a Bignum";
  return "an object of type " + std::to_string(v.type);
}

// The state of one function being lowered: its frame, its slots and the fresh registers.
struct Fn {
  std::size_t nlocals = 0;
  std::size_t frame_slots = 0;  // locals plus the deepest operand stack
  bool method = false;
  std::ostringstream body;
  std::vector<std::pair<std::string, std::size_t>> slots;  // extra slots (name, bytes)
  int next_reg = 0;

  Fn(std::size_t locals, std::size_t frame, bool is_method)
      : nlocals(locals), frame_slots(frame), method(is_method), next_reg(kFirstReg + static_cast<int>(frame)) {}

  std::string fresh() { return "%" + std::to_string(next_reg++); }
  void line(const std::string &s) { body << "  " << s << "\n"; }
  // The register of frame slot k (a pointer to its MV).
  std::string slot(std::size_t k) const { return "%" + std::to_string(kFirstReg + static_cast<int>(k)); }
  // The register of operand stack position d (0 is the bottom) at the instruction's entry.
  std::string stack(std::size_t d) const { return slot(nlocals + d); }
  void add_slot(const std::string &name, std::size_t bytes) { slots.emplace_back(name, bytes); }
  std::string named(const std::string &name) const { return "$\"" + name + "\""; }
};

void copy16(Fn &f, const std::string &dst, const std::string &src) { f.line("(copy 16 " + dst + " " + src + ")"); }

// The tag byte of an address, loaded into a fresh register.
std::string load_tag(Fn &f, const std::string &addr) {
  std::string p = f.fresh(), t = f.fresh();
  f.line("(let " + p + " (ptr unsigned_char) (offset " + addr + " 0))");
  f.line("(let " + t + " unsigned_char (load unsigned_char " + p + "))");
  return t;
}

std::string tag_is(Fn &f, const std::string &tag_reg, int tag) {
  std::string b = f.fresh();
  f.line("(let " + b + " bool (eq unsigned_char " + tag_reg + " (const unsigned_char " + num(tag) + ")))");
  return b;
}

// A bool register that is true when the value is falsy (nil or false: tags 0 and 1).
std::string falsy(Fn &f, const std::string &addr) {
  std::string t = load_tag(f, addr), b = f.fresh();
  f.line("(let " + b + " bool (lt.u unsigned_char " + t + " (const unsigned_char 2)))");
  return b;
}

// A bool register that is true when the value is truthy (every other tag).
std::string truthy(Fn &f, const std::string &addr) {
  std::string t = load_tag(f, addr), b = f.fresh();
  f.line("(let " + b + " bool (le.u unsigned_char (const unsigned_char 2) " + t + "))");
  return b;
}

void store_tag(Fn &f, const std::string &dst, int tag) {
  std::string p = f.fresh();
  f.line("(let " + p + " (ptr unsigned_char) (offset " + dst + " 0))");
  f.line("(store unsigned_char " + p + " (const unsigned_char " + num(tag) + "))");
}

std::string load_int(Fn &f, const std::string &addr) {
  std::string p = f.fresh(), v = f.fresh();
  f.line("(let " + p + " (ptr long) (offset " + addr + " 8))");
  f.line("(let " + v + " long (load long " + p + "))");
  return v;
}

void store_int(Fn &f, const std::string &dst, const std::string &value) {
  store_tag(f, dst, kTagInt);
  std::string p = f.fresh();
  f.line("(let " + p + " (ptr long) (offset " + dst + " 8))");
  f.line("(store long " + p + " " + value + ")");
}

// dst = a OP b through the runtime (mrbbc_binop: every case the fast path does not take, and the errors).
void call_binop(Fn &f, int op, const std::string &dst, const std::string &lhs, const std::string &rhs) {
  f.line("(eval (call void &\"mrbbc_binop\" (const int " + num(op) + ") " + dst + " " + lhs + " " + rhs + "))");
}

// dst = a OP b for the operators with an integer fast path. The fast path is one IR operation on the two integers; the
// division always goes to the runtime (its zero check and floor rounding are there).
void emit_binop(Fn &f, int op, const std::string &dst, const std::string &lhs, const std::string &rhs) {
  if (op == kOpDiv) {
    call_binop(f, op, dst, lhs, rhs);
    return;
  }
  const std::string ta = load_tag(f, lhs), tb = load_tag(f, rhs);
  const std::string ba = tag_is(f, ta, kTagInt), bb = tag_is(f, tb, kTagInt);
  const std::string ok = f.fresh();
  f.line("(let " + ok + " bool (const bool 0))");
  f.line("(if " + ba + " (then (set " + ok + " " + bb + ")))");
  f.line("(if " + ok + " (then");
  const std::string x = load_int(f, lhs), y = load_int(f, rhs);
  if (op == kOpAdd || op == kOpSub || op == kOpMul) {
    const char *cop = op == kOpAdd ? "cadd" : op == kOpSub ? "csub" : "cmul";
    const std::string r = f.fresh();
    f.line("(let " + r + " long (" + cop + " long " + x + " " + y + "))");
    store_int(f, dst, r);
  } else if (op == kOpEq || op == kOpNeq) {
    const std::string r = f.fresh();
    f.line("(let " + r + " bool (eq long " + x + " " + y + "))");
    f.line("(if " + r + " (then");
    store_tag(f, dst, op == kOpEq ? kTagTrue : kTagFalse);
    f.line(") (else");
    store_tag(f, dst, op == kOpEq ? kTagFalse : kTagTrue);
    f.line("))");
  } else {
    // GT and GE swap the operands of LT and LE (the emitter has signed lt.s and le.s)
    const bool swap = op == kOpGt || op == kOpGe;
    const char *cop = (op == kOpLt || op == kOpGt) ? "lt.s" : "le.s";
    const std::string r = f.fresh();
    f.line("(let " + r + " bool (" + cop + " long " + (swap ? y : x) + " " + (swap ? x : y) + "))");
    f.line("(if " + r + " (then");
    store_tag(f, dst, kTagTrue);
    f.line(") (else");
    store_tag(f, dst, kTagFalse);
    f.line("))");
  }
  f.line(") (else");
  call_binop(f, op, dst, lhs, rhs);
  f.line("))");
}

// dst = a % b: the runtime divides (floor), then a - q * b. The division raises ZeroDivisionError for b = 0.
void emit_mod(Fn &f, const std::string &dst, const std::string &lhs, const std::string &rhs, const std::string &tmp_name) {
  f.add_slot(tmp_name, 16);
  const std::string tmp = f.named(tmp_name);
  call_binop(f, kOpDiv, tmp, lhs, rhs);
  const std::string x = load_int(f, lhs), y = load_int(f, rhs), q = load_int(f, tmp);
  const std::string prod = f.fresh(), r = f.fresh();
  f.line("(let " + prod + " long (cmul long " + q + " " + y + "))");
  f.line("(let " + r + " long (csub long " + x + " " + prod + "))");
  store_int(f, dst, r);
}

// The symbol names a program uses, as data items of the module (one `(data ...)` per name, shared by every use).
struct Symbols {
  std::map<std::string, std::string> items;  // name -> data item
  std::ostringstream data;

  std::string item(const std::string &name) {
    auto it = items.find(name);
    if (it != items.end()) return it->second;
    std::string id = "yarv_sym" + std::to_string(items.size());
    items[name] = id;
    data << "(data \"" << id << "\" (const (array " << name.size() + 1 << " (const char))) (string \"" << ir_bytes(name)
         << "\\000\"))\n";
    return id;
  }
};

// A stack-state entry per reachable instruction, found by analyze.
struct Flow {
  bool reached = false;
  Stack stack;
};

class Lowerer {
 public:
  explicit Lowerer(const Module &m) : mod_(m) {}

  std::string run(const std::string &source_name);

 private:
  const Module &mod_;
  std::set<std::string> defined_;              // the names the program defines with def (definemethod, at the top level)
  std::vector<std::size_t> methods_;           // the method iseqs by number
  std::map<std::size_t, int> method_no_;       // a method iseq -> its number
  Symbols syms_;
  std::ostringstream functions_;

  const std::string &symbol_of(const Insn &in, std::uint64_t operand) const {
    const Value &v = mod_.object(in.operands[operand]);
    if (v.kind != Value::Kind::Symbol) throw ReadError("malformed: a method name is not a symbol (pc " + std::to_string(in.pc) + ")");
    return v.s;
  }

  // The stack after one instruction, and the pcs it may go to next. Refuses what the producer does not lower.
  std::vector<std::size_t> step(const Iseq &is, const Insn &in, Stack &st) const;
  std::vector<Flow> analyze(const Iseq &is) const;
  void call_checks(const Insn &in, const CallInfo &ci) const;

  void lower_function(const Iseq &is, const std::string &name, bool method);
  void emit(Fn &f, const Iseq &is, const Insn &in, std::size_t depth);
  void emit_send(Fn &f, const Insn &in, std::size_t depth, const CallInfo &ci);
  std::string user_call() const;
  void check_params(const Iseq &is, bool method) const;
};

// Each stack state must be a single Origin shape where paths meet: a value and self may not meet at one slot.
std::vector<Flow> Lowerer::analyze(const Iseq &is) const {
  const std::vector<Insn> &insns = is.insns;
  std::map<std::size_t, std::size_t> index;  // pc -> instruction index
  for (std::size_t i = 0; i < insns.size(); ++i) index[insns[i].pc] = i;
  std::vector<Flow> flows(insns.size());
  if (insns.empty()) return flows;
  flows[0].reached = true;
  std::vector<std::size_t> work{0};
  while (!work.empty()) {
    const std::size_t i = work.back();
    work.pop_back();
    Stack st = flows[i].stack;
    for (std::size_t pc : step(is, insns[i], st)) {
      auto it = index.find(pc);
      if (it == index.end()) {
        throw ReadError("malformed: the jump at pc " + std::to_string(insns[i].pc) + " goes to pc " + std::to_string(pc) +
                        ", which is not an instruction");
      }
      Flow &to = flows[it->second];
      if (!to.reached) {
        to.reached = true;
        to.stack = st;
        work.push_back(it->second);
      } else if (to.stack != st) {
        if (to.stack.size() != st.size()) {
          throw ReadError("malformed: the stack depth at pc " + std::to_string(pc) + " differs between two paths");
        }
        refuse("a value and self meet on the stack (not lowered yet)", insns[i]);
      }
    }
  }
  return flows;
}

// The checks of a call's call info that every call instruction shares: no bits of splat, block argument, keywords, super or
// the other forms, and no keyword count.
void Lowerer::call_checks(const Insn &in, const CallInfo &ci) const {
  if (!ci.present) refuse("a call with no call info is not lowered yet", in);
  if (ci.kwlen != 0) refuse("a call with keyword arguments is not lowered yet", in);
  if (ci.flag & (kCallArgsSplat | kCallArgsBlockarg)) refuse("a call with a splat or a block argument is not lowered yet", in);
  if (ci.flag & ~kCallKnown) refuse("a call with a keyword splat, super or another argument form is not lowered yet", in);
}

std::vector<std::size_t> Lowerer::step(const Iseq &is, const Insn &in, Stack &st) const {
  const std::string &n = in.name;
  const std::size_t next = in.pc + in.len;
  const std::int64_t target = static_cast<std::int64_t>(next) + static_cast<std::int64_t>(in.operands.empty() ? 0 : in.operands[0]);
  auto need = [&](std::size_t k) {
    if (st.size() < k) throw ReadError("malformed: stack underflow at pc " + std::to_string(in.pc));
  };
  auto pop_value = [&]() {
    need(1);
    if (st.back() != Origin::Value) refuse("self is used as a value (only the receiver of a self call is lowered)", in);
    st.pop_back();
  };
  auto push_value = [&]() { st.push_back(Origin::Value); };
  auto jump_target = [&]() -> std::size_t {
    if (target < 0) throw ReadError("malformed: a jump at pc " + std::to_string(in.pc) + " goes before the iseq");
    return static_cast<std::size_t>(target);
  };

  if (n == "nop") return {next};
  if (n == "definemethod") {
    // a def at the top level only: its body is a method, and the methods of a method are not lowered
    if (is.type != IseqType::Top && is.type != IseqType::Main) refuse("a def inside a method is not lowered yet", in);
    if (in.operands[1] == ~0ull) refuse("a def with no body is not lowered yet", in);
    if (mod_.iseqs[static_cast<std::size_t>(in.operands[1])].type != IseqType::Method) {
      refuse("a definition that is not a method is not lowered yet", in);
    }
    return {next};
  }
  if (n == "getlocal_WC_0" || n == "setlocal_WC_0") {
    // the operand is the local's offset from the environment pointer: table index = locals + 2 - operand (vm_core.h's
    // VM_ENV_DATA_SIZE is 3), so the operand is in 3..locals+2
    const std::uint64_t raw = in.operands[0];
    if (raw < 3 || raw > is.locals.size() + 2) {
      throw ReadError("malformed: local operand " + std::to_string(raw) + " at pc " + std::to_string(in.pc));
    }
    if (n == "setlocal_WC_0") pop_value();
    else push_value();
    return {next};
  }
  if (n == "putnil" || n == "putobject_INT2FIX_0_" || n == "putobject_INT2FIX_1_") {
    push_value();
    return {next};
  }
  if (n == "putself") {
    st.push_back(Origin::Self);
    return {next};
  }
  if (n == "putobject") {
    const Value &v = mod_.object(in.operands[0]);
    switch (v.kind) {
      case Value::Kind::Nil:
      case Value::Kind::True:
      case Value::Kind::False:
      case Value::Kind::Fixnum:
        break;
      default:
        refuse(std::string("putobject of ") + kind_name(v) + " is not lowered yet", in);
    }
    push_value();
    return {next};
  }
  if (n == "pop") {
    need(1);
    st.pop_back();
    return {next};
  }
  if (n == "dup") {
    need(1);
    if (st.back() != Origin::Value) refuse("self is used as a value", in);
    push_value();
    return {next};
  }
  if (n == "opt_not") {
    pop_value();
    push_value();
    return {next};
  }
  if (n == "opt_plus" || n == "opt_minus" || n == "opt_mult" || n == "opt_div" || n == "opt_mod" || n == "opt_lt" ||
      n == "opt_le" || n == "opt_gt" || n == "opt_ge" || n == "opt_eq" || n == "opt_neq") {
    const CallInfo &ci = is.calls[in.operands[0]];
    call_checks(in, ci);
    if (ci.argc != 1) refuse("an operator with other than one argument", in);
    if (n == "opt_neq") call_checks(in, is.calls[in.operands[1]]);  // the call of == that != falls back to
    pop_value();
    pop_value();
    push_value();
    return {next};
  }
  if (n == "branchif" || n == "branchunless") {
    pop_value();
    return {next, jump_target()};
  }
  if (n == "jump") return {jump_target()};
  if (n == "leave") {
    pop_value();
    return {};
  }
  if (n == "send" || n == "opt_send_without_block") {
    const CallInfo &ci = is.calls[in.operands[0]];
    if (n == "send" && in.operands[1] != ~0ull) refuse("a call with a block (e.g. Integer#times) is not lowered yet", in);
    call_checks(in, ci);
    if ((ci.flag & (kCallFcall | kCallVcall)) == 0) refuse("a call with an explicit receiver is not lowered yet", in);
    if (defined_.count(ci.mid) == 0) {
      refuse("a call of '" + ci.mid + "', which the program does not define, is not lowered yet", in);
    }
    const std::size_t argc = static_cast<std::size_t>(ci.argc);
    need(argc + 1);
    if (st[st.size() - argc - 1] != Origin::Self) refuse("a self call's receiver is not self", in);
    for (std::size_t k = 0; k < argc; ++k) {
      if (st[st.size() - argc + k] != Origin::Value) refuse("self is used as an argument", in);
    }
    st.resize(st.size() - argc - 1);
    push_value();
    return {next};
  }
  refuse("instruction " + n + " is not lowered yet", in);
}

// The parameters a function is lowered with: only required ones (the top level takes none).
void Lowerer::check_params(const Iseq &is, bool method) const {
  if (is.catch_count != 0) throw Refused("refused: rescue and ensure (a catch table) are not lowered yet");
  if (method) {
    if ((is.param_flags & ~kParamHasLead) != 0) {
      throw Refused("refused: optional, rest, post, keyword and block parameters are not lowered yet");
    }
    if (is.lead_num > is.locals.size()) throw ReadError("malformed: a method has more parameters than locals");
  } else if (is.param_flags != 0) {
    throw Refused("refused: parameters of the top level are not lowered yet");
  }
}

// One call of a method (or any self call): the argument vector is self then the arguments; mrbbc_find checks the count and
// gives the method's number, and one branch per method calls its function.
void Lowerer::emit_send(Fn &f, const Insn &in, std::size_t depth, const CallInfo &ci) {
  const std::size_t argc = static_cast<std::size_t>(ci.argc);
  const std::size_t recv = depth - argc - 1;
  const std::string tag = std::to_string(in.pc);
  const std::string argv = "argv" + tag, nilb = "nilblk" + tag;
  f.add_slot(argv, 16 * (argc + 1));
  f.add_slot(nilb, 16);
  store_tag(f, f.named(nilb), kTagNil);
  copy16(f, f.named(argv), f.stack(recv));
  for (std::size_t i = 1; i <= argc; ++i) {
    const std::string p = f.fresh();
    f.line("(let " + p + " (ptr unsigned_char) (offset " + f.named(argv) + " " + num(static_cast<long long>(16 * i)) + "))");
    copy16(f, p, f.stack(recv + i));
  }
  const std::string id = f.fresh();
  f.line("(let " + id + " int (call int &\"mrbbc_find\" " + f.stack(recv) + " @\"" + syms_.item(ci.mid) + "\" (const long " +
         num(static_cast<long long>(argc)) + ") (const long 0)))");
  for (std::size_t m = 0; m < methods_.size(); ++m) {
    const std::string hit = f.fresh();
    f.line("(let " + hit + " bool (eq int " + id + " (const int " + num(static_cast<long long>(m)) + ")))");
    f.line("(if " + hit + " (then (eval (call void &\"mrb_m" + std::to_string(m) + "\" " + f.stack(recv) + " " + f.named(argv) +
           " " + f.named(nilb) + " (const long " + num(static_cast<long long>(argc)) + ") (const long 0)))))");
  }
}

void Lowerer::emit(Fn &f, const Iseq &is, const Insn &in, std::size_t depth) {
  const std::string &n = in.name;
  auto local_index = [&](const Insn &x) { return static_cast<std::size_t>(is.locals.size() + 2 - x.operands[0]); };
  auto target_pc = [&]() {
    return static_cast<std::size_t>(static_cast<std::int64_t>(in.pc + in.len) + static_cast<std::int64_t>(in.operands[0]));
  };

  if (n == "nop") return;
  if (n == "getlocal_WC_0") {
    copy16(f, f.stack(depth), f.slot(local_index(in)));
  } else if (n == "setlocal_WC_0") {
    copy16(f, f.slot(local_index(in)), f.stack(depth - 1));
  } else if (n == "putnil") {
    store_tag(f, f.stack(depth), kTagNil);
  } else if (n == "putself") {
    // self is only ever the receiver of a self call, which copies it from this slot: nil is what the runtime needs for it
    store_tag(f, f.stack(depth), kTagNil);
  } else if (n == "putobject") {
    const Value &v = mod_.object(in.operands[0]);
    switch (v.kind) {
      case Value::Kind::Nil: store_tag(f, f.stack(depth), kTagNil); break;
      case Value::Kind::True: store_tag(f, f.stack(depth), kTagTrue); break;
      case Value::Kind::False: store_tag(f, f.stack(depth), kTagFalse); break;
      case Value::Kind::Fixnum: store_int(f, f.stack(depth), "(const long " + num(v.i) + ")"); break;
      default: refuse(std::string("putobject of ") + kind_name(v) + " is not lowered yet", in);
    }
  } else if (n == "putobject_INT2FIX_0_") {
    store_int(f, f.stack(depth), "(const long 0)");
  } else if (n == "putobject_INT2FIX_1_") {
    store_int(f, f.stack(depth), "(const long 1)");
  } else if (n == "pop") {
    // nothing: the slot is dead
  } else if (n == "dup") {
    copy16(f, f.stack(depth), f.stack(depth - 1));
  } else if (n == "opt_not") {
    const std::string fl = falsy(f, f.stack(depth - 1));
    f.line("(if " + fl + " (then");
    store_tag(f, f.stack(depth - 1), kTagTrue);
    f.line(") (else");
    store_tag(f, f.stack(depth - 1), kTagFalse);
    f.line("))");
  } else if (n == "opt_plus" || n == "opt_minus" || n == "opt_mult" || n == "opt_div" || n == "opt_mod" || n == "opt_lt" ||
             n == "opt_le" || n == "opt_gt" || n == "opt_ge" || n == "opt_eq" || n == "opt_neq") {
    const std::size_t d = depth - 2;
    const std::string lhs = f.stack(d), rhs = f.stack(d + 1);
    if (n == "opt_mod") {
      emit_mod(f, lhs, lhs, rhs, "modq" + std::to_string(in.pc));
    } else {
      int op = kOpAdd;
      if (n == "opt_minus") op = kOpSub;
      else if (n == "opt_mult") op = kOpMul;
      else if (n == "opt_div") op = kOpDiv;
      else if (n == "opt_lt") op = kOpLt;
      else if (n == "opt_le") op = kOpLe;
      else if (n == "opt_gt") op = kOpGt;
      else if (n == "opt_ge") op = kOpGe;
      else if (n == "opt_eq") op = kOpEq;
      else if (n == "opt_neq") op = kOpNeq;
      emit_binop(f, op, lhs, lhs, rhs);
    }
  } else if (n == "branchif" || n == "branchunless") {
    const std::string c = n == "branchif" ? truthy(f, f.stack(depth - 1)) : falsy(f, f.stack(depth - 1));
    f.line("(if " + c + " (then (goto " + lbl(target_pc()) + ")))");
  } else if (n == "jump") {
    f.line("(goto " + lbl(target_pc()) + ")");
  } else if (n == "leave") {
    copy16(f, "%0", f.stack(depth - 1));
    f.line("(return)");
  } else if (n == "send" || n == "opt_send_without_block") {
    emit_send(f, in, depth, is.calls[in.operands[0]]);
  } else if (n == "definemethod") {
    const std::size_t child = static_cast<std::size_t>(in.operands[1]);
    auto it = method_no_.find(child);
    if (it == method_no_.end()) throw ReadError("malformed: a definemethod names an iseq that is not a method");
    const std::size_t lead = static_cast<std::size_t>(mod_.iseqs[child].lead_num);
    f.line("(eval (call void &\"mrbbc_def\" @\"" + syms_.item(symbol_of(in, 0)) + "\" (const int " + num(it->second) +
           ") (const long " + num(static_cast<long long>(lead)) + ") (const long " + num(static_cast<long long>(lead)) +
           ") (const int 2)))");
  } else {
    refuse("instruction " + n + " is not lowered yet", in);
  }
}

void Lowerer::lower_function(const Iseq &is, const std::string &name, bool method) {
  if (method && is.type != IseqType::Method) throw Refused("refused: a block or class body is not lowered yet");
  check_params(is, method);
  const std::vector<Flow> flows = analyze(is);
  std::size_t deepest = 0;
  for (const Flow &fl : flows) {
    if (fl.reached && fl.stack.size() + 1 > deepest) deepest = fl.stack.size() + 1;
  }
  const std::size_t nl = is.locals.size();
  Fn f(nl, nl + (deepest == 0 ? 1 : deepest), method);

  // a method's parameters are the first locals: argv[1..lead] (mrbbc_find has checked the count); the rest are nil
  for (std::size_t i = 0; i < f.frame_slots; ++i) {
    f.line("(let " + f.slot(i) + " (ptr unsigned_char) (offset $\"frame\" " + num(static_cast<long long>(16 * i)) + "))");
  }
  const std::size_t lead = method ? static_cast<std::size_t>(is.lead_num) : 0;
  for (std::size_t i = 0; i < lead; ++i) {
    const std::string p = f.fresh();
    f.line("(let " + p + " (ptr unsigned_char) (offset %1 " + num(static_cast<long long>(16 * (i + 1))) + "))");
    copy16(f, f.slot(i), p);
  }
  for (std::size_t i = lead; i < nl; ++i) store_tag(f, f.slot(i), kTagNil);

  for (std::size_t i = 0; i < is.insns.size(); ++i) {
    if (!flows[i].reached) continue;  // dead code: nothing reaches it
    const Insn &in = is.insns[i];
    f.line("");
    f.body << "  (label " << lbl(in.pc) << ")\n";
    emit(f, is, in, flows[i].stack.size());
  }
  f.line("");
  f.body << "  (label " << lbl(is.words) << ")\n";
  f.line("(return)");

  std::ostringstream fn;
  fn << "(function \"" << name << "\" (ret void) (params (param %0 \"ret\" (ptr (struct \"MV\")))";
  if (method) {
    fn << " (param %1 \"argv\" (ptr (struct \"MV\"))) (param %2 \"blk\" (ptr (struct \"MV\"))) (param %3 \"argc\" long)"
       << " (param %4 \"kw\" long)";
  }
  fn << ")\n";
  fn << "  (slot \"frame\" (struct \"MV\") " << 16 * f.frame_slots << " 8)\n";
  for (const auto &s : f.slots) fn << "  (slot \"" << s.first << "\" (struct \"MV\") " << s.second << " 8)\n";
  fn << f.body.str() << ")\n";
  functions_ << fn.str();
}

std::string Lowerer::user_call() const {
  // mrbbc_user_call(id, ret, argv, blk, argc): the runtime calls the program's method number id, one branch per method
  // (tests/mrbbc/runtime: the operators of an object the program defines; this producer has none, but the runtime needs it).
  std::ostringstream uc;
  uc << "(function \"mrbbc_user_call\" (ret void) (params (param %0 \"id\" int)"
     << " (param %1 \"ret\" (ptr (struct \"MV\"))) (param %2 \"argv\" (ptr (struct \"MV\")))"
     << " (param %3 \"blk\" (ptr (struct \"MV\"))) (param %4 \"argc\" long))\n";
  for (std::size_t m = 0; m < methods_.size(); ++m) {
    const std::string hit = "%" + std::to_string(5 + 2 * m);
    uc << "  (let " << hit << " bool (eq int %0 (const int " << m << ")))\n";
    uc << "  (if " << hit << " (then (eval (call void &\"mrb_m" << m << "\" %1 %2 %3 %4 (const long 0)))))\n";
  }
  uc << "  (return))\n";
  return uc.str();
}

std::string Lowerer::run(const std::string &source_name) {
  const Iseq &root = mod_.iseqs[mod_.root];
  if (root.type != IseqType::Top && root.type != IseqType::Main) {
    throw Refused("refused: the program is not a top-level iseq (" + root.label + ")");
  }
  // the methods: every definemethod of the top level, numbered in order (a method defined twice is two numbers)
  for (const Insn &in : root.insns) {
    if (in.name != "definemethod") continue;
    if (in.operands[1] == ~0ull) refuse("a def with no body is not lowered yet", in);
    const std::size_t child = static_cast<std::size_t>(in.operands[1]);
    defined_.insert(symbol_of(in, 0));
    if (method_no_.count(child) == 0) {
      method_no_[child] = static_cast<int>(methods_.size());
      methods_.push_back(child);
    }
  }
  lower_function(root, "mrb_irep_0", false);
  for (std::size_t m = 0; m < methods_.size(); ++m) {
    lower_function(mod_.iseqs[methods_[m]], "mrb_m" + std::to_string(m), true);
  }
  functions_ << user_call();

  std::ostringstream out;
  out << "(ir-module \"" << source_name
      << "\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4) (double 8) (long_double 16)))\n";
  out << "(producer \"ruby-3.3\")\n";
  out << "(abi-type \"MV\" 16 8 (memory))\n";
  out << syms_.data.str();
  out << functions_.str();
  return out.str();
}

}  // namespace

std::string lower_module(const Module &module, const std::string &source_name) {
  Lowerer l(module);
  return l.run(source_name);
}

}  // namespace yarvbc
