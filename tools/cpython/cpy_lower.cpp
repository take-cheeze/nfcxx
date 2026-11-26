// CPython 3.13 .pyc -> Path B mid-level IR text (docs/notes/pathb-stage2.md is the IR; docs/notes/cpython-pathb.md has the
// design). Each code object becomes one IR function `pyf_K(PV *ret, PV *args)`: pyf_0 is the module's code, and the functions
// defined at module level are pyf_1, pyf_2, ... in the order of their definitions.
//
// A PV is 32 bytes: { i64 tag; i64 a; i64 b; i64 c } (tags below). The operand stack and the fast locals are two frame arrays,
// `stk` and `loc`, so the stack depth of an instruction gives a fixed address. The value of an operation is computed by a
// runtime helper (tests/cpython/runtime/pyrt.c), which also raises the Python exception it raises: the IR holds the control
// flow, the frame and the calls, and no integer arithmetic of its own.
//
// Stack entries have a kind that is known at lowering time: a value (Val), the NULL that CALL expects, a function object
// (Func, which is a module-level def bound to one name), the builtin range (Range), an iterator that is range()'s
// (Iter), and a code object waiting for MAKE_FUNCTION (Code). A Func or Range entry can only be called, so a function used as
// a value is refused. Labels are the byte offsets of the instructions; every jump is a goto.
#include "cpy_lower.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "cpy_opcodes.inc"   // kCpyOps: 3.13's opcode numbers, names, inline cache sizes and relative jumps

namespace cpy {

namespace {

constexpr int kTagUnbound = 0, kTagInt = 1, kTagBool = 2, kTagNone = 3, kTagFunc = 4;
constexpr int kPvBytes = 32;
constexpr std::int64_t kConstLimit = std::int64_t{1} << 62;   // integer constants the runtime represents exactly
// co_flags (CO_*) and co_localspluskinds (CO_FAST_*) bits (cpython/code.h, Include/cpython/code.h)
constexpr int kCoVarargs = 0x04, kCoVarkeywords = 0x08, kCoGenerator = 0x20, kCoCoroutine = 0x80,
              kCoIterableCoroutine = 0x100, kCoAsyncGenerator = 0x200;
constexpr int kFastHidden = 0x10, kFastLocal = 0x20, kFastCell = 0x40, kFastFree = 0x80;

[[noreturn]] void refuse(const std::string &what) { throw std::runtime_error("refused: " + what); }

// The opcode of a name, or -1 (the table is indexed by number, so the number is found once).
int opnum(const char *name) {
  for (int i = 0; i < kCpyNumOpcodes; ++i) {
    if (kCpyOps[i].name && std::string(kCpyOps[i].name) == name) return i;
  }
  return -1;
}

bool valid_ident(const std::string &s) {
  if (s.empty()) return false;
  for (std::size_t k = 0; k < s.size(); ++k) {
    unsigned char c = static_cast<unsigned char>(s[k]);
    bool alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
    bool digit = c >= '0' && c <= '9';
    if (!(alpha || (k > 0 && digit))) return false;
  }
  return true;
}

// Escapes a string for an IR (string "...") literal, the way lua54_lower does.
std::string ir_escape(const std::string &s) {
  std::string out;
  char buf[8];
  for (unsigned char ch : s) {
    if (ch == '"' || ch == '\\') {
      out += '\\';
      out += static_cast<char>(ch);
    } else if (ch >= 0x20 && ch < 0x7f) {
      out += static_cast<char>(ch);
    } else {
      std::snprintf(buf, sizeof buf, "\\%03o", ch);
      out += buf;
    }
  }
  return out;
}

// One instruction: `start` is the first code unit (an EXTENDED_ARG prefix, if any), `op_off` the opcode's unit, and `next`
// the unit after the instruction and its inline caches (the base of relative jumps, and the fall-through).
struct Insn {
  std::size_t start = 0, op_off = 0, next = 0;
  int op = 0;
  std::string name;
  int arg = 0;
};

Insn decode(const Code &c, std::size_t start) {
  const std::string &code = c.code;
  int arg = 0;
  std::size_t off = start;
  static const int kExtArg = opnum("EXTENDED_ARG");
  for (;;) {
    if (off + 1 >= code.size()) throw std::runtime_error("pyc: the code ends inside an instruction");
    int op = static_cast<unsigned char>(code[off]);
    arg = (arg << 8) | static_cast<unsigned char>(code[off + 1]);
    if (op == kExtArg) {
      off += 2;
      continue;
    }
    const char *nm = (op < kCpyNumOpcodes) ? kCpyOps[op].name : nullptr;
    if (!nm) throw std::runtime_error("pyc: opcode " + std::to_string(op) + " is not a CPython 3.13 opcode");
    Insn in;
    in.start = start;
    in.op_off = off;
    in.op = op;
    in.name = nm;
    in.arg = arg;
    in.next = off + 2 + 2 * static_cast<std::size_t>(kCpyOps[op].caches);
    return in;
  }
}

// Every instruction of the code, in order (the caches are skipped): for the pre-pass over the module's text.
std::vector<Insn> linear(const Code &c) {
  std::vector<Insn> out;
  std::size_t start = 0;
  while (start < c.code.size()) {
    Insn in = decode(c, start);
    out.push_back(in);
    start = in.next;
  }
  return out;
}

// The offset a relative jump goes to: forward from `next`, or backward (JUMP_BACKWARD*) from it.
std::size_t jump_target(const Insn &in) {
  bool back = in.name.rfind("JUMP_BACKWARD", 0) == 0;
  std::int64_t t = static_cast<std::int64_t>(in.next) + (back ? -2 : 2) * static_cast<std::int64_t>(in.arg);
  if (t < 0) throw std::runtime_error("pyc: a jump goes before the start of the code");
  return static_cast<std::size_t>(t);
}

// The kind of a stack entry at lowering time (see the header comment).
struct Kind {
  enum K { Val, Null, Func, Range, Iter, Code } k = Val;
  int idx = 0;   // Func: the function index; Code: the index into co_consts
  bool operator==(const Kind &o) const { return k == o.k && idx == o.idx; }
};
using Stack = std::vector<Kind>;

const char *kind_name(const Kind &k) {
  switch (k.k) {
    case Kind::Val: return "a value";
    case Kind::Null: return "the NULL of a call";
    case Kind::Func: return "a function object";
    case Kind::Range: return "the builtin range";
    case Kind::Iter: return "a range iterator";
    case Kind::Code: return "a code object";
  }
  return "?";
}

// What the whole module needs, shared by the functions.
struct Module {
  std::vector<const Code *> fns;                 // fns[k] is pyf_k's code; fns[0] is the module
  std::map<const Code *, int> fn_of;             // code object -> its index (defs only)
  std::vector<std::string> def_name;             // per fn: the name its def binds ("" for the module)
  std::map<std::string, int> def_of;             // a def's name -> its index, when the name is bound once
  std::map<std::string, int> stores;             // name -> the number of STORE_NAME/STORE_GLOBAL to it
  std::set<std::string> globals;                 // the names that get a global object
  std::map<std::string, std::string> str_sym;    // name text -> the data item holding it
  std::vector<std::string> data;                 // data items (strings)
  int nstr = 0;

