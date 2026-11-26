// nfcast: Lua 5.4 binary chunks (string.dump, luac) run on the nfcast stack (docs/notes/ast.md, "Bytecode").
//
// tools/lua54bc reads a chunk; each of its functions becomes an nfcast Proto whose body is a BcBody: a register machine over the
// frame that call_closure sets up as for any script function. The registers of a frame are its parameters, locals and
// temporaries R0 .. maxstacksize-1 (the frame's slots); the varargs sit above them; the calls, returns, tail calls, collector
// safe points and error positions are the AST's. A register captured by a closure holds a Cell while the closure lives (T_CELL,
// as a captured local of the AST does); OP_CLOSE, and RETURN or TAILCALL with the k bit, give the value back to the register, so
// each loop iteration gets a fresh variable as in Lua. Error messages name the variables as Lua's ldebug.c does (getobjname),
// from the debug information of the chunk. The chunk is trusted as luac output is: there is no verifier beyond the subset check.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <optional>
#include <stdexcept>
#include <unordered_map>

#include "../../tools/lua54bc/lua54_chunk.hpp"
#include "nfcast_impl.hpp"

namespace nfcast {

namespace L = lua54;

// A local variable of the chunk's debug information (LocVar), kept only when it has a name.
struct BcLocal {
  std::string name;
  int startpc;
  int endpc;
};

// The body of a function of a binary chunk (declared in nfcast_impl.hpp: Proto::bc points at it).
struct BcBody : Node {
  std::vector<L::Insn> insns;
  std::vector<Value> kst;          // the constants (strings are also in the Proto's consts, for the collector)
  std::vector<int> linev;          // the source line of each instruction (-1 in a stripped chunk)
  std::vector<BcLocal> locs;       // the named locals, in order of declaration
  std::vector<std::string> upnames;  // the upvalue names ("?" without debug information)
  std::vector<Node*> names;        // the name nodes of the operands of each instruction (see name_of in exec); created on demand
  std::unordered_map<int, std::vector<Node*>> concat_names;  // the same for the operands of a CONCAT
  Value eval(Frame&) override { return Value(); }  // never: a body runs as a statement, from call_closure
  int exec(Frame& f) override;
};

namespace {

// The register R[r] as a value: a register holding a Cell is a captured variable, read through the Cell.
inline Value rd(const Value* R, unsigned r) {
  const Value& v = R[r];
  return v.t == T_CELL ? static_cast<Cell*>(v.o)->v : v;
}

// Stores V in register R[r] (through the Cell of a captured variable).
inline void wr(Value* R, unsigned r, const Value& v) {
  Value& d = R[r];
  if (d.t == T_CELL) static_cast<Cell*>(d.o)->v = v;
  else d = v;
}

// Gives the values of the captured registers FROM .. N-1 back to their registers (OP_CLOSE; RETURN and TAILCALL with k).
void close_from(Value* R, unsigned from, unsigned n) {
  for (unsigned r = from; r < n; ++r)
    if (R[r].t == T_CELL) R[r] = static_cast<Cell*>(R[r].o)->v;
}

// Copies N values from SRC to DST, which may overlap.
void move_values(Value* dst, const Value* src, int n) {
  if (dst <= src) {
    for (int k = 0; k < n; ++k) dst[k] = src[k];
  } else {
    for (int k = n - 1; k >= 0; --k) dst[k] = src[k];
  }
}

// t[key] as the script reads it: raw when the table has the key or no metatable, else through the metamethods.
Value bc_get(State& S, const Value& t, const Value& key, Node* where) {
  if (t.t == T_TAB) {
    Value v = t.tab()->get(key);
    if (!v.is_nil() || !t.tab()->meta) return v;
  }
  return index_slow(S, t, key, where);
}

// t[key] = v as the script writes it.
void bc_set(State& S, const Value& t, const Value& key, const Value& v, Node* where) {
  if (t.t == T_TAB && !t.tab()->meta && !v.is_nil() && (key.t == T_INT || key.t == T_STR)) {
    t.tab()->set(S, key, v);
    return;
  }
  setindex_slow(S, t, key, v, where);
}

// The arithmetic and bitwise operators: integers with wrapping, and everything else (floats, strings, metamethods) by arith_slow.
// NA and NB name the operands in error messages (null for a constant).
Value bc_arith(State& S, int op, const Value& a, const Value& b, Node* na, Node* nb) {
  if (a.t == T_INT && b.t == T_INT) {
    switch (op) {
      case AR_ADD: return Value::integer(nfcr_add(a.i, b.i));
      case AR_SUB: return Value::integer(nfcr_sub(a.i, b.i));
      case AR_MUL: return Value::integer(nfcr_mul(a.i, b.i));
      default: break;
    }
  }
  return arith_slow(S, op, a, b, na, nb);
}

// The arithmetic operator of a metamethod event (ltm.h: TM_ADD .. TM_SHR), as the MMBIN instructions name it.
int tm_to_arith(int tm) {
  switch (tm) {
    case 6: return AR_ADD;
    case 7: return AR_SUB;
    case 8: return AR_MUL;
    case 9: return AR_MOD;
    case 10: return AR_POW;
    case 11: return AR_DIV;
    case 12: return AR_IDIV;
    case 13: return AR_BAND;
    case 14: return AR_BOR;
    case 15: return AR_BXOR;
    case 16: return AR_SHL;
    case 17: return AR_SHR;
    default: return AR_ADD;
  }
}

// The error of a numeric for loop whose WHAT (limit, step, initial value) is not a number (lvm.c, Lua 5.4.9).
[[noreturn]] void for_error(State& S, const char* what, const Value& v) {
  S.rt_error(std::string("bad 'for' ") + what + " (number expected, got " + State::type_name(v) + ")");
}

// The loop state of a numeric for at RA (lvm.c forprep): true when the loop does not run. An integer loop keeps its iteration count
// in the limit's register; a float loop keeps floats in all of them. The values must be numbers or strings that read as numbers.
bool for_prep(State& S, Value* ra) {
  if (ra[0].t == T_INT && ra[2].t == T_INT) {
    std::int64_t init = ra[0].i, step = ra[2].i, limit = 0;
    if (step == 0) S.rt_error("'for' step is zero");
    Value lim;
    if (!to_number(ra[1], &lim)) for_error(S, "limit", ra[1]);
    // forlimit: the limit as an integer, rounded towards the loop; a float beyond the integers ends the loop at the nearest one.
    if (lim.t == T_INT) {
      limit = lim.i;
    } else {
      double d = lim.d;
      double g = step < 0 ? std::ceil(d) : std::floor(d);
      if (g >= -9223372036854775808.0 && g < 9223372036854775808.0) {
        limit = static_cast<std::int64_t>(g);
      } else if (0 < d) {
        if (step < 0) return true;
        limit = std::numeric_limits<std::int64_t>::max();
      } else {
        if (step > 0) return true;
        limit = std::numeric_limits<std::int64_t>::min();
      }
    }
    wr(ra, 3, Value::integer(init));
    if (step > 0 ? init > limit : init < limit) return true;
    std::uint64_t count;
    if (step > 0) {
      count = static_cast<std::uint64_t>(limit) - static_cast<std::uint64_t>(init);
      if (step != 1) count /= static_cast<std::uint64_t>(step);
    } else {
      count = static_cast<std::uint64_t>(init) - static_cast<std::uint64_t>(limit);
      count /= static_cast<std::uint64_t>(-(step + 1)) + 1u;
    }
    ra[1] = Value::integer(static_cast<std::int64_t>(count));
    return false;
  }
  Value vlim, vstep, vinit;
  if (!to_number(ra[1], &vlim)) for_error(S, "limit", ra[1]);
  if (!to_number(ra[2], &vstep)) for_error(S, "step", ra[2]);
  if (!to_number(ra[0], &vinit)) for_error(S, "initial value", ra[0]);
  double flimit = vlim.t == T_INT ? static_cast<double>(vlim.i) : vlim.d;
  double fstep = vstep.t == T_INT ? static_cast<double>(vstep.i) : vstep.d;
  double finit = vinit.t == T_INT ? static_cast<double>(vinit.i) : vinit.d;
  if (fstep == 0) S.rt_error("'for' step is zero");
  if (fstep > 0 ? flimit < finit : finit < flimit) return true;
  ra[0] = Value::number(finit);
  ra[1] = Value::number(flimit);
  ra[2] = Value::number(fstep);
  wr(ra, 3, Value::number(finit));
  return false;
}

// The line of each instruction (ldebug.c): the deltas of lineinfo, from the absolute lines of abslineinfo.
std::vector<int> line_table(const L::Proto& lp) {
  std::vector<int> lines(lp.code.size(), -1);
  if (lp.lineinfo.size() != lp.code.size()) return lines;  // stripped
  int line = lp.linedefined;
  std::size_t ai = 0;
  for (std::size_t pc = 0; pc < lp.code.size(); ++pc) {
    int d = static_cast<std::int8_t>(lp.lineinfo[pc]);
    if (d == -128) {  // ABSLINEINFO: the line of this instruction is stored in abslineinfo
      while (ai < lp.abslineinfo.size() && lp.abslineinfo[ai].pc < static_cast<int>(pc)) ++ai;
      if (ai < lp.abslineinfo.size() && lp.abslineinfo[ai].pc == static_cast<int>(pc)) line = lp.abslineinfo[ai++].line;
    } else {
      line += d;
    }
    lines[pc] = line;
  }
  return lines;
}

// The name of a chunk as luaO_chunkid gives it: "@file" and "=name" stand for themselves, a chunk from a string shows its
// first line in [string "..."].
std::string chunk_id(const std::string& source) {
  if (!source.empty() && (source[0] == '@' || source[0] == '=')) return source.substr(1);
  std::size_t nl = source.find('\n');
  std::size_t len = nl == std::string::npos ? source.size() : nl;
  const std::size_t bufflen = 45;
  if (nl == std::string::npos && source.size() < bufflen) return "[string \"" + source + "\"]";
  if (len > bufflen) len = bufflen;
  return "[string \"" + source.substr(0, len) + "...\"]";
}

// ---- names for error messages (ldebug.c: getobjname, findsetreg, luaF_getlocalname) ----

// The name of the N-th local variable active at PC, or null.
const std::string* local_name(const BcBody& b, int n, int pc) {
  for (const BcLocal& l : b.locs) {
    if (l.startpc > pc) break;
    if (pc < l.endpc && --n == 0) return &l.name;
  }
  return nullptr;
}

// Whether the instruction sets register A (lopcodes.c, the A mode).
bool sets_a(int op) {
  switch (op) {
    case L::MOVE: case L::LOADI: case L::LOADF: case L::LOADK: case L::LOADKX: case L::LOADFALSE: case L::LFALSESKIP:
    case L::LOADTRUE: case L::LOADNIL: case L::GETUPVAL: case L::GETTABUP: case L::GETTABLE: case L::GETI: case L::GETFIELD:
    case L::NEWTABLE: case L::SELF: case L::ADDI: case L::ADDK: case L::SUBK: case L::MULK: case L::MODK: case L::POWK:
    case L::DIVK: case L::IDIVK: case L::BANDK: case L::BORK: case L::BXORK: case L::SHRI: case L::SHLI: case L::ADD:
    case L::SUB: case L::MUL: case L::MOD: case L::POW: case L::DIV: case L::IDIV: case L::BAND: case L::BOR: case L::BXOR:
    case L::SHL: case L::SHR: case L::UNM: case L::BNOT: case L::NOT: case L::LEN: case L::CONCAT: case L::TESTSET:
    case L::CALL: case L::TAILCALL: case L::FORLOOP: case L::FORPREP: case L::TFORLOOP: case L::CLOSURE: case L::VARARG:
    case L::VARARGPREP:
      return true;
    default:
      return false;
  }
}

// The last instruction before LASTPC that set register REG, or -1 when a jump may skip it (findsetreg).
int findsetreg(const BcBody& b, int lastpc, int reg) {
  int setreg = -1, jmptarget = 0;
  int last_op = b.insns[static_cast<std::size_t>(lastpc)].op();
  if (last_op == L::MMBIN || last_op == L::MMBINI || last_op == L::MMBINK) --lastpc;  // not executed
  for (int pc = 0; pc < lastpc; ++pc) {
    const L::Insn i = b.insns[static_cast<std::size_t>(pc)];
    int op = i.op();
    int a = static_cast<int>(i.A());
    bool change;
    if (op == L::LOADNIL) {
      change = a <= reg && reg <= a + static_cast<int>(i.B());
    } else if (op == L::TFORCALL) {
      change = reg >= a + 2;
    } else if (op == L::CALL || op == L::TAILCALL) {
      change = reg >= a;
    } else if (op == L::JMP) {
      int dest = pc + 1 + i.sJ();
      if (dest <= lastpc && dest > jmptarget) jmptarget = dest;
      change = false;
    } else {
      change = sets_a(op) && reg == a;
    }
    if (change) setreg = pc < jmptarget ? -1 : pc;
  }
  return setreg;
}

// A name for the value of register REG at LASTPC: "local", "global", "field", "upvalue", "constant" or "method", and the name in
// NAME; null when there is none (getobjname).
const char* getobjname(const BcBody& b, int lastpc, int reg, std::string& name);

// The string constant K[c] as a name ("?" when it is not one).
std::string kname(const BcBody& b, unsigned c) {
  const Value& k = b.kst[c];
  return k.t == T_STR ? std::string(k.s()->view()) : std::string("?");
}

// "global" when the table T of a field access is _ENV, else "field" (gxf).
const char* gxf(const BcBody& b, int pc, const L::Insn& i, bool isup) {
  std::string t;
  if (isup) {
    t = b.upnames[i.B()];
  } else {
    getobjname(b, pc, static_cast<int>(i.B()), t);
  }
  return t == "_ENV" ? "global" : "field";
}

const char* getobjname(const BcBody& b, int lastpc, int reg, std::string& name) {
  if (const std::string* ln = local_name(b, reg + 1, lastpc)) {
    name = *ln;
    return "local";
  }
  int pc = findsetreg(b, lastpc, reg);
  if (pc == -1) return nullptr;
  const L::Insn i = b.insns[static_cast<std::size_t>(pc)];
  switch (i.op()) {
    case L::MOVE:
      if (static_cast<int>(i.B()) < static_cast<int>(i.A())) return getobjname(b, pc, static_cast<int>(i.B()), name);
      break;
    case L::GETTABUP:
      name = kname(b, i.C());
      return gxf(b, pc, i, true);
    case L::GETTABLE: {
      std::string key;
      const char* what = getobjname(b, pc, static_cast<int>(i.C()), key);
      name = (what && std::string(what) == "constant") ? key : std::string("?");
      return gxf(b, pc, i, false);
    }
    case L::GETI:
      name = "integer index";
      return "field";
    case L::GETFIELD:
      name = kname(b, i.C());
      return gxf(b, pc, i, false);
    case L::GETUPVAL:
      name = b.upnames[i.B()];
      return "upvalue";
    case L::LOADK:
    case L::LOADKX: {
      unsigned k = i.op() == L::LOADK ? i.Bx() : L::Insn(b.insns[static_cast<std::size_t>(pc) + 1]).Ax();
      if (b.kst[k].t == T_STR) {
        name = kname(b, k);
        return "constant";
      }
      break;
    }
    case L::SELF:
      if (i.k()) {
        name = kname(b, i.C());
      } else {
        std::string key;
        const char* what = getobjname(b, pc, static_cast<int>(i.C()), key);
        name = (what && std::string(what) == "constant") ? key : std::string("?");
      }
      return "method";
    default:
      break;
  }
  return nullptr;
}

// The operand of an instruction as an error message names it: a register of the frame (or an upvalue). It is created the first
// time an error may name it, and kept with the function.
struct BcName : Node {
  const BcBody* body = nullptr;
  int pc = 0;
  int reg = 0;
  bool upval = false;
  Value eval(Frame&) override { return Value(); }
  void describe(std::string& out) const override {
    std::string name;
    const char* kind = upval ? "upvalue" : getobjname(*body, pc, reg, name);
    if (upval) name = body->upnames[static_cast<std::size_t>(reg)];
    if (kind) out = std::string(kind) + " '" + name + "'";
  }
};

// The name node of an operand of the instruction at PC (slot 0 or 1), made on first use.
Node* name_of(Proto* P, BcBody* b, int pc, unsigned slot, unsigned reg, bool upval) {
  Node*& c = b->names[static_cast<std::size_t>(pc) * 2 + slot];
  if (!c) {
    BcName* n = P->make<BcName>();
    n->body = b;
    n->pc = pc;
    n->reg = static_cast<int>(reg);
    n->upval = upval;
    c = n;
  }
  return c;
}

// Builds the Proto of LP and, first, of its children. An opcode outside the subset fails the whole chunk at load time.
Proto* build(State& S, const L::Proto& lp, const std::string& parent_chunk, bool main) {
  std::string chunk = lp.source ? chunk_id(*lp.source) : parent_chunk;
  Proto* p = new Proto();
  try {
    p->chunk = chunk;
    p->linedefined = lp.linedefined;
    p->name = main ? "main chunk" : "function <" + chunk + ":" + std::to_string(lp.linedefined) + ">";
    p->nparams = lp.numparams;
    p->vararg = lp.is_vararg;
    p->nslots = std::max<int>(lp.maxstacksize, 1);
    BcBody* body = p->make<BcBody>();
    for (const L::UpvalDesc& u : lp.upvalues) {
      UpvalDesc d;
      d.from_local = u.instack != 0;
      d.index = u.idx;
      d.name = u.name ? *u.name : std::string("?");
      p->upvals.push_back(d);
      body->upnames.push_back(d.name);
    }
    for (const L::Constant& c : lp.k) {
      switch (c.kind) {
        case L::Constant::Kind::Nil: body->kst.push_back(Value()); break;
        case L::Constant::Kind::False: body->kst.push_back(Value::boolean(false)); break;
        case L::Constant::Kind::True: body->kst.push_back(Value::boolean(true)); break;
        case L::Constant::Kind::Integer: body->kst.push_back(Value::integer(c.i)); break;
        case L::Constant::Kind::Float: body->kst.push_back(Value::number(c.f)); break;
        case L::Constant::Kind::String: {
          String* s = S.str(c.s);
          p->consts.push_back(s);
          body->kst.push_back(Value::str(s));
          break;
        }
      }
    }
    body->insns = lp.code;
    body->linev = line_table(lp);
    for (std::size_t pc = 0; pc < lp.code.size(); ++pc) {
      if (lp.code[pc].op() == L::TBC)
        throw std::runtime_error("refused: opcode TBC (a to-be-closed variable) is not supported by nfcast (" + chunk + ":" +
                                 std::to_string(body->linev[pc]) + ")");
    }
    for (const L::LocVar& v : lp.locvars)
      if (v.name) body->locs.push_back(BcLocal{*v.name, v.startpc, v.endpc});
    body->names.assign(lp.code.size() * 2, nullptr);
    body->line = lp.linedefined;
    for (const auto& c : lp.p) p->children.push_back(build(S, *c, chunk, false));  // owned by p from here on
    p->body = body;
    p->bc = body;
  } catch (...) {
    p->release();
    throw;
  }
  return p;
}

// The stack-access functions' frame: the innermost running script function, which must be a bytecode function.
Frame* bc_frame(State& S, const char* who) {
  Frame* f = S.cur;
  if (!f || !f->cl->proto->bc) S.rt_error(std::string(who) + ": the calling function is not a bytecode function");
  return f;
}

// The register number argument: an integer in 0 .. NREGS-1.
unsigned bc_reg_arg(State& S, Args a, const char* who, unsigned nregs) {
  std::int64_t i = 0;
  if (a.n < 1) S.arg_error(1, who, "number expected, got no value");
  if (!to_integer(a[0], &i)) {
    std::string msg = a[0].is_number() ? std::string("number has no integer representation")
                                       : std::string("number expected, got ") + State::type_name(a[0]);
    S.arg_error(1, who, msg);
  }
  if (i < 0 || static_cast<std::uint64_t>(i) >= nregs)
    S.arg_error(1, who, "register index out of range (the frame has " + std::to_string(nregs) + " registers)");
  return static_cast<unsigned>(i);
}

}  // namespace

Closure* load_binary(State& S, std::string_view code, const std::string& chunkname, std::string* err) {
  L::Chunk ch;
  try {
    ch = L::load(reinterpret_cast<const std::uint8_t*>(code.data()), code.size(), chunkname);
  } catch (const std::exception& e) {
    if (err) *err = e.what();
    return nullptr;
  }
  Proto* p;
  try {
    p = build(S, *ch.main, "?", true);
  } catch (const std::exception& e) {
    if (err) *err = e.what();
    return nullptr;
  }
  Closure* cl = new_closure(S, p, static_cast<std::uint32_t>(p->upvals.size()));
  p->release();  // the closure holds the only reference now
  // As load does: the first upvalue of a main function is the environment, the others start as nil.
  for (std::uint32_t i = 0; i < cl->nup; ++i) cl->up[i] = new_cell(S, i == 0 ? Value::table(S.globals) : Value());
  return cl;
}

// ---- the interpreter ----------------------------------------------------------------------------------------------------------
// The instructions run in groups, each in a function of its own that the back ends do not inline (__attribute__((noinline))):
// every script call goes through exec and one group, so the stack a script level costs is the frame of exec, which is small,
// and the frame of the group that makes the call (Path B gave one function with every case a frame of several KB, which
// overflowed the stack at a depth of about a thousand calls).

namespace {

// The state of a running bytecode frame, passed to the groups.
struct BcRun {
  State& S;
  Frame& f;
  Closure* cl;
  Proto* P;
  BcBody* body;
  Value* R;     // the registers
  Value* ftop;  // the frame's top: its registers, and the varargs, which sit above them
  Value* mtop;  // the end of the values of the last call or `...` with all its results (C == 0), read by the next instruction
  const Value* K;
  const L::Insn* code;
  const int* lines;
  int pc;       // the index of the next instruction
};

// The name node of operand SLOT (register REG, or the upvalue REG) of the instruction being run.
Node* op_name(BcRun& r, unsigned slot, unsigned reg, bool upval) { return name_of(r.P, r.body, r.pc - 1, slot, reg, upval); }

// Moves the varargs up when a multiple-results instruction is about to write to END or beyond where they are.
void keep_varargs_above(BcRun& r, Value* end) {
  Frame& f = r.f;
  State& S = r.S;
  if (f.nva > 0 && end > f.va) {
    if (end + f.nva + 128 > S.stack_end) S.rt_error("stack overflow");
    std::memmove(static_cast<void*>(end), static_cast<const void*>(f.va), sizeof(Value) * static_cast<std::size_t>(f.nva));
    f.va = end;
    r.ftop = end + f.nva;
    if (r.mtop < r.ftop) r.mtop = r.ftop;
    S.top = r.ftop;
  }
}

// A comparison: the next instruction is a jump, taken when the result is the instruction's k.
void cond_jump(BcRun& r, bool cond, const L::Insn& i) {
  if (cond != (i.k() != 0)) {
    ++r.pc;
  } else {
    int d = r.code[r.pc].sJ() + 1;
    r.pc += d;
    if (d < 0) safepoint(r.S);
  }
}

// An arithmetic instruction with an immediate or a constant: the MMBINI or MMBINK after it (MM) gives the operator, the operand
// register (A) and the order the metamethod sees (k: the operands were swapped, as Lua does for a commutative operator whose
// constant comes first); the number is the same either way. Lua writes `a - 1` as ADDI with -1, so the operator is MM's.
Value arith_mm(BcRun& r, const L::Insn& mm, const Value& imm, Node* nreg) {
  Value a = rd(r.R, mm.A());
  int op = tm_to_arith(static_cast<int>(mm.C()));
  return mm.k() ? bc_arith(r.S, op, imm, a, nullptr, nreg) : bc_arith(r.S, op, a, imm, nreg, nullptr);
}

// ---- the groups of instructions ----

// Registers, constants, moves, jumps, tests and the upvalues.
[[gnu::noinline]] int op_load(BcRun& r, const L::Insn& i) {
  [[maybe_unused]] State& S = r.S;
  [[maybe_unused]] Closure* cl = r.cl;
  [[maybe_unused]] Value* R = r.R;
  [[maybe_unused]] const Value* K = r.K;
  [[maybe_unused]] int& pc = r.pc;
  [[maybe_unused]] const L::Insn* code = r.code;
  const unsigned A = i.A();
  switch (i.op()) {
    case L::MOVE: wr(R, A, rd(R, i.B())); break;
    case L::LOADI: wr(R, A, Value::integer(i.sBx())); break;
    case L::LOADF: wr(R, A, Value::number(static_cast<double>(i.sBx()))); break;
    case L::LOADK: wr(R, A, K[i.Bx()]); break;
    case L::LOADKX: wr(R, A, K[L::Insn(code[pc]).Ax()]); ++pc; break;
    case L::LOADFALSE: wr(R, A, Value::boolean(false)); break;
    case L::LFALSESKIP: wr(R, A, Value::boolean(false)); ++pc; break;
    case L::LOADTRUE: wr(R, A, Value::boolean(true)); break;
    case L::LOADNIL:
      for (unsigned j = 0; j <= i.B(); ++j) wr(R, A + j, Value());
      break;
    case L::GETUPVAL: wr(R, A, cl->up[i.B()]->v); break;
    case L::SETUPVAL: cl->up[i.B()]->v = rd(R, A); break;
    case L::NOT: wr(R, A, Value::boolean(!rd(R, i.B()).truthy())); break;
    case L::CLOSE: close_from(R, A, static_cast<unsigned>(r.P->nslots)); break;
    case L::JMP: {
      int d = i.sJ();
      pc += d;
      if (d < 0) safepoint(S);
      break;
    }
    case L::TEST: cond_jump(r, rd(R, A).truthy(), i); break;
    case L::TESTSET: {
      Value rb = rd(R, i.B());
      if (!rb.truthy() == (i.k() != 0)) {
        ++pc;
      } else {
        wr(R, A, rb);
        int d = code[pc].sJ() + 1;
        pc += d;
        if (d < 0) safepoint(S);
      }
      break;
    }
    case L::VARARGPREP: break;  // the varargs were set up by the call (enter_closure)
    case L::EXTRAARG: break;    // only read by the instruction before it
    default: S.rt_error("unsupported bytecode instruction");
  }
  return C_NORMAL;
}

// Tables: the reads and writes that may reach a metamethod, the constructors, the length and the concatenation.
[[gnu::noinline]] int op_table(BcRun& r, const L::Insn& i) {
  [[maybe_unused]] State& S = r.S;
  [[maybe_unused]] Closure* cl = r.cl;
  [[maybe_unused]] Value* R = r.R;
  [[maybe_unused]] const Value* K = r.K;
  [[maybe_unused]] int& pc = r.pc;
  [[maybe_unused]] const L::Insn* code = r.code;
  [[maybe_unused]] Value*& ftop = r.ftop;
  [[maybe_unused]] Proto* P = r.P;
  const unsigned A = i.A();
  switch (i.op()) {
    case L::GETTABUP: wr(R, A, bc_get(S, cl->up[i.B()]->v, K[i.C()], op_name(r, 0, i.B(), true))); break;
    case L::GETTABLE: wr(R, A, bc_get(S, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false))); break;
    case L::GETI: wr(R, A, bc_get(S, rd(R, i.B()), Value::integer(i.C()), op_name(r, 0, i.B(), false))); break;
    case L::GETFIELD: wr(R, A, bc_get(S, rd(R, i.B()), K[i.C()], op_name(r, 0, i.B(), false))); break;
    case L::SETTABUP: bc_set(S, cl->up[A]->v, K[i.B()], i.k() ? K[i.C()] : rd(R, i.C()), op_name(r, 0, A, true)); break;
    case L::SETTABLE: bc_set(S, rd(R, A), rd(R, i.B()), i.k() ? K[i.C()] : rd(R, i.C()), op_name(r, 0, A, false)); break;
    case L::SETI: bc_set(S, rd(R, A), Value::integer(i.B()), i.k() ? K[i.C()] : rd(R, i.C()), op_name(r, 0, A, false)); break;
    case L::SETFIELD: bc_set(S, rd(R, A), K[i.B()], i.k() ? K[i.C()] : rd(R, i.C()), op_name(r, 0, A, false)); break;
    case L::NEWTABLE: {
      unsigned b = i.B(), c = i.C();
      std::uint32_t nhash = b > 0 ? 1u << (b - 1) : 0u;
      std::uint32_t narr = c;
      if (i.k()) narr += static_cast<std::uint32_t>(L::Insn(code[pc]).Ax()) * 256u;
      ++pc;  // the EXTRAARG that follows
      wr(R, A, Value::table(S.new_table(narr, nhash)));
      break;
    }
    case L::SELF: {
      Value obj = rd(R, i.B());
      Value key = i.k() ? K[i.C()] : rd(R, i.C());
      wr(R, A + 1, obj);
      wr(R, A, bc_get(S, obj, key, op_name(r, 0, i.B(), false)));
      break;
    }
    case L::LEN: {
      Value v = rd(R, i.B());
      Value res;
      if (v.t == T_STR) res = Value::integer(v.s()->len);
      else if (v.t == T_TAB && !v.tab()->meta) res = Value::integer(v.tab()->length());
      else res = len_slow(S, v, op_name(r, 0, i.B(), false));
      wr(R, A, res);
      break;
    }
    case L::SETLIST: {
      Value* ra = R + A;
      int n = i.B() ? static_cast<int>(i.B()) : static_cast<int>(r.mtop - ra - 1);
      std::int64_t last = i.C();
      if (i.k()) {
        last += static_cast<std::int64_t>(L::Insn(code[pc]).Ax()) * 256;
        ++pc;
      }
      Table* t = rd(R, A).tab();
      // A positional item goes into the array part, a nil included (as the AST's constructor stores it), so that the length
      // of {...} with holes is the one Lua gives: the array part grows to hold the item.
      for (int j = 1; j <= n; ++j) {
        std::uint32_t idx = static_cast<std::uint32_t>(last + j);
        Value v = rd(R, A + static_cast<unsigned>(j));
        if (idx > t->asize) {
          t->reserve_array(S, idx);
          for (std::uint32_t k = t->asize; k + 1 < idx; ++k) t->arr[k] = Value();
          t->arr[idx - 1] = v;
          t->asize = idx;
          t->absorb(S);
        } else {
          t->arr[idx - 1] = v;
        }
      }
      break;
    }
    case L::CONCAT: {
      int n = static_cast<int>(i.B());
      Value* vals = ftop;
      if (vals + n + 128 > S.stack_end) S.rt_error("stack overflow");
      for (int j = 0; j < n; ++j) vals[j] = rd(R, A + static_cast<unsigned>(j));
      std::vector<Node*>& nodes = r.body->concat_names[pc - 1];
      if (nodes.size() != static_cast<std::size_t>(n)) {
        nodes.assign(static_cast<std::size_t>(n), nullptr);
        for (int j = 0; j < n; ++j) {
          BcName* bn = P->make<BcName>();
          bn->body = r.body;
          bn->pc = pc - 1;
          bn->reg = static_cast<int>(A) + j;
          nodes[static_cast<std::size_t>(j)] = bn;
        }
      }
      S.top = vals + n;
      Value res = concat_slow(S, vals, n, nodes.data());
      S.top = ftop;
      wr(R, A, res);
      break;
    }
    default: S.rt_error("unsupported bytecode instruction");
  }
  return C_NORMAL;
}

// Arithmetic. Each operation does the whole of the instruction, the metamethods included; the MMBIN after it is skipped (for the
// forms with an immediate or a constant the MMBIN gives the operator, see arith_mm).
[[gnu::noinline]] int op_arith(BcRun& r, const L::Insn& i) {
  [[maybe_unused]] State& S = r.S;
  [[maybe_unused]] Value* R = r.R;
  [[maybe_unused]] const Value* K = r.K;
  [[maybe_unused]] int& pc = r.pc;
  [[maybe_unused]] const L::Insn* code = r.code;
  const unsigned A = i.A();
  switch (i.op()) {
    case L::ADDI:
    case L::SHRI:
    case L::SHLI: {
      const L::Insn mm = code[pc];
      wr(R, A, arith_mm(r, mm, Value::integer(mm.sB()), op_name(r, 0, mm.A(), false)));
      ++pc;
      break;
    }
    case L::ADDK:
    case L::SUBK:
    case L::MULK:
    case L::MODK:
    case L::POWK:
    case L::DIVK:
    case L::IDIVK:
    case L::BANDK:
    case L::BORK:
    case L::BXORK: {
      const L::Insn mm = code[pc];
      wr(R, A, arith_mm(r, mm, K[mm.B()], op_name(r, 0, mm.A(), false)));
      ++pc;
      break;
    }
    case L::ADD: wr(R, A, bc_arith(S, AR_ADD, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false), op_name(r, 1, i.C(), false))); ++pc; break;
    case L::SUB: wr(R, A, bc_arith(S, AR_SUB, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false), op_name(r, 1, i.C(), false))); ++pc; break;
    case L::MUL: wr(R, A, bc_arith(S, AR_MUL, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false), op_name(r, 1, i.C(), false))); ++pc; break;
    case L::MOD: wr(R, A, bc_arith(S, AR_MOD, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false), op_name(r, 1, i.C(), false))); ++pc; break;
    case L::POW: wr(R, A, bc_arith(S, AR_POW, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false), op_name(r, 1, i.C(), false))); ++pc; break;
    case L::DIV: wr(R, A, bc_arith(S, AR_DIV, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false), op_name(r, 1, i.C(), false))); ++pc; break;
    case L::IDIV: wr(R, A, bc_arith(S, AR_IDIV, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false), op_name(r, 1, i.C(), false))); ++pc; break;
    case L::BAND: wr(R, A, bc_arith(S, AR_BAND, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false), op_name(r, 1, i.C(), false))); ++pc; break;
    case L::BOR: wr(R, A, bc_arith(S, AR_BOR, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false), op_name(r, 1, i.C(), false))); ++pc; break;
    case L::BXOR: wr(R, A, bc_arith(S, AR_BXOR, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false), op_name(r, 1, i.C(), false))); ++pc; break;
    case L::SHL: wr(R, A, bc_arith(S, AR_SHL, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false), op_name(r, 1, i.C(), false))); ++pc; break;
    case L::SHR: wr(R, A, bc_arith(S, AR_SHR, rd(R, i.B()), rd(R, i.C()), op_name(r, 0, i.B(), false), op_name(r, 1, i.C(), false))); ++pc; break;
    case L::MMBIN: {  // reached only if the arithmetic before it did not run; that instruction always does the whole operation
      Value a = rd(R, A), b = rd(R, i.B());
      L::Insn prev = code[pc - 2];
      wr(R, prev.A(), arith_slow(S, tm_to_arith(static_cast<int>(i.C())), a, b, op_name(r, 0, A, false), op_name(r, 1, i.B(), false)));
      break;
    }
    case L::MMBINI: {
      L::Insn prev = code[pc - 2];
      Value a = rd(R, A), imm = Value::integer(i.sB());
      int op = tm_to_arith(static_cast<int>(i.C()));
      wr(R, prev.A(), i.k() ? arith_slow(S, op, imm, a, nullptr, op_name(r, 0, A, false))
                            : arith_slow(S, op, a, imm, op_name(r, 0, A, false), nullptr));
      break;
    }
    case L::MMBINK: {
      L::Insn prev = code[pc - 2];
      Value a = rd(R, A);
      int op = tm_to_arith(static_cast<int>(i.C()));
      wr(R, prev.A(), i.k() ? arith_slow(S, op, K[i.B()], a, nullptr, op_name(r, 0, A, false))
                            : arith_slow(S, op, a, K[i.B()], op_name(r, 0, A, false), nullptr));
      break;
    }
    case L::UNM: {
      Value a = rd(R, i.B());
      wr(R, A, a.t == T_INT ? Value::integer(nfcr_neg(a.i)) : arith_slow(S, AR_UNM, a, a, op_name(r, 0, i.B(), false), op_name(r, 0, i.B(), false)));
      break;
    }
    case L::BNOT: {
      Value a = rd(R, i.B());
      wr(R, A, a.t == T_INT ? Value::integer(~a.i) : arith_slow(S, AR_BNOT, a, a, op_name(r, 0, i.B(), false), op_name(r, 0, i.B(), false)));
      break;
    }
    default: S.rt_error("unsupported bytecode instruction");
  }
  return C_NORMAL;
}

