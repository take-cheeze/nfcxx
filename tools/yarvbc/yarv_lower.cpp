// Ruby 3.3 YARV bytecode -> Path B IR text (tools/yarvbc/yarv_lower.hpp). The first subset: integers, nil, true and false,
// local variables of the top level and of a method, the integer operators and comparisons, branches and while loops, and
// calls of the methods the program defines at the top level with def (positional arguments, recursion). The second: a
// block literal (a `send` with a block iseq) passed to a method the program defines, which yields to it (`yield` with
// arguments, `block_given?`), and `Integer#times` with a block. A block reads and writes the locals of the frame it is made
// in (level 1). Everything else is refused with a named message (yarv::Refused).
//
// Blocks: a block is the function mrb_b<N>(ret, argv, argc, outer): argv[0..argc-1] are the arguments, outer is the frame of
// the function the block literal is in (its locals are the level-1 locals). `Integer#times` calls the block's function
// directly in a loop with the receiver's count. A block passed to a method is a closure (mrbbc_block, the runtime's Clo of
// tests/mrbbc/runtime, in a slot of the creator's frame) whose id is the block's number; `yield` in the method calls
// the function of that number (mrbbc_blk_id, mrbbc_blk_frame). A block is only ever called while its creator's frame is
// alive (it cannot be stored: &blk, proc and lambda are refused). A block that leaves early (`next` with or without a
// value, which compiles to a `leave` before the block's end) is refused, and so are a block in a block, `yield` and
// `block_given?` in a block, `break` (a throw) and the redo/next catch table.
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
#include "../common/stack_slots.hpp"
#include "yarv_lower.hpp"

#include <cstdint>
#include <cstdio>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <utility>
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
constexpr int kTagNil = 0, kTagFalse = 1, kTagTrue = 2, kTagInt = 3, kTagBlk = 7;
// The closure slot of a block value (the runtime's MRBBC_CLO_BYTES: a Clo of tests/mrbbc/runtime/mrbrt.c).
constexpr std::size_t kCloBytes = 192;
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
// bit 7 (ambiguous_param0): a block with one required parameter and no comma (`|x|`), which only stops an array argument
// from being splatted; nothing here is an array, so a block takes it as lowered
constexpr std::uint64_t kParamAmbiguous0 = 1u << 7;

enum class Origin : std::uint8_t { Value, Self };
using Stack = std::vector<Origin>;

// What a function is: the top level, a method (with a block parameter) or a block (argv and an outer frame).
enum class Kind : std::uint8_t { Top, Method, Block };

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
  std::string stack(std::size_t d) const { return slot(stack_slots::slot(nlocals, d)); }
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

// A stack's entries as the shared walk keeps them: the depth, and each entry's origin as its ctx.
stack_slots::State state_of(const Stack &st) {
  stack_slots::State s;
  s.depth = st.size();
  for (Origin o : st) s.ctx.push_back(static_cast<std::int64_t>(o));
  return s;
}
Stack stack_of(const stack_slots::State &s) {
  Stack st;
  for (std::int64_t v : s.ctx) st.push_back(static_cast<Origin>(v));
  return st;
}

class Lowerer {
 public:
  explicit Lowerer(const Module &m) : mod_(m) {}

  std::string run(const std::string &source_name);

 private:
  const Module &mod_;
  std::set<std::string> defined_;              // the names the program defines with def (definemethod, at the top level)
  std::vector<std::size_t> methods_;           // the method iseqs by number
  std::map<std::size_t, int> method_no_;       // a method iseq -> its number
  std::vector<std::size_t> blocks_;            // the block iseqs by number (the functions mrb_b<N>)
  std::map<const Iseq *, int> block_no_;       // a block iseq -> its number
  std::map<const Iseq *, std::size_t> outer_locals_;  // a block iseq -> the local count of the iseq it is made in
  Symbols syms_;
  std::ostringstream functions_;