  std::string str(const std::string &text) {
    auto it = str_sym.find(text);
    if (it != str_sym.end()) return it->second;
    std::string sym = "pystr_" + std::to_string(nstr++);
    str_sym[text] = sym;
    data.push_back("(data \"" + sym + "\" (const (array " + std::to_string(text.size() + 1) + " (const char))) (string \"" +
                   ir_escape(text) + "\\000\"))\n");
    return sym;
  }
};

// The name of a global object's symbol: pyg_NAME (the driver reads pyg_result).
std::string gsym(const std::string &name) { return "pyg_" + name; }

// What a code object must look like to be lowered at all: a plain function or the module. Refused before anything is
// lowered, so the reason is the construct's and not a call site's (a call to a *args function is refused here).
void check_code(const Code &c, int k) {
  auto refuse_in = [&](const std::string &what) {
    refuse(what + " (in " + (k == 0 ? std::string("the module") : "function " + c.name) + ")");
  };
  if (c.flags & (kCoVarargs | kCoVarkeywords)) refuse_in("*args or **kwargs (CO_VARARGS/CO_VARKEYWORDS) not lowered yet");
  if (c.flags & (kCoGenerator | kCoCoroutine | kCoIterableCoroutine | kCoAsyncGenerator)) {
    refuse_in("generator or coroutine not lowered yet");
  }
  if (c.kwonlyargcount != 0) refuse_in("keyword-only parameters not lowered yet");
  if (!c.exctable.empty()) refuse_in("exception table (a try, with or inlined comprehension region) not lowered yet");
  if (static_cast<std::size_t>(c.argcount) > c.localsplusnames.size()) refuse_in("malformed parameter list");
  for (std::size_t i = 0; i < c.localspluskinds.size(); ++i) {
    int kind = static_cast<unsigned char>(c.localspluskinds[i]);
    if (kind & (kFastCell | kFastFree)) refuse_in("closure (a cell or free variable) not lowered yet");
    if (kind & kFastHidden) refuse_in("comprehension (a hidden local) not lowered yet");
    if (!(kind & kFastLocal)) refuse_in("local of an unknown kind not lowered yet");
    if (!valid_ident(c.localsplusnames[i])) refuse_in("local name '" + c.localsplusnames[i] + "' is not an ASCII identifier");
  }
}

// Lowers one code object to the text of its IR function.
class FnLower {
 public:
  FnLower(Module &m, int k) : m_(m), k_(k), code_(*m.fns[static_cast<std::size_t>(k)]) {}