// Comparisons (each followed by a jump, see cond_jump).
[[gnu::noinline]] int op_cmp(BcRun& r, const L::Insn& i) {
  [[maybe_unused]] State& S = r.S;
  [[maybe_unused]] Value* R = r.R;
  [[maybe_unused]] const Value* K = r.K;
  const unsigned A = i.A();
  switch (i.op()) {
    case L::EQ: {
      Value a = rd(R, A), b = rd(R, i.B());
      cond_jump(r, (a.t == T_INT && b.t == T_INT) ? a.i == b.i : equals_slow(S, a, b), i);
      break;
    }
    case L::LT: {
      Value a = rd(R, A), b = rd(R, i.B());
      cond_jump(r, (a.t == T_INT && b.t == T_INT) ? a.i < b.i : less_slow(S, a, b), i);
      break;
    }
    case L::LE: {
      Value a = rd(R, A), b = rd(R, i.B());
      cond_jump(r, (a.t == T_INT && b.t == T_INT) ? a.i <= b.i : lesseq_slow(S, a, b), i);
      break;
    }
    case L::EQK: cond_jump(r, raw_equal(rd(R, A), K[i.B()]), i); break;
    case L::EQI: {
      Value a = rd(R, A);
      bool c = a.t == T_INT ? a.i == i.sB() : a.t == T_FLT && a.d == static_cast<double>(i.sB());
      cond_jump(r, c, i);
      break;
    }
    case L::LTI:
    case L::LEI:
    case L::GTI:
    case L::GEI: {
      Value a = rd(R, A);
      std::int64_t im = i.sB();
      Value imm = i.C() ? Value::number(static_cast<double>(im)) : Value::integer(im);  // C: the immediate is a float
      bool c;
      if (a.t == T_INT || a.t == T_FLT) {
        bool isint = a.t == T_INT;
        double x = isint ? 0 : a.d;
        std::int64_t xi = isint ? a.i : 0;
        if (i.op() == L::LTI) c = isint ? xi < im : x < static_cast<double>(im);
        else if (i.op() == L::LEI) c = isint ? xi <= im : x <= static_cast<double>(im);
        else if (i.op() == L::GTI) c = isint ? xi > im : x > static_cast<double>(im);
        else c = isint ? xi >= im : x >= static_cast<double>(im);
      } else if (i.op() == L::LTI) {
        c = less_slow(S, a, imm);
      } else if (i.op() == L::LEI) {
        c = lesseq_slow(S, a, imm);
      } else if (i.op() == L::GTI) {
        c = less_slow(S, imm, a);
      } else {
        c = lesseq_slow(S, imm, a);
      }
      cond_jump(r, c, i);
      break;
    }
    default: S.rt_error("unsupported bytecode instruction");
  }
  return C_NORMAL;
}

