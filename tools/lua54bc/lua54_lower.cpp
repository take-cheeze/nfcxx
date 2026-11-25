// Lua 5.4 bytecode -> Path B mid-level IR text (docs/notes/pathb-stage2.md; the producer rule is section 1, as amended).
//
// Each Proto becomes one IR function `lua54_fn_N(LV *ret, LV *base, void *cl)`. A register R(i) is `base + 16*i`; an LV
// is { u8 tag at offset 0; i64 or f64 at offset 8 }, 16 bytes, align 8. The tags are lobject.h's variants.
//
// Integer fast paths are inline IR. Everything else calls a runtime helper (docs/notes/lua54-pathb.md) that performs the
// whole operation, metamethods included. An operation that can fail first sets its site: the source position and the
// variable info of its operands, computed here from ldebug.c's rules (namespace dbg), so the runtime prints the messages
// lua.c prints. An opcode without a template is refused by name.
//
// Arithmetic skips the MMBIN* after it, as lvm.c does on success. The helpers do the metamethod work, so the MMBIN*
// opcodes lower to nothing.
#include "lua54_lower.hpp"

#include <cstdint>
#include <cstdio>
#include <map>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace lua54 {

namespace {

// lobject.h variants: type | variant << 4.
constexpr int kTagNil = 0x00, kTagFalse = 0x01, kTagTrue = 0x11, kTagInt = 0x03, kTagFloat = 0x13;

// Helper kinds for lua54rt_cmp (docs/notes/lua54-pathb.md).
constexpr int kCmpLt = 0, kCmpLe = 1, kCmpEq = 2;

// testAMode (lopcodes.c): the opcodes that set register A. Generated from the pinned source.
const bool kOpSetsA[NUM_OPCODES] = {
    true, true, true, true, true, true, true, true, true, true, false, true, true, true, true, false,
    false, false, false, true, true, true, true, true, true, true, true, true, true, true, true, true,
    true, true, true, true, true, true, true, true, true, true, true, true, true, true, false, false,
    false, true, true, true, true, true, false, false, false, false, false, false, false, false, false, false,
    false, false, false, true, true, true, false, false, false, true, true, false, false, true, false, true,
    true, true, false,
};
bool testmm(std::uint8_t op) { return op == MMBIN || op == MMBINI || op == MMBINK; }
bool testa(std::uint8_t op) { return op < NUM_OPCODES && kOpSetsA[op]; }

// ---- ldebug.c: the names of variables in the messages (getobjname and its helpers) ----
namespace dbg {

constexpr int kMaxIWthAbs = 128;   // ldebug.h

// luaF_getlocalname: the name of the local_number-th active local at pc.
std::optional<std::string> local_name(const Proto &p, int local_number, int pc) {
  for (std::size_t i = 0; i < p.locvars.size() && p.locvars[i].startpc <= pc; ++i) {
    if (pc < p.locvars[i].endpc) {
      if (--local_number == 0) return p.locvars[i].name ? *p.locvars[i].name : std::string("?");
    }
  }
  return std::nullopt;
}

std::string upvalname(const Proto &p, int uv) {
  const UpvalDesc &u = p.upvalues.at(static_cast<std::size_t>(uv));
  return u.name ? *u.name : std::string("?");
}

// kname: a constant's name when it is a string.
std::string kname(const Proto &p, unsigned c, std::string &name) {
  const Constant &k = p.k.at(c);
  name = k.kind == Constant::Kind::String ? k.s : std::string("?");
  return "constant";
}

int findsetreg(const Proto &p, int lastpc, int reg);

// basicgetobjname: "local", "upvalue", "constant" or "" (none); updates pc like the C version.
std::string basicgetobjname(const Proto &p, int &pc, int reg, std::string &name) {
  if (auto ln = local_name(p, reg + 1, pc)) {
    name = *ln;
    return "local";
  }
  pc = findsetreg(p, pc, reg);
  if (pc != -1) {
    const Insn &i = p.code[static_cast<std::size_t>(pc)];
    switch (i.op()) {
      case MOVE: {
        int b = static_cast<int>(i.B());
        if (b < static_cast<int>(i.A())) return basicgetobjname(p, pc, b, name);
        break;
      }
      case GETUPVAL:
        name = upvalname(p, static_cast<int>(i.B()));
        return "upvalue";
      case LOADK: return kname(p, i.Bx(), name);
      case LOADKX: return kname(p, p.code[static_cast<std::size_t>(pc) + 1].Ax(), name);
      default: break;
    }
  }
  return "";
}

// filterpc / findsetreg: the last instruction before lastpc that set reg, if it is not inside a conditional jump.
int findsetreg(const Proto &p, int lastpc, int reg) {
  int setreg = -1, jmptarget = 0;
  if (testmm(p.code[static_cast<std::size_t>(lastpc)].op())) lastpc--;   // the MMBIN was not executed
  for (int pc = 0; pc < lastpc; ++pc) {
    const Insn &i = p.code[static_cast<std::size_t>(pc)];
    std::uint8_t op = i.op();
    int a = static_cast<int>(i.A());
    bool change;
    switch (op) {
      case LOADNIL: change = a <= reg && reg <= a + static_cast<int>(i.B()); break;
      case TFORCALL: change = reg >= a + 2; break;
      case CALL:
      case TAILCALL: change = reg >= a; break;
      case JMP: {
        int dest = pc + 1 + i.sJ();
        if (dest <= lastpc && dest > jmptarget) jmptarget = dest;
        change = false;
        break;
      }
      default: change = testa(op) && reg == a; break;
    }
    if (change) setreg = pc < jmptarget ? -1 : pc;
  }
  return setreg;
}

// isEnv: "global" when the indexed table is _ENV, "field" otherwise.
std::string is_env(const Proto &p, int pc, const Insn &i, bool isup) {
  int t = static_cast<int>(i.B());
  std::string name;
  bool named = false;
  if (isup) {
    name = upvalname(p, t);
    named = true;
  } else {
    int at = pc;
    std::string what = basicgetobjname(p, at, t, name);
    named = what == "local" || what == "upvalue";
  }
  return (named && name == "_ENV") ? "global" : "field";
}

// rname: the name of a key in register c, if it is a constant; "?" otherwise.
void rname(const Proto &p, int pc, int c, std::string &name) {
  std::string what = basicgetobjname(p, pc, c, name);
  if (what != "constant") name = "?";
}

void rkname(const Proto &p, int pc, const Insn &i, std::string &name) {
  unsigned c = i.C();
  if (i.k()) kname(p, c, name);
  else rname(p, pc, static_cast<int>(c), name);
}

// getobjname: the kind ("local", "global", "field", "method", "upvalue", "constant") and the name of the value that
// register reg holds at lastpc; "" when there is none.
std::string getobjname(const Proto &p, int lastpc, int reg, std::string &name) {
  std::string kind = basicgetobjname(p, lastpc, reg, name);
  if (!kind.empty()) return kind;
  if (lastpc != -1) {
    const Insn &i = p.code[static_cast<std::size_t>(lastpc)];
    switch (i.op()) {
      case GETTABUP:
        kname(p, i.C(), name);
        return is_env(p, lastpc, i, true);
      case GETTABLE:
        rname(p, lastpc, static_cast<int>(i.C()), name);
        return is_env(p, lastpc, i, false);
      case GETI:
        name = "integer index";
        return "field";
      case GETFIELD:
        kname(p, i.C(), name);
        return is_env(p, lastpc, i, false);
      case SELF:
        rkname(p, lastpc, i, name);
        return "method";
      default: break;
    }
  }
  return "";
}

// formatvarinfo: " (kind 'name')", or "" when there is no information.
std::string formatvarinfo(const std::string &kind, const std::string &name) {
  if (kind.empty()) return "";
  return " (" + kind + " '" + name + "')";
}

// varinfo of a register at pc: the operand of an operation that fails there.
std::string varinfo_reg(const Proto &p, int pc, int reg) {
  std::string name;
  std::string kind = getobjname(p, pc, reg, name);
  return formatvarinfo(kind, name);
}

// varinfo of an upvalue (the table of a GETTABUP or SETTABUP, when it is not a table).
std::string varinfo_upval(const Proto &p, int uv) { return formatvarinfo("upvalue", upvalname(p, uv)); }

// The line of an instruction: luaG_getfuncline with the base lines of ldebug.c.
int getbaseline(const Proto &p, int pc, int &basepc) {
  if (p.abslineinfo.empty() || pc < p.abslineinfo[0].pc) {
    basepc = -1;
    return p.linedefined;
  }
  int i = pc / kMaxIWthAbs - 1;
  while (i + 1 < static_cast<int>(p.abslineinfo.size()) && pc >= p.abslineinfo[static_cast<std::size_t>(i) + 1].pc) i++;
  basepc = p.abslineinfo[static_cast<std::size_t>(i)].pc;
  return p.abslineinfo[static_cast<std::size_t>(i)].line;
}

int getfuncline(const Proto &p, int pc) {
  if (p.lineinfo.empty()) return -1;
  int basepc;
  int baseline = getbaseline(p, pc, basepc);
  while (basepc++ < pc) baseline += static_cast<int8_t>(p.lineinfo[static_cast<std::size_t>(basepc)]);
  return baseline;
}

}  // namespace dbg

// Function numbers of every prototype of the chunk (pre-order, the main function is 0).
using FnIndex = std::map<const Proto *, std::size_t>;

// What the whole module needs: the function numbers, the data items (string constants and sites), the chunk name.
struct Module {
  FnIndex index;
  std::vector<std::string> data;                // IR `(data ...)` lines
  std::size_t nstr = 0;
  std::map<std::string, std::string> strings;   // string constant text -> data symbol
  std::map<std::string, std::string> sites;     // site text -> data symbol
  std::string chunkname;
};

struct Ctx {
  const Proto &p;
  Module &m;
  std::size_t pc = 0;
  int next = 3;                    // %0 is ret, %1 is base, %2 is the closure (cl)
  std::ostringstream body;
  std::vector<std::string> slots;  // slot declarations, emitted before the body