  std::string lower() {
    in_[0] = Stack{};
    work_.push_back(0);
    while (!work_.empty()) {
      std::size_t s = work_.front();
      work_.pop_front();
      process(s);
    }
    // The frame and the prologue: the stack and locals are slots, the locals are zeroed (UNBOUND), and the arguments are
    // copied into the first locals. The prologue's registers are numbered after the body's.
    std::ostringstream out;
    std::size_t nloc = code_.localsplusnames.size();
    std::size_t stkbytes = (maxdepth_ + 1) * kPvBytes;
    out << "(function \"pyf_" << k_ << "\" (ret void) (params (param %0 \"ret\" (ptr (struct \"PV\"))) (param %1 \"args\" (ptr (struct \"PV\"))))\n";
    out << "  (slot \"loc\" (struct \"PV\") " << std::max<std::size_t>(nloc, 1) * kPvBytes << " 8)\n";
    out << "  (slot \"stk\" (struct \"PV\") " << stkbytes << " 8)\n";
    out << "  (slot \"tmp\" (struct \"PV\") " << kPvBytes << " 8)\n";
    out << "  (let %2 (ptr (struct \"PV\")) $\"stk\")\n";
    out << "  (let %3 (ptr (struct \"PV\")) $\"loc\")\n";
    out << "  (let %4 (ptr (struct \"PV\")) $\"tmp\")\n";
    out << "  (eval (call void &\"pyrt_init_frame\" %3 (const long " << nloc << ")))\n";
    int argc = k_ == 0 ? 0 : code_.argcount;
    for (int i = 0; i < argc; ++i) {
      std::string dst = reg(), src = reg();
      out << "  (let " << dst << " (ptr (struct \"PV\")) (offset %3 " << i * kPvBytes << "))\n";
      out << "  (let " << src << " (ptr (struct \"PV\")) (offset %1 " << i * kPvBytes << "))\n";
      out << "  (copy " << kPvBytes << " " << dst << " " << src << ")\n";
    }
    for (const auto &b : blocks_) out << b.second;
    out << ")\n";
    return out.str();
  }

 private:
  Module &m_;
  int k_;
  const Code &code_;
  std::map<std::size_t, std::string> blocks_;   // offset -> label and body
  std::map<std::size_t, Stack> in_;             // offset -> the stack when the instruction starts
  std::deque<std::size_t> work_;
  std::string cur_;                             // the body of the instruction being lowered
  int next_reg_ = 5;
  std::size_t maxdepth_ = 0;                    // the deepest stack seen, in entries
  std::size_t at_ = 0;                          // the offset being lowered, for messages

  std::string where() const {
    return std::string(" (in ") + (k_ == 0 ? "the module" : "function " + code_.name) + ", offset " + std::to_string(at_) + ")";
  }
  [[noreturn]] void fail(const std::string &what) const { refuse(what + where()); }

  std::string reg() { return "%" + std::to_string(next_reg_++); }
  void line(const std::string &s) { cur_ += "    " + s + "\n"; }
  std::string stkp(std::size_t d) {
    std::string r = reg();
    line("(let " + r + " (ptr (struct \"PV\")) (offset %2 " + std::to_string(d * kPvBytes) + "))");
    return r;
  }
  std::string locp(int i) {
    std::string r = reg();
    line("(let " + r + " (ptr (struct \"PV\")) (offset %3 " + std::to_string(i * kPvBytes) + "))");
    return r;
  }
  std::string globp(const std::string &name) {
    std::string r = reg();
    line("(let " + r + " (ptr (struct \"PV\")) @\"" + gsym(name) + "\")");
    return r;
  }
  std::string field(const std::string &p, int off) {
    std::string r = reg();
    line("(let " + r + " (ptr long) (offset " + p + " " + std::to_string(off) + "))");
    return r;
  }
  void copy(const std::string &dst, const std::string &src) { line("(copy " + std::to_string(kPvBytes) + " " + dst + " " + src + ")"); }
  void set_tag(const std::string &p, int tag, std::int64_t a) {
    line("(store long " + field(p, 0) + " (const long " + std::to_string(tag) + "))");
    line("(store long " + field(p, 8) + " (const long " + std::to_string(a) + "))");
  }
  void helper(const std::string &name, const std::vector<std::string> &args) {
    std::string call = "(eval (call void &\"" + name + "\"";
    for (const std::string &a : args) call += " " + a;
    line(call + "))");
  }