// Calls. The callee runs in a frame of its own (call_value); a tail call replaces this frame (call_closure runs the callee in it).
[[gnu::noinline]] int op_call(BcRun& r, const L::Insn& i) {
  [[maybe_unused]] State& S = r.S;
  Frame& f = r.f;
  [[maybe_unused]] Proto* P = r.P;
  [[maybe_unused]] Value* R = r.R;
  [[maybe_unused]] int& pc = r.pc;
  [[maybe_unused]] Value*& ftop = r.ftop;
  [[maybe_unused]] Value*& mtop = r.mtop;
  const unsigned A = i.A();
  switch (i.op()) {
    case L::CALL: {
      Value* ra = R + A;
      int nargs = i.B() ? static_cast<int>(i.B()) - 1 : static_cast<int>(mtop - ra - 1);
      Value fnv = rd(R, A);
      Value* args = ra + 1;
      if (P->vararg) {
        // The callee's frame goes above the varargs, which it must not overwrite.
        if (ftop + nargs + 128 > S.stack_end) S.rt_error("stack overflow");
        move_values(ftop + 1, args, nargs);
        ftop[0] = fnv;
        args = ftop + 1;
      }
      S.top = std::max(ftop, args + nargs);
      Rets out;
      call_value(S, fnv, args, nargs, out, op_name(r, 0, A, false));
      S.top = ftop;
      if (i.C()) {
        for (unsigned j = 0; j + 1 < i.C(); ++j) wr(R, A + j, static_cast<int>(j) < out.n ? out.p[j] : Value());
      } else {
        keep_varargs_above(r, ra + out.n);
        if (ra + out.n + 128 > S.stack_end) S.rt_error("stack overflow");
        for (int j = 0; j < out.n; ++j) ra[j] = out.p[j];
        mtop = ra + out.n;
        S.top = std::max(ftop, mtop);
      }
      break;
    }
    case L::TAILCALL: {
      Value* ra = R + A;
      int nargs = i.B() ? static_cast<int>(i.B()) - 1 : static_cast<int>(mtop - ra - 1);
      if (i.k()) close_from(R, 0, static_cast<unsigned>(P->nslots));
      Value fnv = rd(R, A);
      Value* args = ra + 1;
      if (!fnv.is_closure() && fnv.t != T_FUN) {  // a callable object: its __call, with the object as the first argument
        Value tm = tm_value(S, fnv, TM_CALL);
        if (tm.is_closure()) {
          if (args + nargs + 130 > S.stack_end) S.rt_error("stack overflow");
          move_values(args + 1, args, nargs);
          args[0] = fnv;
          ++nargs;
          fnv = tm;
        }
      }
      if (fnv.is_closure()) {
        // The callee replaces this frame: its arguments go to the parameter slots and call_closure runs it in this frame.
        move_values(f.base, args, nargs);
        f.base[-1] = fnv;
        f.tail_cl = fnv.closure();
        f.tail_n = nargs;
        S.top = f.base + nargs;
        return C_RETURN;
      }
      S.top = std::max(ftop, args + nargs);
      Rets out;
      call_value(S, fnv, args, nargs, out, op_name(r, 0, A, false));
      for (int j = 0; j < out.n; ++j) f.rets->push(out.p[j]);
      return C_RETURN;
    }
    case L::TFORCALL: {
      // R[A+4], ... R[A+3+C] := R[A](R[A+1], R[A+2]); as the AST's generic for, a native iterator's errors have no position
      Value fn = rd(R, A), st = rd(R, A + 1), ctl = rd(R, A + 2);
      wr(R, A + 4, fn);
      wr(R, A + 5, st);
      wr(R, A + 6, ctl);
      Value* args = R + A + 5;
      S.top = std::max(ftop, args + 2);
      Rets out;
      call_value(S, fn, args, 2, out, nullptr);
      S.top = ftop;
      for (unsigned j = 0; j < i.C(); ++j) wr(R, A + 4 + j, static_cast<int>(j) < out.n ? out.p[j] : Value());
      break;
    }
    default: S.rt_error("unsupported bytecode instruction");
  }
  return C_NORMAL;
}