  const std::string &symbol_of(const Insn &in, std::uint64_t operand) const {
    const Value &v = mod_.object(in.operands[operand]);
    if (v.kind != Value::Kind::Symbol) throw ReadError("malformed: a method name is not a symbol (pc " + std::to_string(in.pc) + ")");
    return v.s;
  }

  // The block literal of a send (its block iseq), or none.
  static bool has_block(const Insn &in) { return in.name == "send" && in.operands[1] != ~0ull; }
  // `Integer#times` with a block, on an explicit receiver the program does not define times for (lowered as a loop).
  bool is_times(const Insn &in, const CallInfo &ci) const {
    return has_block(in) && ci.mid == "times" && ci.argc == 0 && (ci.flag & (kCallFcall | kCallVcall)) == 0 &&
           defined_.count("times") == 0;
  }
  // `block_given?`, a self call with no arguments that the program does not define.
  bool is_block_given(const Insn &in, const CallInfo &ci) const {
    return in.name == "opt_send_without_block" && ci.mid == "block_given?" && ci.argc == 0 && (ci.flag & kCallFcall) != 0 &&
           defined_.count("block_given?") == 0;
  }
  // The block number of a send's block literal.
  int block_number(const Insn &in) const { return block_no_.at(&mod_.iseqs[static_cast<std::size_t>(in.operands[1])]); }

  // Numbers the block literals of a function (its sends with a block iseq).
  void collect_blocks(const Iseq &is);

  // The stack after one instruction, and the pcs it may go to next. Refuses what the producer does not lower.
  std::vector<std::size_t> step(const Iseq &is, const Insn &in, Stack &st) const;
  stack_slots::Flow analyze(const Iseq &is) const;
  void call_checks(const Insn &in, const CallInfo &ci) const;

  void lower_function(const Iseq &is, const std::string &name, Kind kind);
  void emit(Fn &f, const Iseq &is, const Insn &in, std::size_t depth);
  void emit_send(Fn &f, const Insn &in, std::size_t depth, const CallInfo &ci);
  void emit_times(Fn &f, const Insn &in, std::size_t depth);
  void emit_yield(Fn &f, const Insn &in, std::size_t depth, const CallInfo &ci);
  std::string user_call() const;
  void check_params(const Iseq &is, Kind kind) const;
};

void Lowerer::collect_blocks(const Iseq &is) {
  for (const Insn &in : is.insns) {
    if (!has_block(in)) continue;
    const std::size_t child = static_cast<std::size_t>(in.operands[1]);
    if (child >= mod_.iseqs.size() || mod_.iseqs[child].type != IseqType::Block) {
      throw ReadError("malformed: the block of a send at pc " + std::to_string(in.pc) + " is not a block");
    }
    const Iseq *b = &mod_.iseqs[child];
    if (block_no_.count(b) == 0) {
      block_no_[b] = static_cast<int>(blocks_.size());
      blocks_.push_back(child);
      outer_locals_[b] = is.locals.size();
    }
  }
}