  // The tag and payload of a constant that the stack or the return value holds (refused for other constants).
  std::pair<int, std::int64_t> constant_pv(const Obj &c) {
    switch (c.kind) {
      case Obj::Kind::Int:
        if (c.big || c.i >= kConstLimit || c.i <= -kConstLimit) fail("integer constant wider than 62 bits not lowered yet");
        return {kTagInt, c.i};
      case Obj::Kind::True: return {kTagBool, 1};
      case Obj::Kind::False: return {kTagBool, 0};
      case Obj::Kind::None: return {kTagNone, 0};
      case Obj::Kind::Str: fail("str constant not lowered yet");
      case Obj::Kind::Bytes: fail("bytes constant not lowered yet");
      case Obj::Kind::Tuple: fail("tuple constant not lowered yet");
      case Obj::Kind::Ellipsis: fail("Ellipsis constant not lowered yet");
      case Obj::Kind::Code: fail("code constant in this position not lowered yet");
      case Obj::Kind::Float: fail("float constant not lowered yet");
      case Obj::Kind::Other:
        switch (c.other) {
          case 'f': case 'g': fail("float constant not lowered yet");
          case 'x': case 'y': fail("complex constant not lowered yet");
          case 'S': fail("StopIteration constant not lowered yet");
          default: fail("constant of this kind not lowered yet");
        }
    }
    fail("constant of an unknown kind");
  }

  // Lowers one instruction at `s` with the stack `st` (updated in place to the fall-through stack). Jump successors go to
  // `jump_to` with `jump_st`; `falls` says the next instruction is a successor.
  void process(std::size_t s) {
    Insn in = decode(code_, s);
    at_ = s;
    Stack st = in_.at(s);
    cur_.clear();
    std::size_t jump_to = 0;
    Stack jump_st;
    bool has_jump = false, falls = true;
    step(in, st, jump_to, jump_st, has_jump, falls);
    blocks_[s] = "  (label \"o" + std::to_string(s) + "\")\n" + cur_;
    if (has_jump) edge(jump_to, jump_st);
    if (falls) edge(in.next, st);
  }

  void edge(std::size_t t, const Stack &st) {
    if (t >= code_.code.size()) fail("a jump leaves the code");
    auto it = in_.find(t);
    if (it == in_.end()) {
      in_[t] = st;
      if (st.size() > maxdepth_) maxdepth_ = st.size();
      work_.push_back(t);
      return;
    }
    if (it->second != st) refuse("stack shape differs where two paths join (offset " + std::to_string(t) + ")");
  }

  Kind pop(Stack &st) {
    if (st.empty()) fail("the stack underflows");
    Kind k = st.back();
    st.pop_back();
    return k;
  }
  // `what` names the use, e.g. "as a binary operator operand": the refusal reads "<kind> <what> not lowered yet".
  void need_val(const Kind &k, const char *what) {
    if (k.k != Kind::Val) fail(std::string(kind_name(k)) + " " + what + " not lowered yet");
  }

  // The name of a global load or store: a def bound once (a Func), or a value. Builtins other than range are refused.
  void load_name(const std::string &name, bool push_null, Stack &st) {
    if (!valid_ident(name)) fail("name '" + name + "' is not an ASCII identifier");
    if (name == "range" && !m_.stores.count("range")) {
      st.push_back(Kind{Kind::Range, 0});
      if (push_null) st.push_back(Kind{Kind::Null, 0});
      return;
    }
    if (!m_.stores.count(name)) fail("name '" + name + "' is never assigned in the module (builtins are not lowered yet)");
    m_.globals.insert(name);
    std::string g = globp(name);
    line("(eval (call void &\"pyrt_check_name\" " + g + " @\"" + m_.str(name) + "\"))");
    auto def = m_.def_of.find(name);
    std::size_t d = st.size();
    if (def != m_.def_of.end()) {
      st.push_back(Kind{Kind::Func, def->second});
    } else {
      std::string dst = stkp(d);
      copy(dst, g);
      st.push_back(Kind{Kind::Val, 0});
    }
    if (push_null) st.push_back(Kind{Kind::Null, 0});
  }

  void store_name(const std::string &name, Stack &st) {
    if (!valid_ident(name)) fail("name '" + name + "' is not an ASCII identifier");
    m_.globals.insert(name);
    Kind top = pop(st);
    std::size_t d = st.size();
    if (top.k == Kind::Val) {
      std::string g = globp(name);
      copy(g, stkp(d));
      return;
    }
    if (top.k == Kind::Func && m_.def_name[static_cast<std::size_t>(top.idx)] == name) {
      std::string g = globp(name);
      set_tag(g, kTagFunc, top.idx);
      return;
    }
    fail("storing " + std::string(kind_name(top)) + " into '" + name + "' not lowered yet");
  }