// Returns: the values go to the caller's Rets; a frame with captured registers gives them back first.
[[gnu::noinline]] int op_ret(BcRun& r, const L::Insn& i) {
  [[maybe_unused]] State& S = r.S;
  Frame& f = r.f;
  Value* R = r.R;
  const unsigned A = i.A();
  switch (i.op()) {
    case L::RETURN: {
      Value* ra = R + A;
      int n = i.B() ? static_cast<int>(i.B()) - 1 : static_cast<int>(r.mtop - ra);
      for (int j = 0; j < n; ++j) f.rets->push(rd(R, A + static_cast<unsigned>(j)));
      if (i.k()) close_from(R, 0, static_cast<unsigned>(r.P->nslots));
      return C_RETURN;
    }
    case L::RETURN0: return C_RETURN;
    case L::RETURN1: f.rets->push(rd(R, A)); return C_RETURN;
    default: S.rt_error("unsupported bytecode instruction");
  }
}

// Numeric and generic loops.
[[gnu::noinline]] int op_for(BcRun& r, const L::Insn& i) {
  [[maybe_unused]] State& S = r.S;
  [[maybe_unused]] Value* R = r.R;
  [[maybe_unused]] int& pc = r.pc;
  [[maybe_unused]] Value*& ftop = r.ftop;
  const unsigned A = i.A();
  switch (i.op()) {
    case L::FORLOOP: {
      Value* ra = R + A;
      if (ra[2].t == T_INT) {
        std::uint64_t count = static_cast<std::uint64_t>(ra[1].i);
        if (count > 0) {
          std::int64_t step = ra[2].i;
          std::int64_t idx = static_cast<std::int64_t>(static_cast<std::uint64_t>(ra[0].i) + static_cast<std::uint64_t>(step));
          ra[1] = Value::integer(static_cast<std::int64_t>(count - 1));
          ra[0] = Value::integer(idx);
          wr(R, A + 3, Value::integer(idx));
          pc -= static_cast<int>(i.Bx());
          safepoint(S);
        }
      } else {
        double step = ra[2].d, limit = ra[1].d;
        double idx = ra[0].d + step;
        if (0 < step ? idx <= limit : limit <= idx) {
          ra[0] = Value::number(idx);
          wr(R, A + 3, Value::number(idx));
          pc -= static_cast<int>(i.Bx());
          safepoint(S);
        }
      }
      break;
    }
    case L::FORPREP:
      if (for_prep(S, R + A)) pc += static_cast<int>(i.Bx()) + 1;
      break;
    case L::TFORPREP:
      if (!rd(R, A + 3).is_nil()) S.rt_error("to-be-closed variables are not supported");
      pc += static_cast<int>(i.Bx());
      break;
    case L::TFORLOOP:
      if (!rd(R, A + 4).is_nil()) {
        wr(R, A + 2, rd(R, A + 4));
        pc -= static_cast<int>(i.Bx());
        safepoint(S);
      }
      break;
    default: S.rt_error("unsupported bytecode instruction");
  }
  return C_NORMAL;
}

