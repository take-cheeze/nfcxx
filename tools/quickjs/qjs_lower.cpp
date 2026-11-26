// QuickJS bytecode -> Path B mid-level IR text (docs/notes/pathb-stage2.md is the IR). Each function of the image becomes
// one IR function `qjf_K(JV *ret, JV *args)`: qjf_0 is the script, and the functions it declares are qjf_1, qjf_2, ... (their
// index in the image). The subset, and what is refused, is in the comments of refuse() call sites and opcode_reason().
//
// A JV is 16 bytes: { long tag; long val }. The operand stack and the locals are two frame arrays, `stk` and `loc`, so the
// stack depth of an instruction gives a fixed address (the depth is found by a walk over the control flow, as the CPython
// producer does). Arithmetic, comparisons and the truth test are runtime helpers (tests/quickjs/runtime/qjrt.c), which also
// decide whether a result is an int32; the IR holds the control flow, the frame and the calls.
//
// Stack entries have a kind known at lowering time: a value (Val), or a function object (Func: a function declaration,
// which is bound to one global name). A Func can only be called or bound to its own name; any other use is refused.
//
// The globals are the `var`s of the script, which the image gives as closure variables of kind GLOBAL_DECL (4) in the
// script, and the function declarations. A closure variable of kind GLOBAL_REF (3) in a function names one of those globals.
// Any other closure variable is a capture of a local, and is refused.
#include "qjs_lower.hpp"

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

#include "qjs_bc.hpp"
#include "qjs_insn.hpp"