  void step(const Insn &in, Stack &st, std::size_t &jump_to, Stack &jump_st, bool &has_jump, bool &falls) {
    const std::string &n = in.name;
    int arg = in.arg;
    std::size_t d = st.size();
    if (n == "RESUME" || n == "NOP") return;

    if (n == "LOAD_CONST") {
      const Obj &c = *code_.consts.at(static_cast<std::size_t>(arg));
      if (c.kind == Obj::Kind::Code) {
        st.push_back(Kind{Kind::Code, arg});
        return;
      }
      auto [tag, a] = constant_pv(c);
      std::string p = stkp(d);
      set_tag(p, tag, a);
      st.push_back(Kind{Kind::Val, 0});
      return;
    }
    if (n == "PUSH_NULL") {
      st.push_back(Kind{Kind::Null, 0});
      return;
    }
    if (n == "POP_TOP") {
      pop(st);
      return;
    }
    if (n == "COPY") {
      if (arg < 1 || static_cast<std::size_t>(arg) > d) fail("COPY past the stack");
      Kind src = st[d - static_cast<std::size_t>(arg)];
      if (src.k == Kind::Iter) fail("copy of a range iterator not lowered yet");
      copy(stkp(d), stkp(d - static_cast<std::size_t>(arg)));
      st.push_back(src);
      return;
    }
    if (n == "SWAP") {
      if (arg < 2 || static_cast<std::size_t>(arg) > d) fail("SWAP past the stack");
      std::size_t other = d - static_cast<std::size_t>(arg);
      std::string a = stkp(d - 1), b = stkp(other), t = reg();
      line("(let " + t + " (ptr (struct \"PV\")) (offset %4 0))");
      copy(t, a);
      copy(a, b);
      copy(b, t);
      std::swap(st[d - 1], st[other]);
      return;
    }
    if (n == "LOAD_FAST" || n == "LOAD_FAST_CHECK") {
      if (static_cast<std::size_t>(arg) >= code_.localsplusnames.size()) fail("local index out of range");
      if (n == "LOAD_FAST_CHECK") {
        line("(eval (call void &\"pyrt_check_local\" " + locp(arg) + " @\"" + m_.str(code_.localsplusnames[arg]) + "\"))");
      }
      copy(stkp(d), locp(arg));
      st.push_back(Kind{Kind::Val, 0});
      return;
    }
    if (n == "LOAD_FAST_LOAD_FAST") {
      int hi = arg >> 4, lo = arg & 15;
      copy(stkp(d), locp(hi));
      st.push_back(Kind{Kind::Val, 0});
      copy(stkp(d + 1), locp(lo));
      st.push_back(Kind{Kind::Val, 0});
      return;
    }
    if (n == "STORE_FAST") {
      Kind top = pop(st);
      if (top.k != Kind::Val) fail("storing " + std::string(kind_name(top)) + " in a local not lowered yet");
      copy(locp(arg), stkp(d - 1));
      return;
    }
    if (n == "STORE_FAST_LOAD_FAST") {
      Kind top = pop(st);
      if (top.k != Kind::Val) fail("storing " + std::string(kind_name(top)) + " in a local not lowered yet");
      copy(locp(arg >> 4), stkp(d - 1));
      copy(stkp(d - 1), locp(arg & 15));
      st.push_back(Kind{Kind::Val, 0});
      return;
    }
    if (n == "STORE_FAST_STORE_FAST") {
      Kind top = pop(st);
      Kind next = pop(st);
      if (top.k != Kind::Val || next.k != Kind::Val) fail("storing a non-value in a local not lowered yet");
      copy(locp(arg >> 4), stkp(d - 1));
      copy(locp(arg & 15), stkp(d - 2));
      return;
    }
    if (n == "LOAD_NAME") {
      load_name(code_.names.at(static_cast<std::size_t>(arg)), false, st);
      return;
    }
    if (n == "LOAD_GLOBAL") {
      load_name(code_.names.at(static_cast<std::size_t>(arg >> 1)), (arg & 1) != 0, st);
      return;
    }
    if (n == "STORE_NAME" || n == "STORE_GLOBAL") {
      store_name(code_.names.at(static_cast<std::size_t>(arg)), st);
      return;
    }
    if (n == "MAKE_FUNCTION") {
      if (k_ != 0) fail("a def inside a function (a closure or nested function) not lowered yet");
      Kind top = pop(st);
      if (top.k != Kind::Code) fail("MAKE_FUNCTION of " + std::string(kind_name(top)) + " not lowered yet");
      const Code *c = code_.consts.at(static_cast<std::size_t>(top.idx))->code.get();
      auto it = m_.fn_of.find(c);
      if (it == m_.fn_of.end()) fail("a function object that is not bound by a def not lowered yet");
      st.push_back(Kind{Kind::Func, it->second});
      return;
    }
    if (n == "SET_FUNCTION_ATTRIBUTE") fail("function attributes (defaults, annotations, closures) not lowered yet");

    if (n == "BINARY_OP") {
      int op = arg >= 13 ? arg - 13 : arg;   // the in-place forms (+=, ...) compute the same value
      int rt = -1;
      switch (op) {
        case 0: rt = 0; break;   // +
        case 10: rt = 1; break;  // -
        case 5: rt = 2; break;   // *
        case 2: rt = 3; break;   // //
        case 6: rt = 4; break;   // %
        default: break;
      }
      if (rt < 0) fail("binary operator (NB_* " + std::to_string(arg) + ") not lowered yet");
      if (d < 2) fail("BINARY_OP past the stack");
      need_val(st[d - 2], "as a binary operator operand");
      need_val(st[d - 1], "as a binary operator operand");
      std::string dst = stkp(d - 2), a = stkp(d - 2), b = stkp(d - 1);
      helper("pyrt_binop", {"(const long " + std::to_string(rt) + ")", dst, a, b});
      pop(st);
      return;
    }
    if (n == "COMPARE_OP") {
      int cmp = arg >> 5;
      if (cmp > 5) fail("comparison " + std::to_string(cmp) + " not lowered yet");
      if (d < 2) fail("COMPARE_OP past the stack");
      need_val(st[d - 2], "as a comparison operand");
      need_val(st[d - 1], "as a comparison operand");
      std::string dst = stkp(d - 2), a = stkp(d - 2), b = stkp(d - 1);
      helper("pyrt_cmp", {"(const long " + std::to_string(cmp) + ")", dst, a, b});
      pop(st);
      return;
    }
    if (n == "UNARY_NEGATIVE" || n == "UNARY_NOT" || n == "TO_BOOL") {
      if (d < 1) fail(n + " past the stack");
      need_val(st[d - 1], "as an operand of a unary operator");
      int op = n == "UNARY_NEGATIVE" ? 0 : n == "UNARY_NOT" ? 1 : 2;
      std::string p = stkp(d - 1);
      helper("pyrt_unop", {"(const long " + std::to_string(op) + ")", p, p});
      return;
    }
    if (n == "POP_JUMP_IF_FALSE" || n == "POP_JUMP_IF_TRUE") {
      Kind top = pop(st);
      if (top.k != Kind::Val) fail("branch on " + std::string(kind_name(top)) + " not lowered yet");
      std::string c = reg(), b = reg();
      line("(let " + c + " int (call int &\"pyrt_truth\" " + stkp(d - 1) + "))");
      line("(let " + b + " bool (" + std::string(n == "POP_JUMP_IF_TRUE" ? "ne" : "eq") + " int " + c + " (const int 0)))");
      line("(if " + b + " (then (goto \"o" + std::to_string(jump_target(in)) + "\")))");
      jump_to = jump_target(in);
      jump_st = st;
      has_jump = true;
      return;
    }
    if (n == "POP_JUMP_IF_NONE" || n == "POP_JUMP_IF_NOT_NONE") {
      Kind top = pop(st);
      if (top.k != Kind::Val) fail("branch on " + std::string(kind_name(top)) + " not lowered yet");
      std::string tag = field(stkp(d - 1), 0), v = reg(), b = reg();
      line("(let " + v + " long (load long " + tag + "))");
      line("(let " + b + " bool (" + std::string(n == "POP_JUMP_IF_NONE" ? "eq" : "ne") + " long " + v + " (const long " +
           std::to_string(kTagNone) + ")))");
      line("(if " + b + " (then (goto \"o" + std::to_string(jump_target(in)) + "\")))");
      jump_to = jump_target(in);
      jump_st = st;
      has_jump = true;
      return;
    }
    if (n == "JUMP_FORWARD" || n == "JUMP_BACKWARD" || n == "JUMP_BACKWARD_NO_INTERRUPT") {
      line("(goto \"o" + std::to_string(jump_target(in)) + "\")");
      jump_to = jump_target(in);
      jump_st = st;
      has_jump = true;
      falls = false;
      return;
    }
    if (n == "RETURN_VALUE") {
      Kind top = pop(st);
      if (top.k != Kind::Val) fail("return of " + std::string(kind_name(top)) + " not lowered yet");
      copy("%0", stkp(d - 1));
      line("(return)");
      falls = false;
      return;
    }
    if (n == "RETURN_CONST") {
      auto [tag, a] = constant_pv(*code_.consts.at(static_cast<std::size_t>(arg)));
      set_tag("%0", tag, a);
      line("(return)");
      falls = false;
      return;
    }
    if (n == "CALL") {
      if (arg < 0 || d < static_cast<std::size_t>(arg) + 2) fail("CALL past the stack");
      std::size_t base = d - static_cast<std::size_t>(arg) - 2;
      Kind callee = st[base], self = st[base + 1];
      if (self.k != Kind::Null) fail("a method call (an object as self) not lowered yet");
      for (std::size_t i = base + 2; i < d; ++i) need_val(st[i], "as a call argument");
      if (callee.k == Kind::Func) {
        const Code *c = m_.fns[static_cast<std::size_t>(callee.idx)];
        if (c->argcount != arg) {
          fail("call with " + std::to_string(arg) + " arguments to a function of " + std::to_string(c->argcount) +
               " parameter(s) not lowered yet");
        }
        std::string ret = stkp(base), argp = stkp(base + 2);
        line("(eval (call void &\"pyf_" + std::to_string(callee.idx) + "\" " + ret + " " + argp + "))");
      } else if (callee.k == Kind::Range) {
        if (arg < 1 || arg > 3) fail("range() with " + std::to_string(arg) + " arguments not lowered yet");
        std::string ret = stkp(base), argp = stkp(base + 2);
        helper("pyrt_range", {ret, "(const long " + std::to_string(arg) + ")", argp});
        st.resize(base);
        st.push_back(Kind{Kind::Iter, 0});
        return;
      } else {
        fail("call of " + std::string(kind_name(callee)) + " not lowered yet (only a def or range())");
      }
      st.resize(base);
      st.push_back(Kind{Kind::Val, 0});
      return;
    }
    if (n == "GET_ITER") {
      if (d < 1 || st.back().k != Kind::Iter) fail("iteration over something other than range() not lowered yet");
      return;
    }
    if (n == "FOR_ITER") {
      if (d < 1 || st.back().k != Kind::Iter) fail("iteration over something other than range() not lowered yet");
      std::string r = reg(), ex = reg();
      line("(let " + r + " int (call int &\"pyrt_for_iter\" " + stkp(d - 1) + " " + stkp(d) + "))");
      line("(let " + ex + " bool (eq int " + r + " (const int 0)))");
      std::size_t target = jump_target(in);
      line("(if " + ex + " (then (goto \"o" + std::to_string(target) + "\")))");
      // Exhausted: the target sees one dummy entry more (END_FOR pops it), as dis.stack_effect gives for FOR_ITER's jump.
      jump_to = target;
      jump_st = st;
      jump_st.push_back(Kind{Kind::Null, 0});
      has_jump = true;
      st.push_back(Kind{Kind::Val, 0});
      return;
    }
    if (n == "END_FOR") {
      pop(st);
      return;
    }
    fail(opcode_reason(n) + " not lowered yet");
  }