// Closures, and the varargs.
[[gnu::noinline]] int op_misc(BcRun& r, const L::Insn& i) {
  [[maybe_unused]] State& S = r.S;
  Frame& f = r.f;
  [[maybe_unused]] Closure* cl = r.cl;
  [[maybe_unused]] Proto* P = r.P;
  [[maybe_unused]] Value* R = r.R;
  [[maybe_unused]] Value*& mtop = r.mtop;
  const unsigned A = i.A();
  switch (i.op()) {
    case L::CLOSURE: {
      Proto* child = P->children[i.Bx()];
      Closure* c = new_closure(S, child, static_cast<std::uint32_t>(child->upvals.size()));
      for (std::size_t u = 0; u < child->upvals.size(); ++u) {
        const UpvalDesc& d = child->upvals[u];
        if (d.from_local) {
          // The register is captured: it holds a Cell from now on, shared by every closure that captures it.
          Value& slot = R[d.index];
          if (slot.t != T_CELL) slot = Value::object(T_CELL, new_cell(S, slot));
          c->up[u] = static_cast<Cell*>(slot.o);
        } else {
          c->up[u] = cl->up[d.index];
        }
      }
      wr(R, A, Value::function(c));
      break;
    }
    case L::VARARG: {
      int n = f.nva;
      if (i.C() == 0) {
        keep_varargs_above(r, R + A + n);
        if (R + A + n + 128 > S.stack_end) S.rt_error("stack overflow");
        for (int j = 0; j < n; ++j) R[A + static_cast<unsigned>(j)] = f.va[j];
        mtop = R + A + n;
        S.top = std::max(r.ftop, mtop);
      } else {
        for (unsigned j = 0; j + 1 < i.C(); ++j) wr(R, A + j, static_cast<int>(j) < n ? f.va[j] : Value());
      }
      break;
    }
    case L::TBC: S.rt_error("to-be-closed variables are not supported");  // refused at load time; kept for a chunk built by hand
    default: S.rt_error("unsupported bytecode instruction");
  }
  return C_NORMAL;
}

}  // namespace

