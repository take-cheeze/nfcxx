// Lua 5.4 bytecode -> Path B mid-level IR text (docs/notes/pathb-stage2.md; the producer rule is section 1, as amended).
//
// Each Proto becomes one IR function `lua54_fn_N(LV *ret, LV *base)`. A register R(i) is `base + 16*i`; an LV is
// { u8 tag at offset 0; i64 or f64 at offset 8 }, 16 bytes, align 8. The tags are lobject.h's variants.
// Integer fast paths are inline IR. Everything else calls a runtime helper (docs/notes/lua54-pathb.md) that performs the
// whole operation, metamethods included. An opcode with no template in the table below is refused by name.
//
// Arithmetic skips the MMBIN* after it, as lvm.c does on success. On the slow path the helper performs the operation and
// stores the result where the MMBIN would have stored it. So the MMBIN* opcodes lower to nothing: they are never reached
// by falling through an arithmetic op.
#include "lua54_lower.hpp"

#include <cstdio>
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

struct Ctx {
  const Proto &p;
  std::size_t pc = 0;
  int next = 2;                    // %0 is ret, %1 is base
  std::ostringstream body;
  std::vector<std::string> slots;  // slot declarations, emitted before the body

  explicit Ctx(const Proto &proto) : p(proto) {}

  std::string fresh() { return "%" + std::to_string(next++); }
  void line(const std::string &s) { body << "  " << s << "\n"; }

  // A temporary LV in the frame, for an operand the helpers take by address.
  std::string temp_lv() {
    std::string name = "tmp." + std::to_string(pc) + "." + std::to_string(slots.size());
    slots.push_back("(slot \"" + name + "\" (struct \"LV\") 16 8)");
    return "$\"" + name + "\"";
  }

  const Insn &insn_at(std::size_t i) const { return p.code.at(i); }
};

// `set cond RVALUE`: the IR's set takes an operand, so an rvalue (a comparison) goes through a temporary.
void set_rv(Ctx &c, const std::string &cond, const std::string &rvalue) {
  std::string t = c.fresh();
  c.line("(let " + t + " bool " + rvalue + ")");
  c.line("(set " + cond + " " + t + ")");
}

std::string lbl(std::size_t pc) { return "\"pc" + std::to_string(pc) + "\""; }
void go(Ctx &c, std::size_t pc) { c.line("(goto " + lbl(pc) + ")"); }

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

std::string fmt_double(double d) {
  char buf[64];
  std::snprintf(buf, sizeof buf, "%.17g", d);
  return buf;
}