namespace qjs {

namespace {

constexpr int kTagUndef = 0, kTagInt = 1, kTagBool = 2, kTagNull = 3, kTagUninit = 4;
constexpr int kJvBytes = 16;
// Operators of the runtime helpers (tests/quickjs/runtime/qjrt.h must agree).
enum Op { kAdd, kSub, kMul, kDiv, kMod, kLt, kLe, kGt, kGe, kEq, kNe, kSeq, kSne };
enum UnOp { kNeg, kPlus, kLnot };
// Closure variable kinds (JSClosureType in quickjs.c).
constexpr int kClosureGlobalRef = 3, kClosureGlobalDecl = 4, kClosureGlobal = 5;
[[noreturn]] void refuse(const std::string &what) { throw std::runtime_error("refused: " + what); }

// The kind of a stack entry at lowering time.
struct Kind {
  enum K { Val, Func } k = Val;
  int idx = 0;   // Func: the function index
  bool operator==(const Kind &o) const { return k == o.k && idx == o.idx; }
};
using Stack = std::vector<Kind>;

const char *kind_name(const Kind &k) { return k.k == Kind::Val ? "a value" : "a function object"; }

// A name is an ASCII identifier: it is used in IR symbols, and in the messages of the runtime.
bool valid_ident(const std::string &s) {
  if (s.empty()) return false;
  for (std::size_t k = 0; k < s.size(); ++k) {
    unsigned char c = static_cast<unsigned char>(s[k]);
    bool alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$';
    bool digit = c >= '0' && c <= '9';
    if (!(alpha || (k > 0 && digit))) return false;
  }
  return true;
}

// Escapes a string for an IR (string "...") literal.
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

// Refusal names for the opcodes that are not lowered, by the construct they belong to. The name is for the message only.
std::string opcode_reason(const std::string &n) {
  auto starts = [&](const char *p) { return n.rfind(p, 0) == 0; };
  if (n == "object" || n == "array_from" || n == "append" || n == "define_array_el" || n == "copy_data_properties" ||
      n == "to_object" || n == "to_propkey" || n == "rest") {
    return "object or array (" + n + ")";
  }
  if (n == "special_object" || n == "push_this") return "arguments, eval, new.target or this (" + n + ")";
  if (starts("get_field") || starts("put_field") || starts("define_field") || starts("get_array_el") ||
      starts("put_array_el") || starts("set_name") || n == "delete" || n == "delete_var" || n == "get_length" ||
      n == "private_in" || starts("get_private") || starts("put_private") || starts("define_private")) {
    return "property access (" + n + ")";
  }
  if (n == "push_empty_string" || n == "push_atom_value" || n == "private_symbol" || n == "typeof" ||
      n == "typeof_is_undefined" || n == "typeof_is_function" || n == "is_undefined_or_null" || n == "is_undefined" ||
      n == "is_null") {
    return "string or type test (" + n + ")";
  }
  if (n == "catch" || n == "gosub" || n == "ret" || n == "nip_catch" || n == "throw" || n == "throw_error") {
    return "try/catch/finally or throw (" + n + ")";
  }
  if (n == "define_class" || n == "define_class_computed" || n == "define_method" || n == "define_method_computed" ||
      n == "set_home_object" || n == "set_proto" || n == "get_super" || n == "get_super_value" ||
      n == "put_super_value" || n == "check_ctor" || n == "check_ctor_return" || n == "init_ctor" || n == "add_brand" ||
      n == "check_brand" || n == "set_class_name") {
    return "class (" + n + ")";
  }
  if (n == "initial_yield" || n == "yield" || n == "yield_star" || n == "async_yield_star" || n == "await" ||
      n == "return_async" || starts("for_await")) {
    return "generator or async function (" + n + ")";
  }
  if (starts("with_")) return "with statement (" + n + ")";
  if (n == "eval" || n == "apply_eval" || n == "apply" || n == "import") return "eval or dynamic call (" + n + ")";
  if (starts("for_in") || starts("for_of") || starts("iterator_")) return "for-in or for-of (" + n + ")";
  if (n == "regexp" || n == "using_dispose_init" || starts("using_")) return "regexp or using (" + n + ")";
  if (n == "call_constructor" || n == "tail_call" || n == "call_method" || n == "tail_call_method") {
    return "method or constructor call (" + n + ")";
  }
  if (n == "get_var_undef" || n == "check_define_var" || n == "define_var" || n == "define_func" ||
      n == "delete_var" || n == "make_var_ref" || n == "make_loc_ref" || n == "make_arg_ref" ||
      n == "make_var_ref_ref" || n == "get_ref_value" || n == "put_ref_value" || n == "scope_get_var") {
    return "global reference or declaration (" + n + ")";
  }
  if (starts("get_var_ref_check") || starts("put_var_ref_check") || n == "get_loc_checkthis" || n == "close_loc") {
    return "closure or this check (" + n + ")";
  }
  if (n == "and" || n == "or" || n == "xor" || n == "not" || n == "shl" || n == "sar" || n == "shr" || n == "pow" ||
      n == "in" || n == "instanceof") {
    return "operator (" + n + ")";
  }
  return "opcode " + n;
}

// The whole image, as the lowering needs it.
struct Module {
  const Bc &bc;
  std::map<std::string, int> def_of;   // a function declaration's global name -> its function index
  std::set<std::string> declared;      // the script's `var` names (closure variables of kind GLOBAL_DECL in fn 0)
  std::set<std::string> lexical;       // the script's `let` names: a global read before its declaration is a ReferenceError
  std::set<std::string> consts;        // the script's `const` names: a store after the declaration is refused
  std::set<std::string> globals;       // the names that get a global JV object (the declared ones that are read or written)
  std::vector<std::string> data;       // data items (names used by the runtime's messages)
  std::map<std::string, std::string> str_sym;
  int nstr = 0;

  explicit Module(const Bc &b) : bc(b) {}