int BcBody::exec(Frame& f) {
  State& S = *f.S;
  Proto* P = f.cl->proto;
  Value* R = f.base;
  // The frame's top: its registers, and the varargs, which sit above them.
  Value* ftop = R + P->nslots;
  if (f.nva > 0 && f.va + f.nva > ftop) ftop = f.va + f.nva;
  S.top = ftop;
  BcRun r{S, f, f.cl, P, this, R, ftop, ftop, kst.data(), insns.data(), linev.data(), 0};
  for (;;) {
    const L::Insn i = r.code[r.pc++];
    f.line = r.lines[r.pc - 1];
    int rc;
    switch (i.op()) {
      case L::MOVE: case L::LOADI: case L::LOADF: case L::LOADK: case L::LOADKX: case L::LOADFALSE: case L::LFALSESKIP:
      case L::LOADTRUE: case L::LOADNIL: case L::GETUPVAL: case L::SETUPVAL: case L::NOT: case L::CLOSE: case L::JMP:
      case L::TEST: case L::TESTSET: case L::VARARGPREP: case L::EXTRAARG:
        rc = op_load(r, i);
        break;
      case L::GETTABUP: case L::GETTABLE: case L::GETI: case L::GETFIELD: case L::SETTABUP: case L::SETTABLE: case L::SETI:
      case L::SETFIELD: case L::NEWTABLE: case L::SELF: case L::LEN: case L::SETLIST: case L::CONCAT:
        rc = op_table(r, i);
        break;
      case L::ADDI: case L::ADDK: case L::SUBK: case L::MULK: case L::MODK: case L::POWK: case L::DIVK: case L::IDIVK:
      case L::BANDK: case L::BORK: case L::BXORK: case L::SHRI: case L::SHLI: case L::ADD: case L::SUB: case L::MUL:
      case L::MOD: case L::POW: case L::DIV: case L::IDIV: case L::BAND: case L::BOR: case L::BXOR: case L::SHL: case L::SHR:
      case L::MMBIN: case L::MMBINI: case L::MMBINK: case L::UNM: case L::BNOT:
        rc = op_arith(r, i);
        break;
      case L::EQ: case L::LT: case L::LE: case L::EQK: case L::EQI: case L::LTI: case L::LEI: case L::GTI: case L::GEI:
        rc = op_cmp(r, i);
        break;
      case L::CALL: case L::TAILCALL: case L::TFORCALL:
        rc = op_call(r, i);
        break;
      case L::RETURN: case L::RETURN0: case L::RETURN1:
        rc = op_ret(r, i);
        break;
      case L::FORLOOP: case L::FORPREP: case L::TFORPREP: case L::TFORLOOP:
        rc = op_for(r, i);
        break;
      case L::CLOSURE: case L::VARARG: case L::TBC:
        rc = op_misc(r, i);
        break;
      default:
        S.rt_error("unsupported bytecode instruction");
    }
    if (rc != C_NORMAL) return rc;
  }
}