// The LV of a numeric, boolean or nil constant, written to a temporary. Strings are refused for now.
std::string constant_lv(Ctx &c, const Constant &k) {
  std::string t = c.temp_lv();
  switch (k.kind) {
    case Constant::Kind::Integer: store_int(c, t, "(const long " + std::to_string(k.i) + ")"); break;
    case Constant::Kind::Float: store_float(c, t, "(const double " + fmt_double(k.f) + ")"); break;
    case Constant::Kind::Nil: store_tag(c, t, kTagNil); break;
    case Constant::Kind::False: store_tag(c, t, kTagFalse); break;
    case Constant::Kind::True: store_tag(c, t, kTagTrue); break;
    case Constant::Kind::String: throw std::runtime_error("refused: string constants are not lowered yet");
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

// Arithmetic `R[a] := lhs op rhs` where op is ADD, SUB or MUL. The inline path needs both operands to be ints; a
// constant int right operand is known to be an int, so its tag test is not emitted. Otherwise the helper runs.
void emit_arith(Ctx &c, Op op, unsigned a, const std::string &lhs, const std::string &rhs,
                const std::string *int_const) {
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
  c.line("(eval (call void &\"lua54rt_arith\" (const int " + std::to_string(static_cast<int>(op)) + ") " + dst + " " +
         lhs + " " + rhs + "))");
  go(c, c.pc + 2);
}

// The bool of a comparison: `(lt.s|le.s|eq long X Y)` when both are ints, else the helper. `fast_kind` names the
// inline form; the helper gets (kind, A, B), and the result is 0 or 1.
void emit_compare(Ctx &c, const char *fast_op, int kind, const std::string &a, const std::string &b,
                  bool inline_ok, const std::string &ta_tag, const std::string &tb_tag, const std::string &cond) {
  auto slow = [&]() {
    std::string r = c.fresh();
    c.line("(let " + r + " int (call int &\"lua54rt_cmp\" (const int " + std::to_string(kind) + ") " + a + " " + b + "))");
    set_rv(c, cond, "(ne int " + r + " (const int 0))");
  };
  if (!inline_ok) {
    slow();
    return;
  }
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

// --- The op table: one lowering function per opcode. ---

using Lower = void (*)(Ctx &, const Insn &);

void lower_move(Ctx &c, const Insn &i) {
  std::string dst = reg(c, i.A()), src = reg(c, i.B());
  c.line("(copy 16 " + dst + " " + src + ")");
}

void lower_loadi(Ctx &c, const Insn &i) {
  store_int(c, reg(c, i.A()), "(const long " + std::to_string(i.sBx()) + ")");
}

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

void lower_add(Ctx &c, const Insn &i) { emit_arith(c, ADD, i.A(), reg(c, i.B()), reg(c, i.C()), nullptr); }
void lower_sub(Ctx &c, const Insn &i) { emit_arith(c, SUB, i.A(), reg(c, i.B()), reg(c, i.C()), nullptr); }
void lower_mul(Ctx &c, const Insn &i) { emit_arith(c, MUL, i.A(), reg(c, i.B()), reg(c, i.C()), nullptr); }

// ADDI A B sC: R[A] := R[B] + sC, the immediate being an integer.
void lower_addi(Ctx &c, const Insn &i) {
  std::string rb = reg(c, i.B());
  std::string imm = imm_lv(c, i.sC(), false);
  std::string v = "(const long " + std::to_string(i.sC()) + ")";
  emit_arith(c, ADD, i.A(), rb, imm, &v);
}

// The K operand of ADDK/SUBK/MULK: an integer keeps the inline path, anything else goes to the helper.
void arith_k(Ctx &c, const Insn &i, Op op) {
  const Constant &k = c.p.k.at(i.C());
  std::string rb = reg(c, i.B());
  std::string kv = constant_lv(c, k);
  if (k.kind == Constant::Kind::Integer) {
    std::string v = "(const long " + std::to_string(k.i) + ")";
    emit_arith(c, op, i.A(), rb, kv, &v);
  } else {
    emit_arith(c, op, i.A(), rb, kv, nullptr);
  }
}

void lower_addk(Ctx &c, const Insn &i) { arith_k(c, i, ADD); }
void lower_subk(Ctx &c, const Insn &i) { arith_k(c, i, SUB); }
void lower_mulk(Ctx &c, const Insn &i) { arith_k(c, i, MUL); }

// The MMBIN* after an arithmetic op: never reached by falling through (see the header comment), so nothing.
void lower_nothing(Ctx &, const Insn &) {}

// EQ/LT/LE on two registers. The fast path is the int compare; the helper handles the rest.
void lower_eq(Ctx &c, const Insn &i) {
  std::string cond = c.fresh();
  c.line("(let " + cond + " bool (const bool 0))");
  std::string a = reg(c, i.A()), b = reg(c, i.B());
  std::string ta = load_tag(c, a), tb = load_tag(c, b);
  emit_compare(c, "eq", kCmpEq, a, b, true, ta, tb, cond);
  emit_cond_jump(c, cond, i.k());
}

void lower_lt(Ctx &c, const Insn &i) {
  std::string cond = c.fresh();
  c.line("(let " + cond + " bool (const bool 0))");
  std::string a = reg(c, i.A()), b = reg(c, i.B());
  std::string ta = load_tag(c, a), tb = load_tag(c, b);
  emit_compare(c, "lt.s", kCmpLt, a, b, true, ta, tb, cond);
  emit_cond_jump(c, cond, i.k());
}

void lower_le(Ctx &c, const Insn &i) {
  std::string cond = c.fresh();
  c.line("(let " + cond + " bool (const bool 0))");
  std::string a = reg(c, i.A()), b = reg(c, i.B());
  std::string ta = load_tag(c, a), tb = load_tag(c, b);
  emit_compare(c, "le.s", kCmpLe, a, b, true, ta, tb, cond);
  emit_cond_jump(c, cond, i.k());
}

// Comparisons with an immediate: `R[A] op sB`. C is the isf flag: a float immediate always goes to the helper.
// GTI and GEI compare the other way round (sB < R[A], sB <= R[A]).
void imm_compare(Ctx &c, const Insn &i, const char *fast_op, int kind, bool swapped) {
  std::string cond = c.fresh();
  c.line("(let " + cond + " bool (const bool 0))");
  std::string ra = reg(c, i.A());
  std::string ta = load_tag(c, ra);
  std::string imm = imm_lv(c, i.sB(), i.C() != 0);
  bool inline_ok = i.C() == 0;   // a float immediate (C flag set) always goes to the helper
  if (inline_ok) {
    // The immediate is an int, so only R[A]'s tag is tested.
    std::string ai = tag_is(c, ta, kTagInt);
    c.line("(if " + ai + " (then");
    std::string x = load_value(c, ra, "long");
    std::string y = "(const long " + std::to_string(i.sB()) + ")";
    if (swapped) set_rv(c, cond, std::string("(") + fast_op + " long " + y + " " + x + ")");
    else set_rv(c, cond, std::string("(") + fast_op + " long " + x + " " + y + ")");
    c.line(") (else");
    std::string r = c.fresh();
    if (swapped) c.line("(let " + r + " int (call int &\"lua54rt_cmp\" (const int " + std::to_string(kind) + ") " + imm + " " + ra + "))");
    else c.line("(let " + r + " int (call int &\"lua54rt_cmp\" (const int " + std::to_string(kind) + ") " + ra + " " + imm + "))");
    set_rv(c, cond, "(ne int " + r + " (const int 0))");
    c.line("))");
  } else {
    std::string r = c.fresh();
    if (swapped) c.line("(let " + r + " int (call int &\"lua54rt_cmp\" (const int " + std::to_string(kind) + ") " + imm + " " + ra + "))");
    else c.line("(let " + r + " int (call int &\"lua54rt_cmp\" (const int " + std::to_string(kind) + ") " + ra + " " + imm + "))");
    set_rv(c, cond, "(ne int " + r + " (const int 0))");
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

void lower_jmp(Ctx &c, const Insn &i) {
  go(c, c.pc + 1 + static_cast<std::size_t>(static_cast<long long>(i.sJ())));
}

// RETURN A B k: B is the number of results plus one. B = 1 returns nothing and B = 2 returns R[A]. A count taken from
// the stack top (B = 0), more than one value, or upvalues to close (k) are refused for now.
void lower_return(Ctx &c, const Insn &i) {
  if (i.k()) throw std::runtime_error("refused: RETURN with upvalues to close is not lowered yet");
  if (i.B() == 1) {
    c.line("(return)");
  } else if (i.B() == 2) {
    c.line("(copy 16 %0 " + reg(c, i.A()) + ")");
    c.line("(return)");
  } else {
    throw std::runtime_error("refused: RETURN with several values is not lowered yet");
  }
}

void lower_return0(Ctx &c, const Insn &) { c.line("(return)"); }

void lower_return1(Ctx &c, const Insn &i) {
  c.line("(copy 16 %0 " + reg(c, i.A()) + ")");
  c.line("(return)");
}

// Table: an entry is null for an opcode that is not lowered yet. `refuse_reason` gives the reason for the refusal.
struct Entry {
  Lower fn;
  const char *note;
};

const Entry *table() {
  static Entry t[NUM_OPCODES] = {};
  static bool built = false;
  if (built) return t;
  built = true;
  t[MOVE] = {lower_move, nullptr};
  t[LOADI] = {lower_loadi, nullptr};
  t[LOADF] = {lower_loadf, nullptr};
  t[LOADK] = {lower_loadk, nullptr};
  t[LOADFALSE] = {lower_loadfalse, nullptr};
  t[LOADTRUE] = {lower_loadtrue, nullptr};
  t[LOADNIL] = {lower_loadnil, nullptr};
  t[ADD] = {lower_add, nullptr};
  t[SUB] = {lower_sub, nullptr};
  t[MUL] = {lower_mul, nullptr};
  t[ADDI] = {lower_addi, nullptr};
  t[ADDK] = {lower_addk, nullptr};
  t[SUBK] = {lower_subk, nullptr};
  t[MULK] = {lower_mulk, nullptr};
  t[MMBIN] = {lower_nothing, nullptr};
  t[MMBINI] = {lower_nothing, nullptr};
  t[MMBINK] = {lower_nothing, nullptr};
  t[EQ] = {lower_eq, nullptr};
  t[LT] = {lower_lt, nullptr};
  t[LE] = {lower_le, nullptr};
  t[EQK] = {lower_eqk, nullptr};
  t[EQI] = {lower_eqi, nullptr};
  t[LTI] = {lower_lti, nullptr};
  t[LEI] = {lower_lei, nullptr};
  t[GTI] = {lower_gti, nullptr};
  t[GEI] = {lower_gei, nullptr};
  t[TEST] = {lower_test, nullptr};
  t[JMP] = {lower_jmp, nullptr};
  t[RETURN] = {lower_return, nullptr};
  t[RETURN0] = {lower_return0, nullptr};
  t[RETURN1] = {lower_return1, nullptr};
  // VARARGPREP moves the fixed parameters above the varargs; registers keep their contents, and no lowered op reads varargs.
  t[VARARGPREP] = {lower_nothing, nullptr};
  return t;
}

// The IR of one function. The body lowers instruction by instruction, each with its label.
std::string lower_function(const Proto &p, const std::string &name) {
  Ctx c(p);
  for (std::size_t pc = 0; pc < p.code.size(); ++pc) {
    c.pc = pc;
    const Insn &i = p.code[pc];
    c.line("");   // blank line keeps the labels readable
    c.body << "  (label " << lbl(pc) << ")\n";
    if (i.op() >= NUM_OPCODES || table()[i.op()].fn == nullptr) {
      throw std::runtime_error(std::string("refused: opcode ") + op_name(i.op()) + " is not lowered yet (pc " +
                               std::to_string(pc) + ")");
    }
    table()[i.op()].fn(c, i);
  }
  std::ostringstream out;
  out << "(function \"" << name << "\" (ret void) (params (param %0 \"ret\" (ptr (struct \"LV\")))"
      << " (param %1 \"base\" (ptr (struct \"LV\"))))\n";
  for (const std::string &s : c.slots) out << "  " << s << "\n";
  out << c.body.str() << ")\n";
  return out.str();
}

void collect(const Proto &p, std::vector<const Proto *> &out) {
  out.push_back(&p);
  for (const auto &child : p.p) collect(*child, out);
}

}  // namespace

std::string lower_module(const Chunk &chunk, const std::string &source_name) {
  std::vector<const Proto *> protos;
  collect(*chunk.main, protos);
  std::ostringstream out;
  out << "(ir-module \"" << source_name << "\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4)"
      << " (double 8) (long_double 16)))\n";
  out << "(producer \"lua-5.4\")\n";
  out << "(abi-type \"LV\" 16 8 (memory))\n";
  for (std::size_t n = 0; n < protos.size(); ++n) {
    out << "\n" << lower_function(*protos[n], "lua54_fn_" + std::to_string(n));
  }
  return out.str();
}

}  // namespace lua54