  std::string str(const std::string &text) {
    auto it = str_sym.find(text);
    if (it != str_sym.end()) return it->second;
    std::string sym = "qjs_str_" + std::to_string(nstr++);
    str_sym[text] = sym;
    data.push_back("(data \"" + sym + "\" (const (array " + std::to_string(text.size() + 1) + " (const char))) (string \"" +
                   ir_escape(text) + "\\000\"))\n");
    return sym;
  }
};

// The IR symbol of a global's JV object: qjg_NAME (the driver reads qjg_result).
std::string gsym(const std::string &name) { return "qjg_" + name; }

// The name of a var-ref operand: the closure variable it names in the function.
const std::string &var_ref_name(const Fn &f, std::int64_t idx, const char *op) {
  if (idx < 0 || static_cast<std::size_t>(idx) >= f.closure_vars.size()) {
    throw std::runtime_error(std::string("malformed image: ") + op + " of closure variable " + std::to_string(idx) +
                             " out of range");
  }
  return f.closure_vars[static_cast<std::size_t>(idx)].name;
}

// How a function is named in a message: its name, or its index when it has none (an anonymous function).
std::string fn_label(const Fn &f, std::size_t k) {
  return f.name.empty() ? "anonymous function " + std::to_string(k) : "function " + f.name;
}

// What a function must look like to be lowered at all. Refused before anything is lowered, so the reason is the construct's
// and not a call site's.
void check_fn(const Fn &f, std::size_t k) {
  auto where = [&] { return k == 0 ? std::string("the script") : fn_label(f, k); };
  if (k != 0 && f.func_kind != 0) refuse("generator or async function (" + where() + ")");
  for (const ClosureVar &cv : f.closure_vars) {
    if (cv.closure_type != kClosureGlobalRef && cv.closure_type != kClosureGlobalDecl && cv.closure_type != kClosureGlobal) {
      refuse("closure over a local or argument (closure variable '" + cv.name + "', closure type " +
             std::to_string(cv.closure_type) + ") not lowered yet (in " + where() + ")");
    }
    if (!valid_ident(cv.name)) refuse("name '" + cv.name + "' is not an ASCII identifier (in " + where() + ")");
  }
}

// Decodes every instruction of the code, in order. A jump must land on one of them.
std::vector<Insn> linear(const Fn &f) {
  std::vector<Insn> out;
  std::size_t pc = 0;
  while (pc < f.code.size()) {
    Insn in = decode_insn(f.code, pc);
    out.push_back(in);
    pc = in.next();
  }
  return out;
}

// The binding of a function declaration: fclosure (or fclosure8) of function k, followed by a store of it to the global
// (put_var, put_var_init, put_var_ref*). Recorded in the module before any lowering.
void find_bindings(Module &m, std::size_t k, const Fn &f) {
  std::vector<Insn> ins = linear(f);
  for (std::size_t i = 0; i < ins.size(); ++i) {
    const Insn &in = ins[i];
    if (in.name != "fclosure" && in.name != "fclosure8") continue;
    const Const &c = f.cpool.at(static_cast<std::size_t>(in.arg));
    if (c.kind != Const::Func) continue;
    if (i + 1 >= ins.size()) continue;
    const Insn &st = ins[i + 1];
    bool store = st.name.rfind("put_var", 0) == 0 || st.name.rfind("set_var_ref", 0) == 0;
    if (!store) continue;
    std::string name = var_ref_name(f, st.arg, st.name.c_str());
    auto it = m.def_of.find(name);
    if (it != m.def_of.end()) refuse("function '" + name + "' is declared more than once not lowered yet");
    m.def_of[name] = c.i;
    (void)k;
  }
}

class FnLower {
 public:
  FnLower(Module &m, std::size_t k) : m_(m), k_(k), f_(m.bc.fns[k]) {}

  std::string lower() {
    std::vector<Insn> ins = linear(f_);
    for (const Insn &in : ins) starts_.insert(in.pc);
    for (const Insn &in : ins) {
      if (in.target >= 0 && !starts_.count(static_cast<std::size_t>(in.target))) {
        throw std::runtime_error("malformed image: a jump of " + in.name + " at " + std::to_string(in.pc) +
                                 " lands inside an instruction");
      }
    }
    in_[0] = Stack{};
    work_.push_back(0);
    while (!work_.empty()) {
      std::size_t s = work_.front();
      work_.pop_front();
      process(s);
    }
    std::size_t nloc = static_cast<std::size_t>(f_.var_count);
    std::size_t stkbytes = (maxdepth_ + 1) * kJvBytes;
    std::size_t argvbytes = std::max<std::size_t>(argv_max_, 1) * kJvBytes;
    std::ostringstream out;
    out << "(function \"qjf_" << k_ << "\" (ret void) (params (param %0 \"ret\" (ptr (struct \"JV\"))) (param %1 \"args\" (ptr (struct \"JV\"))))\n";
    out << "  (slot \"loc\" (struct \"JV\") " << std::max<std::size_t>(nloc, 1) * kJvBytes << " 8)\n";
    out << "  (slot \"stk\" (struct \"JV\") " << stkbytes << " 8)\n";
    out << "  (slot \"argv\" (struct \"JV\") " << argvbytes << " 8)\n";
    out << "  (slot \"tmp\" (struct \"JV\") " << kJvBytes << " 8)\n";
    out << "  (let %2 (ptr (struct \"JV\")) $\"stk\")\n";
    out << "  (let %3 (ptr (struct \"JV\")) $\"loc\")\n";
    out << "  (let %4 (ptr (struct \"JV\")) $\"argv\")\n";
    out << "  (let %5 (ptr (struct \"JV\")) $\"tmp\")\n";
    if (nloc > 0) out << "  (zero-fill " << nloc * kJvBytes << " %3)\n";
    for (const auto &b : blocks_) out << b.second;
    out << ")\n";
    return out.str();
  }