  Ctx(const Proto &proto, Module &module) : p(proto), m(module) {}

  std::string fresh() { return "%" + std::to_string(next++); }
  void line(const std::string &s) { body << "  " << s << "\n"; }

  // A temporary LV in the frame, for an operand the helpers take by address.
  std::string temp_lv() {
    std::string name = "tmp." + std::to_string(pc) + "." + std::to_string(slots.size());
    slots.push_back("(slot \"" + name + "\" (struct \"LV\") 16 8)");
    return "$\"" + name + "\"";
  }

  const Insn &insn_at(std::size_t i) const { return p.code.at(i); }

  // The info of a register operand at this instruction, and of an upvalue.
  std::string reg_info(unsigned r) const { return dbg::varinfo_reg(p, static_cast<int>(pc), static_cast<int>(r)); }
  std::string upval_info(unsigned uv) const { return dbg::varinfo_upval(p, static_cast<int>(uv)); }
};

std::string lbl(std::size_t pc) { return "\"pc" + std::to_string(pc) + "\""; }
void go(Ctx &c, std::size_t pc) { c.line("(goto " + lbl(pc) + ")"); }

// `set cond RVALUE`: the IR's set takes an operand, so an rvalue (a comparison) goes through a temporary.
void set_rv(Ctx &c, const std::string &cond, const std::string &rvalue) {
  std::string t = c.fresh();
  c.line("(let " + t + " bool " + rvalue + ")");
  c.line("(set " + cond + " " + t + ")");
}

// The address of R(i). A fresh register each time, so each IR register is declared once.
std::string reg(Ctx &c, unsigned i) {
  std::string r = c.fresh();
  c.line("(let " + r + " (ptr (struct \"LV\")) (offset %1 " + std::to_string(i * 16) + "))");
  return r;
}

std::string load_tag(Ctx &c, const std::string &lv) {
  std::string p = c.fresh(), t = c.fresh();
  c.line("(let " + p + " (ptr unsigned_char) (offset " + lv + " 0))");
  c.line("(let " + t + " unsigned_char (load unsigned_char " + p + "))");
  return t;
}

// A bool register: the tag register `tag_reg` equals `tag`.
std::string tag_is(Ctx &c, const std::string &tag_reg, int tag) {
  std::string b = c.fresh();
  c.line("(let " + b + " bool (eq unsigned_char " + tag_reg + " (const unsigned_char " + std::to_string(tag) + ")))");
  return b;
}

std::string load_value(Ctx &c, const std::string &lv, const std::string &type) {
  std::string p = c.fresh(), v = c.fresh();
  c.line("(let " + p + " (ptr " + type + ") (offset " + lv + " 8))");
  c.line("(let " + v + " " + type + " (load " + type + " " + p + "))");
  return v;
}

void store_tag(Ctx &c, const std::string &dst, int tag) {
  std::string tp = c.fresh();
  c.line("(let " + tp + " (ptr unsigned_char) (offset " + dst + " 0))");
  c.line("(store unsigned_char " + tp + " (const unsigned_char " + std::to_string(tag) + "))");
}

void store_value(Ctx &c, const std::string &dst, const std::string &type, const std::string &value) {
  std::string vp = c.fresh();
  c.line("(let " + vp + " (ptr " + type + ") (offset " + dst + " 8))");
  c.line("(store " + type + " " + vp + " " + value + ")");
}

void store_int(Ctx &c, const std::string &dst, const std::string &value) {
  store_tag(c, dst, kTagInt);
  store_value(c, dst, "long", value);
}

void store_float(Ctx &c, const std::string &dst, const std::string &value) {
  store_tag(c, dst, kTagFloat);
  store_value(c, dst, "double", value);
}

// The bytes of a string as IR string text: printable ASCII as it is, the rest as octal escapes.
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

std::string fmt_double(double d) {
  char buf[64];
  std::snprintf(buf, sizeof buf, "%.17g", d);
  return buf;
}

// The LV of a constant, written to a temporary. A string is a data item and lua54rt_str makes the object.
std::string constant_lv(Ctx &c, const Constant &k) {
  std::string t = c.temp_lv();
  switch (k.kind) {
    case Constant::Kind::Integer: store_int(c, t, "(const long " + std::to_string(k.i) + ")"); break;
    case Constant::Kind::Float: store_float(c, t, "(const double " + fmt_double(k.f) + ")"); break;
    case Constant::Kind::Nil: store_tag(c, t, kTagNil); break;
    case Constant::Kind::False: store_tag(c, t, kTagFalse); break;
    case Constant::Kind::True: store_tag(c, t, kTagTrue); break;
    case Constant::Kind::String: {
      auto it = c.m.strings.find(k.s);
      std::string sym;
      if (it != c.m.strings.end()) {
        sym = it->second;
      } else {
        sym = "lua54.s." + std::to_string(c.m.nstr++);
        c.m.strings[k.s] = sym;
        c.m.data.push_back("(data \"" + sym + "\" (const (array " + std::to_string(k.s.size() + 1) +
                           " (const char))) (string \"" + ir_escape(k.s) + "\\000\"))\n");
      }
      c.line("(eval (call void &\"lua54rt_str\" " + t + " @\"" + sym + "\" (const long " +
             std::to_string(k.s.size()) + ")))");
      break;
    }
  }
  return t;
}

// The LV of an immediate: an integer, or a float when the C flag of the instruction says so.
std::string imm_lv(Ctx &c, int value, bool is_float) {
  std::string t = c.temp_lv();
  if (is_float) store_float(c, t, "(const double " + fmt_double(value) + ")");
  else store_int(c, t, "(const long " + std::to_string(value) + ")");
  return t;
}

// An RK operand: a constant (is_k set) or a register.
std::string rk(Ctx &c, unsigned idx, bool is_k) { return is_k ? constant_lv(c, c.p.k.at(idx)) : reg(c, idx); }

// Sets the site of the operation about to run: the runtime reports its errors with this position and these operand infos.
// The data item is shared by sites with the same text.
void set_site(Ctx &c, const std::vector<std::string> &infos) {
  std::string text = c.m.chunkname + ":" + std::to_string(dbg::getfuncline(c.p, static_cast<int>(c.pc))) + ":";
  for (const std::string &s : infos) text += "\n" + s;
  std::string sym;
  auto it = c.m.sites.find(text);
  if (it != c.m.sites.end()) {
    sym = it->second;
  } else {
    sym = "lua54.site." + std::to_string(c.m.sites.size());
    c.m.sites[text] = sym;
    c.m.data.push_back("(data \"" + sym + "\" (const (array " + std::to_string(text.size() + 1) +
                       " (const char))) (string \"" + ir_escape(text) + "\\000\"))\n");
  }
  c.line("(eval (call void &\"lua54rt_site\" @\"" + sym + "\"))");
}

// Arithmetic `R[a] := lhs op rhs` where op is ADD, SUB or MUL. The inline path needs both operands to be ints; a
// constant int right operand is known to be an int, so its tag test is not emitted. Otherwise the helper runs.
void emit_arith(Ctx &c, int op, unsigned a, const std::string &lhs, const std::string &rhs,
                const std::string *int_const, const std::vector<std::string> &infos) {
  std::string dst = reg(c, a);
  std::string ta = load_tag(c, lhs);
  std::string a_int = tag_is(c, ta, kTagInt);
  c.line("(if " + a_int + " (then");
  std::string b_int;
  if (int_const) {
    b_int = c.fresh();
    c.line("(let " + b_int + " bool (const bool 1))");
  } else {
    b_int = tag_is(c, load_tag(c, rhs), kTagInt);
  }
  c.line("(if " + b_int + " (then");
  std::string x = load_value(c, lhs, "long");
  std::string y = int_const ? *int_const : load_value(c, rhs, "long");
  std::string r = c.fresh();
  // Lua integers wrap around: the w-prefixed operators are two's-complement, as lvm.c's integer ops are.
  const char *wop = op == ADD ? "wadd" : op == SUB ? "wsub" : "wmul";
  c.line("(let " + r + " long (" + wop + " long " + x + " " + y + "))");
  store_int(c, dst, r);
  go(c, c.pc + 2);
  c.line("))");   // closes (then of the inner if and the inner if
  c.line("))");   // closes (then of the outer if and the outer if
  // Slow path: the helper does the whole operation, metamethods included.
  set_site(c, infos);
  c.line("(eval (call void &\"lua54rt_arith\" (const int " + std::to_string(op) + ") " + dst + " " + lhs + " " + rhs + "))");
  go(c, c.pc + 2);
}

// A comparison: the int compare inline when both are ints, else the helper; the result is a bool in `cond`.
void emit_compare(Ctx &c, const std::string &fast_op, int kind, const std::string &a, const std::string &b,
                  const std::string &ta_tag, const std::string &tb_tag, const std::string &cond) {
  auto slow = [&]() {
    std::string r = c.fresh();
    set_site(c, {});
    c.line("(let " + r + " int (call int &\"lua54rt_cmp\" (const int " + std::to_string(kind) + ") " + a + " " + b + "))");
    set_rv(c, cond, "(ne int " + r + " (const int 0))");
  };
  std::string ai = tag_is(c, ta_tag, kTagInt);
  c.line("(if " + ai + " (then");
  std::string bi = tag_is(c, tb_tag, kTagInt);
  c.line("(if " + bi + " (then");
  std::string x = load_value(c, a, "long");
  std::string y = load_value(c, b, "long");
  set_rv(c, cond, std::string("(") + fast_op + " long " + x + " " + y + ")");
  c.line(") (else");   // closes the then of the inner test and opens its else
  slow();
  c.line("))");        // closes that else and the inner test
  c.line(") (else");   // closes the then of the outer test and opens its else
  slow();
  c.line("))");        // closes that else and the outer test
}

// A comparison followed by its JMP (docondjump in lvm.c). The condition is taken when it equals k; then the JMP after
// this instruction runs, going to its destination. Otherwise that JMP is skipped.
void emit_cond_jump(Ctx &c, const std::string &cond, unsigned k) {
  std::size_t jmp_pc = c.pc + 1;
  const Insn &j = c.insn_at(jmp_pc);
  if (j.op() != JMP) throw std::runtime_error("refused: a test is not followed by a JMP at pc " + std::to_string(c.pc));
  std::size_t dest = jmp_pc + 1 + static_cast<std::size_t>(static_cast<long long>(j.sJ()));
  std::size_t skip = c.pc + 2;
  if (k != 0) {
    c.line("(if " + cond + " (then (goto " + lbl(dest) + ")) (else (goto " + lbl(skip) + ")))");
  } else {
    c.line("(if " + cond + " (then (goto " + lbl(skip) + ")) (else (goto " + lbl(dest) + ")))");
  }
}

// A binary op the helper performs whole (floats, bitwise, division, modulo, power, shifts). On success lvm.c skips the
// MMBIN after the op, so control goes to pc+2.
void emit_helper_arith(Ctx &c, Op base, unsigned a, const std::string &lhs, const std::string &rhs,
                       const std::vector<std::string> &infos) {
  std::string dst = reg(c, a);
  set_site(c, infos);
  c.line("(eval (call void &\"lua54rt_arith\" (const int " + std::to_string(static_cast<int>(base)) + ") " + dst + " " +
         lhs + " " + rhs + "))");
  go(c, c.pc + 2);
}

// A unary op (UNM, BNOT). No MMBIN follows these, so control falls through.
void emit_helper_unary(Ctx &c, int op, unsigned a, unsigned b) {
  std::string src = reg(c, b), dst = reg(c, a);
  set_site(c, {c.reg_info(b)});
  c.line("(eval (call void &\"lua54rt_unary\" (const int " + std::to_string(op) + ") " + dst + " " + src + "))");
}

// CALL: R[a] is the function; its arguments are R[a+1..] (nargs values, an IR int); the results go to R[a..] (wanted of
// them, or all of them with -1). The callee's base is R[a+1]; the function value is copied first, because R[a] receives
// the first result. `info` is the variable info of the function for an error.
void emit_call(Ctx &c, unsigned a, const std::string &nargs, int wanted, const std::string &info) {
  std::string fn_slot = c.temp_lv();
  std::string fn_reg = reg(c, a);
  c.line("(copy 16 " + fn_slot + " " + fn_reg + ")");
  store_tag(c, fn_reg, kTagNil);   // a call that returns nothing leaves R[A] nil
  std::string args = reg(c, a + 1);
  std::string ret = reg(c, a);
  set_site(c, {info});
  c.line("(eval (call void &\"lua54rt_call\" " + fn_slot + " " + nargs + " " + args + " " + ret + " (const int " +
         std::to_string(wanted) + ") (const int " + std::to_string(a) + ")))");
}

// The number of values up to the stack top, from register index `from` on: top - from, as an IR int register.
std::string values_to_top(Ctx &c, unsigned from) {
  std::string t = c.fresh(), n = c.fresh();
  c.line("(let " + t + " int (call int &\"lua54rt_gettop\"))");
  c.line("(let " + n + " int (wsub int " + t + " (const int " + std::to_string(from) + ")))");
  return n;
}

// Results are returned: n values (an IR int register or a constant) are copied from src to the caller's ret.
void emit_return_values(Ctx &c, const std::string &src, const std::string &n) {
  c.line("(eval (call void &\"lua54rt_setret\" %0 " + src + " " + n + "))");
  c.line("(return)");
}

// --- The op table: one lowering function per opcode. ---

using Lower = void (*)(Ctx &, const Insn &);

void lower_move(Ctx &c, const Insn &i) {
  std::string dst = reg(c, i.A()), src = reg(c, i.B());
  c.line("(copy 16 " + dst + " " + src + ")");
}

void lower_loadi(Ctx &c, const Insn &i) { store_int(c, reg(c, i.A()), "(const long " + std::to_string(i.sBx()) + ")"); }

void lower_loadf(Ctx &c, const Insn &i) {
  store_float(c, reg(c, i.A()), "(const double " + fmt_double(i.sBx()) + ")");
}

void lower_loadk(Ctx &c, const Insn &i) {
  std::string src = constant_lv(c, c.p.k.at(i.Bx()));
  c.line("(copy 16 " + reg(c, i.A()) + " " + src + ")");
}

void lower_loadfalse(Ctx &c, const Insn &i) { store_tag(c, reg(c, i.A()), kTagFalse); }
void lower_loadtrue(Ctx &c, const Insn &i) { store_tag(c, reg(c, i.A()), kTagTrue); }

void lower_loadnil(Ctx &c, const Insn &i) {
  for (unsigned n = 0; n <= i.B(); ++n) store_tag(c, reg(c, i.A() + n), kTagNil);
}

void lower_add(Ctx &c, const Insn &i) {
  std::string b = reg(c, i.B()), cc = reg(c, i.C());
  emit_arith(c, ADD, i.A(), b, cc, nullptr, {c.reg_info(i.B()), c.reg_info(i.C())});
}
void lower_sub(Ctx &c, const Insn &i) {
  std::string b = reg(c, i.B()), cc = reg(c, i.C());
  emit_arith(c, SUB, i.A(), b, cc, nullptr, {c.reg_info(i.B()), c.reg_info(i.C())});
}
void lower_mul(Ctx &c, const Insn &i) {
  std::string b = reg(c, i.B()), cc = reg(c, i.C());
  emit_arith(c, MUL, i.A(), b, cc, nullptr, {c.reg_info(i.B()), c.reg_info(i.C())});
}

// ADDI A B sC: R[A] := R[B] + sC, the immediate being an integer.
void lower_addi(Ctx &c, const Insn &i) {
  std::string rb = reg(c, i.B());
  std::string imm = imm_lv(c, i.sC(), false);
  std::string v = "(const long " + std::to_string(i.sC()) + ")";
  emit_arith(c, ADD, i.A(), rb, imm, &v, {c.reg_info(i.B()), ""});
}

// The K operand of ADDK/SUBK/MULK: an integer keeps the inline path, anything else goes to the helper.
void arith_k(Ctx &c, const Insn &i, Op op) {
  const Constant &k = c.p.k.at(i.C());
  std::string rb = reg(c, i.B());
  std::string kv = constant_lv(c, k);
  if (k.kind == Constant::Kind::Integer) {
    std::string v = "(const long " + std::to_string(k.i) + ")";
    emit_arith(c, op, i.A(), rb, kv, &v, {c.reg_info(i.B()), ""});
  } else {
    emit_arith(c, op, i.A(), rb, kv, nullptr, {c.reg_info(i.B()), ""});
  }
}

void lower_addk(Ctx &c, const Insn &i) { arith_k(c, i, ADD); }
void lower_subk(Ctx &c, const Insn &i) { arith_k(c, i, SUB); }
void lower_mulk(Ctx &c, const Insn &i) { arith_k(c, i, MUL); }

// The MMBIN* after an arithmetic op: never reached by falling through, so nothing.
void lower_nothing(Ctx &, const Insn &) {}

// EQ/LT/LE on two registers. The fast path is the int compare; the helper handles the rest.
void lower_compare_regs(Ctx &c, const Insn &i, const char *fast, int kind) {
  std::string cond = c.fresh();
  c.line("(let " + cond + " bool (const bool 0))");
  std::string a = reg(c, i.A()), b = reg(c, i.B());
  std::string ta = load_tag(c, a), tb = load_tag(c, b);
  emit_compare(c, fast, kind, a, b, ta, tb, cond);
  emit_cond_jump(c, cond, i.k());
}

void lower_eq(Ctx &c, const Insn &i) { lower_compare_regs(c, i, "eq", kCmpEq); }
void lower_lt(Ctx &c, const Insn &i) { lower_compare_regs(c, i, "lt.s", kCmpLt); }
void lower_le(Ctx &c, const Insn &i) { lower_compare_regs(c, i, "le.s", kCmpLe); }

// Comparisons with an immediate: `R[A] op sB`. C is the isf flag: a float immediate always goes to the helper.
// GTI and GEI compare the other way round (sB < R[A], sB <= R[A]).
void imm_compare(Ctx &c, const Insn &i, const char *fast_op, int kind, bool swapped) {
  std::string cond = c.fresh();
  c.line("(let " + cond + " bool (const bool 0))");
  std::string ra = reg(c, i.A());
  std::string ta = load_tag(c, ra);
  std::string imm = imm_lv(c, i.sB(), i.C() != 0);
  auto call = [&](const std::string &x, const std::string &y) {
    std::string r = c.fresh();
    set_site(c, {});
    c.line("(let " + r + " int (call int &\"lua54rt_cmp\" (const int " + std::to_string(kind) + ") " + x + " " + y + "))");
    set_rv(c, cond, "(ne int " + r + " (const int 0))");
  };
  if (i.C() == 0) {
    // The immediate is an int, so only R[A]'s tag is tested.
    std::string ai = tag_is(c, ta, kTagInt);
    c.line("(if " + ai + " (then");
    std::string x = load_value(c, ra, "long");
    std::string y = "(const long " + std::to_string(i.sB()) + ")";
    if (swapped) set_rv(c, cond, std::string("(") + fast_op + " long " + y + " " + x + ")");
    else set_rv(c, cond, std::string("(") + fast_op + " long " + x + " " + y + ")");
    c.line(") (else");
    if (swapped) call(imm, ra);
    else call(ra, imm);
    c.line("))");
  } else {
    if (swapped) call(imm, ra);
    else call(ra, imm);
  }
  emit_cond_jump(c, cond, i.k());
}

void lower_lti(Ctx &c, const Insn &i) { imm_compare(c, i, "lt.s", kCmpLt, false); }
void lower_lei(Ctx &c, const Insn &i) { imm_compare(c, i, "le.s", kCmpLe, false); }
void lower_gti(Ctx &c, const Insn &i) { imm_compare(c, i, "lt.s", kCmpLt, true); }
void lower_gei(Ctx &c, const Insn &i) { imm_compare(c, i, "le.s", kCmpLe, true); }

void lower_eqi(Ctx &c, const Insn &i) {
  std::string cond = c.fresh();
  c.line("(let " + cond + " bool (const bool 0))");
  std::string ra = reg(c, i.A());
  std::string ta = load_tag(c, ra);
  std::string imm = imm_lv(c, i.sB(), i.C() != 0);
  if (i.C() == 0) {
    std::string ai = tag_is(c, ta, kTagInt);
    c.line("(if " + ai + " (then");
    std::string x = load_value(c, ra, "long");
    set_rv(c, cond, "(eq long " + x + " (const long " + std::to_string(i.sB()) + "))");
    c.line(") (else");
  }
  std::string r = c.fresh();
  set_site(c, {});
  c.line("(let " + r + " int (call int &\"lua54rt_cmp\" (const int " + std::to_string(kCmpEq) + ") " + ra + " " + imm + "))");
  set_rv(c, cond, "(ne int " + r + " (const int 0))");
  if (i.C() == 0) c.line("))");
  emit_cond_jump(c, cond, i.k());
}

void lower_eqk(Ctx &c, const Insn &i) {
  std::string cond = c.fresh();
  c.line("(let " + cond + " bool (const bool 0))");
  std::string ra = reg(c, i.A());
  std::string kv = constant_lv(c, c.p.k.at(i.B()));
  std::string r = c.fresh();
  set_site(c, {});
  c.line("(let " + r + " int (call int &\"lua54rt_cmp\" (const int " + std::to_string(kCmpEq) + ") " + ra + " " + kv + "))");
  set_rv(c, cond, "(ne int " + r + " (const int 0))");
  emit_cond_jump(c, cond, i.k());
}

// TEST A k: the condition is the truthiness of R[A] (lvm.c: !l_isfalse). Nil and false are the falsy tags.
void lower_test(Ctx &c, const Insn &i) {
  std::string cond = c.fresh();
  c.line("(let " + cond + " bool (const bool 0))");
  std::string ra = reg(c, i.A());
  std::string t = load_tag(c, ra);
  std::string is_nil = tag_is(c, t, kTagNil), is_false = tag_is(c, t, kTagFalse);
  // if nil then false else (if false then false else true)
  c.line("(if " + is_nil + " (then (set " + cond + " (const bool 0))) (else");
  c.line("(if " + is_false + " (then (set " + cond + " (const bool 0))) (else (set " + cond + " (const bool 1))))");
  c.line("))");   // closes the else of the nil test and the nil test itself
  emit_cond_jump(c, cond, i.k());
}

void lower_jmp(Ctx &c, const Insn &i) { go(c, c.pc + 1 + static_cast<std::size_t>(static_cast<long long>(i.sJ()))); }

void lower_div(Ctx &c, const Insn &i) {
  std::string b = reg(c, i.B()), cc = reg(c, i.C());
  emit_helper_arith(c, DIV, i.A(), b, cc, {c.reg_info(i.B()), c.reg_info(i.C())});
}
void lower_idiv(Ctx &c, const Insn &i) {
  std::string b = reg(c, i.B()), cc = reg(c, i.C());
  emit_helper_arith(c, IDIV, i.A(), b, cc, {c.reg_info(i.B()), c.reg_info(i.C())});
}
void lower_mod(Ctx &c, const Insn &i) {
  std::string b = reg(c, i.B()), cc = reg(c, i.C());
  emit_helper_arith(c, MOD, i.A(), b, cc, {c.reg_info(i.B()), c.reg_info(i.C())});
}
void lower_pow(Ctx &c, const Insn &i) {
  std::string b = reg(c, i.B()), cc = reg(c, i.C());
  emit_helper_arith(c, POW, i.A(), b, cc, {c.reg_info(i.B()), c.reg_info(i.C())});
}
void lower_band(Ctx &c, const Insn &i) {
  std::string b = reg(c, i.B()), cc = reg(c, i.C());
  emit_helper_arith(c, BAND, i.A(), b, cc, {c.reg_info(i.B()), c.reg_info(i.C())});
}
void lower_bor(Ctx &c, const Insn &i) {
  std::string b = reg(c, i.B()), cc = reg(c, i.C());
  emit_helper_arith(c, BOR, i.A(), b, cc, {c.reg_info(i.B()), c.reg_info(i.C())});
}
void lower_bxor(Ctx &c, const Insn &i) {
  std::string b = reg(c, i.B()), cc = reg(c, i.C());
  emit_helper_arith(c, BXOR, i.A(), b, cc, {c.reg_info(i.B()), c.reg_info(i.C())});
}
void lower_shl(Ctx &c, const Insn &i) {
  std::string b = reg(c, i.B()), cc = reg(c, i.C());
  emit_helper_arith(c, SHL, i.A(), b, cc, {c.reg_info(i.B()), c.reg_info(i.C())});
}
void lower_shr(Ctx &c, const Insn &i) {
  std::string b = reg(c, i.B()), cc = reg(c, i.C());
  emit_helper_arith(c, SHR, i.A(), b, cc, {c.reg_info(i.B()), c.reg_info(i.C())});
}

// The K forms: the constant goes through a temporary; the helper does the op.
void arith_k_helper(Ctx &c, const Insn &i, Op base) {
  std::string rb = reg(c, i.B());
  std::string kv = constant_lv(c, c.p.k.at(i.C()));
  emit_helper_arith(c, base, i.A(), rb, kv, {c.reg_info(i.B()), ""});
}
void lower_divk(Ctx &c, const Insn &i) { arith_k_helper(c, i, DIV); }
void lower_idivk(Ctx &c, const Insn &i) { arith_k_helper(c, i, IDIV); }
void lower_modk(Ctx &c, const Insn &i) { arith_k_helper(c, i, MOD); }
void lower_powk(Ctx &c, const Insn &i) { arith_k_helper(c, i, POW); }
void lower_bandk(Ctx &c, const Insn &i) { arith_k_helper(c, i, BAND); }
void lower_bork(Ctx &c, const Insn &i) { arith_k_helper(c, i, BOR); }
void lower_bxork(Ctx &c, const Insn &i) { arith_k_helper(c, i, BXOR); }

// SHRI A B sC: R[A] := R[B] >> sC (shiftl by -sC). SHLI A B sC: R[A] := sC << R[B].
void lower_shri(Ctx &c, const Insn &i) {
  std::string rb = reg(c, i.B());
  std::string imm = imm_lv(c, i.sC(), false);
  emit_helper_arith(c, SHR, i.A(), rb, imm, {c.reg_info(i.B()), ""});
}
void lower_shli(Ctx &c, const Insn &i) {
  std::string imm = imm_lv(c, i.sC(), false);
  std::string rb = reg(c, i.B());
  emit_helper_arith(c, SHL, i.A(), imm, rb, {"", c.reg_info(i.B())});
}

void lower_unm(Ctx &c, const Insn &i) { emit_helper_unary(c, UNM, i.A(), i.B()); }
void lower_bnot(Ctx &c, const Insn &i) { emit_helper_unary(c, BNOT, i.A(), i.B()); }

// NOT A B: R[A] is true when R[B] is nil or false.
void lower_not(Ctx &c, const Insn &i) {
  std::string rb = reg(c, i.B());
  std::string t = load_tag(c, rb);
  std::string is_nil = tag_is(c, t, kTagNil), is_false = tag_is(c, t, kTagFalse);
  std::string falsy = c.fresh();
  c.line("(let " + falsy + " bool (const bool 0))");
  // if nil then falsy := true else (if false then falsy := true else falsy := false)
  c.line("(if " + is_nil + " (then (set " + falsy + " (const bool 1))) (else");
  c.line("(if " + is_false + " (then (set " + falsy + " (const bool 1))) (else (set " + falsy + " (const bool 0))))");
  c.line("))");   // closes the else of the nil test and the nil test itself
  std::string dst = reg(c, i.A());
  c.line("(if " + falsy + " (then");
  store_tag(c, dst, kTagTrue);
  c.line(") (else");
  store_tag(c, dst, kTagFalse);
  c.line("))");
}

// The numeric for loop (lvm.c forprep and OP_FORLOOP). The helpers do the work on the four registers from R[A].
void lower_forprep(Ctx &c, const Insn &i) {
  std::string ra = reg(c, i.A());
  std::string s = c.fresh();
  set_site(c, {});
  c.line("(let " + s + " int (call int &\"lua54rt_forprep\" " + ra + "))");
  std::string skip = c.fresh();
  c.line("(let " + skip + " bool (ne int " + s + " (const int 0)))");
  // lvm.c: `pc += Bx + 1` after pc was advanced, so the loop is skipped to pc + Bx + 2.
  std::size_t exit_pc = c.pc + i.Bx() + 2;
  c.line("(if " + skip + " (then (goto " + lbl(exit_pc) + ")) (else (goto " + lbl(c.pc + 1) + ")))");
}

void lower_forloop(Ctx &c, const Insn &i) {
  std::string ra = reg(c, i.A());
  std::string s = c.fresh();
  c.line("(let " + s + " int (call int &\"lua54rt_forloop\" " + ra + "))");
  std::string again = c.fresh();
  c.line("(let " + again + " bool (ne int " + s + " (const int 0)))");
  // lvm.c: `pc -= Bx` after pc was advanced, so the jump back goes to pc + 1 - Bx.
  std::size_t back = c.pc + 1 - i.Bx();
  c.line("(if " + again + " (then (goto " + lbl(back) + ")) (else (goto " + lbl(c.pc + 1) + ")))");
}

// CLOSURE A Bx: a closure of prototype Bx. Its upvalues are captured one by one (lvm.c's pushclosure): from the frame
// (instack: the register idx) or from the enclosing closure (%2: its upvalue idx).
void lower_closure(Ctx &c, const Insn &i) {
  const Proto &child = *c.p.p.at(i.Bx());
  std::size_t fn = c.m.index.at(&child);
  std::string dst = reg(c, i.A());
  c.line("(eval (call void &\"lua54rt_closure\" " + dst + " &\"lua54_fn_" + std::to_string(fn) + "\" (const int " +
         std::to_string(child.numparams) + ") (const int " + std::to_string(child.upvalues.size()) + ")))");
  for (std::size_t k = 0; k < child.upvalues.size(); ++k) {
    const UpvalDesc &u = child.upvalues[k];
    c.line("(eval (call void &\"lua54rt_capture\" " + dst + " (const int " + std::to_string(k) + ") (const int " +
           std::to_string(u.instack) + ") (const int " + std::to_string(u.idx) + ") %2 %1))");
  }
}

// GETUPVAL A B: R[A] := upvalue B. SETUPVAL A B: upvalue B := R[A].
void lower_getupval(Ctx &c, const Insn &i) {
  std::string dst = reg(c, i.A());
  c.line("(eval (call void &\"lua54rt_getupval\" " + dst + " %2 (const int " + std::to_string(i.B()) + ")))");
}

void lower_setupval(Ctx &c, const Insn &i) {
  std::string src = reg(c, i.A());
  c.line("(eval (call void &\"lua54rt_setupval\" %2 (const int " + std::to_string(i.B()) + ") " + src + "))");
}

// CLOSE A: the upvalues of the registers from R[A] up are closed.
void lower_close(Ctx &c, const Insn &i) { c.line("(eval (call void &\"lua54rt_close\" " + reg(c, i.A()) + "))"); }

// CALL A B C: R[A] is the function, R[A+1..] its arguments: B-1 of them, or those up to the stack top when B is 0.
// The results go to R[A..]: C-1 of them, or all of them and the stack top when C is 0.
void lower_call(Ctx &c, const Insn &i) {
  std::string nargs = i.B() == 0 ? values_to_top(c, i.A() + 1) : "(const int " + std::to_string(i.B() - 1) + ")";
  emit_call(c, i.A(), nargs, i.C() == 0 ? -1 : static_cast<int>(i.C()) - 1, c.reg_info(i.A()));
}

// TAILCALL A B k: `return f(x)`. The frame's upvalues close first (lvm.c). The call's values are returned.
void lower_tailcall(Ctx &c, const Insn &i) {
  if (i.k()) c.line("(eval (call void &\"lua54rt_close\" %1))");
  std::string nargs = i.B() == 0 ? values_to_top(c, i.A() + 1) : "(const int " + std::to_string(i.B() - 1) + ")";
  emit_call(c, i.A(), nargs, -1, c.reg_info(i.A()));
  emit_return_values(c, reg(c, i.A()), values_to_top(c, i.A()));
}

// RETURN A B k: B is the number of results plus one; B = 0 returns the values up to the stack top.
void lower_return(Ctx &c, const Insn &i) {
  if (i.k()) c.line("(eval (call void &\"lua54rt_close\" %1))");   // the frame's upvalues close before it goes
  if (i.B() == 0) {
    emit_return_values(c, reg(c, i.A()), values_to_top(c, i.A()));
  } else {
    emit_return_values(c, reg(c, i.A()), "(const int " + std::to_string(i.B() - 1) + ")");
  }
}

void lower_return0(Ctx &c, const Insn &) { emit_return_values(c, "%1", "(const int 0)"); }
void lower_return1(Ctx &c, const Insn &i) { emit_return_values(c, reg(c, i.A()), "(const int 1)"); }

// SETLIST A B C k: t[C + j] := R[A+j] for j = 1..n, n = B or the values up to the stack top when B is 0. With k, C
// is extended by the EXTRAARG after it, and that instruction is skipped.
void lower_setlist(Ctx &c, const Insn &i) {
  long long offset = static_cast<long long>(i.C());
  bool skip_extra = i.k() != 0;
  if (skip_extra) {
    const Insn &extra = c.p.code.at(c.pc + 1);
    if (extra.op() != EXTRAARG) throw std::runtime_error("refused: SETLIST with k is not followed by EXTRAARG");
    offset += static_cast<long long>(extra.Ax()) * 256;   // MAXARG_C + 1
  }
  std::string t = reg(c, i.A()), vals = reg(c, i.A() + 1);
  std::string count = i.B() == 0 ? values_to_top(c, i.A() + 1) : "(const int " + std::to_string(i.B()) + ")";
  c.line("(eval (call void &\"lua54rt_setlist\" " + t + " (const long " + std::to_string(offset) + ") " + vals + " " +
         count + "))");
  if (skip_extra) go(c, c.pc + 2);
}

// VARARGPREP: the extra arguments are saved in the frame's `va` slot; the runtime knows their count at this point.
void lower_varargprep(Ctx &c, const Insn &i) {
  std::string vp = c.fresh();
  c.line("(let " + vp + " (ptr unsigned_char) (call (ptr unsigned_char) &\"lua54rt_varargprep\" %1 (const int " +
         std::to_string(i.A()) + ")))");
  c.line("(store (ptr unsigned_char) $\"va\" " + vp + ")");
}

// VARARG A C: R[A..] := the extra arguments; C is 0 for all of them, and then the stack top is set.
void lower_vararg(Ctx &c, const Insn &i) {
  std::string vp = c.fresh();
  c.line("(let " + vp + " (ptr unsigned_char) (load (ptr unsigned_char) $\"va\"))");
  std::string dst = reg(c, i.A());
  c.line("(eval (call void &\"lua54rt_vararg\" " + vp + " " + dst + " (const int " +
         std::to_string(i.C() == 0 ? -1 : static_cast<int>(i.C()) - 1) + ") (const int " + std::to_string(i.A()) + ")))");
}

// TESTSET A B k: when R[B] is falsy equal to k, skip the JMP after this; otherwise R[A] := R[B] and take the JMP.
void lower_testset(Ctx &c, const Insn &i) {
  std::size_t jmp_pc = c.pc + 1;
  const Insn &j = c.insn_at(jmp_pc);
  if (j.op() != JMP) throw std::runtime_error("refused: a TESTSET is not followed by a JMP");
  std::size_t dest = jmp_pc + 1 + static_cast<std::size_t>(static_cast<long long>(j.sJ()));
  std::size_t skip = c.pc + 2;
  std::string rb = reg(c, i.B());
  std::string t = load_tag(c, rb);
  std::string is_nil = tag_is(c, t, kTagNil), is_false = tag_is(c, t, kTagFalse);
  std::string falsy = c.fresh();
  c.line("(let " + falsy + " bool (const bool 0))");
  c.line("(if " + is_nil + " (then (set " + falsy + " (const bool 1))) (else");
  c.line("(if " + is_false + " (then (set " + falsy + " (const bool 1))) (else (set " + falsy + " (const bool 0))))");
  c.line("))");
  std::string take_copy = "(copy 16 " + reg(c, i.A()) + " " + reg(c, i.B()) + ")";
  if (i.k() != 0) {
    c.line("(if " + falsy + " (then (goto " + lbl(skip) + ")) (else");
    c.line(take_copy);
    c.line("(goto " + lbl(dest) + ")))");
  } else {
    c.line("(if " + falsy + " (then");
    c.line(take_copy);
    c.line("(goto " + lbl(dest) + ")) (else (goto " + lbl(skip) + ")))");
  }
}

// LFALSESKIP A: R[A] := false and skip the next instruction.
void lower_lfalseskip(Ctx &c, const Insn &i) {
  store_tag(c, reg(c, i.A()), kTagFalse);
  go(c, c.pc + 2);
}

// LOADKX A: R[A] := K[Ax] where the EXTRAARG after this instruction holds Ax; that instruction is skipped.
void lower_loadkx(Ctx &c, const Insn &i) {
  const Insn &extra = c.p.code.at(c.pc + 1);
  if (extra.op() != EXTRAARG) throw std::runtime_error("refused: LOADKX is not followed by EXTRAARG");
  std::string src = constant_lv(c, c.p.k.at(extra.Ax()));
  c.line("(copy 16 " + reg(c, i.A()) + " " + src + ")");
  go(c, c.pc + 2);
}

// TFORPREP A Bx: go to the TFORCALL. (The to-be-closed fourth value is not tracked yet.)
void lower_tforprep(Ctx &c, const Insn &i) { go(c, c.pc + 1 + i.Bx()); }

// TFORCALL A C: R[A+4..A+3+C] := R[A](R[A+1], R[A+2]).
void lower_tforcall(Ctx &c, const Insn &i) {
  for (unsigned k = 0; k < 3; ++k) c.line("(copy 16 " + reg(c, i.A() + 4 + k) + " " + reg(c, i.A() + k) + ")");
  emit_call(c, i.A() + 4, "(const int 2)", static_cast<int>(i.C()), " (for iterator 'for iterator')");
}

// TFORLOOP A Bx: if R[A+4] is not nil, R[A+2] := R[A+4] and jump back to the loop body.
void lower_tforloop(Ctx &c, const Insn &i) {
  std::string v = reg(c, i.A() + 4);
  std::string t = load_tag(c, v);
  std::string nil = tag_is(c, t, kTagNil);
  std::size_t back = c.pc + 1 - i.Bx();
  c.line("(if " + nil + " (then (goto " + lbl(c.pc + 1) + ")) (else");
  c.line("(copy 16 " + reg(c, i.A() + 2) + " " + reg(c, i.A() + 4) + ")");
  c.line("(goto " + lbl(back) + ")))");
}

// NEWTABLE A: a fresh table. The size hints are not used.
void lower_newtable(Ctx &c, const Insn &i) { c.line("(eval (call void &\"lua54rt_newtable\" " + reg(c, i.A()) + "))"); }

// GETTABLE A B C: R[A] := R[B][R[C]]. GETI: the key is the integer C. GETFIELD: the key is the string K[C].
void emit_gettable(Ctx &c, unsigned a, const std::string &t, const std::string &key, const std::string &info) {
  std::string dst = reg(c, a);
  set_site(c, {info});
  c.line("(eval (call void &\"lua54rt_gettable\" " + dst + " " + t + " " + key + "))");
}

void lower_gettable(Ctx &c, const Insn &i) {
  std::string t = reg(c, i.B()), key = reg(c, i.C());
  emit_gettable(c, i.A(), t, key, c.reg_info(i.B()));
}

void lower_geti(Ctx &c, const Insn &i) {
  std::string t = reg(c, i.B());
  std::string key = imm_lv(c, static_cast<int>(i.C()), false);
  emit_gettable(c, i.A(), t, key, c.reg_info(i.B()));
}

void lower_getfield(Ctx &c, const Insn &i) {
  std::string t = reg(c, i.B());
  std::string key = constant_lv(c, c.p.k.at(i.C()));
  emit_gettable(c, i.A(), t, key, c.reg_info(i.B()));
}

// GETTABUP A B C: R[A] := upvalue B [K[C]]. The upvalue is loaded into a temporary first.
void lower_gettabup(Ctx &c, const Insn &i) {
  std::string up = c.temp_lv();
  c.line("(eval (call void &\"lua54rt_getupval\" " + up + " %2 (const int " + std::to_string(i.B()) + ")))");
  std::string key = constant_lv(c, c.p.k.at(i.C()));
  emit_gettable(c, i.A(), up, key, c.upval_info(i.B()));
}

// SETTABLE A B C k: R[A][R[B]] := RK(C). SETI: the key is the integer B. SETFIELD: the key is the string K[B].
void emit_settable(Ctx &c, const std::string &t, const std::string &key, const std::string &val, const std::string &info) {
  set_site(c, {info});
  c.line("(eval (call void &\"lua54rt_settable\" " + t + " " + key + " " + val + "))");
}

void lower_settable(Ctx &c, const Insn &i) {
  std::string t = reg(c, i.A()), key = reg(c, i.B());
  std::string val = rk(c, i.C(), i.k());
  emit_settable(c, t, key, val, c.reg_info(i.A()));
}

void lower_seti(Ctx &c, const Insn &i) {
  std::string t = reg(c, i.A());
  std::string key = imm_lv(c, static_cast<int>(i.B()), false);
  std::string val = rk(c, i.C(), i.k());
  emit_settable(c, t, key, val, c.reg_info(i.A()));
}

void lower_setfield(Ctx &c, const Insn &i) {
  std::string t = reg(c, i.A());
  std::string key = constant_lv(c, c.p.k.at(i.B()));
  std::string val = rk(c, i.C(), i.k());
  emit_settable(c, t, key, val, c.reg_info(i.A()));
}

// SETTABUP A B C k: upvalue A [K[B]] := RK(C).
void lower_settabup(Ctx &c, const Insn &i) {
  std::string up = c.temp_lv();
  c.line("(eval (call void &\"lua54rt_getupval\" " + up + " %2 (const int " + std::to_string(i.A()) + ")))");
  std::string key = constant_lv(c, c.p.k.at(i.B()));
  std::string val = rk(c, i.C(), i.k());
  emit_settable(c, up, key, val, c.upval_info(i.A()));
}

// SELF A B C: R[A+1] := R[B]; R[A] := R[B][RK(C)]. The object and the key are copied first: A may be B.
void lower_self(Ctx &c, const Insn &i) {
  std::string obj = c.temp_lv(), key = c.temp_lv();
  c.line("(copy 16 " + obj + " " + reg(c, i.B()) + ")");
  std::string k = rk(c, i.C(), i.k());
  c.line("(copy 16 " + key + " " + k + ")");
  c.line("(copy 16 " + reg(c, i.A() + 1) + " " + obj + ")");
  emit_gettable(c, i.A(), obj, key, c.reg_info(i.B()));
}

void lower_len(Ctx &c, const Insn &i) {
  std::string dst = reg(c, i.A()), src = reg(c, i.B());
  set_site(c, {c.reg_info(i.B())});
  c.line("(eval (call void &\"lua54rt_len\" " + dst + " " + src + "))");
}

// CONCAT A B: R[A] := R[A] .. ... .. R[A+B-1]. The helper reads all of them before it writes R[A].
void lower_concat(Ctx &c, const Insn &i) {
  std::string base = reg(c, i.A());
  std::vector<std::string> infos;
  for (unsigned k = 0; k < i.B(); ++k) infos.push_back(c.reg_info(i.A() + k));
  set_site(c, infos);
  c.line("(eval (call void &\"lua54rt_concat\" " + base + " " + base + " (const int " + std::to_string(i.B()) + ")))");
}

void lower_extraarg(Ctx &, const Insn &) {}

// ---- the table: an entry is null for an opcode that is not lowered yet ----

const Lower *table() {
  static Lower t[NUM_OPCODES] = {};
  static bool built = false;
  if (built) return t;
  built = true;
  t[MOVE] = lower_move;
  t[LOADI] = lower_loadi;
  t[LOADF] = lower_loadf;
  t[LOADK] = lower_loadk;
  t[LOADKX] = lower_loadkx;
  t[LOADFALSE] = lower_loadfalse;
  t[LFALSESKIP] = lower_lfalseskip;
  t[LOADTRUE] = lower_loadtrue;
  t[LOADNIL] = lower_loadnil;
  t[ADD] = lower_add;
  t[SUB] = lower_sub;
  t[MUL] = lower_mul;
  t[ADDI] = lower_addi;
  t[ADDK] = lower_addk;
  t[SUBK] = lower_subk;
  t[MULK] = lower_mulk;
  t[MMBIN] = lower_nothing;
  t[MMBINI] = lower_nothing;
  t[MMBINK] = lower_nothing;
  t[DIV] = lower_div;
  t[IDIV] = lower_idiv;
  t[MOD] = lower_mod;
  t[POW] = lower_pow;
  t[BAND] = lower_band;
  t[BOR] = lower_bor;
  t[BXOR] = lower_bxor;
  t[SHL] = lower_shl;
  t[SHR] = lower_shr;
  t[DIVK] = lower_divk;
  t[IDIVK] = lower_idivk;
  t[MODK] = lower_modk;
  t[POWK] = lower_powk;
  t[BANDK] = lower_bandk;
  t[BORK] = lower_bork;
  t[BXORK] = lower_bxork;
  t[SHRI] = lower_shri;
  t[SHLI] = lower_shli;
  t[UNM] = lower_unm;
  t[BNOT] = lower_bnot;
  t[NOT] = lower_not;
  t[FORPREP] = lower_forprep;
  t[FORLOOP] = lower_forloop;
  t[EQ] = lower_eq;
  t[LT] = lower_lt;
  t[LE] = lower_le;
  t[EQK] = lower_eqk;
  t[EQI] = lower_eqi;
  t[LTI] = lower_lti;
  t[LEI] = lower_lei;
  t[GTI] = lower_gti;
  t[GEI] = lower_gei;
  t[TEST] = lower_test;
  t[TESTSET] = lower_testset;
  t[JMP] = lower_jmp;
  t[RETURN] = lower_return;
  t[RETURN0] = lower_return0;
  t[RETURN1] = lower_return1;
  t[VARARGPREP] = lower_varargprep;
  t[VARARG] = lower_vararg;
  t[CLOSURE] = lower_closure;
  t[GETUPVAL] = lower_getupval;
  t[SETUPVAL] = lower_setupval;
  t[CLOSE] = lower_close;
  t[NEWTABLE] = lower_newtable;
  t[GETTABLE] = lower_gettable;
  t[GETI] = lower_geti;
  t[GETFIELD] = lower_getfield;
  t[GETTABUP] = lower_gettabup;
  t[SETTABLE] = lower_settable;
  t[SETI] = lower_seti;
  t[SETFIELD] = lower_setfield;
  t[SETTABUP] = lower_settabup;
  t[SELF] = lower_self;
  t[LEN] = lower_len;
  t[CONCAT] = lower_concat;
  t[CALL] = lower_call;
  t[TAILCALL] = lower_tailcall;
  t[SETLIST] = lower_setlist;
  t[EXTRAARG] = lower_extraarg;
  t[TFORPREP] = lower_tforprep;
  t[TFORCALL] = lower_tforcall;
  t[TFORLOOP] = lower_tforloop;
  return t;
}

// The IR of one function. The body lowers instruction by instruction, each with its label.
std::string lower_function(const Proto &p, const std::string &name, Module &m) {
  Ctx c(p, m);
  if (p.is_vararg) c.slots.push_back("(slot \"va\" (ptr unsigned_char) 8 8)");   // the saved extra arguments
  for (std::size_t pc = 0; pc < p.code.size(); ++pc) {
    c.pc = pc;
    const Insn &i = p.code[pc];
    c.line("");   // blank line keeps the labels readable
    c.body << "  (label " << lbl(pc) << ")\n";
    if (i.op() >= NUM_OPCODES || table()[i.op()] == nullptr) {
      throw std::runtime_error(std::string("refused: opcode ") + op_name(i.op()) + " is not lowered yet (pc " +
                               std::to_string(pc) + ")");
    }
    table()[i.op()](c, i);
  }
  std::ostringstream out;
  out << "(function \"" << name << "\" (ret void) (params (param %0 \"ret\" (ptr (struct \"LV\")))"
      << " (param %1 \"base\" (ptr (struct \"LV\"))) (param %2 \"cl\" (ptr unsigned_char)))\n";
  for (const std::string &s : c.slots) out << "  " << s << "\n";
  out << c.body.str() << ")\n";
  return out.str();
}

void collect(const Proto &p, std::vector<const Proto *> &out) {
  out.push_back(&p);
  for (const auto &child : p.p) collect(*child, out);
}

// The chunk name as lua.c's messages show it (lobject.c's luaO_chunkid, LUA_IDSIZE 60): a file name is the source
// without '@', and a longer one keeps only its last 56 characters after "...".
std::string chunk_name(const Proto &main) {
  if (!main.source) return "?";
  const std::string &s = *main.source;
  if (!s.empty() && s[0] == '@') {
    if (s.size() <= 60) return s.substr(1);
    return "..." + s.substr(s.size() - 56);
  }
  if (!s.empty() && s[0] == '=') return s.size() <= 60 ? s.substr(1) : s.substr(1, 59);
  return s;
}

}  // namespace

std::string lower_module(const Chunk &chunk, const std::string &source_name) {
  std::vector<const Proto *> protos;
  collect(*chunk.main, protos);
  Module m;
  m.chunkname = chunk_name(*chunk.main);
  for (std::size_t n = 0; n < protos.size(); ++n) m.index[protos[n]] = n;
  std::ostringstream fns;
  for (std::size_t n = 0; n < protos.size(); ++n) {
    fns << "\n" << lower_function(*protos[n], "lua54_fn_" + std::to_string(n), m);
  }
  std::ostringstream out;
  out << "(ir-module \"" << source_name << "\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4)"
      << " (double 8) (long_double 16)))\n";
  out << "(producer \"lua-5.4\")\n";
  out << "(abi-type \"LV\" 16 8 (memory))\n";
  for (const std::string &d : m.data) out << d;   // data first: the functions refer to it
  out << fns.str();
  return out.str();
}

}  // namespace lua54