  // The refusal's name for an opcode, by the construct it belongs to.
  static std::string opcode_reason(const std::string &n) {
    auto starts = [&](const char *p) { return n.rfind(p, 0) == 0; };
    if (n == "RETURN_GENERATOR" || n == "YIELD_VALUE" || n == "SEND" || n == "END_SEND" || n == "GET_AWAITABLE" ||
        n == "GET_YIELD_FROM_ITER") {
      return "generator (" + n + ")";
    }
    if (n == "LOAD_BUILD_CLASS") return "class definition (" + n + ")";
    if (n == "IMPORT_NAME" || n == "IMPORT_FROM") return "import (" + n + ")";
    if (n == "FORMAT_SIMPLE" || n == "FORMAT_WITH_SPEC" || n == "BUILD_STRING" || n == "CONVERT_VALUE") {
      return "f-string (" + n + ")";
    }
    if (n == "LOAD_FAST_AND_CLEAR" || n == "STORE_FAST_MAYBE_NULL" || n == "LIST_APPEND" || n == "MAP_ADD" ||
        n == "SET_ADD") {
      return "comprehension (" + n + ")";
    }
    if (n == "BUILD_LIST" || n == "LIST_EXTEND" || n == "BUILD_MAP" || n == "BUILD_SET" || n == "BUILD_CONST_KEY_MAP") {
      return "list, dict or set display (" + n + ")";
    }
    if (n == "MAKE_CELL" || n == "COPY_FREE_VARS" || starts("LOAD_DEREF") || starts("STORE_DEREF") || n == "LOAD_CLOSURE" ||
        n == "DELETE_DEREF" || n == "LOAD_FROM_DICT_OR_DEREF") {
      return "closure (" + n + ")";
    }
    if (starts("RAISE") || starts("RERAISE") || n == "PUSH_EXC_INFO" || n == "POP_EXCEPT" || n == "CHECK_EXC_MATCH" ||
        n == "WITH_EXCEPT_START" || n == "CHECK_EG_MATCH" || n == "LOAD_ASSERTION_ERROR") {
      return "exception handling (" + n + ")";
    }
    if (n == "CALL_KW" || n == "CALL_FUNCTION_EX" || n == "KW_NAMES") return "keyword or star arguments (" + n + ")";
    if (n == "BUILD_TUPLE" || n == "UNPACK_SEQUENCE" || n == "BUILD_SLICE" || n == "BINARY_SUBSCR" || n == "STORE_SUBSCR" ||
        n == "BINARY_SLICE" || n == "STORE_SLICE" || n == "LOAD_ATTR" || n == "STORE_ATTR" || n == "DELETE_ATTR" ||
        n == "CONTAINS_OP" || n == "IS_OP" || n == "LOAD_SUPER_ATTR") {
      return "opcode " + n;
    }
    if (n == "DELETE_NAME" || n == "DELETE_FAST" || n == "DELETE_GLOBAL") return "del (" + n + ")";
    return "opcode " + n;
  }
};

}  // namespace

std::string lower_module(const Pyc &pyc, const std::string &source_name) {
  Module m;
  m.fns.push_back(pyc.main.get());
  m.def_name.push_back("");
  // Pass 1: the module's defs. A def is LOAD_CONST code, MAKE_FUNCTION, STORE_NAME name in the module's own code. A function
  // object with attributes (defaults, annotations) is refused here: its MAKE_FUNCTION is followed by SET_FUNCTION_ATTRIBUTE.
  std::vector<Insn> top = linear(*pyc.main);
  std::map<std::string, int> def_count;
  bool has_class = false;
  for (const Insn &in : top) has_class = has_class || in.name == "LOAD_BUILD_CLASS";
  for (std::size_t i = 0; i < top.size(); ++i) {
    const Insn &in = top[i];
    if (in.name != "LOAD_CONST" || i + 1 >= top.size() || top[i + 1].name != "MAKE_FUNCTION") continue;
    const Obj &c = *pyc.main->consts.at(static_cast<std::size_t>(in.arg));
    if (c.kind != Obj::Kind::Code) continue;
    if (i + 2 < top.size() && top[i + 2].name == "SET_FUNCTION_ATTRIBUTE") {
      refuse("function attributes (defaults, annotations or closure) not lowered yet");
    }
    int k = static_cast<int>(m.fns.size());
    m.fns.push_back(c.code.get());
    m.fn_of[c.code.get()] = k;
    std::string bound;
    if (i + 2 < top.size() && top[i + 2].name == "STORE_NAME") {
      bound = pyc.main->names.at(static_cast<std::size_t>(top[i + 2].arg));
      def_count[bound] += 1;
    }
    m.def_name.push_back(bound);
  }
  // Pass 2: every store of a name, in the module and in its functions.
  for (std::size_t k = 0; k < m.fns.size(); ++k) {
    for (const Insn &in : linear(*m.fns[k])) {
      if (in.name == "STORE_NAME" || in.name == "STORE_GLOBAL") {
        m.stores[m.fns[k]->names.at(static_cast<std::size_t>(in.arg))] += 1;
      }
    }
  }
  // A def binds its name once; a name a def binds and something else also binds is refused, and so is a def without
  // a name of its own.
  for (std::size_t k = 0; k < m.fns.size(); ++k) check_code(*m.fns[k], static_cast<int>(k));
  for (std::size_t k = 1; k < m.fns.size(); ++k) {
    const std::string &name = m.def_name[k];
    if (name.empty()) {
      if (has_class) refuse("class definition (LOAD_BUILD_CLASS) not lowered yet");
      refuse("a function object that is not bound by a def not lowered yet");
    }
    if (def_count[name] != 1 || m.stores[name] != 1) refuse("function '" + name + "' is bound more than once not lowered yet");
    m.def_of[name] = static_cast<int>(k);
  }

  std::vector<std::string> fn_text;
  for (std::size_t k = 0; k < m.fns.size(); ++k) {
    fn_text.push_back(FnLower(m, static_cast<int>(k)).lower());
  }

  std::ostringstream out;
  out << "(ir-module \"" << source_name << "\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4)"
      << " (double 8) (long_double 16)))\n";
  out << "(producer \"cpython-3.13\")\n";
  out << "(abi-type \"PV\" 32 8 (memory))\n";
  // The name the driver prints is always a global, even when the module never assigns it.
  m.globals.insert("result");
  for (const std::string &g : m.globals) {
    out << "(global \"" << gsym(g) << "\" (struct \"PV\") " << kPvBytes << " 8 (init (zero 0 " << kPvBytes << ")))\n";
  }
  for (const std::string &d : m.data) out << d;
  for (const std::string &f : fn_text) out << "\n" << f;
  return out.str();
}

}  // namespace cpy