 private:
  Module &m_;
  std::size_t k_;
  const Fn &f_;
  std::set<std::size_t> starts_;                 // the offsets of instructions
  std::map<std::size_t, std::string> blocks_;    // offset -> label and body
  std::map<std::size_t, Stack> in_;              // offset -> the stack when the instruction starts
  std::deque<std::size_t> work_;
  std::string cur_;                              // the body of the instruction being lowered
  int next_reg_ = 6;
  std::size_t maxdepth_ = 0;                     // the deepest stack seen, in entries
  std::size_t argv_max_ = 0;                     // the largest argument vector of a call, in entries
  std::size_t at_ = 0;                           // the offset being lowered, for messages

  std::string where() const {
    return std::string(" (in ") + (k_ == 0 ? "the script" : fn_label(f_, k_)) + ", offset " + std::to_string(at_) + ")";
  }
  [[noreturn]] void fail(const std::string &what) const { refuse(what + where()); }

  std::string reg() { return "%" + std::to_string(next_reg_++); }
  void line(const std::string &s) { cur_ += "    " + s + "\n"; }

  // Address of stack entry d, of local i, of argument i, of the argv vector's entry i, and of the global `name`.
  std::string stkp(std::size_t d) {
    std::string r = reg();
    line("(let " + r + " (ptr (struct \"JV\")) (offset %2 " + std::to_string(d * kJvBytes) + "))");
    return r;
  }
  std::string locp(std::int64_t i) {
    std::string r = reg();
    line("(let " + r + " (ptr (struct \"JV\")) (offset %3 " + std::to_string(i * kJvBytes) + "))");
    return r;
  }
  std::string argp(std::int64_t i) {
    std::string r = reg();
    line("(let " + r + " (ptr (struct \"JV\")) (offset %1 " + std::to_string(i * kJvBytes) + "))");
    return r;
  }
  std::string vecp(std::size_t i) {
    std::string r = reg();
    line("(let " + r + " (ptr (struct \"JV\")) (offset %4 " + std::to_string(i * kJvBytes) + "))");
    return r;
  }
  std::string globp(const std::string &name) {
    std::string r = reg();
    line("(let " + r + " (ptr (struct \"JV\")) @\"" + gsym(name) + "\")");
    return r;
  }
  std::string field(const std::string &p, int off) {
    std::string r = reg();
    line("(let " + r + " (ptr long) (offset " + p + " " + std::to_string(off) + "))");
    return r;
  }
  void copy(const std::string &dst, const std::string &src) { line("(copy " + std::to_string(kJvBytes) + " " + dst + " " + src + ")"); }
  void set_tag(const std::string &p, int tag, std::int64_t a) {
    line("(store long " + field(p, 0) + " (const long " + std::to_string(tag) + "))");
    line("(store long " + field(p, 8) + " (const long " + std::to_string(a) + "))");
  }
  void helper(const std::string &name, const std::vector<std::string> &args) {
    std::string call = "(eval (call void &\"" + name + "\"";
    for (const std::string &a : args) call += " " + a;
    line(call + "))");
  }
  std::string ci(std::int64_t v) { return "(const long " + std::to_string(v) + ")"; }

  // The tag and payload of a constant of the pool that the stack holds (refused for the others).
  std::pair<int, std::int64_t> constant_jv(const Const &c) {
    switch (c.kind) {
      case Const::Int: return {kTagInt, c.i};
      case Const::Bool: return {kTagBool, c.i};
      case Const::Undefined: return {kTagUndef, 0};
      case Const::Null: return {kTagNull, 0};
      case Const::Float: fail("a number that is not an int32 constant (the runtime has no doubles yet)");
      case Const::Str: fail("string constant not lowered yet");
      case Const::Func: fail("function constant in this position not lowered yet");
    }
    fail("constant of an unknown kind");
  }

  void process(std::size_t s) {
    Insn in = decode_insn(f_.code, s);
    at_ = s;
    Stack st = in_.at(s);
    cur_.clear();
    std::size_t jump_to = 0;
    Stack jump_st;
    bool has_jump = false, falls = true;
    step(in, st, jump_to, jump_st, has_jump, falls);
    blocks_[s] = "  (label \"o" + std::to_string(s) + "\")\n" + cur_;
    if (has_jump) edge(jump_to, jump_st);
    if (falls) edge(in.next(), st);
  }