// Each stack state must be a single Origin shape where paths meet: a value and self may not meet at one slot.
stack_slots::Flow Lowerer::analyze(const Iseq &is) const {
  const std::vector<Insn> &insns = is.insns;
  std::map<std::size_t, std::size_t> index;  // pc -> instruction index
  for (std::size_t i = 0; i < insns.size(); ++i) index[insns[i].pc] = i;
  if (insns.empty()) return {};
  // The successors of one instruction on a path: the same stack goes to each (step has pushed or popped already).
  auto transfer = [&](std::size_t pc, const stack_slots::State &in) {
    const Insn &insn = insns[index.at(pc)];
    Stack st = stack_of(in);
    stack_slots::Step out;
    out.high = in.depth;
    for (std::size_t target : step(is, insn, st)) {
      if (index.find(target) == index.end()) {
        throw ReadError("malformed: the jump at pc " + std::to_string(insn.pc) + " goes to pc " + std::to_string(target) +
                        ", which is not an instruction");
      }
      out.succ.push_back({target, state_of(st)});
    }
    return out;
  };
  stack_slots::Flow flow = stack_slots::analyze(insns[0].pc, transfer);
  if (flow.join) {
    if (flow.join->depth_differs) {
      throw ReadError("malformed: the stack depth at pc " + std::to_string(flow.join->pc) + " differs between two paths");
    }
    refuse("a value and self meet on the stack (not lowered yet)", insns[index.at(flow.join->from)]);
  }
  return flow;
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
  if (n == "getlocal_WC_0" || n == "setlocal_WC_0" || n == "getlocal_WC_1" || n == "setlocal_WC_1") {
    // the operand is the local's offset from the environment pointer: table index = locals + 2 - operand (vm_core.h's
    // VM_ENV_DATA_SIZE is 3), so the operand is in 3..locals+2; level 1 is the iseq the block is made in
    const bool level1 = n == "getlocal_WC_1" || n == "setlocal_WC_1";
    std::size_t outer = is.locals.size();
    if (level1) {
      auto it = outer_locals_.find(&is);
      if (it == outer_locals_.end()) throw ReadError("malformed: a level-1 local at pc " + std::to_string(in.pc) + " is not in a block");
      outer = it->second;
    }
    const std::uint64_t raw = in.operands[0];
    if (raw < 3 || raw > outer + 2) {
      throw ReadError("malformed: local operand " + std::to_string(raw) + " at pc " + std::to_string(in.pc));
    }
    if (n == "setlocal_WC_0" || n == "setlocal_WC_1") pop_value();
    else push_value();
    return {next};
  }
  if (n == "invokeblock") {
    // yield: the arguments are popped and the block's value pushed. A yield in a block, or at the top level, is refused.
    if (is.type != IseqType::Method) refuse("yield in a block (or outside a method) is not lowered yet", in);
    const CallInfo &ci = is.calls[in.operands[0]];
    call_checks(in, ci);
    const std::size_t argc = static_cast<std::size_t>(ci.argc);
    need(argc);
    for (std::size_t k = 0; k < argc; ++k) {
      if (st[st.size() - argc + k] != Origin::Value) refuse("self is used as an argument", in);
    }
    st.resize(st.size() - argc);
    push_value();
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
    call_checks(in, ci);
    const std::size_t argc = static_cast<std::size_t>(ci.argc);
    if (is_block_given(in, ci)) {
      if (is.type == IseqType::Block) refuse("block_given? in a block is not lowered yet", in);
      need(1);
      if (st.back() != Origin::Self) refuse("block_given? with a receiver is not lowered yet", in);
      st.pop_back();
      push_value();
      return {next};
    }
    if (has_block(in) && is.type == IseqType::Block) refuse("a block in a block is not lowered yet", in);
    if (is_times(in, ci)) {
      pop_value();  // the receiver is a value (self is refused); the result is the receiver itself
      push_value();
      return {next};
    }
    if ((ci.flag & (kCallFcall | kCallVcall)) == 0) refuse("a call with an explicit receiver is not lowered yet", in);
    if (defined_.count(ci.mid) == 0) {
      refuse("a call of '" + ci.mid + "', which the program does not define, is not lowered yet", in);
    }
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
void Lowerer::check_params(const Iseq &is, Kind kind) const {
  if (kind == Kind::Block) {
    // a block's catch table is next or redo (break is a throw, refused by the reader)
    if (is.catch_count != 0) throw Refused("refused: next and redo (a catch table in a block) are not lowered yet");
    if ((is.param_flags & ~(kParamHasLead | kParamAmbiguous0)) != 0) {
      throw Refused("refused: optional, rest, post, keyword and block parameters of a block are not lowered yet");
    }
    if (is.lead_num > is.locals.size()) throw ReadError("malformed: a block has more parameters than locals");
    return;
  }
  if (is.catch_count != 0) throw Refused("refused: rescue and ensure (a catch table) are not lowered yet");
  if (kind == Kind::Method) {
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
  // the block the call gives: a closure of this frame (mrbbc_block: the block's number, a nil self, this frame as the
  // frame the block reads its level-1 locals from); the method's blk parameter is its address
  std::string blk = f.named(nilb);
  if (has_block(in)) {
    const std::string clo = "clo" + tag, blkmv = "blkmv" + tag, selfnil = "selfnil" + tag;
    f.add_slot(clo, kCloBytes);
    f.add_slot(blkmv, 16);
    f.add_slot(selfnil, 16);
    store_tag(f, f.named(selfnil), kTagNil);
    f.line("(eval (call void &\"mrbbc_block\" " + f.named(blkmv) + " " + f.named(clo) + " (const long " +
           num(block_number(in)) + ") " + f.named(selfnil) + " " + f.named("frame") + " " + f.named("frame") + "))");
    blk = f.named(blkmv);
  }
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
           " " + blk + " (const long " + num(static_cast<long long>(argc)) + ") (const long 0)))))");
  }
}

// Integer#times with a block: a loop that calls the block's function with the count 0 .. n-1 (n is the receiver's value, in
// the receiver's slot, which the result is too: times returns its receiver). A receiver that is not an Integer has no times:
// NoMethodError, as mrbbc_no_method raises it.
void Lowerer::emit_times(Fn &f, const Insn &in, std::size_t depth) {
  const std::string tag = std::to_string(in.pc);
  const std::string recv = f.stack(depth - 1);
  const std::string argv = "tv" + tag, ret = "tret" + tag;
  f.add_slot(argv, 16);
  f.add_slot(ret, 16);
  const std::string tg = load_tag(f, recv);
  const std::string isint = tag_is(f, tg, kTagInt);
  const std::string ok = "tint" + tag, top = "tl" + tag, end = "te" + tag;
  f.line("(if " + isint + " (then (goto \"" + ok + "\")))");
  // the message of ruby 3.3 for the receivers that are not integers (nil, true, false: the only other values here)
  const std::pair<int, const char *> others[] = {{kTagNil, "nil"}, {kTagTrue, "true"}, {kTagFalse, "false"}};
  for (const auto &o : others) {
    const std::string hit = tag_is(f, tg, o.first);
    f.line("(if " + hit + " (then (eval (call void &\"mrbbc_raise\" @\"" + syms_.item("NoMethodError") + "\" @\"" +
           syms_.item(std::string("undefined method `times' for ") + o.second) + "\"))))");
  }
  f.line("(eval (call void &\"mrbbc_no_method\" " + recv + " @\"" + syms_.item("times") + "\"))");
  f.line("(label \"" + ok + "\")");
  const std::string n = load_int(f, recv), i = f.fresh();
  f.line("(let " + i + " long (const long 0))");
  f.line("(label \"" + top + "\")");
  const std::string done = f.fresh();
  f.line("(let " + done + " bool (le.s long " + n + " " + i + "))");
  f.line("(if " + done + " (then (goto \"" + end + "\")))");
  store_int(f, f.named(argv), i);
  f.line("(eval (call void &\"mrb_b" + num(block_number(in)) + "\" " + f.named(ret) + " " + f.named(argv) + " (const long 1) " +
         f.named("frame") + "))");
  const std::string next = f.fresh();
  f.line("(let " + next + " long (cadd long " + i + " (const long 1)))");
  f.line("(set " + i + " " + next + ")");
  f.line("(goto \"" + top + "\")");
  f.line("(label \"" + end + "\")");
}

// yield: the arguments go to a vector, the method's block (blk, the %2 parameter) must be a block (LocalJumpError as vm.c
// raises it, when it is not), and the block's number picks the function, as a self call's method does.
void Lowerer::emit_yield(Fn &f, const Insn &in, std::size_t depth, const CallInfo &ci) {
  const std::string tag = std::to_string(in.pc);
  const std::size_t argc = static_cast<std::size_t>(ci.argc);
  const std::size_t base = depth - argc;  // the first argument's position, which the result takes
  const std::string argv = "yargv" + tag;
  f.add_slot(argv, 16 * (argc == 0 ? 1 : argc));
  for (std::size_t i = 0; i < argc; ++i) {
    const std::string p = f.fresh();
    f.line("(let " + p + " (ptr unsigned_char) (offset " + f.named(argv) + " " + num(static_cast<long long>(16 * i)) + "))");
    copy16(f, p, f.stack(base + i));
  }
  const std::string isblk = tag_is(f, load_tag(f, "%2"), kTagBlk), ok = "yok" + tag;
  f.line("(if " + isblk + " (then (goto \"" + ok + "\")))");
  f.line("(eval (call void &\"mrbbc_raise\" @\"" + syms_.item("LocalJumpError") + "\" @\"" + syms_.item("no block given (yield)") +
         "\"))");
  f.line("(label \"" + ok + "\")");
  const std::string id = f.fresh(), fr = f.fresh();
  f.line("(let " + id + " long (call long &\"mrbbc_blk_id\" %2))");
  f.line("(let " + fr + " (ptr unsigned_char) (call (ptr unsigned_char) &\"mrbbc_blk_frame\" %2))");
  for (std::size_t m = 0; m < blocks_.size(); ++m) {
    const std::string hit = f.fresh();
    f.line("(let " + hit + " bool (eq long " + id + " (const long " + num(static_cast<long long>(m)) + ")))");
    f.line("(if " + hit + " (then (eval (call void &\"mrb_b" + std::to_string(m) + "\" " + f.stack(base) + " " + f.named(argv) +
           " (const long " + num(static_cast<long long>(argc)) + ") " + fr + "))))");
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
  } else if (n == "getlocal_WC_1" || n == "setlocal_WC_1") {
    // the block's level-1 local: a slot of the frame the block was made in (%3, the outer parameter)
    const std::size_t k = outer_locals_.at(&is) + 2 - static_cast<std::size_t>(in.operands[0]);
    const std::string p = f.fresh();
    f.line("(let " + p + " (ptr unsigned_char) (offset %3 " + num(static_cast<long long>(16 * k)) + "))");
    if (n == "getlocal_WC_1") copy16(f, f.stack(depth), p);
    else copy16(f, p, f.stack(depth - 1));
  } else if (n == "invokeblock") {
    emit_yield(f, in, depth, is.calls[in.operands[0]]);
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
    const CallInfo &ci = is.calls[in.operands[0]];
    if (is_block_given(in, ci)) {
      // the method's own block (its blk parameter, %2) in a method; false at the top level (the step refused a block)
      if (is.type == IseqType::Method) f.line("(eval (call void &\"mrbbc_blk_given\" " + f.stack(depth - 1) + " %2))");
      else store_tag(f, f.stack(depth - 1), kTagFalse);
    } else if (is_times(in, ci)) {
      emit_times(f, in, depth);
    } else {
      emit_send(f, in, depth, ci);
    }
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

void Lowerer::lower_function(const Iseq &is, const std::string &name, Kind kind) {
  if (kind == Kind::Method && is.type != IseqType::Method) throw Refused("refused: a class body is not lowered yet");
  if (kind == Kind::Block && is.type != IseqType::Block) throw ReadError("malformed: a block's iseq is not a block");
  check_params(is, kind);
  if (kind == Kind::Block) {
    // next (with or without a value) compiles to a leave before the block's end, as the block's own value does at the end:
    // an early leave is not told apart from the value, so such a block is refused
    for (std::size_t i = 0; i + 1 < is.insns.size(); ++i) {
      if (is.insns[i].name == "leave") refuse("a block that returns before its end (next) is not lowered yet", is.insns[i]);
    }
  }
  const stack_slots::Flow flow = analyze(is);
  const std::size_t deepest = is.insns.empty() ? 0 : flow.max_depth + 1;
  const std::size_t nl = is.locals.size();
  Fn f(nl, nl + (deepest == 0 ? 1 : deepest), kind != Kind::Top);

  // a method's parameters are the first locals: argv[1..lead] (mrbbc_find has checked the count); a block's are argv[0..]
  // (the ones the yield gave; the rest are nil). The rest of the locals are nil.
  for (std::size_t i = 0; i < f.frame_slots; ++i) {
    f.line("(let " + f.slot(i) + " (ptr unsigned_char) (offset $\"frame\" " + num(static_cast<long long>(16 * i)) + "))");
  }
  const std::size_t lead = kind == Kind::Top ? 0 : static_cast<std::size_t>(is.lead_num);
  if (kind == Kind::Method) {
    for (std::size_t i = 0; i < lead; ++i) {
      const std::string p = f.fresh();
      f.line("(let " + p + " (ptr unsigned_char) (offset %1 " + num(static_cast<long long>(16 * (i + 1))) + "))");
      copy16(f, f.slot(i), p);
    }
  } else if (kind == Kind::Block) {
    for (std::size_t i = 0; i < lead; ++i) {
      // a parameter the yield gave (i < argc) takes its argument; the others are nil (no array is splatted: there are none)
      const std::string given = f.fresh(), p = f.fresh();
      f.line("(let " + given + " bool (lt.s long (const long " + num(static_cast<long long>(i)) + ") %2))");
      f.line("(if " + given + " (then");
      f.line("(let " + p + " (ptr unsigned_char) (offset %1 " + num(static_cast<long long>(16 * i)) + "))");
      copy16(f, f.slot(i), p);
      f.line(") (else");
      store_tag(f, f.slot(i), kTagNil);
      f.line("))");
    }
  }
  for (std::size_t i = lead; i < nl; ++i) store_tag(f, f.slot(i), kTagNil);

  for (const Insn &in : is.insns) {
    const auto reached = flow.at.find(in.pc);
    if (reached == flow.at.end()) continue;  // dead code: nothing reaches it
    f.line("");
    f.body << "  (label " << lbl(in.pc) << ")\n";
    emit(f, is, in, reached->second.depth);
  }
  f.line("");
  f.body << "  (label " << lbl(is.words) << ")\n";
  f.line("(return)");

  std::ostringstream fn;
  fn << "(function \"" << name << "\" (ret void) (params (param %0 \"ret\" (ptr (struct \"MV\")))";
  if (kind == Kind::Method) {
    fn << " (param %1 \"argv\" (ptr (struct \"MV\"))) (param %2 \"blk\" (ptr (struct \"MV\"))) (param %3 \"argc\" long)"
       << " (param %4 \"kw\" long)";
  } else if (kind == Kind::Block) {
    fn << " (param %1 \"argv\" (ptr (struct \"MV\"))) (param %2 \"argc\" long) (param %3 \"outer\" (ptr (struct \"MV\")))";
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
  // the blocks: the block literals of the top level and of the methods, numbered in order
  collect_blocks(root);
  for (std::size_t m = 0; m < methods_.size(); ++m) collect_blocks(mod_.iseqs[methods_[m]]);
  lower_function(root, "mrb_irep_0", Kind::Top);
  for (std::size_t m = 0; m < methods_.size(); ++m) {
    lower_function(mod_.iseqs[methods_[m]], "mrb_m" + std::to_string(m), Kind::Method);
  }
  for (std::size_t b = 0; b < blocks_.size(); ++b) {
    lower_function(mod_.iseqs[blocks_[b]], "mrb_b" + std::to_string(b), Kind::Block);
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