// ---- stack access -----------------------------------------------------------------------------------------------------------

void bc_stack_get(State& S, Args a, Rets& r, Native&) {
  Frame* f = bc_frame(S, "stack_get");
  unsigned idx = bc_reg_arg(S, a, "stack_get", static_cast<unsigned>(f->cl->proto->nslots));
  r.push(rd(f->base, idx));
}

void bc_stack_set(State& S, Args a, Rets&, Native&) {
  Frame* f = bc_frame(S, "stack_set");
  unsigned idx = bc_reg_arg(S, a, "stack_set", static_cast<unsigned>(f->cl->proto->nslots));
  wr(f->base, idx, a[1]);
}

void bc_stack_top(State& S, Args, Rets& r, Native&) {
  Frame* f = bc_frame(S, "stack_top");
  r.push(Value::integer(f->cl->proto->nslots));
}

void bc_bind_stack_access(State& S) {
  const struct {
    const char* name;
    NativeFn fn;
  } fns[] = {{"stack_get", bc_stack_get}, {"stack_set", bc_stack_set}, {"stack_top", bc_stack_top}};
  for (const auto& e : fns) {
    Native* n = S.new_native(e.fn, S.keep_name(e.name));
    S.globals->set_str(S, S.str(e.name), Value::function(n));
  }
}

}  // namespace nfcast