  void edge(std::size_t t, const Stack &st) {
    if (t >= f_.code.size()) fail("a jump leaves the code");
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
  Kind peek(const Stack &st) {
    if (st.empty()) fail("the stack underflows");
    return st.back();
  }
  void need_val(const Kind &k, const char *what) {
    if (k.k != Kind::Val) fail(std::string(kind_name(k)) + " " + what + " not lowered yet");
  }

  // The local (a `var`) of a global name, read or written through a closure variable of the script.
  void global_name_ok(const std::string &name) {
    if (!valid_ident(name)) fail("name '" + name + "' is not an ASCII identifier");
    if (!m_.def_of.count(name) && !m_.declared.count(name)) {
      fail("global '" + name + "' is not declared by the script (builtins are not lowered yet)");
    }
  }

  // A read of a global: a `let` read before its declaration is a ReferenceError (the storage starts uninitialized).
  void get_global(const std::string &name, Stack &st) {
    // `undefined` is a non-writable property of the global object that the script never declares: its value is undefined.
    if (name == "undefined" && !m_.declared.count(name) && !m_.def_of.count(name)) {
      set_tag(stkp(st.size()), kTagUndef, 0);
      st.push_back(Kind{Kind::Val, 0});
      return;
    }
    global_name_ok(name);
    auto def = m_.def_of.find(name);
    if (def != m_.def_of.end()) {
      st.push_back(Kind{Kind::Func, def->second});
      return;
    }
    m_.globals.insert(name);
    std::string g = globp(name);
    if (m_.lexical.count(name)) helper("qjrt_check_global", {g, "@\"" + m_.str(name) + "\""});
    std::size_t d = st.size();
    copy(stkp(d), g);
    st.push_back(Kind{Kind::Val, 0});
  }

  // A store to a global. `init` is the declaration's own initialization (put_var_init): it is not checked, and it is the
  // only store a `const` takes.
  void put_global(const std::string &name, Stack &st, bool keep, bool init) {
    global_name_ok(name);
    Kind top = keep ? peek(st) : pop(st);
    if (m_.def_of.count(name)) {
      if (top.k == Kind::Func && m_.def_of[name] == top.idx) return;   // the binding of the declaration
      fail("assignment to the function declaration '" + name + "' not lowered yet");
    }
    if (top.k != Kind::Val) fail(std::string(kind_name(top)) + " stored into '" + name + "' not lowered yet");
    if (m_.consts.count(name) && !init) fail("assignment to the constant '" + name + "' not lowered yet");
    m_.globals.insert(name);
    std::string g = globp(name);
    if (m_.lexical.count(name) && !init) helper("qjrt_check_global", {g, "@\"" + m_.str(name) + "\""});
    copy(g, stkp(st.size() - (keep ? 1 : 0)));
  }

  // The tag test of a local (TDZ): `name` is the local's name for the message.
  void check_init(const std::string &p, const std::string &name) {
    helper("qjrt_check_init", {p, "@\"" + m_.str(name) + "\""});
  }

  std::string local_name(std::int64_t i) const {
    std::size_t idx = static_cast<std::size_t>(f_.arg_count + i);
    if (idx < f_.vardefs.size()) return f_.vardefs[idx].name;
    return "local" + std::to_string(i);
  }

  void step(const Insn &in, Stack &st, std::size_t &jump_to, Stack &jump_st, bool &has_jump, bool &falls) {
    const std::string &n = in.name;
    std::size_t d = st.size();

    // constants
    if (n == "nop") return;
    if (n == "push_i32" || n == "push_i8" || n == "push_i16" || n == "push_0" || n == "push_1" || n == "push_2" ||
        n == "push_3" || n == "push_4" || n == "push_5" || n == "push_6" || n == "push_7" || n == "push_minus1") {
      set_tag(stkp(d), kTagInt, in.arg);
      st.push_back(Kind{Kind::Val, 0});
      return;
    }
    if (n == "push_const" || n == "push_const8") {
      const Const &c = f_.cpool.at(static_cast<std::size_t>(in.arg));
      if (c.kind == Const::Func) {
        fail("a function constant pushed without fclosure not lowered yet");
      }
      auto [tag, a] = constant_jv(c);
      set_tag(stkp(d), tag, a);
      st.push_back(Kind{Kind::Val, 0});
      return;
    }
    if (n == "fclosure" || n == "fclosure8") {
      const Const &c = f_.cpool.at(static_cast<std::size_t>(in.arg));
      if (c.kind != Const::Func) fail("fclosure of a constant that is not a function not lowered yet");
      st.push_back(Kind{Kind::Func, c.i});
      return;
    }
    if (n == "undefined" || n == "null" || n == "push_false" || n == "push_true") {
      int tag = n == "undefined" ? kTagUndef : n == "null" ? kTagNull : kTagBool;
      set_tag(stkp(d), tag, n == "push_true" ? 1 : 0);
      st.push_back(Kind{Kind::Val, 0});
      return;
    }

    // the stack
    if (n == "drop") {
      pop(st);
      return;
    }
    if (n == "dup") {
      Kind top = peek(st);
      if (top.k == Kind::Val) copy(stkp(d), stkp(d - 1));
      st.push_back(top);
      return;
    }
    if (n == "nip") {
      Kind top = pop(st);
      if (st.empty()) fail("nip past the stack");
      if (top.k == Kind::Val) copy(stkp(st.size() - 1), stkp(st.size()));
      st.back() = top;
      return;
    }
    if (n == "swap") {
      if (d < 2) fail("swap past the stack");
      Kind a = st[d - 1], b = st[d - 2];
      if (a.k == Kind::Val && b.k == Kind::Val) {
        std::string pa = stkp(d - 1), pb = stkp(d - 2);
        copy("%5", pa);
        copy(pa, pb);
        copy(pb, "%5");
      }
      std::swap(st[d - 1], st[d - 2]);
      return;
    }

    // locals and arguments
    if (n == "get_loc" || n == "get_loc8" || n == "get_loc0" || n == "get_loc1" || n == "get_loc2" || n == "get_loc3" ||
        n == "get_loc_check") {
      std::int64_t i = in.arg;
      if (i < 0 || i >= f_.var_count) fail("local index out of range");
      if (n == "get_loc_check") {
        std::string p = locp(i);
        check_init(p, local_name(i));
      }
      copy(stkp(d), locp(i));
      st.push_back(Kind{Kind::Val, 0});
      return;
    }
    if (n == "put_loc" || n == "put_loc8" || n == "put_loc0" || n == "put_loc1" || n == "put_loc2" || n == "put_loc3" ||
        n == "put_loc_check" || n == "put_loc_check_init" || n == "set_loc" || n == "set_loc8" || n == "set_loc0" ||
        n == "set_loc1" || n == "set_loc2" || n == "set_loc3" || n == "set_loc_check") {
      bool keep = n.rfind("set_", 0) == 0;
      std::int64_t i = in.arg;
      if (i < 0 || i >= f_.var_count) fail("local index out of range");
      Kind top = keep ? peek(st) : pop(st);
      if (top.k != Kind::Val) fail(std::string(kind_name(top)) + " stored in a local not lowered yet");
      if (n == "put_loc_check" || n == "set_loc_check") check_init(locp(i), local_name(i));
      copy(locp(i), stkp(st.size() - (keep ? 1 : 0)));
      return;
    }
    if (n == "set_loc_uninitialized") {
      std::int64_t i = in.arg;
      if (i < 0 || i >= f_.var_count) fail("local index out of range");
      set_tag(locp(i), kTagUninit, 0);
      return;
    }
    if (n == "inc_loc" || n == "dec_loc" || n == "add_loc") {
      std::int64_t i = in.arg;
      if (i < 0 || i >= f_.var_count) fail("local index out of range");
      if (n == "add_loc") {
        Kind top = pop(st);
        if (top.k != Kind::Val) fail("add_loc of " + std::string(kind_name(top)) + " not lowered yet");
        helper("qjrt_binop", {ci(kAdd), locp(i), locp(i), stkp(st.size())});
        return;
      }
      helper("qjrt_inc", {ci(n == "inc_loc" ? 1 : -1), locp(i), locp(i)});
      return;
    }
    if (n == "get_arg" || n == "get_arg0" || n == "get_arg1" || n == "get_arg2" || n == "get_arg3") {
      std::int64_t i = in.arg;
      if (i < 0 || i >= f_.arg_count) fail("argument index out of range");
      copy(stkp(d), argp(i));
      st.push_back(Kind{Kind::Val, 0});
      return;
    }
    if (n == "put_arg" || n == "put_arg0" || n == "put_arg1" || n == "put_arg2" || n == "put_arg3" || n == "set_arg" ||
        n == "set_arg0" || n == "set_arg1" || n == "set_arg2" || n == "set_arg3") {
      bool keep = n.rfind("set_", 0) == 0;
      std::int64_t i = in.arg;
      if (i < 0 || i >= f_.arg_count) fail("argument index out of range");
      Kind top = keep ? peek(st) : pop(st);
      if (top.k != Kind::Val) fail(std::string(kind_name(top)) + " stored in an argument not lowered yet");
      copy(argp(i), stkp(st.size() - (keep ? 1 : 0)));
      return;
    }

    // global variables: var references (closure variables of the script or of a function that name a global)
    if (n == "get_var" || n == "get_var_ref" || n == "get_var_ref0" || n == "get_var_ref1" || n == "get_var_ref2" ||
        n == "get_var_ref3" || n == "get_var_ref_check") {
      get_global(var_ref_name(f_, in.arg, n.c_str()), st);
      return;
    }
    if (n == "put_var" || n == "put_var_init" || n == "put_var_ref" || n == "put_var_ref0" || n == "put_var_ref1" ||
        n == "put_var_ref2" || n == "put_var_ref3" || n == "put_var_ref_check" || n == "put_var_ref_check_init") {
      bool init = n == "put_var_init" || n == "put_var_ref_check_init";
      put_global(var_ref_name(f_, in.arg, n.c_str()), st, false, init);
      return;
    }
    if (n == "set_var_ref" || n == "set_var_ref0" || n == "set_var_ref1" || n == "set_var_ref2" || n == "set_var_ref3") {
      put_global(var_ref_name(f_, in.arg, n.c_str()), st, true, false);
      return;
    }

    // operators
    static const std::map<std::string, int> kBinary = {
        {"add", kAdd}, {"sub", kSub}, {"mul", kMul}, {"div", kDiv}, {"mod", kMod}, {"lt", kLt}, {"lte", kLe},
        {"gt", kGt},   {"gte", kGe},  {"eq", kEq},   {"neq", kNe},  {"strict_eq", kSeq}, {"strict_neq", kSne}};
    auto bin = kBinary.find(n);
    if (bin != kBinary.end()) {
      if (d < 2) fail(n + " past the stack");
      need_val(st[d - 2], "as an operator operand");
      need_val(st[d - 1], "as an operator operand");
      std::string dst = stkp(d - 2), a = stkp(d - 2), b = stkp(d - 1);
      helper("qjrt_binop", {ci(bin->second), dst, a, b});
      pop(st);
      return;
    }
    static const std::map<std::string, int> kUnary = {{"neg", kNeg}, {"plus", kPlus}, {"lnot", kLnot}};
    auto un = kUnary.find(n);
    if (un != kUnary.end()) {
      if (d < 1) fail(n + " past the stack");
      need_val(st[d - 1], "as an operand of a unary operator");
      std::string p = stkp(d - 1);
      helper("qjrt_unop", {ci(un->second), p, p});
      return;
    }
    if (n == "inc" || n == "dec") {
      if (d < 1) fail(n + " past the stack");
      need_val(st[d - 1], "as an operand of ++ or --");
      std::string p = stkp(d - 1);
      helper("qjrt_inc", {ci(n == "inc" ? 1 : -1), p, p});
      return;
    }
    if (n == "post_inc" || n == "post_dec") {
      if (d < 1) fail(n + " past the stack");
      need_val(st[d - 1], "as an operand of ++ or --");
      std::string src = stkp(d - 1), old = stkp(d - 1), neu = stkp(d);
      helper("qjrt_post", {ci(n == "post_inc" ? 1 : -1), old, neu, src});
      st.push_back(Kind{Kind::Val, 0});
      return;
    }

    // jumps and branches
    if (n == "if_false" || n == "if_false8" || n == "if_true" || n == "if_true8") {
      Kind top = pop(st);
      if (top.k != Kind::Val) fail("branch on " + std::string(kind_name(top)) + " not lowered yet");
      std::string c = reg(), b = reg();
      line("(let " + c + " int (call int &\"qjrt_truthy\" " + stkp(d - 1) + "))");
      bool jump_if_true = n.rfind("if_true", 0) == 0;
      line("(let " + b + " bool (" + (jump_if_true ? "ne" : "eq") + " int " + c + " (const int 0)))");
      line("(if " + b + " (then (goto \"o" + std::to_string(in.target) + "\")))");
      jump_to = static_cast<std::size_t>(in.target);
      jump_st = st;
      has_jump = true;
      return;
    }
    if (n == "goto" || n == "goto8" || n == "goto16") {
      line("(goto \"o" + std::to_string(in.target) + "\")");
      jump_to = static_cast<std::size_t>(in.target);
      jump_st = st;
      has_jump = true;
      falls = false;
      return;
    }
    if (n == "return") {
      Kind top = pop(st);
      if (top.k != Kind::Val) fail("return of " + std::string(kind_name(top)) + " not lowered yet");
      copy("%0", stkp(d - 1));
      line("(return)");
      falls = false;
      return;
    }
    if (n == "return_undef") {
      set_tag("%0", kTagUndef, 0);
      line("(return)");
      falls = false;
      return;
    }

    // calls of the script's function declarations
    if (n == "call0" || n == "call1" || n == "call2" || n == "call3" || n == "call" || n == "tail_call") {
      std::size_t argc = static_cast<std::size_t>(in.arg);
      if (d < argc + 1) fail("call past the stack");
      std::size_t base = d - argc - 1;
      Kind callee = st[base];
      if (callee.k != Kind::Func) fail("call of a value that is not a function declaration not lowered yet");
      for (std::size_t i = base + 1; i < d; ++i) need_val(st[i], "as a call argument");
      const Fn &cf = m_.bc.fns[static_cast<std::size_t>(callee.idx)];
      std::size_t n_params = static_cast<std::size_t>(cf.arg_count);
      std::size_t vec = std::max(argc, n_params);
      argv_max_ = std::max(argv_max_, vec);
      for (std::size_t i = 0; i < argc; ++i) copy(vecp(i), stkp(base + 1 + i));
      for (std::size_t i = argc; i < n_params; ++i) set_tag(vecp(i), kTagUndef, 0);
      std::string ret = stkp(base);
      line("(eval (call void &\"qjf_" + std::to_string(callee.idx) + "\" " + ret + " %4))");
      if (n == "tail_call") {
        // `return f(...)`: the callee's result is this function's result (the frame is not reused: no tail call is made)
        copy("%0", ret);
        line("(return)");
        falls = false;
        return;
      }
      st.resize(base);
      st.push_back(Kind{Kind::Val, 0});
      return;
    }

    fail(opcode_reason(n) + " not lowered yet");
  }
};

}  // namespace

std::string lower_image(const std::vector<std::uint8_t> &bytes, const std::string &source_name) {
  Bc bc = read_bc(bytes);
  for (std::size_t k = 0; k < bc.fns.size(); ++k) check_fn(bc.fns[k], k);
  Module m(bc);
  for (const ClosureVar &cv : bc.fns[0].closure_vars) {
    if (cv.closure_type != kClosureGlobalDecl) continue;
    m.declared.insert(cv.name);
    if (cv.is_lexical) m.lexical.insert(cv.name);
    if (cv.is_const) m.consts.insert(cv.name);
  }
  for (std::size_t k = 0; k < bc.fns.size(); ++k) find_bindings(m, k, bc.fns[k]);

  std::vector<std::string> fn_text;
  for (std::size_t k = 0; k < bc.fns.size(); ++k) fn_text.push_back(FnLower(m, k).lower());

  std::ostringstream out;
  out << "(ir-module \"" << source_name << "\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4)"
      << " (double 8) (long_double 16)))\n";
  out << "(producer \"quickjs\")\n";
  out << "(abi-type \"JV\" 16 8 (memory))\n";
  // The driver prints the global `result` whether or not the script declares it (undeclared, it is undefined). Every name
  // with storage here is read or written by the script, or is `result`; a function declaration's name is never accessed
  // through storage, so its storage is only there for the driver.
  m.globals.insert("result");
  for (const std::string &g : m.globals) {
    // a `let` starts uninitialized (tag UNINIT), the others undefined (tag 0)
    std::string init = m.lexical.count(g) ? "(init (scalar 0 long (const long " + std::to_string(kTagUninit) + ")) (zero 8 8))"
                                          : "(init (zero 0 " + std::to_string(kJvBytes) + "))";
    out << "(global \"" << gsym(g) << "\" (struct \"JV\") " << kJvBytes << " 8 " << init << ")\n";
  }
  for (const std::string &d : m.data) out << d;
  for (const std::string &f : fn_text) out << "\n" << f;
  return out.str();
}

}  // namespace qjs
