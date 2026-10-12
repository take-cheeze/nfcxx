// nfcast tier: hot numeric kernels become native code (docs/notes/ast.md, "Tiering").
//
// A script function that is called (or loops) often enough, and whose body is a numeric kernel, is lowered to C++, compiled by the
// nfcxx driver into a shared object and called in place of the tree. A kernel is a function whose body has only numeric and boolean
// locals and parameters, constants, arithmetic, bitwise and comparison operators, `if` / `while` / `repeat` / numeric `for` /
// `return` / `break`, reads of numeric upvalues and globals, and calls of other kernels through an upvalue or a global (itself
// included). Nothing else is lowered: a function that does anything more simply stays interpreted.
//
// Soundness. The compiled code has no side effects: it reads its arguments and the free variables it was given at entry, and
// returns one number. So whatever it assumed and finds untrue (an argument of another type than the one it was compiled for, a
// callee that is another function now, an integer division by zero, a recursion deeper than the interpreter allows) is handled by
// abandoning the run (a longjmp to the entry) and doing the whole call again in the interpreter, which then produces the result,
// the error text and the position exactly as it would have without a tier. The arithmetic itself is the interpreter's
// (nfcast_tier_rt.h, one source for both), and the types are static: a variable has one type for the whole function (an integer, a
// float, a boolean, or a "number", which is an integer or a float as the run goes: `local s = 0` ... `s = s + 0.5`), an expression's
// type follows from its operands as in the specialized nodes, and a function in which that does not hold (a local that is a boolean
// here and a number there) is not compiled.
//
// The engine stays single threaded. There is no compile thread: a compile is a child process (the nfcxx driver) that the engine
// starts and then either waits for (sync) or polls from the calls it serves (async). The reason is that EDG's exception runtime
// keeps one global stack of try blocks (lib_src/throw.c of the front end), so a second thread running C++ code with destructors
// while the interpreter runs would corrupt it.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "../eval/nfceval_build.hpp"
#include "nfcast_impl.hpp"

namespace nfcast {

namespace bld = nfceval::build;

namespace {

const int kMaxParams = 12;
const int kMaxLive = 24;  // live locals a loop may hand to compiled code
const std::size_t kMaxVersions = 4;
const int kMaxInstances = 48;
const unsigned kMaxRejects = 3;

// ---- types ---------------------------------------------------------------------------------------------------------------------
// The static types of the compiled code. Y_V: no value (a function that returns nothing). Y_Q: a value that is only good for its
// truth (`a and 5` with a boolean a): it may be a condition but not stored, passed or returned. Y_N: a number that is an integer or
// a float, which the value itself says (an nfcr_N of nfcast_tier_rt.h); a variable that gets both kinds is one, and so is what
// arithmetic makes of one and an integer.
enum Ty : unsigned char { Y_UNK = 0, Y_I, Y_F, Y_B, Y_V, Y_Q, Y_N };

const char* ty_c(Ty t) {
  switch (t) {
    case Y_I: return "nfcr_i64";
    case Y_F: return "double";
    case Y_N: return "nfcr_N";
    case Y_V: return "void";
    default: return "int";
  }
}

char ty_ch(Ty t) {
  switch (t) {
    case Y_I: return 'i';
    case Y_F: return 'f';
    case Y_B: return 'b';
    case Y_V: return 'v';
    case Y_Q: return 'q';
    case Y_N: return 'n';
    default: return '?';
  }
}

inline bool is_num(Ty t) { return t == Y_I || t == Y_F || t == Y_N; }
inline bool is_val(Ty t) { return t == Y_I || t == Y_F || t == Y_B || t == Y_N; }

Ty ty_of_tag(Tag t) {
  switch (t) {
    case T_INT: return Y_I;
    case T_FLT: return Y_F;
    case T_TRUE:
    case T_FALSE: return Y_B;
    default: return Y_UNK;
  }
}

std::string sig_str(const std::vector<Ty>& sig, Ty ret) {
  std::string s;
  for (Ty t : sig) s += ty_ch(t);
  s += "->";
  s += ty_ch(ret);
  return s;
}

// ---- the lowered form ------------------------------------------------------------------------------------------------------------
// A function as the tier sees it: expressions and statements over numbered variables (a slot of the interpreter's frame is reused
// by later declarations, a variable is not), free variables (an upvalue or a global read) and calls through a binding. It holds no
// pointers into the tree, so everything after its construction can run without the State.
struct IExpr {
  enum K { Const, Var, Free, Arith, Unary, Cmp, Eq, And, Or, Call } k = Const;
  int id = 0;
  int line = 0;
  int op = 0;
  Ty cty = Y_UNK;  // Const
  long long ci = 0;
  double cd = 0;
  int var = -1;  // Var
  int fv = -1;   // Free
  int dep = -1;  // Call
  bool neg = false;  // Eq: ~=
  std::vector<IExpr*> kids;
};

struct IStmt {
  enum K { Block, Decl, Assign, If, While, Repeat, For, Return, Break, CallStat } k = Block;
  int line = 0;
  std::vector<int> vars;
  std::vector<IExpr*> exprs;    // Decl, Assign: values; If: conditions; While, Repeat: the condition; For: start, limit, step; Return: 0 or 1; CallStat: the call
  std::vector<IStmt*> blocks;   // Block: statements; If: the blocks (then the else block); loops: the body
  bool has_else = false;
  int osr = 0;  // the loop at which a unit for on-stack replacement starts: 1 `while` or `repeat`, 2 an integer `for`, 3 a float `for` (no header)
};

struct FreeVar {
  int kind;  // 0: upvalue INDEX of the closure, 1: global NAME
  int idx;
  std::string name;
  Ty ty;     // the type of the value when the unit was built (what the entry guard checks)
  bool written = false;  // assigned by the code (upvalues only): copied in at entry, copied out when the run has ended
};

struct Dep {
  int kind;  // as FreeVar, or 2: a local of the frame the unit's loop runs in (on-stack replacement), slot IDX, in a Cell if CELL
  int idx;
  std::string name;
  int callee;  // index of the callee in the unit
  bool cell = false;
};

struct ProtoIR {
  std::uint64_t serial = 0;
  int nparams = 0, nslots = 0, nvars = 0, line = 0;
  IStmt* body = nullptr;
  std::vector<FreeVar> fvs;
  std::vector<Dep> deps;
  std::vector<std::unique_ptr<IExpr>> exprs;
  std::vector<std::unique_ptr<IStmt>> stmts;
  int fvbase = 0;  // where this function's free variables start in the unit's array
  // The function's parameters are variables PVARS[0..nparams). For a unit that starts at a loop (on-stack replacement) the first
  // function is not a function but that loop: its "parameters" are the locals of the running function that the loop reads or
  // assigns without having declared them (IN_SLOTS, their slots in the interpreter's frame), found while the loop is lowered.
  bool osr = false;
  std::vector<int> pvars, in_slots;
  std::vector<char> in_cell;     // a live local that is captured by a closure: its slot holds a Cell
  std::vector<char> in_written;  // a live local the loop assigns
};

// What the engine needs at every entry to check that the code's assumptions about the functions and variables it reads still
// hold, and to collect the values of the free variables.
struct MFree {
  int kind, idx;
  std::string name;
  Ty ty;           // the type the guard wants at entry
  bool written;
  Ty sty = Y_UNK;  // the type it is kept in while the code runs (a written variable that took both kinds of number is an N)
};
struct MDep {
  int kind, idx;
  std::string name;
  int callee;
  bool cell;
};
struct MProto {
  std::uint64_t serial;
  int nslots;
  int fvbase;
  std::vector<MFree> fvs;
  std::vector<MDep> deps;
};
struct UnitMeta {
  std::vector<MProto> protos;  // [0] is the function that was asked for
  int nfv = 0;
  int max_nslots = 0;
};

// ---- the state of the tier -----------------------------------------------------------------------------------------------------
typedef int (*RunFn)(nfcr_Ctx*, const nfcr_W*, nfcr_W*);

}  // namespace

struct TierState;

namespace {

struct Version {
  enum St { Building, Ready, Rejected, Failed, Dead } st = Building;
  std::vector<Ty> sig;
  Ty ret = Y_V;
  UnitMeta meta;
  std::string why;
  std::string so, tmp, cpp, log;
  bld::Child child;
  bool spawned = false;
  void* handle = nullptr;
  RunFn run = nullptr;
  std::uint32_t runs = 0, aborts = 0;
  int style = 0;                // on-stack replacement: the TierLoopState::Kind of the loop (its sig is the types of the live locals)
  std::vector<int> in_slots;    //   the live locals: slots of the frame
  std::vector<char> in_cell, in_written;
  std::vector<Ty> out_ty;       //   their types when the loop has ended (a local that took both kinds of number is an N)
  TierState* T = nullptr;
  ~Version();
};

}  // namespace

// What the tier knows about one loop (a `while`, `repeat` or numeric `for` statement) of a function: the compiled versions that take
// the loop over (on-stack replacement), and what it takes to make one.
struct TierLoop {
  std::vector<std::unique_ptr<Version>> vers;
  std::vector<int> in_slots;  // the slots of the frame the loop reads or assigns without declaring them (known once it was lowered)
  std::vector<char> in_cell, in_written;
  bool in_known = false;
  std::uint32_t edges = 0, next_try = 0;  // iterations counted since the last compile request, and how many make the next
  unsigned rejects = 0;
  bool dead = false;     // not compilable, looked at often enough
  bool blocked = false;  // a run was abandoned (or a guard failed): not again until the loop is entered anew
  bool counted = false;
  int line = 0;
  std::string reason;
};

struct TierProto {
  std::uint64_t serial = 0;
  std::vector<std::unique_ptr<TierLoop>> loops;
  std::uint32_t calls = 0, edges = 0;
  std::vector<std::unique_ptr<Version>> vers;
  std::string reason;  // why the function as a whole is not a kernel (the last time we looked)
  unsigned rejects = 0;
  std::uint32_t retry_at = 0;
  bool counted = false;
  bool dead = false;  // not a kernel, looked at often enough: the hooks return at once
  ~TierProto();
};

struct TierState {
  TierOptions opt;
  std::string driver, cache, rt_text, rt_dir;
  bool cache_ok = false, rt_ok = false, resolved = false;
  std::uint64_t next_serial = 1;
  std::vector<Version*> pending;  // compiles running (Async)
  std::vector<Version*> queued;   // compiles waiting for one of the TierOptions::jobs to end (Async)
  unsigned tick = 0;
  unsigned build_seq = 0;
  bool debug = false;
  std::vector<nfcr_W> fvbuf;  // two words for each free variable of a unit: the value, and for an N its kind
  std::vector<Closure*> closbuf;
  std::vector<std::pair<Cell*, bool>> cellbuf;  // the cells a run can reach, and whether it assigns them
  std::vector<std::pair<Cell*, bool>> extrabuf; // the same for the locals a loop hands over
};

namespace {

void note(TierState* T, const char* fmt, const std::string& a, const std::string& b = std::string()) {
  if (!T->debug) return;
  std::fprintf(stderr, "nfcast tier: ");
  std::fprintf(stderr, fmt, a.c_str(), b.c_str());
  std::fprintf(stderr, "\n");
}

Version::~Version() {
  if (spawned && !child.finished) {  // a compile still running: stop it and take away what it was making
    bld::abandon(child);
    ::unlink(tmp.c_str());
    ::unlink(log.c_str());
    ::unlink(cpp.c_str());
  } else if (!spawned && st == Building && !cpp.empty()) {
    ::unlink(cpp.c_str());  // queued and never started
  }
  if (T) {
    for (std::size_t i = 0; i < T->pending.size(); ++i)
      if (T->pending[i] == this) {
        T->pending.erase(T->pending.begin() + static_cast<long>(i));
        break;
      }
    for (std::size_t i = 0; i < T->queued.size(); ++i)
      if (T->queued[i] == this) {
        T->queued.erase(T->queued.begin() + static_cast<long>(i));
        break;
      }
  }
  if (handle) ::dlclose(handle);
}

}  // namespace

TierProto::~TierProto() {}

void tier_free(TierProto* tp) { delete tp; }

namespace {

TierProto* new_tier_proto(State& S, Proto* p) {
  TierProto* tp = new TierProto();
  tp->serial = S.tier->next_serial++;
  p->tier = tp;
  return tp;
}

// ================================================================================================================================
// building the lowered form from the tree
// ================================================================================================================================
struct Fail {
  std::string why;
  bool failed() const { return !why.empty(); }
  void set(const std::string& s) {
    if (why.empty()) why = s;
  }
};

struct Unit {
  std::vector<std::unique_ptr<ProtoIR>> protos;
  std::vector<Closure*> closures;  // the closure each function was reached through (only valid while building)
  int nfv = 0;
  int max_nslots = 0;
  Node* osr_loop = nullptr;  // a unit for on-stack replacement: the loop that its first function is (the closure is the one that runs it)
  int osr_style = 0;         //   its TierLoopState::Kind
  Frame* osr_frame = nullptr;  //   the frame of the running function (while the unit is built: the locals that hold functions are read there)
};

// The first function of a unit that starts at the loop LOOP of the function of CL (on-stack replacement).
int unit_add_osr(State& S, Unit& U, Closure* cl, Node* loop, int style) {
  Proto* p = cl->proto;
  if (!p->tier) new_tier_proto(S, p);
  std::unique_ptr<ProtoIR> ir(new ProtoIR());
  ir->serial = 0;  // no function has this serial: a call of the function the loop is in is a call of a function, not of the loop
  ir->nslots = 0;  // the frame of the function the loop is in exists already; only the frames of what it calls count for the stack guard
  ir->line = p->linedefined;
  ir->osr = true;
  U.protos.push_back(std::move(ir));
  U.closures.push_back(cl);
  U.osr_loop = loop;
  U.osr_style = style;
  return 0;
}

// Adds the function of CL to the unit (or finds it); -1 with FAIL set when it cannot be one.
int unit_add(State& S, Unit& U, Closure* cl, Fail& f) {
  Proto* p = cl->proto;
  TierProto* tp = p->tier ? p->tier : new_tier_proto(S, p);
  for (std::size_t i = 0; i < U.protos.size(); ++i)
    if (U.protos[i]->serial == tp->serial) {
      if (U.closures[i] != cl) {
        f.set("one function reached through two different closures");
        return -1;
      }
      return static_cast<int>(i);
    }
  if (U.protos.size() >= 24) {
    f.set("too many functions in one unit");
    return -1;
  }
  std::unique_ptr<ProtoIR> ir(new ProtoIR());
  ir->serial = tp->serial;
  ir->nparams = p->nparams;
  ir->nslots = p->nslots;
  ir->line = p->linedefined;
  U.protos.push_back(std::move(ir));
  U.closures.push_back(cl);
  return static_cast<int>(U.protos.size()) - 1;
}

struct Builder {
  State& S;
  Unit& U;
  int pi;  // the function being built
  ProtoIR& P;
  Closure* cl;
  Fail& fail;
  std::vector<int> slot_var;

  Builder(State& s, Unit& u, int idx, Fail& f) : S(s), U(u), pi(idx), P(*u.protos[static_cast<std::size_t>(idx)]), cl(u.closures[static_cast<std::size_t>(idx)]), fail(f) {}

  IExpr* mk_expr(IExpr::K k, int line) {
    P.exprs.emplace_back(new IExpr());
    IExpr* e = P.exprs.back().get();
    e->k = k;
    e->line = line;
    e->id = static_cast<int>(P.exprs.size()) - 1;
    return e;
  }
  IStmt* mk_stmt(IStmt::K k, int line) {
    P.stmts.emplace_back(new IStmt());
    IStmt* s = P.stmts.back().get();
    s->k = k;
    s->line = line;
    return s;
  }
  int new_var() { return P.nvars++; }
  int bind_slot(int slot) {
    if (slot < 0 || slot >= static_cast<int>(slot_var.size())) {
      fail.set("internal: local slot out of range");
      return -1;
    }
    int v = new_var();
    slot_var[static_cast<std::size_t>(slot)] = v;
    return v;
  }

  // The variable of the local in SLOT, as it is read or assigned. In the first function of a unit for on-stack replacement a slot
  // that nothing in the loop declared yet is a local of the running function that was declared before the loop: a live variable.
  int var_of_slot(int slot, bool cell, bool write) {
    if (slot < 0 || slot >= static_cast<int>(slot_var.size())) return -1;
    int v = slot_var[static_cast<std::size_t>(slot)];
    if (v < 0 && P.osr) {
      v = new_var();
      slot_var[static_cast<std::size_t>(slot)] = v;
      P.in_slots.push_back(slot);
      P.pvars.push_back(v);
      P.in_cell.push_back(cell);
      P.in_written.push_back(0);
    }
    if (v >= 0 && P.osr)
      for (std::size_t k = 0; k < P.pvars.size(); ++k)
        if (P.pvars[k] == v) {
          if (static_cast<bool>(P.in_cell[k]) != cell) fail.set("internal: a local that is a cell in one place and not in another");
          if (write) P.in_written[k] = 1;
        }
    if (cell && !P.osr) {
      fail.set("a local captured by a closure");
      return -1;
    }
    return v;
  }

  // The loop of a unit for on-stack replacement: its test, body and (for a `for`) loop variable, but not the header of a `for`,
  // which has run already.
  IStmt* osr_root(Node* n) {
    TierView v;
    tier_view(n, v);
    typedef TierView TV;
    switch (v.kind) {
      case TV::K_WHILE:
      case TV::K_REPEAT: {
        IStmt* s = stmt(n);
        if (s) s->osr = 1;
        return s;
      }
      case TV::K_FOR: {
        if (v.captured) return fail.set("a loop variable captured by a closure"), nullptr;
        IStmt* s = mk_stmt(IStmt::For, v.line);
        s->osr = U.osr_style == TierLoopState::FOR_INT ? 2 : 3;
        int var = bind_slot(v.slots[0]);
        if (var < 0) return nullptr;
        s->vars.push_back(var);
        IStmt* b = stmt(v.blocks[0]);
        if (!b) return nullptr;
        s->blocks.push_back(b);
        return s;
      }
      default: return fail.set("not a loop the tier takes over"), nullptr;
    }
  }

  bool build_osr() {
    Proto* p = cl->proto;
    if (!p->body) return fail.set("no body"), false;
    slot_var.assign(static_cast<std::size_t>(p->nslots) + 1, -1);
    P.body = osr_root(U.osr_loop);
    if (fail.failed() || !P.body) return false;
    P.nparams = static_cast<int>(P.pvars.size());
    if (P.nparams > kMaxLive) return fail.set("too many local variables live in the loop"), false;
    return true;
  }

  bool build() {
    Proto* p = cl->proto;
    if (P.osr) return build_osr();
    if (p->vararg) return fail.set("a vararg function"), false;
    if (!p->captured_params.empty()) return fail.set("a parameter captured by a closure"), false;
    if (p->nparams > kMaxParams) return fail.set("too many parameters"), false;
    if (!p->body) return fail.set("no body"), false;
    slot_var.assign(static_cast<std::size_t>(p->nslots > p->nparams ? p->nslots : p->nparams) + 1, -1);
    for (int k = 0; k < p->nparams; ++k) {
      slot_var[static_cast<std::size_t>(k)] = new_var();
      P.pvars.push_back(slot_var[static_cast<std::size_t>(k)]);
    }
    P.body = stmt(p->body);
    return !fail.failed() && P.body;
  }

  // The type of a value read from a free variable, or Y_UNK (with FAIL set).
  Ty free_ty(const Value& v, const char* what) {
    Ty t = ty_of_tag(v.t);
    if (t == Y_UNK) {
      if (v.is_closure()) fail.set(std::string("a function used as a value (") + what + ")");
      else fail.set(std::string(what) + " is not a number or a boolean");
    }
    return t;
  }

  Value read_binding(int kind, int idx, const std::string& name, bool cell = false) {
    if (kind == 2) {  // a local of the frame the loop runs in
      Frame* fr = U.osr_frame;
      if (!fr || idx < 0) return Value();
      const Value& sv = fr->base[idx];
      return cell ? static_cast<Cell*>(sv.o)->v : sv;
    }
    if (kind == 0) {
      if (idx < 0 || static_cast<std::uint32_t>(idx) >= cl->nup || !cl->up[idx]) return Value();
      return cl->up[idx]->v;
    }
    return S.globals->get_str(S.str(name));
  }

  int free_index(int kind, int idx, const std::string& name, Ty ty) {
    for (std::size_t i = 0; i < P.fvs.size(); ++i)
      if (P.fvs[i].kind == kind && P.fvs[i].idx == idx && P.fvs[i].name == name) return static_cast<int>(i);
    FreeVar f;
    f.kind = kind;
    f.idx = idx;
    f.name = name;
    f.ty = ty;
    f.written = false;
    P.fvs.push_back(f);
    return static_cast<int>(P.fvs.size()) - 1;
  }

  IExpr* call(const TierView& v) {
    TierView fv;
    tier_view(v.kids[0], fv);
    int kind, idx = -1;
    bool cell = false;
    std::string name;
    if (fv.kind == TierView::K_UPVAL) {
      kind = 0;
      idx = fv.index;
    } else if (fv.kind == TierView::K_GLOBAL) {
      kind = 1;
      name = std::string(fv.name->view());
    } else if (fv.kind == TierView::K_LOCAL && P.osr && fv.slot >= 0 && fv.slot < static_cast<int>(slot_var.size()) &&
               slot_var[static_cast<std::size_t>(fv.slot)] < 0) {
      kind = 2;  // the loop calls a function that a local of the running function holds (not one the loop declares or assigns)
      idx = fv.slot;
      cell = fv.flag;
    } else {
      fail.set("a call of something that is not a named function");
      return nullptr;
    }
    Value cv = read_binding(kind, idx, name, cell);
    if (!cv.is_closure()) {
      fail.set("a call of '" + (kind == 1 ? name : std::string(kind == 2 ? "a local" : "an upvalue")) + "', which is not a script function now");
      return nullptr;
    }
    int callee = unit_add(S, U, cv.closure(), fail);
    if (callee < 0) return nullptr;
    int dep = -1;
    for (std::size_t i = 0; i < P.deps.size(); ++i)
      if (P.deps[i].kind == kind && P.deps[i].idx == idx && P.deps[i].name == name) dep = static_cast<int>(i);
    if (dep < 0) {
      Dep d;
      d.kind = kind;
      d.idx = idx;
      d.name = name;
      d.callee = callee;
      d.cell = cell;
      P.deps.push_back(d);
      dep = static_cast<int>(P.deps.size()) - 1;
    }
    IExpr* e = mk_expr(IExpr::Call, v.line);
    e->dep = dep;
    for (std::size_t i = 1; i < v.kids.size(); ++i) {
      IExpr* a = expr(v.kids[i]);
      if (!a) return nullptr;
      e->kids.push_back(a);
    }
    Proto* cp = U.closures[static_cast<std::size_t>(callee)]->proto;
    if (static_cast<int>(e->kids.size()) != cp->nparams) {
      fail.set("a call with a different number of arguments than the function has parameters");
      return nullptr;
    }
    return e;
  }

  IExpr* expr(Node* n) {
    if (fail.failed()) return nullptr;
    TierView v;
    tier_view(n, v);
    typedef TierView TV;
    switch (v.kind) {
      case TV::K_CONST: {
        IExpr* e = mk_expr(IExpr::Const, v.line);
        switch (v.k.t) {
          case T_INT: e->cty = Y_I; e->ci = v.k.i; break;
          case T_FLT: e->cty = Y_F; e->cd = v.k.d; break;
          case T_TRUE: e->cty = Y_B; e->ci = 1; break;
          case T_FALSE: e->cty = Y_B; e->ci = 0; break;
          default: fail.set("a constant that is not a number or a boolean"); return nullptr;
        }
        return e;
      }
      case TV::K_LOCAL: {
        int var = var_of_slot(v.slot, v.flag, false);
        if (var < 0) return fail.set("internal: a local that is not bound"), nullptr;
        IExpr* e = mk_expr(IExpr::Var, v.line);
        e->var = var;
        return e;
      }
      case TV::K_UPVAL:
      case TV::K_GLOBAL: {
        int kind = v.kind == TV::K_UPVAL ? 0 : 1;
        int idx = v.kind == TV::K_UPVAL ? v.index : -1;
        std::string name = v.kind == TV::K_GLOBAL ? std::string(v.name->view()) : std::string();
        Value val = read_binding(kind, idx, name);
        Ty t = free_ty(val, kind == 1 ? ("global '" + name + "'").c_str() : "an upvalue");
        if (t == Y_UNK) return nullptr;
        IExpr* e = mk_expr(IExpr::Free, v.line);
        e->fv = free_index(kind, idx, name, t);
        return e;
      }
      case TV::K_ARITH: {
        IExpr* e = mk_expr(IExpr::Arith, v.line);
        e->op = v.op;
        for (Node* k : v.kids) {
          IExpr* c = expr(k);
          if (!c) return nullptr;
          e->kids.push_back(c);
        }
        return e;
      }
      case TV::K_UNARY: {
        if (v.op != AR_UNM && v.op != AR_BNOT && v.op != OPX_NOT) return fail.set("the length operator"), nullptr;
        IExpr* e = mk_expr(IExpr::Unary, v.line);
        e->op = v.op;
        IExpr* c = expr(v.kids[0]);
        if (!c) return nullptr;
        e->kids.push_back(c);
        return e;
      }
      case TV::K_CMP:
      case TV::K_EQ:
      case TV::K_AND:
      case TV::K_OR: {
        IExpr* e = mk_expr(v.kind == TV::K_CMP ? IExpr::Cmp : v.kind == TV::K_EQ ? IExpr::Eq : v.kind == TV::K_AND ? IExpr::And : IExpr::Or, v.line);
        e->op = v.op;
        e->neg = v.flag;
        for (Node* k : v.kids) {
          IExpr* c = expr(k);
          if (!c) return nullptr;
          e->kids.push_back(c);
        }
        return e;
      }
      case TV::K_CALL: return call(v);
      default: fail.set("an expression the tier does not lower"); return nullptr;
    }
  }

  IStmt* stmt(Node* n) {
    if (fail.failed()) return nullptr;
    TierView v;
    tier_view(n, v);
    typedef TierView TV;
    switch (v.kind) {
      case TV::K_BLOCK: {
        IStmt* b = mk_stmt(IStmt::Block, v.line);
        for (Node* k : v.kids) {
          IStmt* s = stmt(k);
          if (!s) return nullptr;
          b->blocks.push_back(s);
        }
        return b;
      }
      case TV::K_DECL:
      case TV::K_ASSIGN: {
        bool decl = v.kind == TV::K_DECL;
        if (decl && v.captured) return fail.set("a local captured by a closure"), nullptr;
        for (int tk : v.tkinds)
          if (tk == TV::T_OTHER) return fail.set("an assignment to a global or a field"), nullptr;
        if (v.kids.size() != v.slots.size()) return fail.set("an assignment or declaration with a different number of values and variables"), nullptr;
        IStmt* s = mk_stmt(decl ? IStmt::Decl : IStmt::Assign, v.line);
        for (Node* k : v.kids) {
          IExpr* e = expr(k);
          if (!e) return nullptr;
          s->exprs.push_back(e);
        }
        for (int slot : v.slots) {
          if (decl) {
            int var = bind_slot(slot);
            if (var < 0) return nullptr;
            s->vars.push_back(var);
          } else if (v.tkinds[s->vars.size()] == TV::T_UPVAL) {
            Value cv = read_binding(0, slot, std::string());
            Ty t = free_ty(cv, "an assigned upvalue");
            if (t == Y_UNK) return nullptr;
            int fi = free_index(0, slot, std::string(), t);
            P.fvs[static_cast<std::size_t>(fi)].written = true;
            s->vars.push_back(-1 - fi);  // an upvalue: -1 - its index among the free variables
          } else {
            int var = var_of_slot(slot, v.tkinds[s->vars.size()] == TV::T_CELL, true);
            if (var < 0) return fail.set("internal: an assignment to a local that is not bound"), nullptr;
            s->vars.push_back(var);
          }
        }
        return s;
      }
      case TV::K_IF: {
        IStmt* s = mk_stmt(IStmt::If, v.line);
        for (Node* k : v.kids) {
          IExpr* e = expr(k);
          if (!e) return nullptr;
          s->exprs.push_back(e);
        }
        for (Node* b : v.blocks) {
          IStmt* bs = stmt(b);
          if (!bs) return nullptr;
          s->blocks.push_back(bs);
        }
        if (v.els) {
          IStmt* bs = stmt(v.els);
          if (!bs) return nullptr;
          s->blocks.push_back(bs);
          s->has_else = true;
        }
        return s;
      }
      case TV::K_WHILE: {
        IStmt* s = mk_stmt(IStmt::While, v.line);
        IExpr* c = expr(v.cond);
        if (!c) return nullptr;
        s->exprs.push_back(c);
        IStmt* b = stmt(v.blocks[0]);
        if (!b) return nullptr;
        s->blocks.push_back(b);
        return s;
      }
      case TV::K_REPEAT: {
        IStmt* s = mk_stmt(IStmt::Repeat, v.line);
        IStmt* b = stmt(v.blocks[0]);  // the condition sees the body's locals: the body first
        if (!b) return nullptr;
        s->blocks.push_back(b);
        IExpr* c = expr(v.cond);
        if (!c) return nullptr;
        s->exprs.push_back(c);
        return s;
      }
      case TV::K_FOR: {
        if (v.captured) return fail.set("a loop variable captured by a closure"), nullptr;
        IStmt* s = mk_stmt(IStmt::For, v.line);
        for (std::size_t i = 0; i < 3; ++i) {
          if (!v.kids[i]) {
            if (i == 2) break;
            return fail.set("internal: a for loop without a bound"), nullptr;
          }
          IExpr* e = expr(v.kids[i]);
          if (!e) return nullptr;
          s->exprs.push_back(e);
        }
        int var = bind_slot(v.slots[0]);
        if (var < 0) return nullptr;
        s->vars.push_back(var);
        IStmt* b = stmt(v.blocks[0]);
        if (!b) return nullptr;
        s->blocks.push_back(b);
        return s;
      }
      case TV::K_RETURN: {
        if (v.kids.size() > 1) return fail.set("a return of several values"), nullptr;
        IStmt* s = mk_stmt(IStmt::Return, v.line);
        if (!v.kids.empty()) {
          IExpr* e = expr(v.kids[0]);
          if (!e) return nullptr;
          s->exprs.push_back(e);
        }
        return s;
      }
      case TV::K_BREAK: return mk_stmt(IStmt::Break, v.line);
      case TV::K_CALL: {
        IStmt* s = mk_stmt(IStmt::CallStat, v.line);
        IExpr* e = call(v);
        if (!e) return nullptr;
        s->exprs.push_back(e);
        return s;
      }
      default: fail.set("a statement the tier does not lower (a table, a string, a closure, a global write, ...)"); return nullptr;
    }
  }
};

// Builds the unit for the function of CL: that function and every kernel it calls.
bool build_unit(State& S, Unit& U, Closure* cl, Fail& f, Node* osr_loop = nullptr, int osr_style = 0) {
  if (osr_loop) unit_add_osr(S, U, cl, osr_loop, osr_style);
  else if (unit_add(S, U, cl, f) < 0) return false;
  for (std::size_t i = 0; i < U.protos.size(); ++i) {  // the unit grows while we go
    Builder b(S, U, static_cast<int>(i), f);
    if (!b.build()) {
      f.set("?");
      return false;
    }
  }
  int base = 0;
  for (std::unique_ptr<ProtoIR>& p : U.protos) {
    p->fvbase = base;
    base += static_cast<int>(p->fvs.size());
    if (p->nslots > U.max_nslots) U.max_nslots = p->nslots;
  }
  U.nfv = base;
  return true;
}

// ================================================================================================================================
// types
// ================================================================================================================================
struct Inst {
  int proto = 0;
  std::vector<Ty> sig;
  std::vector<Ty> vty;
  Ty ret = Y_UNK;
  std::vector<Ty> ety;
  std::vector<int> cinst;
  std::string bad;
};

bool has_break(const IStmt* s) {
  switch (s->k) {
    case IStmt::Break: return true;
    case IStmt::Block:
    case IStmt::If:
      for (const IStmt* b : s->blocks)
        if (has_break(b)) return true;
      return false;
    default: return false;  // a break inside a nested loop leaves that loop
  }
}

bool const_true(const IExpr* e) {
  if (e->k != IExpr::Const) return false;
  return e->cty == Y_B ? e->ci != 0 : true;
}

// Can control reach the end of S?
bool can_complete(const IStmt* s) {
  switch (s->k) {
    case IStmt::Block:
      for (const IStmt* b : s->blocks)
        if (!can_complete(b)) return false;
      return true;
    case IStmt::Return:
    case IStmt::Break: return false;
    case IStmt::If:
      if (!s->has_else) return true;
      for (const IStmt* b : s->blocks)
        if (can_complete(b)) return true;
      return false;
    case IStmt::While: return const_true(s->exprs[0]) ? has_break(s->blocks[0]) : true;
    default: return true;
  }
}

struct Infer {
  Unit& U;
  std::deque<Inst> insts;  // a deque: get_inst adds to it while a caller holds a reference to one of its elements
  bool changed = false;
  std::string error;
  std::vector<Ty> fvty;  // the type each free variable of the unit is kept in (by the unit's index: fvbase + the function's own)

  explicit Infer(Unit& u) : U(u) {
    for (const std::unique_ptr<ProtoIR>& p : u.protos) {
      if (fvty.size() < static_cast<std::size_t>(p->fvbase) + p->fvs.size()) fvty.resize(static_cast<std::size_t>(p->fvbase) + p->fvs.size(), Y_UNK);
      for (std::size_t j = 0; j < p->fvs.size(); ++j) fvty[static_cast<std::size_t>(p->fvbase) + j] = p->fvs[j].ty;
    }
  }

  ProtoIR& proto(const Inst& I) { return *U.protos[static_cast<std::size_t>(I.proto)]; }

  int get_inst(int proto_idx, const std::vector<Ty>& sig) {
    for (std::size_t i = 0; i < insts.size(); ++i)
      if (insts[i].proto == proto_idx && insts[i].sig == sig) return static_cast<int>(i);
    if (static_cast<int>(insts.size()) >= kMaxInstances) {
      error = "too many instances of functions (one per combination of argument types)";
      return -1;
    }
    Inst I;
    I.proto = proto_idx;
    I.sig = sig;
    ProtoIR& P = *U.protos[static_cast<std::size_t>(proto_idx)];
    I.vty.assign(static_cast<std::size_t>(P.nvars), Y_UNK);
    for (std::size_t k = 0; k < sig.size() && k < static_cast<std::size_t>(P.nparams); ++k) I.vty[static_cast<std::size_t>(P.pvars[k])] = sig[k];
    I.ety.assign(P.exprs.size(), Y_UNK);
    I.cinst.assign(P.exprs.size(), -1);
    insts.push_back(std::move(I));
    changed = true;
    return static_cast<int>(insts.size()) - 1;
  }

  void bad(Inst& I, const std::string& why) {
    if (I.bad.empty()) I.bad = why;
  }

  // DST (the type of a variable or of a result) takes in a value of type T. A number of one kind and a number of the other make a
  // Y_N; a boolean (or no value) with anything else is not a kernel.
  void join(Inst& I, Ty& dst, Ty t, const char* what) {
    if (t == Y_UNK) return;
    if (dst == Y_UNK) {
      dst = t;
      changed = true;
    } else if (dst != t) {
      if (is_num(dst) && is_num(t)) {
        if (dst != Y_N) {  // N takes in an integer and a float alike
          dst = Y_N;
          changed = true;
        }
      } else {
        bad(I, std::string(what) + " has two types (" + ty_ch(dst) + " and " + ty_ch(t) + ")");
      }
    }
  }

  // Need a value (an integer, a float or a boolean) here.
  bool need_val(Inst& I, Ty t, const char* what) {
    if (t == Y_UNK) return false;
    if (!is_val(t)) {
      bad(I, std::string(what) + " has no value of a storable type");
      return false;
    }
    return true;
  }

  Ty ex(Inst& I, IExpr* e) {
    Ty t = ex_(I, e);
    I.ety[static_cast<std::size_t>(e->id)] = t;
    return t;
  }

  Ty ex_(Inst& I, IExpr* e) {
    ProtoIR& P = proto(I);
    switch (e->k) {
      case IExpr::Const: return e->cty;
      case IExpr::Var: return I.vty[static_cast<std::size_t>(e->var)];
      case IExpr::Free: return fvty[static_cast<std::size_t>(P.fvbase + e->fv)];
      case IExpr::Arith: {
        Ty a = ex(I, e->kids[0]), b = ex(I, e->kids[1]);
        if (a == Y_UNK || b == Y_UNK) return Y_UNK;
        if (!is_num(a) || !is_num(b)) {
          bad(I, "arithmetic on a boolean");
          return Y_UNK;
        }
        switch (e->op) {
          case AR_ADD: case AR_SUB: case AR_MUL: case AR_MOD: case AR_IDIV:
            if (a == Y_F || b == Y_F) return Y_F;  // a float and anything is a float
            return a == Y_I && b == Y_I ? Y_I : Y_N;
          case AR_DIV: case AR_POW: return Y_F;
          case AR_BAND: case AR_BOR: case AR_BXOR: case AR_SHL: case AR_SHR:
            if (a != Y_F && b != Y_F) return Y_I;  // an N is converted when it runs, and abandons the run if it has no integer value
            bad(I, "a bitwise operation on a float");
            return Y_UNK;
          default: bad(I, "an arithmetic operator the tier does not lower"); return Y_UNK;
        }
      }
      case IExpr::Unary: {
        Ty a = ex(I, e->kids[0]);
        if (a == Y_UNK) return Y_UNK;
        if (e->op == OPX_NOT) {
          if (a == Y_V) {
            bad(I, "'not' of a call that returns nothing");
            return Y_UNK;
          }
          return Y_B;
        }
        if (e->op == AR_UNM) {
          if (is_num(a)) return a;
          bad(I, "unary minus on a boolean");
          return Y_UNK;
        }
        if (a == Y_I || a == Y_N) return Y_I;
        bad(I, "bitwise not on a float");
        return Y_UNK;
      }
      case IExpr::Cmp: {
        Ty a = ex(I, e->kids[0]), b = ex(I, e->kids[1]);
        if (a == Y_UNK || b == Y_UNK) return Y_UNK;
        if (!is_num(a) || !is_num(b)) {
          bad(I, "an order comparison of non-numbers");
          return Y_UNK;
        }
        return Y_B;
      }
      case IExpr::Eq: {
        Ty a = ex(I, e->kids[0]), b = ex(I, e->kids[1]);
        if (a == Y_UNK || b == Y_UNK) return Y_UNK;
        if ((is_num(a) && is_num(b)) || (a == Y_B && b == Y_B)) return Y_B;
        bad(I, "an equality comparison of a boolean with a number, or of something without a value");
        return Y_UNK;
      }
      case IExpr::And:
      case IExpr::Or: {
        Ty a = ex(I, e->kids[0]), b = ex(I, e->kids[1]);
        if (a == Y_UNK || b == Y_UNK) return Y_UNK;
        if (a == Y_V || b == Y_V) {
          bad(I, "'and' / 'or' of a call that returns nothing");
          return Y_UNK;
        }
        bool is_and = e->k == IExpr::And;
        if (is_num(a)) return is_and ? b : a;  // a number is always true
        if (a == Y_B && b == Y_B) return Y_B;
        return Y_Q;
      }
      case IExpr::Call: {
        bool known = true;
        std::vector<Ty> sig;
        for (IExpr* k : e->kids) {
          Ty t = ex(I, k);
          if (t == Y_UNK) known = false;
          else if (!need_val(I, t, "an argument")) known = false;
          sig.push_back(t);
        }
        if (!known) return Y_UNK;
        const Dep& d = P.deps[static_cast<std::size_t>(e->dep)];
        int ci = get_inst(d.callee, sig);
        if (ci < 0) {
          bad(I, error);
          return Y_UNK;
        }
        I.cinst[static_cast<std::size_t>(e->id)] = ci;
        return insts[static_cast<std::size_t>(ci)].ret;
      }
    }
    return Y_UNK;
  }

  void st(Inst& I, IStmt* s) {
    switch (s->k) {
      case IStmt::Block:
        for (IStmt* b : s->blocks) st(I, b);
        break;
      case IStmt::Decl:
      case IStmt::Assign:
        for (std::size_t i = 0; i < s->exprs.size(); ++i) {
          Ty t = ex(I, s->exprs[i]);
          if (!need_val(I, t, "a value that is assigned")) continue;
          int var = s->vars[i];
          if (var >= 0) join(I, I.vty[static_cast<std::size_t>(var)], t, "a variable");
          else join(I, fvty[static_cast<std::size_t>(proto(I).fvbase - 1 - var)], t, "an assigned upvalue");
        }
        break;
      case IStmt::If:
        for (IExpr* c : s->exprs) cond(I, c);
        for (IStmt* b : s->blocks) st(I, b);
        break;
      case IStmt::While:
        cond(I, s->exprs[0]);
        st(I, s->blocks[0]);
        break;
      case IStmt::Repeat:
        st(I, s->blocks[0]);
        cond(I, s->exprs[0]);
        break;
      case IStmt::For: {
        if (s->osr) {  // the loop of a unit for on-stack replacement: its header has run, and says which kind of loop it is
          join(I, I.vty[static_cast<std::size_t>(s->vars[0])], s->osr == 2 ? Y_I : Y_F, "a loop variable");
          st(I, s->blocks[0]);
          break;
        }
        Ty ts[3] = {Y_UNK, Y_UNK, Y_I};
        bool known = true;
        for (std::size_t i = 0; i < s->exprs.size(); ++i) {
          ts[i] = ex(I, s->exprs[i]);
          if (ts[i] == Y_UNK) known = false;
          else if (!is_num(ts[i])) {
            bad(I, "a 'for' loop over a boolean or a non-value");
            known = false;
          } else if (ts[i] == Y_N && i != 1) {  // whether the loop counts in integers or in floats depends on these two
            bad(I, "a 'for' loop whose start or step is an integer or a float as the run goes");
            known = false;
          }
        }
        if (known) join(I, I.vty[static_cast<std::size_t>(s->vars[0])], ts[0] == Y_I && ts[2] == Y_I ? Y_I : Y_F, "a loop variable");
        st(I, s->blocks[0]);
        break;
      }
      case IStmt::Return: {
        if (s->exprs.empty()) {
          join(I, I.ret, Y_V, "the result of a function");
        } else {
          Ty t = ex(I, s->exprs[0]);
          if (need_val(I, t, "a returned value")) join(I, I.ret, t, "the result of a function");
        }
        break;
      }
      case IStmt::Break: break;
      case IStmt::CallStat: ex(I, s->exprs[0]); break;
    }
  }

  void cond(Inst& I, IExpr* c) {
    Ty t = ex(I, c);
    if (t == Y_V) bad(I, "a condition that is a call returning nothing");
  }

  void pass(Inst& I) {
    ProtoIR& P = proto(I);
    I.bad.clear();  // what is wrong with the types as they stand now; they widen while the rounds go on
    st(I, P.body);
    if (!P.osr && can_complete(P.body)) join(I, I.ret, Y_V, "the result of a function");  // a loop that is taken over ends normally and returns nothing
  }

  std::vector<char> live;  // the instances the root function can reach; the others came from types that have widened since

  // Types the unit for the root function with SIG. False with ERROR set when it is not a kernel with those argument types.
  bool run(const std::vector<Ty>& sig) {
    if (get_inst(0, sig) < 0) return false;
    int round = 0;
    for (; round < 400; ++round) {
      changed = false;
      for (std::size_t i = 0; i < insts.size(); ++i) pass(insts[i]);
      if (!error.empty()) return false;
      if (!changed) break;
    }
    if (round >= 400) {
      error = "the types do not settle";
      return false;
    }
    // A call made with an argument of a type that was widened later left an instance behind that nothing calls any more.
    live.assign(insts.size(), 0);
    live[0] = 1;
    std::vector<int> work(1, 0);
    while (!work.empty()) {
      int n = work.back();
      work.pop_back();
      for (int c : insts[static_cast<std::size_t>(n)].cinst)
        if (c >= 0 && !live[static_cast<std::size_t>(c)]) {
          live[static_cast<std::size_t>(c)] = 1;
          work.push_back(c);
        }
    }
    for (std::size_t n = 0; n < insts.size(); ++n) {
      if (!live[n]) continue;
      Inst& I = insts[n];
      ProtoIR& P = proto(I);
      if (!I.bad.empty()) {
        error = I.bad;
        return false;
      }
      if (I.ret == Y_UNK) I.ret = Y_V;  // never returns (an endless loop)
      for (Ty t : I.vty)
        if (t == Y_UNK) {
          error = "a variable whose type cannot be determined";
          return false;
        }
      for (std::size_t i = 0; i < P.exprs.size(); ++i)
        if (I.ety[i] == Y_UNK) {
          error = "an expression whose type cannot be determined (a recursion that never returns a value?)";
          return false;
        }
#if defined(__aarch64__) || defined(__FP_FAST_FMA) || defined(__ARM_FEATURE_FMA)
      // The C compiler of the generated code fuses a multiplication and an addition on this target unless told not to, which
      // changes the last bit of a float result; the interpreter never fuses. Float kernels stay interpreted here (untested: it
      // needs such a host).
      for (Ty t : I.vty)
        if (t == Y_F || t == Y_N) {
          error = "floating point on a target that fuses multiply-add";
          return false;
        }
      for (Ty t : I.ety)
        if (t == Y_F || t == Y_N) {
          error = "floating point on a target that fuses multiply-add";
          return false;
        }
#endif
    }
    return true;
  }
};

// ================================================================================================================================
// source text
// ================================================================================================================================
std::string num(long long v) {
  char buf[40];
  std::snprintf(buf, sizeof buf, "%lld", v);
  return buf;
}

const char* kPreamble =
    "// generated by the nfcast tier (docs/notes/ast.md); do not edit\n"
    "#define NFCAST_RT_GENERATED 1\n"
    "#include <setjmp.h>\n"
    "extern \"C\" { double floor(double); double ceil(double); double fmod(double, double); double pow(double, double); }\n"
    "static double (*volatile nfct_pow_p)(double, double) = pow;\n"  // not foldable by the C compiler: the interpreter calls pow at run time
    "#define NFCR_POW(a, b) nfct_pow_p((a), (b))\n";

const char* kPostRt =
    "static void nfct_bail(nfcr_Ctx* cx) { longjmp(*(jmp_buf*)cx->jb, 1); }\n"
    "static nfcr_i64 nfct_idiv(nfcr_Ctx* cx, nfcr_i64 a, nfcr_i64 b) { if (b == 0) nfct_bail(cx); return nfcr_idiv(a, b); }\n"
    "static nfcr_i64 nfct_imod(nfcr_Ctx* cx, nfcr_i64 a, nfcr_i64 b) { if (b == 0) nfct_bail(cx); return nfcr_imod(a, b); }\n"
    "static nfcr_N nfct_nidiv(nfcr_Ctx* cx, nfcr_N a, nfcr_N b) { if (!(a.f | b.f) && b.w.i == 0) nfct_bail(cx); return nfcr_nidiv(a, b); }\n"
    "static nfcr_N nfct_nmod(nfcr_Ctx* cx, nfcr_N a, nfcr_N b) { if (!(a.f | b.f) && b.w.i == 0) nfct_bail(cx); return nfcr_nmod(a, b); }\n"
    "static nfcr_i64 nfct_ntoi(nfcr_Ctx* cx, nfcr_N n) { nfcr_i64 r = 0; if (!nfcr_ntoi(n, &r)) nfct_bail(cx); return r; }\n"
    "static nfcr_N nfct_fvn(const nfcr_W* p) { nfcr_N n; n.w = p[0]; n.f = p[1].i; return n; }\n"
    "static double nfct_dbl(nfcr_u64 bits) { union { nfcr_u64 u; double d; } x; x.u = bits; return x.d; }\n"
    // The C compiler folds 0.0 / 0.0 to a positive NaN where the interpreter divides at run time and gets the processor's (negative on
    // x86); an operation on two constants, which the parser leaves alone exactly when its result is a NaN, goes through this.
    "static double nfct_id(double x) { return x; }\n"
    "static double (*volatile nfct_opq_p)(double) = nfct_id;\n";

struct Gen {
  Unit& U;
  Infer& in;
  std::string cur;  // the statements being written
  int ntmp = 0;
  int inst_idx = 0;

  Gen(Unit& u, Infer& i) : U(u), in(i) {}

  std::string tmp() { return "t" + num(ntmp++); }
  Inst& inst() { return in.insts[static_cast<std::size_t>(inst_idx)]; }
  ProtoIR& proto() { return *U.protos[static_cast<std::size_t>(inst().proto)]; }
  Ty ty(const IExpr* e) { return inst().ety[static_cast<std::size_t>(e->id)]; }
  static std::string vname(int v) { return "v" + num(v); }

  static std::string dbl_lit(double d) {
    if (d != d || d - d != 0) {  // NaN or infinite: by bits
      nfcr_u64 bits;
      std::memcpy(&bits, &d, sizeof bits);
      char buf[48];
      std::snprintf(buf, sizeof buf, "nfct_dbl(0x%llxULL)", static_cast<unsigned long long>(bits));
      return buf;
    }
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.17g", d);
    std::string s = buf;
    if (s.find_first_of(".eE") == std::string::npos) s += ".0";
    if (d == 0 && std::signbit(d)) return "(-0.0)";
    return "(" + s + ")";
  }

  static std::string int_lit(long long v) {
    if (v == static_cast<long long>(-9223372036854775807LL - 1)) return "(-9223372036854775807LL - 1)";
    return "(" + num(v) + "LL)";
  }

  // Does evaluating E run a call, or an operation that can abandon the run? Such expressions keep their order.
  static bool is_bit(int op) { return op == AR_BAND || op == AR_BOR || op == AR_BXOR || op == AR_SHL || op == AR_SHR; }

  bool impure(const IExpr* e) {
    if (e->k == IExpr::Call) return true;
    if (e->k == IExpr::Arith) {
      if ((e->op == AR_MOD || e->op == AR_IDIV) && ty(e) != Y_F) {  // two integers at run time may divide by zero
        const IExpr* d = e->kids[1];
        if (!(d->k == IExpr::Const && d->cty == Y_I && d->ci != 0)) return true;
      }
      if (is_bit(e->op) && (ty(e->kids[0]) == Y_N || ty(e->kids[1]) == Y_N)) return true;  // a float without an integer value
    } else if (e->k == IExpr::Unary && e->op == AR_BNOT && ty(e->kids[0]) == Y_N) {
      return true;
    }
    for (const IExpr* k : e->kids)
      if (impure(k)) return true;
    return false;
  }

  static std::string D(const std::string& s, Ty t) { return t == Y_I ? "((double)(" + s + "))" : t == Y_N ? "nfcr_nd(" + s + ")" : s; }

  // The C expression S, of type FROM, as a value of type TO: a variable, a result or a parameter has the type that all the values
  // put into it fit in.
  static std::string conv(const std::string& s, Ty from, Ty to) {
    if (from == to || to != Y_N) return s;
    return from == Y_I ? "nfcr_ni(" + s + ")" : from == Y_F ? "nfcr_nf(" + s + ")" : s;
  }

  static std::string zero(Ty t) { return t == Y_F ? "0.0" : t == Y_N ? "nfcr_ni(0)" : "0"; }

  // An operand of a bitwise operator, as an integer.
  static std::string toi(const std::string& s, Ty t) { return t == Y_N ? "nfct_ntoi(cx, " + s + ")" : s; }

  // The operands in order. An operand with side effects that is followed by another one goes into a temporary first, so that C's
  // unspecified order of evaluation cannot make an endless loop in the second win over an error in the first.
  std::vector<std::string> operands(const std::vector<IExpr*>& kids) {
    std::vector<std::string> r(kids.size());
    int last = -1;
    for (std::size_t i = 0; i < kids.size(); ++i)
      if (impure(kids[i])) last = static_cast<int>(i);
    for (std::size_t i = 0; i < kids.size(); ++i) {
      r[i] = ex(kids[i]);
      if (static_cast<int>(i) < last && impure(kids[i])) {
        std::string t = tmp();
        cur += std::string(ty_c(ty(kids[i]) == Y_V ? Y_I : ty(kids[i]))) + " " + t + " = " + r[i] + ";\n";
        r[i] = t;
      }
    }
    return r;
  }

  std::string cond(IExpr* e) {
    switch (e->k) {
      case IExpr::And:
      case IExpr::Or: {
        bool is_and = e->k == IExpr::And;
        std::string a = cond(e->kids[0]);
        if (!impure(e->kids[1])) {
          std::string b = cond(e->kids[1]);
          return "(" + a + (is_and ? " && " : " || ") + b + ")";
        }
        std::string t = tmp();
        cur += "int " + t + " = " + a + ";\nif (" + (is_and ? "" : "!") + t + ") {\n";
        std::string b = cond(e->kids[1]);
        cur += t + " = " + b + ";\n}\n";
        return t;
      }
      case IExpr::Unary:
        if (e->op == OPX_NOT) return "(!" + cond(e->kids[0]) + ")";
        break;
      default: break;
    }
    Ty t = ty(e);
    std::string s = ex(e);
    if (t == Y_B || t == Y_Q) return s;
    if (!impure(e)) return "1";
    return "((void)(" + s + "), 1)";
  }

  std::string ex(IExpr* e) {
    switch (e->k) {
      case IExpr::Const:
        if (e->cty == Y_I) return int_lit(e->ci);
        if (e->cty == Y_F) return dbl_lit(e->cd);
        return e->ci ? "1" : "0";
      case IExpr::Var: return vname(e->var);
      case IExpr::Free: {
        Ty ft = in.fvty[static_cast<std::size_t>(proto().fvbase + e->fv)];
        std::string a = "cx->fv[" + num(2 * (proto().fvbase + e->fv)) + "]";
        if (ft == Y_N) return "nfct_fvn(&" + a + ")";
        return ft == Y_F ? a + ".d" : (ft == Y_B ? "(int)" + a + ".i" : a + ".i");
      }
      case IExpr::Arith: {
        Ty ta = ty(e->kids[0]), tb = ty(e->kids[1]), rt = ty(e);
        std::vector<std::string> o = operands(e->kids);
        bool ii = ta == Y_I && tb == Y_I;
        if (e->kids[0]->k == IExpr::Const && e->kids[1]->k == IExpr::Const && (!ii || e->op == AR_DIV || e->op == AR_POW) && !is_bit(e->op)) {
          o[0] = "nfct_opq_p(" + D(o[0], ta) + ")";  // not for the C compiler to evaluate
          ta = Y_F;
        }
        const std::string &a = o[0], &b = o[1];
        switch (e->op) {
          case AR_ADD:
          case AR_SUB:
          case AR_MUL: {
            const char* name = e->op == AR_ADD ? "add" : e->op == AR_SUB ? "sub" : "mul";
            const char* sym = e->op == AR_ADD ? " + " : e->op == AR_SUB ? " - " : " * ";
            if (rt == Y_I) return std::string("nfcr_") + name + "(" + a + ", " + b + ")";
            if (rt == Y_N) return std::string("nfcr_n") + name + "(" + conv(a, ta, Y_N) + ", " + conv(b, tb, Y_N) + ")";
            return "(" + D(a, ta) + sym + D(b, tb) + ")";
          }
          case AR_MOD:
          case AR_IDIV: {
            bool mod = e->op == AR_MOD;
            if (rt == Y_F) return std::string(mod ? "nfcr_fmod(" : "nfcr_fidiv(") + D(a, ta) + ", " + D(b, tb) + ")";
            const IExpr* d = e->kids[1];
            bool safe = d->k == IExpr::Const && d->cty == Y_I && d->ci != 0;
            if (rt == Y_I) return std::string(safe ? (mod ? "nfcr_imod(" : "nfcr_idiv(") : (mod ? "nfct_imod(cx, " : "nfct_idiv(cx, ")) + a + ", " + b + ")";
            return std::string(safe ? (mod ? "nfcr_nmod(" : "nfcr_nidiv(") : (mod ? "nfct_nmod(cx, " : "nfct_nidiv(cx, ")) + conv(a, ta, Y_N) + ", " + conv(b, tb, Y_N) + ")";
          }
          case AR_DIV: return "(" + D(a, ta) + " / " + D(b, tb) + ")";
          case AR_POW: return "nfcr_fpow(" + D(a, ta) + ", " + D(b, tb) + ")";
          case AR_BAND: return "(" + toi(a, ta) + " & " + toi(b, tb) + ")";
          case AR_BOR: return "(" + toi(a, ta) + " | " + toi(b, tb) + ")";
          case AR_BXOR: return "(" + toi(a, ta) + " ^ " + toi(b, tb) + ")";
          case AR_SHL: return "nfcr_shl(" + toi(a, ta) + ", " + toi(b, tb) + ")";
          default: return "nfcr_shr(" + toi(a, ta) + ", " + toi(b, tb) + ")";
        }
      }
      case IExpr::Unary: {
        if (e->op == OPX_NOT) return "(!" + cond(e->kids[0]) + ")";
        std::string a = ex(e->kids[0]);
        Ty ta = ty(e->kids[0]);
        if (e->op == AR_UNM) return ta == Y_I ? "nfcr_neg(" + a + ")" : ta == Y_N ? "nfcr_nneg(" + a + ")" : "(-" + a + ")";
        return "(~" + toi(a, ta) + ")";
      }
      case IExpr::Cmp: {
        Ty ta = ty(e->kids[0]), tb = ty(e->kids[1]);
        std::vector<std::string> o = operands(e->kids);
        const std::string &a = o[0], &b = o[1];
        if (ta == Y_N || tb == Y_N) {
          std::string na = conv(a, ta, Y_N), nb = conv(b, tb, Y_N);
          switch (e->op) {
            case CMP_LT: return "nfcr_nlt(" + na + ", " + nb + ")";
            case CMP_LE: return "nfcr_nle(" + na + ", " + nb + ")";
            case CMP_GT: return "nfcr_nlt(" + nb + ", " + na + ")";
            default: return "nfcr_nle(" + nb + ", " + na + ")";
          }
        }
        if (ta == tb) {
          const char* sym = e->op == CMP_LT ? " < " : e->op == CMP_LE ? " <= " : e->op == CMP_GT ? " > " : " >= ";
          return "(" + a + sym + b + ")";
        }
        bool int_first = ta == Y_I;
        switch (e->op) {
          case CMP_LT: return int_first ? "nfcr_lt_if(" + a + ", " + b + ")" : "nfcr_lt_fi(" + a + ", " + b + ")";
          case CMP_LE: return int_first ? "nfcr_le_if(" + a + ", " + b + ")" : "nfcr_le_fi(" + a + ", " + b + ")";
          case CMP_GT: return int_first ? "nfcr_lt_fi(" + b + ", " + a + ")" : "nfcr_lt_if(" + b + ", " + a + ")";
          default: return int_first ? "nfcr_le_fi(" + b + ", " + a + ")" : "nfcr_le_if(" + b + ", " + a + ")";
        }
      }
      case IExpr::Eq: {
        Ty ta = ty(e->kids[0]), tb = ty(e->kids[1]);
        std::vector<std::string> o = operands(e->kids);
        std::string r;
        if (ta == Y_N || tb == Y_N) r = "nfcr_neq(" + conv(o[0], ta, Y_N) + ", " + conv(o[1], tb, Y_N) + ")";
        else if (ta == tb) r = "(" + o[0] + " == " + o[1] + ")";
        else if (ta == Y_I) r = "nfcr_eq_if(" + o[0] + ", " + o[1] + ")";
        else r = "nfcr_eq_if(" + o[1] + ", " + o[0] + ")";
        return e->neg ? "(!" + r + ")" : r;
      }
      case IExpr::And:
      case IExpr::Or: {
        Ty t = ty(e);
        bool is_and = e->k == IExpr::And;
        if (t == Y_B || t == Y_Q) return cond(e);
        // The left operand is a number, which is always true: `a and b` is b, `a or b` is a (and b is never evaluated).
        std::string a = ex(e->kids[0]);
        if (!is_and) return a;
        if (impure(e->kids[0])) cur += "(void)(" + a + ");\n";
        return ex(e->kids[1]);
      }
      case IExpr::Call: {
        const Dep& d = proto().deps[static_cast<std::size_t>(e->dep)];
        (void)d;
        std::vector<std::string> o = operands(e->kids);
        std::string s = "nfct_f" + num(inst().cinst[static_cast<std::size_t>(e->id)]) + "(cx";
        for (const std::string& a : o) s += ", " + a;
        return s + ")";
      }
    }
    return "0";
  }

  void emit_block(const IStmt* s) {
    if (s->k == IStmt::Block) {
      for (const IStmt* b : s->blocks) stmt(b);
    } else {
      stmt(s);
    }
  }

  // Runs F with the output redirected, and returns what it wrote.
  template <class F>
  std::string capture(F f) {
    std::string saved;
    saved.swap(cur);
    f();
    std::string out;
    out.swap(cur);
    cur.swap(saved);
    return out;
  }

  void emit_if(const IStmt* s, std::size_t k) {
    std::string c = cond(s->exprs[k]);
    cur += "if (" + c + ") {\n";
    emit_block(s->blocks[k]);
    cur += "}";
    if (k + 1 < s->exprs.size()) {
      cur += " else {\n";
      emit_if(s, k + 1);
      cur += "}\n";
    } else if (s->has_else) {
      cur += " else {\n";
      emit_block(s->blocks.back());
      cur += "}\n";
    } else {
      cur += "\n";
    }
  }

  // The C statement that stores S, the C expression for the value of E, in the variable VAR (a negative VAR is the upvalue -1 - VAR).
  std::string store(int var, const IExpr* e, const std::string& s) {
    if (var >= 0) return vname(var) + " = " + conv(s, ty(e), inst().vty[static_cast<std::size_t>(var)]) + ";\n";
    int g = proto().fvbase - 1 - var;
    Ty st = in.fvty[static_cast<std::size_t>(g)];
    std::string a = "cx->fv[" + num(2 * g) + "]";
    if (st == Y_N) {
      std::string t = tmp();
      return "{ nfcr_N " + t + " = " + conv(s, ty(e), Y_N) + "; " + a + " = " + t + ".w; cx->fv[" + num(2 * g + 1) + "].i = " + t + ".f; }\n";
    }
    return a + (st == Y_F ? ".d" : ".i") + " = " + s + ";\n";
  }

  void stmt(const IStmt* s) {
    switch (s->k) {
      case IStmt::Block: emit_block(s); break;
      case IStmt::Decl:
      case IStmt::Assign: {
        std::vector<std::string> o = operands(s->exprs);
        if (s->vars.size() == 1) {
          cur += store(s->vars[0], s->exprs[0], o[0]);
          break;
        }
        if (s->k == IStmt::Decl) {  // new variables: nothing the values read changes
          for (std::size_t i = 0; i < s->vars.size(); ++i) cur += store(s->vars[i], s->exprs[i], o[i]);
          break;
        }
        std::vector<std::string> t;
        for (std::size_t i = 0; i < s->vars.size(); ++i) {
          t.push_back(tmp());
          cur += std::string(ty_c(ty(s->exprs[i]))) + " " + t[i] + " = " + o[i] + ";\n";
        }
        for (std::size_t i = s->vars.size(); i > 0; --i) cur += store(s->vars[i - 1], s->exprs[i - 1], t[i - 1]);  // right to left, as the interpreter stores
        break;
      }
      case IStmt::If: emit_if(s, 0); break;
      case IStmt::While: {
        std::string c;
        std::string pre = capture([&] { c = cond(s->exprs[0]); });
        if (pre.empty()) {
          cur += "while (" + c + ") {\n";
        } else {
          cur += "for (;;) {\n" + pre + "if (!" + c + ") break;\n";
        }
        emit_block(s->blocks[0]);
        cur += "}\n";
        break;
      }
      case IStmt::Repeat: {
        cur += "for (;;) {\n";
        emit_block(s->blocks[0]);
        std::string c = cond(s->exprs[0]);
        cur += "if (" + c + ") break;\n}\n";
        break;
      }
      case IStmt::For: s->osr ? osr_for(s) : for_loop(s); break;
      case IStmt::Return: {
        if (inst_idx == 0 && is_osr()) {  // the function the loop is in returns: the value goes out through O, after the live locals
          std::size_t at = static_cast<std::size_t>(2 * proto().nparams);
          if (!s->exprs.empty()) {
            Ty rt = inst().ret;
            std::string t = tmp();
            cur += std::string(ty_c(rt)) + " " + t + " = " + conv(ex(s->exprs[0]), ty(s->exprs[0]), rt) + ";\n";
            if (rt == Y_N) cur += "o[" + num(static_cast<long long>(at)) + "] = " + t + ".w;\no[" + num(static_cast<long long>(at) + 1) + "].i = " + t + ".f;\n";
            else if (rt == Y_F) cur += "o[" + num(static_cast<long long>(at)) + "].d = " + t + ";\n";
            else cur += "o[" + num(static_cast<long long>(at)) + "].i = " + t + ";\n";
          }
          cur += "return 1;\n";
          break;
        }
        if (s->exprs.empty()) {
          cur += "--cx->depth;\nreturn;\n";
        } else {
          std::string v = ex(s->exprs[0]);
          std::string t = tmp();
          Ty rt = inst().ret;
          cur += std::string(ty_c(rt)) + " " + t + " = " + conv(v, ty(s->exprs[0]), rt) + ";\n--cx->depth;\nreturn " + t + ";\n";
        }
        break;
      }
      case IStmt::Break: cur += "break;\n"; break;
      case IStmt::CallStat: {
        std::string v = ex(s->exprs[0]);
        cur += v + ";\n";
        break;
      }
    }
  }

  void for_loop(const IStmt* s) {
    Ty ts = ty(s->exprs[0]), tl = ty(s->exprs[1]);
    Ty tp = s->exprs.size() > 2 ? ty(s->exprs[2]) : Y_I;
    std::vector<IExpr*> hdr(s->exprs.begin(), s->exprs.end());
    std::vector<std::string> o = operands(hdr);
    std::string var = vname(s->vars[0]);
    Ty vt = inst().vty[static_cast<std::size_t>(s->vars[0])];
    std::string id = num(ntmp++);
    std::string i0 = "i" + id, lim = "l" + id, st = "s" + id, cnt = "n" + id, ix = "x" + id;
    cur += "{\n";
    if (ts == Y_I && tp == Y_I) {  // an integer loop
      cur += "nfcr_i64 " + i0 + " = " + o[0] + ";\nnfcr_i64 " + st + " = " + (o.size() > 2 ? o[2] : std::string("1")) + ";\n";
      cur += "nfcr_i64 " + lim + " = 0;\nint go" + id + " = 1;\n";
      cur += "if (" + st + " == 0) nfct_bail(cx);\n";
      if (tl == Y_I) {
        cur += lim + " = " + o[1] + ";\n";
      } else if (tl == Y_N) {  // an integer or a float, as the run goes
        cur += "nfcr_N ln" + id + " = " + o[1] + ";\nif (ln" + id + ".f) { if (!nfcr_forlimit(ln" + id + ".w.d, " + st + ", &" + lim + ")) go" + id + " = 0; } else " + lim + " = ln" + id + ".w.i;\n";
      } else {
        cur += "if (!nfcr_forlimit(" + o[1] + ", " + st + ", &" + lim + ")) go" + id + " = 0;\n";
      }
      cur += "if (go" + id + " && (" + st + " > 0 ? " + i0 + " > " + lim + " : " + i0 + " < " + lim + ")) go" + id + " = 0;\n";
      cur += "if (go" + id + ") {\nnfcr_u64 " + cnt + " = nfcr_forcount(" + i0 + ", " + lim + ", " + st + ");\nnfcr_i64 " + ix + " = " + i0 + ";\nfor (;;) {\n";
      cur += var + " = " + conv(ix, Y_I, vt) + ";\n";
      emit_block(s->blocks[0]);
      cur += "if (" + cnt + "-- == 0) break;\n" + ix + " = nfcr_add(" + ix + ", " + st + ");\n}\n}\n";
    } else {  // a float loop
      cur += "double " + ix + " = " + D(o[0], ts) + ";\ndouble " + lim + " = " + D(o[1], tl) + ";\ndouble " + st + " = " +
             (o.size() > 2 ? D(o[2], tp) : std::string("1.0")) + ";\n";
      cur += "if (" + st + " == 0) nfct_bail(cx);\n";
      // like Lua's forprep: only a start beyond the limit skips the loop, so a NaN bound runs the body once
      cur += "for (int f" + id + " = 1; f" + id + " ? !(0 < " + st + " ? " + lim + " < " + ix + " : " + ix + " < " + lim + ") : (0 < " + st + " ? " + ix + " <= " + lim +
             " : " + lim + " <= " + ix + "); " + ix + " += " + st + ", f" + id + " = 0) {\n";
      cur += var + " = " + conv(ix, Y_F, vt) + ";\n";
      emit_block(s->blocks[0]);
      cur += "}\n";
    }
    cur += "}\n";
  }

  // The loop of a unit for on-stack replacement, from the state the interpreter hands over: the next value of the loop variable and
  // what remains of the count (an integer loop: E0, E1, E2 are the variable, the iterations after this one and the step), or
  // (a float loop) the variable, the limit and the step. The test of a float loop comes first, as in the interpreter's.
  void osr_for(const IStmt* s) {
    Ty vt = inst().vty[static_cast<std::size_t>(s->vars[0])];
    std::string var = vname(s->vars[0]);
    if (s->osr == 2) {
      cur += "{\nnfcr_i64 ox = e0;\nnfcr_u64 oc = e1;\nnfcr_i64 os = e2;\nfor (;;) {\n" + var + " = " + conv("ox", Y_I, vt) + ";\n";
      emit_block(s->blocks[0]);
      cur += "if (oc-- == 0) break;\nox = nfcr_add(ox, os);\n}\n}\n";
    } else {
      cur += "{\ndouble ox = e0;\ndouble ol = e1;\ndouble os = e2;\nfor (; os > 0 ? ox <= ol : ol <= ox; ox += os) {\n" + var + " = " + conv("ox", Y_F, vt) + ";\n";
      emit_block(s->blocks[0]);
      cur += "}\n}\n";
    }
  }

  bool is_osr() { return U.protos[0]->osr; }

  // The first function of a unit for on-stack replacement: the live locals come in as parameters, the loop runs, and their values go
  // out through O (a word each, and a second one with the kind of an N). It returns nothing and has no `return`, so there is no
  // depth to count: the running function's frame is the interpreter's.
  std::string head_osr() {
    Inst& I = in.insts[0];
    ProtoIR& P = *U.protos[0];
    std::string h = "static int nfct_f0(nfcr_Ctx* cx";
    for (int k = 0; k < P.nparams; ++k) h += std::string(", ") + ty_c(I.sig[static_cast<std::size_t>(k)]) + " p" + num(k);
    if (U.osr_style == TierLoopState::FOR_INT) h += ", nfcr_i64 e0, nfcr_u64 e1, nfcr_i64 e2";
    else if (U.osr_style == TierLoopState::FOR_FLT) h += ", double e0, double e1, double e2";
    return h + ", nfcr_W* o)";
  }

  std::string function_osr() {
    inst_idx = 0;
    Inst& I = inst();
    ProtoIR& P = proto();
    cur.clear();
    ntmp = 0;
    std::vector<int> pidx(static_cast<std::size_t>(P.nvars), -1);
    for (int k = 0; k < P.nparams; ++k) pidx[static_cast<std::size_t>(P.pvars[static_cast<std::size_t>(k)])] = k;
    for (int v = 0; v < P.nvars; ++v) {
      Ty t = I.vty[static_cast<std::size_t>(v)];
      int k = pidx[static_cast<std::size_t>(v)];
      std::string init = k >= 0 ? conv("p" + num(k), I.sig[static_cast<std::size_t>(k)], t) : zero(t);
      cur += std::string(ty_c(t)) + " " + vname(v) + " = " + init + ";\n";
    }
    stmt(P.body);
    for (int k = 0; k < P.nparams; ++k) {
      int v = P.pvars[static_cast<std::size_t>(k)];
      Ty t = I.vty[static_cast<std::size_t>(v)];
      std::string o = "o[" + num(2 * k) + "]";
      if (t == Y_N) cur += o + " = " + vname(v) + ".w;\no[" + num(2 * k + 1) + "].i = " + vname(v) + ".f;\n";
      else if (t == Y_F) cur += o + ".d = " + vname(v) + ";\n";
      else cur += o + ".i = " + vname(v) + ";\n";
    }
    return head_osr() + " {\n" + cur + "return 0;\n}\n";
  }

  std::string trampoline_osr() {
    Inst& I = in.insts[0];
    ProtoIR& P = *U.protos[0];
    std::string call = "nfct_f0(cx";
    for (int k = 0; k < P.nparams; ++k) {
      Ty t = I.sig[static_cast<std::size_t>(k)];
      call += ", " + std::string(t == Y_F ? "a[" + num(k) + "].d" : t == Y_B ? "(int)a[" + num(k) + "].i" : "a[" + num(k) + "].i");
    }
    std::string n0 = num(P.nparams), n1 = num(P.nparams + 1), n2 = num(P.nparams + 2);
    if (U.osr_style == TierLoopState::FOR_INT) call += ", a[" + n0 + "].i, (nfcr_u64)a[" + n1 + "].i, a[" + n2 + "].i";
    else if (U.osr_style == TierLoopState::FOR_FLT) call += ", a[" + n0 + "].d, a[" + n1 + "].d, a[" + n2 + "].d";
    call += ", r)";
    return "extern \"C\" int nfcast_tier_run(nfcr_Ctx* cx, const nfcr_W* a, nfcr_W* r) {\n  jmp_buf jb;\n  cx->jb = &jb;\n  if (setjmp(jb)) return 1;\n  return " +
           call + " ? 2 : 0;\n}\n";
  }

  std::string head(int idx) {
    if (idx == 0 && is_osr()) return head_osr();
    Inst& I = in.insts[static_cast<std::size_t>(idx)];
    ProtoIR& P = *U.protos[static_cast<std::size_t>(I.proto)];
    std::string h = std::string("static ") + ty_c(I.ret) + " nfct_f" + num(idx) + "(nfcr_Ctx* cx";
    for (int k = 0; k < P.nparams; ++k) h += std::string(", ") + ty_c(I.sig[static_cast<std::size_t>(k)]) + " p" + num(k);
    return h + ")";
  }

  std::string function(int idx) {
    if (idx == 0 && is_osr()) return function_osr();
    inst_idx = idx;
    Inst& I = inst();
    ProtoIR& P = proto();
    cur.clear();
    ntmp = 0;
    for (int v = 0; v < P.nvars; ++v) {
      Ty t = I.vty[static_cast<std::size_t>(v)];
      std::string init = v < P.nparams ? conv("p" + num(v), I.sig[static_cast<std::size_t>(v)], t) : zero(t);  // a parameter that is assigned a float is an N
      cur += std::string(ty_c(t)) + " " + vname(v) + " = " + init + ";\n";
    }
    cur += "if (cx->depth >= cx->maxd) nfct_bail(cx);\n++cx->depth;\n";
    emit_block(P.body);
    if (can_complete(P.body)) cur += "--cx->depth;\n";
    else if (I.ret != Y_V) cur += "return " + zero(I.ret) + ";\n";
    return head(idx) + " {\n" + cur + "}\n";
  }

  std::string trampoline() {
    if (is_osr()) return trampoline_osr();
    Inst& I = in.insts[0];
    ProtoIR& P = *U.protos[static_cast<std::size_t>(I.proto)];
    std::string call = "nfct_f0(cx";
    for (int k = 0; k < P.nparams; ++k) {
      Ty t = I.sig[static_cast<std::size_t>(k)];
      call += ", " + std::string(t == Y_F ? "a[" + num(k) + "].d" : t == Y_B ? "(int)a[" + num(k) + "].i" : "a[" + num(k) + "].i");
    }
    call += ")";
    std::string s = "extern \"C\" int nfcast_tier_run(nfcr_Ctx* cx, const nfcr_W* a, nfcr_W* r) {\n  jmp_buf jb;\n  cx->jb = &jb;\n  if (setjmp(jb)) return 1;\n";
    if (I.ret == Y_V) s += "  " + call + ";\n";
    else if (I.ret == Y_N) s += "  { nfcr_N rn = " + call + "; *r = rn.w; cx->rtag = rn.f; }\n";
    else if (I.ret == Y_F) s += "  r->d = " + call + ";\n";
    else s += "  r->i = " + call + ";\n";
    return s + "  return 0;\n}\n";
  }

  std::string source(const std::string& rt_text) {
    std::string out = kPreamble;
    out += rt_text;
    out += "\n";
    out += kPostRt;
    for (std::size_t i = 0; i < in.insts.size(); ++i)
      if (in.live[i]) out += head(static_cast<int>(i)) + ";\n";
    for (std::size_t i = 0; i < in.insts.size(); ++i)
      if (in.live[i]) out += function(static_cast<int>(i));
    out += trampoline();
    return out;
  }
};

// ================================================================================================================================
// building, caching and loading
// ================================================================================================================================
bool has_slash(const std::string& s) { return s.find('/') != std::string::npos; }

std::string dir_of(const std::string& p) {
  std::size_t s = p.rfind('/');
  return s == std::string::npos ? "." : p.substr(0, s);
}

// Finds the driver, the cache directory and the text of nfcast_tier_rt.h, once.
void resolve(TierState* T) {
  if (T->resolved) return;
  T->resolved = true;
  T->driver = T->opt.driver.empty() ? bld::default_driver(__FILE__) : T->opt.driver;
  T->cache = T->opt.cache_dir.empty() ? bld::default_cache_dir("NFCAST_TIER_CACHE", "nfcast-tier-cache") : T->opt.cache_dir;
  std::string err = bld::ensure_cache_dir(T->cache);
  T->cache_ok = err.empty();
  if (!T->cache_ok) note(T, "%s", err);
  std::vector<std::string> cands;
  if (!T->opt.rt_dir.empty()) cands.push_back(T->opt.rt_dir);
  if (const char* e = std::getenv("NFCAST_TIER_RT")) cands.push_back(e);
  cands.push_back(dir_of(__FILE__));
  cands.push_back(bld::repo_root_of(__FILE__) + "/lib/ast");
  if (has_slash(T->driver)) cands.push_back(dir_of(T->driver) + "/lib/ast");
  for (const std::string& c : cands) {
    std::string t = bld::read_file(c + "/nfcast_tier_rt.h");
    if (!t.empty()) {
      T->rt_text = t;
      T->rt_dir = c;
      T->rt_ok = true;
      break;
    }
  }
  if (!T->rt_ok) note(T, "cannot find nfcast_tier_rt.h (set TierOptions::rt_dir or NFCAST_TIER_RT)%s", std::string());
}

void fail_version(State& S, Version* v, const std::string& why) {
  v->st = Version::Failed;
  v->why = why;
  ++S.stats.tier_failed;
  note(S.tier, "compile failed: %s", why);
}

// Loads the shared object of V; false (with ERR set) when it cannot be loaded.
bool install(State& S, Version* v, bool from_cache, std::string* err) {
  void* sym = nullptr;
  void* h = bld::open_so(v->so, "nfcast_tier_run", &sym, err);
  if (!h) return false;
  v->handle = h;
  v->run = reinterpret_cast<RunFn>(sym);
  v->st = Version::Ready;
  ++S.stats.tier_compiled;
  if (from_cache) ++S.stats.tier_cache_hits;
  note(S.tier, from_cache ? "loaded %s from the cache" : "compiled %s", v->so);
  return true;
}

// The child has ended: look at what it made.
void finish(State& S, Version* v) {
  bool ok = v->child.status == 0 && bld::file_exists(v->tmp);
  std::string out = bld::read_file(v->log);
  ::unlink(v->log.c_str());
  std::string kept = v->so.substr(0, v->so.size() - 3) + (ok ? ".cpp" : ".failed.cpp");  // the source stays next to the code, for a look
  ::rename(v->cpp.c_str(), kept.c_str());
  if (!ok) {
    ::unlink(v->tmp.c_str());
    std::string why = bld::failure_reason(v->child.status, S.tier->driver, S.tier->opt.timeout);
    if (!out.empty()) why += ": " + out.substr(0, 300);
    fail_version(S, v, why);
    return;
  }
  if (::rename(v->tmp.c_str(), v->so.c_str()) != 0) {
    ::unlink(v->tmp.c_str());
    fail_version(S, v, std::string("cannot install ") + v->so + ": " + std::strerror(errno));
    return;
  }
  std::string err;
  if (!install(S, v, false, &err)) fail_version(S, v, err);
}

// Starts the driver for V (its source is written already); in Sync mode waits for it.
void launch(State& S, Version* v) {
  TierState* T = S.tier;
  std::vector<std::string> args;
  args.push_back(T->driver);
  args.push_back("-shared");
  args.push_back(v->cpp);
  args.push_back("-o");
  args.push_back(v->tmp);
  ++S.stats.tier_compiles;
  note(T, "compiling %s", v->cpp);
  v->spawned = true;
  if (!bld::spawn(v->child, args, v->log)) {
    v->spawned = false;
    ::unlink(v->cpp.c_str());
    return fail_version(S, v, "cannot start the driver");
  }
  if (T->opt.mode == TierOptions::Sync) {
    bld::wait(v->child, true, T->opt.timeout);
    finish(S, v);
  } else {
    v->T = T;
    T->pending.push_back(v);
  }
}

// Looks at the compiles that are running and installs the ones that ended; starts queued ones in their place.
void poll_pending(State& S) {
  TierState* T = S.tier;
  for (std::size_t i = 0; i < T->pending.size();) {
    Version* v = T->pending[i];
    if (!bld::wait(v->child, false, T->opt.timeout)) {
      ++i;
      continue;
    }
    T->pending.erase(T->pending.begin() + static_cast<long>(i));
    finish(S, v);
  }
  while (!T->queued.empty() && T->pending.size() < (T->opt.jobs ? T->opt.jobs : 1u)) {
    Version* v = T->queued.front();
    T->queued.erase(T->queued.begin());
    launch(S, v);
  }
}

// Starts the build of V from SRC: from the cache if the shared object is there, else by running the driver.
void start_build(State& S, Version* v, const std::string& src) {
  TierState* T = S.tier;
  resolve(T);
  if (!T->rt_ok) return fail_version(S, v, "cannot find nfcast_tier_rt.h");
  if (!T->cache_ok) return fail_version(S, v, "no usable cache directory");
  std::string k = src;
  k += "\n//driver:" + T->driver;
  const char* be = std::getenv("NFCXX_BACKEND");
  k += std::string("\n//backend:") + (be ? be : "");
  std::string key = bld::hash_hex(k);
  std::string base = T->cache + "/nfcast-tier-" + key;
  v->so = base + ".so";
  if (bld::file_exists(v->so)) {
    std::string err;
    if (install(S, v, true, &err)) return;
    note(T, "unusable cache entry %s", v->so);
    ::unlink(v->so.c_str());  // a damaged file: build it again
  }
  // Every file this process makes has its pid in its name: another process may be building the same code, and a half-written
  // source must never be what a compiler reads.
  // Two functions or loops of one State can have the same code (a chunk loaded twice): the sequence number keeps their files apart.
  std::string pid = std::to_string(static_cast<long>(::getpid())) + "-" + std::to_string(T->build_seq++);
  v->cpp = base + "." + pid + ".cpp";
  v->tmp = base + "." + pid + ".so";
  v->log = base + "." + pid + ".log";
  if (!bld::write_file(v->cpp, src)) return fail_version(S, v, "cannot write " + v->cpp);
  if (T->opt.mode == TierOptions::Async && T->pending.size() >= (T->opt.jobs ? T->opt.jobs : 1u)) {
    v->T = T;
    T->queued.push_back(v);
    return;
  }
  launch(S, v);
}

// ================================================================================================================================
// asking for a compile
// ================================================================================================================================
Version* find_version(TierProto* tp, const std::vector<Ty>& sig) {
  for (std::unique_ptr<Version>& v : tp->vers)
    if (v->sig == sig) return v.get();
  return nullptr;
}

UnitMeta make_meta(const Unit& U) {
  UnitMeta m;
  for (const std::unique_ptr<ProtoIR>& p : U.protos) {
    MProto mp;
    mp.serial = p->serial;
    mp.nslots = p->nslots;
    mp.fvbase = p->fvbase;
    for (const FreeVar& f : p->fvs) mp.fvs.push_back(MFree{f.kind, f.idx, f.name, f.ty, f.written, f.ty});
    for (const Dep& d : p->deps) mp.deps.push_back(MDep{d.kind, d.idx, d.name, d.callee, d.cell});
    m.protos.push_back(std::move(mp));
  }
  m.nfv = U.nfv;
  m.max_nslots = U.max_nslots;
  return m;
}

// The types the typing settled on for the free variables, into the meta data the entry guard and the copy-back use.
void set_storage_types(UnitMeta& m, const Unit& U, const Infer& in) {
  for (std::size_t p = 0; p < m.protos.size(); ++p)
    for (std::size_t j = 0; j < m.protos[p].fvs.size(); ++j)
      m.protos[p].fvs[j].sty = in.fvty[static_cast<std::size_t>(U.protos[p]->fvbase) + j];
}

// The function of CL called with arguments of types SIG has been hot: lower it, and build it.
void request(State& S, TierProto* tp, Closure* cl, const std::vector<Ty>& sig) {
  TierState* T = S.tier;
  resolve(T);
  Unit U;
  Fail f;
  if (!build_unit(S, U, cl, f)) {
    tp->reason = f.why;
    if (!tp->counted) {
      tp->counted = true;
      ++S.stats.tier_ineligible;
    }
    ++tp->rejects;
    tp->retry_at = tp->rejects >= kMaxRejects ? 0xffffffffu : tp->calls + T->opt.threshold * (1u << (2 * tp->rejects));
    if (tp->rejects >= kMaxRejects) tp->dead = true;
    note(T, "not a kernel: %s", f.why);
    return;
  }
  tp->reason.clear();
  tp->calls = 0;  // the next version (for other argument types) has to earn its compile by its own calls
  tp->rejects = 0;
  tp->retry_at = 0;
  std::unique_ptr<Version> v(new Version());
  v->sig = sig;
  v->T = nullptr;
  Infer in(U);
  if (!in.run(sig)) {
    v->st = Version::Rejected;
    v->why = in.error;
    if (!tp->counted) {
      tp->counted = true;
      ++S.stats.tier_ineligible;
    }
    note(T, "not a kernel with these argument types: %s", in.error);
    tp->vers.push_back(std::move(v));
    return;
  }
  v->ret = in.insts[0].ret;
  v->meta = make_meta(U);
  set_storage_types(v->meta, U, in);
  Gen g(U, in);
  std::string src = g.source(T->rt_text);
  Version* raw = v.get();
  tp->vers.push_back(std::move(v));
  start_build(S, raw, src);
}

bool signature(const Value* args, int n, int nparams, std::vector<Ty>& sig) {
  if (n < nparams) return false;
  sig.clear();
  for (int k = 0; k < nparams; ++k) {
    Ty t = ty_of_tag(args[k].t);
    if (t == Y_UNK) return false;
    sig.push_back(t);
  }
  return true;
}

// ================================================================================================================================
// calling
// ================================================================================================================================
// Reads the binding KIND/IDX/NAME as seen from CL (kind 2: the local in slot IDX of the frame FR, in a Cell if CELL).
bool lookup(State& S, Closure* cl, Frame* fr, int kind, int idx, const std::string& name, bool cell, Value* out) {
  if (kind == 2) {
    if (!fr || idx < 0) return false;
    const Value& sv = fr->base[idx];
    *out = cell ? static_cast<Cell*>(sv.o)->v : sv;
    return true;
  }
  if (kind == 0) {
    if (idx < 0 || static_cast<std::uint32_t>(idx) >= cl->nup || !cl->up[idx]) return false;
    *out = cl->up[idx]->v;
    return true;
  }
  *out = S.globals->get_str(S.str(name));
  return true;
}

// Checks that every function and variable the code was compiled against is still what it assumed, as seen from the closure CL that
// is being called, and collects the values of the free variables. Nothing runs between this check and the end of the compiled
// run, so the answer holds for the whole run. FR is the frame of the running function when the unit is a loop of it; EXTRA are the
// cells of the locals that the loop reads or assigns (with whether it assigns them).
//
// The upvalues that the code assigns are worked on as copies and written back when the run has ended; that is only right if no
// other way into the same cell is used meanwhile, so a cell that is assigned and is reached in more than one place (two upvalues
// of two functions of the unit that are one variable, or a local of the loop's frame that a function of the unit also has as an
// upvalue) is a guard that fails.
bool bind(State& S, Closure* root, const UnitMeta& m, std::vector<Closure*>& clos, std::vector<nfcr_W>& fv, Frame* fr,
          const std::vector<std::pair<Cell*, bool>>* extra) {
  TierState* T = S.tier;
  clos.assign(m.protos.size(), nullptr);
  fv.resize(2 * static_cast<std::size_t>(m.nfv));
  clos[0] = root;
  if (!root->proto->tier || root->proto->tier->serial != m.protos[0].serial) return false;
  std::vector<std::pair<Cell*, bool>>& cells = T->cellbuf;
  cells.clear();
  if (extra) cells = *extra;
  bool any_written = false;
  for (const std::pair<Cell*, bool>& c : cells) any_written = any_written || c.second;
  for (std::size_t p = 0; p < m.protos.size(); ++p) {
    if (!clos[p]) continue;  // reached only through a call that the code does not make
    Closure* cl = clos[p];
    const MProto& mp = m.protos[p];
    for (const MDep& d : mp.deps) {
      Value v;
      if (!lookup(S, cl, p == 0 ? fr : nullptr, d.kind, d.idx, d.name, d.cell, &v) || !v.is_closure()) return false;
      Closure* c = v.closure();
      const MProto& cp = m.protos[static_cast<std::size_t>(d.callee)];
      if (!c->proto->tier || c->proto->tier->serial != cp.serial) return false;
      Closure*& slot = clos[static_cast<std::size_t>(d.callee)];
      if (slot && slot != c) return false;
      slot = c;
    }
    for (std::size_t j = 0; j < mp.fvs.size(); ++j) {
      const MFree& f = mp.fvs[j];
      Value v;
      if (!lookup(S, cl, nullptr, f.kind, f.idx, f.name, false, &v) || ty_of_tag(v.t) != f.ty) return false;
      nfcr_W* w = &fv[2 * (static_cast<std::size_t>(mp.fvbase) + j)];
      if (f.ty == Y_F) w[0].d = v.d;
      else w[0].i = f.ty == Y_B ? (v.t == T_TRUE ? 1 : 0) : v.i;
      w[1].i = (f.sty == Y_N && f.ty == Y_F) ? 1 : 0;
      if (f.kind == 0) {
        cells.push_back(std::make_pair(cl->up[f.idx], f.written));
        any_written = any_written || f.written;
      }
    }
  }
  if (any_written)
    for (std::size_t i = 0; i < cells.size(); ++i)
      if (cells[i].second)
        for (std::size_t j = 0; j < cells.size(); ++j)
          if (j != i && cells[j].first == cells[i].first) return false;
  return true;
}

// The run has ended: the upvalues it assigned get their values.
void commit(const UnitMeta& m, const std::vector<Closure*>& clos, const std::vector<nfcr_W>& fv) {
  for (std::size_t p = 0; p < m.protos.size(); ++p) {
    if (!clos[p]) continue;
    const MProto& mp = m.protos[p];
    for (std::size_t j = 0; j < mp.fvs.size(); ++j) {
      const MFree& f = mp.fvs[j];
      if (!f.written) continue;
      const nfcr_W* w = &fv[2 * (static_cast<std::size_t>(mp.fvbase) + j)];
      Value x;
      switch (f.sty) {
        case Y_I: x = Value::integer(w[0].i); break;
        case Y_F: x = Value::number(w[0].d); break;
        case Y_B: x = Value::boolean(w[0].i != 0); break;
        default: x = w[1].i ? Value::number(w[0].d) : Value::integer(w[0].i); break;
      }
      clos[p]->up[f.idx]->v = x;
    }
  }
}

// A deeper recursion than the value stack of the interpreter could hold must be left to the interpreter, which reports it.
bool stack_room(State& S, const UnitMeta& m) {
  long avail = static_cast<long>(S.stack_end - S.top);
  long levels = static_cast<long>(S.max_depth) - static_cast<long>(S.depth);
  return levels * (m.max_nslots + 8) + 700 <= avail;
}

bool run_version(State& S, Version* v, Closure* cl, const nfcr_W* argv, Rets& out) {
  TierState* T = S.tier;
  if (S.depth >= S.max_depth || !stack_room(S, v->meta)) {
    ++S.stats.tier_bailouts;
    ++S.stats.tier_guard_misses;
    return false;
  }
  if (!bind(S, cl, v->meta, T->closbuf, T->fvbuf, nullptr, nullptr)) {
    ++S.stats.tier_bailouts;
    ++S.stats.tier_guard_misses;
    return false;
  }
  nfcr_Ctx cx;
  cx.rtag = 0;
  cx.jb = nullptr;
  cx.depth = S.depth;
  cx.maxd = S.max_depth;
  cx.fv = T->fvbuf.data();
  nfcr_W r;
  r.i = 0;
  int rc = v->run(&cx, argv, &r);
  ++v->runs;
  if (rc != 0) {
    ++v->aborts;
    ++S.stats.tier_aborts;
    ++S.stats.tier_bailouts;
    if (v->aborts >= 8 && v->aborts * 4 > v->runs) v->st = Version::Dead;  // it mostly fails: stop trying
    return false;
  }
  commit(v->meta, T->closbuf, T->fvbuf);
  ++S.stats.tier_calls;
  switch (v->ret) {
    case Y_I: out.push(Value::integer(r.i)); break;
    case Y_F: out.push(Value::number(r.d)); break;
    case Y_N: out.push(cx.rtag ? Value::number(r.d) : Value::integer(r.i)); break;
    case Y_B: out.push(Value::boolean(r.i != 0)); break;
    default: break;
  }
  return true;
}

// Runs a ready version whose argument types match. Sets *MATCHED when there was one (even if it fell back).
bool try_versions(State& S, TierProto* tp, Closure* cl, Value* args, int n, Rets& out, bool* any_ready, bool* matched) {
  for (std::size_t i = 0; i < tp->vers.size(); ++i) {
    Version* v = tp->vers[i].get();
    if (v->st != Version::Ready) continue;
    *any_ready = true;
    if (n < static_cast<int>(v->sig.size())) continue;
    nfcr_W argv[kMaxParams];
    bool ok = true;
    for (std::size_t k = 0; k < v->sig.size(); ++k) {
      Ty t = ty_of_tag(args[k].t);
      if (t != v->sig[k]) {
        ok = false;
        break;
      }
      if (t == Y_F) argv[k].d = args[k].d;
      else argv[k].i = t == Y_B ? (args[k].t == T_TRUE ? 1 : 0) : args[k].i;
    }
    if (!ok) continue;
    *matched = true;
    return run_version(S, v, cl, argv, out);
  }
  return false;
}

// ================================================================================================================================
// on-stack replacement
// ================================================================================================================================
// The types of the live locals of a loop, as the frame holds them now; false when one is not a number or a boolean.
const Value& osr_local(Frame& f, int slot, bool cell) {
  const Value& x = f.base[slot];
  return cell ? static_cast<Cell*>(x.o)->v : x;
}

bool osr_signature(Frame& f, const std::vector<int>& slots, const std::vector<char>& cells, std::vector<Ty>& sig) {
  sig.clear();
  for (std::size_t k = 0; k < slots.size(); ++k) {
    Ty t = ty_of_tag(osr_local(f, slots[k], cells[k]).t);
    if (t == Y_UNK) return false;
    sig.push_back(t);
  }
  return true;
}

Version* find_osr_version(TierLoop* tl, const std::vector<Ty>& sig, int style) {
  for (std::unique_ptr<Version>& v : tl->vers)
    if (v->style == style && v->sig == sig) return v.get();
  return nullptr;
}

// The loop has been hot, or has not been looked at yet: lower it with the locals it has live, and build it. TL->in_slots is set when
// the loop could be lowered; a loop that cannot be is looked at again later, up to kMaxRejects times.
void osr_reject(State& S, TierLoop* tl, const std::string& why) {
  TierState* T = S.tier;
  tl->reason = why;
  if (!tl->counted) {
    tl->counted = true;
    ++S.stats.tier_osr_ineligible;
  }
  ++tl->rejects;
  tl->edges = 0;
  if (tl->rejects >= kMaxRejects) tl->dead = true;
  else tl->next_try = T->opt.loop_threshold * (1u << (2 * tl->rejects));
  note(T, "loop not taken over: %s", why);
}

void osr_request(State& S, TierProto* tp, TierLoop* tl, Frame& f, Node* loop, int style) {
  TierState* T = S.tier;
  resolve(T);
  Unit U;
  Fail fl;
  U.osr_frame = &f;
  if (!build_unit(S, U, f.cl, fl, loop, style)) return osr_reject(S, tl, fl.why);
  tl->in_slots = U.protos[0]->in_slots;
  tl->in_cell = U.protos[0]->in_cell;
  tl->in_written = U.protos[0]->in_written;
  tl->in_known = true;
  std::vector<Ty> sig;
  if (!osr_signature(f, tl->in_slots, tl->in_cell, sig)) return osr_reject(S, tl, "a local used in the loop is not a number or a boolean");
  tl->rejects = 0;
  tl->reason.clear();
  tl->edges = 0;  // another version (other types of the locals) has to earn its compile by its own iterations
  tl->next_try = T->opt.loop_threshold;
  if (find_osr_version(tl, sig, style)) return;
  std::unique_ptr<Version> v(new Version());
  v->sig = sig;
  v->style = style;
  v->T = nullptr;
  Infer in(U);
  if (!in.run(sig)) {
    v->st = Version::Rejected;
    v->why = in.error;
    if (!tl->counted) {
      tl->counted = true;
      ++S.stats.tier_osr_ineligible;
    }
    note(T, "loop not compiled with these types: %s", in.error);
    tl->vers.push_back(std::move(v));
    return;
  }
  v->ret = in.insts[0].ret;
  v->meta = make_meta(U);
  set_storage_types(v->meta, U, in);
  v->meta.protos[0].serial = tp->serial;  // the guard checks that the closure that runs the loop is of the function the loop is in
  v->in_slots = tl->in_slots;
  v->in_cell = tl->in_cell;
  v->in_written = tl->in_written;
  const ProtoIR& P = *U.protos[0];
  for (int var : P.pvars) v->out_ty.push_back(in.insts[0].vty[static_cast<std::size_t>(var)]);
  Gen g(U, in);
  std::string src = g.source(T->rt_text);
  Version* raw = v.get();
  tl->vers.push_back(std::move(v));
  start_build(S, raw, src);
}

// Runs the compiled loop V from the state ST: 1 when it ran to the end and the live locals are written back, 2 when it ran into a
// `return` (the value is pushed on the frame's results), 0 when it did not run. Nothing is touched then: the compiled loop works on
// copies, has no side effects, and the interpreter goes on from where it was.
int osr_run(State& S, Frame& f, Version* v, const TierLoopState& st) {
  TierState* T = S.tier;
  std::size_t n = v->sig.size();
  std::vector<std::pair<Cell*, bool>>& extra = T->extrabuf;
  extra.clear();
  for (std::size_t k = 0; k < n; ++k)
    if (v->in_cell[k]) extra.push_back(std::make_pair(static_cast<Cell*>(f.base[v->in_slots[k]].o), static_cast<bool>(v->in_written[k])));
  const char* why = S.depth >= S.max_depth ? "the depth" : !stack_room(S, v->meta) ? "the stack" : !bind(S, f.cl, v->meta, T->closbuf, T->fvbuf, &f, &extra) ? "a binding" : nullptr;
  if (why) {
    ++S.stats.tier_osr_bailouts;
    ++v->runs;  // a guard that keeps failing (a cell reached in two ways, say) is given up like a run that keeps being abandoned
    ++v->aborts;
    if (v->aborts >= 8 && v->aborts * 4 > v->runs) v->st = Version::Dead;
    note(T, "loop: a guard failed: %s", std::string(why));
    return 0;
  }
  nfcr_W argv[kMaxLive + 3];
  nfcr_W out[2 * kMaxLive + 2];
  for (std::size_t k = 0; k < n; ++k) {
    const Value& x = osr_local(f, v->in_slots[k], v->in_cell[k]);
    if (v->sig[k] == Y_F) argv[k].d = x.d;
    else argv[k].i = v->sig[k] == Y_B ? (x.t == T_TRUE ? 1 : 0) : x.i;
  }
  if (st.kind == TierLoopState::FOR_INT) {
    argv[n].i = st.i;
    argv[n + 1].i = static_cast<nfcr_i64>(st.count);
    argv[n + 2].i = st.step;
  } else if (st.kind == TierLoopState::FOR_FLT) {
    argv[n].d = st.d;
    argv[n + 1].d = st.limit;
    argv[n + 2].d = st.dstep;
  }
  nfcr_Ctx cx;
  cx.rtag = 0;
  cx.jb = nullptr;
  cx.depth = S.depth;
  cx.maxd = S.max_depth;
  cx.fv = T->fvbuf.data();
  int rc = v->run(&cx, argv, out);  // 0: the loop ended, 1: the run was abandoned, 2: the function returned
  ++v->runs;
  if (rc == 1) {
    ++v->aborts;
    ++S.stats.tier_osr_bailouts;
    note(T, "loop: a run was abandoned%s", std::string());
    if (v->aborts >= 8 && v->aborts * 4 > v->runs) v->st = Version::Dead;
    return 0;
  }
  ++S.stats.tier_osr_runs;
  commit(v->meta, T->closbuf, T->fvbuf);
  if (rc == 2) {  // the function returns
    switch (v->ret) {
      case Y_I: f.rets->push(Value::integer(out[2 * n].i)); break;
      case Y_F: f.rets->push(Value::number(out[2 * n].d)); break;
      case Y_B: f.rets->push(Value::boolean(out[2 * n].i != 0)); break;
      case Y_N: f.rets->push(out[2 * n + 1].i ? Value::number(out[2 * n].d) : Value::integer(out[2 * n].i)); break;
      default: break;
    }
    return 2;
  }
  for (std::size_t k = 0; k < n; ++k) {
    Value& x = v->in_cell[k] ? static_cast<Cell*>(f.base[v->in_slots[k]].o)->v : f.base[v->in_slots[k]];
    switch (v->out_ty[k]) {
      case Y_I: x = Value::integer(out[2 * k].i); break;
      case Y_F: x = Value::number(out[2 * k].d); break;
      case Y_B: x = Value::boolean(out[2 * k].i != 0); break;
      default: x = out[2 * k + 1].i ? Value::number(out[2 * k].d) : Value::integer(out[2 * k].i); break;
    }
  }
  return 1;
}

bool want_compile(TierState* T, TierProto* tp, std::uint32_t count, std::uint32_t threshold) {
  if (T->opt.mode == TierOptions::Off) return false;
  if (count < threshold) return false;
  if (tp->retry_at && tp->calls < tp->retry_at) return false;
  return tp->vers.size() < kMaxVersions;
}

}  // namespace

// ---- the hooks ------------------------------------------------------------------------------------------------------------------
bool tier_dispatch(State& S, Closure* cl, Value* args, int n, Rets& out) {
  TierState* T = S.tier;
  Proto* p = cl->proto;
  if (p->vararg) return false;
  if (!T->pending.empty() && (++T->tick & 15) == 0) poll_pending(S);
  TierProto* tp = p->tier ? p->tier : new_tier_proto(S, p);
  if (tp->dead) return false;
  bool any_ready = false, matched = false;
  if (try_versions(S, tp, cl, args, n, out, &any_ready, &matched)) return true;
  if (matched) return false;  // it ran and fell back (already counted)
  ++tp->calls;
  std::vector<Ty> sig;
  if (want_compile(T, tp, tp->calls, T->opt.threshold) && signature(args, n, p->nparams, sig) && !find_version(tp, sig)) {
    request(S, tp, cl, sig);
    bool ready2 = false;
    if (try_versions(S, tp, cl, args, n, out, &ready2, &matched)) return true;  // a synchronous compile is ready now
    if (matched) return false;
    any_ready = any_ready || ready2;
  }
  if (any_ready) {  // a compiled version exists, for other argument types, and nothing made one for these in time
    ++S.stats.tier_bailouts;
    ++S.stats.tier_guard_misses;
  }
  return false;
}

void tier_backedge(Frame& f) {
  State& S = *f.S;
  TierState* T = S.tier;
  Proto* p = f.cl->proto;
  if (p->vararg) return;
  TierProto* tp = p->tier ? p->tier : new_tier_proto(S, p);
  if (tp->dead) return;
  if (++tp->edges != T->opt.loop_threshold) return;
  if (T->opt.mode == TierOptions::Off || tp->vers.size() >= kMaxVersions) return;
  // The arguments the activation started with are not known any more; the parameters as they are now give the signature (a
  // version for a signature that never comes is merely never used).
  std::vector<Ty> sig;
  for (int k = 0; k < p->nparams; ++k) {
    Ty t = ty_of_tag(f.base[k].t);
    if (t == Y_UNK) return;
    sig.push_back(t);
  }
  if (find_version(tp, sig)) return;
  request(S, tp, f.cl, sig);
}

int tier_loop(Frame& f, Node* loop, TierLoop*& hook, const TierLoopState& st, bool edge) {
  State& S = *f.S;
  TierState* T = S.tier;
  if (T->opt.mode == TierOptions::Off || !T->opt.osr || f.inlined) return 0;
  TierLoop* tl = hook;
  if (!tl) {
    Proto* p = f.cl->proto;
    TierProto* tp = p->tier ? p->tier : new_tier_proto(S, p);
    tp->loops.emplace_back(new TierLoop());
    tl = hook = tp->loops.back().get();
    tl->next_try = T->opt.loop_threshold;
    tl->line = loop->line;
  }
  if (tl->dead) return 0;
  if (edge) {
    if (!T->pending.empty() && (++T->tick & 15) == 0) poll_pending(S);
    ++tl->edges;
  } else {
    tl->blocked = false;  // a loop that is entered anew is tried again
  }
  if (tl->blocked) return 0;
  bool ready = false;
  for (std::unique_ptr<Version>& v : tl->vers)
    if (v->st == Version::Ready) ready = true;
  std::vector<Ty> sig;
  bool have_sig = false;
  if (ready && tl->in_known) {
    have_sig = osr_signature(f, tl->in_slots, tl->in_cell, sig);
    if (have_sig) {
      Version* v = find_osr_version(tl, sig, st.kind);
      if (v && v->st == Version::Ready) {
        if (int r = osr_run(S, f, v, st)) return r;
        tl->blocked = true;  // abandoned, or a guard failed: the interpreter goes on, and does not try again at every edge
        return 0;
      }
    }
  }
  if (edge && tl->edges >= tl->next_try && tl->vers.size() < kMaxVersions) {
    Proto* p = f.cl->proto;
    TierProto* tp = p->tier ? p->tier : new_tier_proto(S, p);
    osr_request(S, tp, tl, f, loop, st.kind);
    if (tl->dead) return 0;
    // A synchronous compile is ready now.
    if (tl->in_known && osr_signature(f, tl->in_slots, tl->in_cell, sig)) {
      Version* v = find_osr_version(tl, sig, st.kind);
      if (v && v->st == Version::Ready) {
        if (int r = osr_run(S, f, v, st)) return r;
        tl->blocked = true;
      }
    }
  }
  return 0;
}

void tier_init_from_env(State& S) {
  const char* e = std::getenv("NFCAST_TIER");
  if (!e || !*e) return;
  std::string m = e;
  if (m == "0" || m == "off" || m == "no") return;
  TierOptions o;
  o.mode = m == "async" ? TierOptions::Async : TierOptions::Sync;
  if (const char* t = std::getenv("NFCAST_TIER_THRESHOLD")) {
    long v = std::atol(t);
    if (v > 0) o.threshold = o.loop_threshold = static_cast<unsigned>(v);
  }
  if (const char* r = std::getenv("NFCAST_TIER_OSR")) o.osr = !(r[0] == '0' && !r[1]);
  S.enable_tier(o);
}

void tier_shutdown(State& S) {
  if (!S.tier) return;
  TierState* T = S.tier;
  for (Version* v : T->pending) v->T = nullptr;  // the versions are freed with their functions; the objects are gone already
  for (Version* v : T->queued) v->T = nullptr;
  T->pending.clear();
  T->queued.clear();
  delete T;
  S.tier = nullptr;
}

void State::enable_tier(const TierOptions& opt) {
  if (opt.mode == TierOptions::Off) {
    if (tier) tier->opt.mode = TierOptions::Off;
    return;
  }
  if (!tier) {
    tier = new TierState();
    const char* d = std::getenv("NFCAST_TIER_DEBUG");
    tier->debug = d && d[0] == '1';
  }
  bool was_resolved = tier->resolved;
  tier->opt = opt;
  if (was_resolved) tier->resolved = false;  // the driver or the directories may have changed
}

void State::tier_wait() {
  if (!tier) return;
  while (!tier->pending.empty() || !tier->queued.empty()) {
    for (std::size_t i = 0; i < tier->pending.size(); ++i) bld::wait(tier->pending[i]->child, true, tier->opt.timeout);
    poll_pending(*this);
  }
}

std::string State::tier_loops(const Value& fn) {
  if (!tier) return "off";
  if (!fn.is_closure()) return "not a script function";
  TierProto* tp = fn.closure()->proto->tier;
  std::string s;
  if (tp)
    for (std::unique_ptr<TierLoop>& tl : tp->loops) {
      std::string one = "line " + std::to_string(tl->line) + ":";
      bool any = false;
      for (std::unique_ptr<Version>& v : tl->vers) {
        std::string sg;
        for (Ty t : v->sig) sg += ty_ch(t);
        any = true;
        switch (v->st) {
          case Version::Ready: one += " compiled " + sg + ";"; break;
          case Version::Building: one += " compiling " + sg + ";"; break;
          case Version::Rejected: one += " ineligible for " + sg + ": " + v->why + ";"; break;
          case Version::Failed: one += " failed for " + sg + ": " + v->why + ";"; break;
          case Version::Dead: one += " abandoned " + sg + ";"; break;
        }
      }
      if (!tl->reason.empty()) {
        one += " ineligible: " + tl->reason + ";";
        any = true;
      }
      if (!any) one += " cold;";
      one.erase(one.size() - 1);
      if (!s.empty()) s += "; ";
      s += one;
    }
  return s.empty() ? "cold" : s;
}

std::string State::tier_state(const Value& fn) {
  if (!tier) return "off";
  if (!fn.is_closure()) return "not a script function";
  Proto* p = fn.closure()->proto;
  TierProto* tp = p->tier;
  if (!tp) return "cold";
  std::string s;
  for (std::unique_ptr<Version>& v : tp->vers) {
    if (!s.empty()) s += "; ";
    switch (v->st) {
      case Version::Ready: s += "compiled " + sig_str(v->sig, v->ret); break;
      case Version::Building: s += "compiling " + sig_str(v->sig, v->ret); break;
      case Version::Rejected: s += "ineligible for " + sig_str(v->sig, Y_V) + ": " + v->why; break;
      case Version::Failed: s += "failed for " + sig_str(v->sig, Y_V) + ": " + v->why; break;
      case Version::Dead: s += "abandoned " + sig_str(v->sig, v->ret) + " (it keeps bailing out)"; break;
    }
  }
  if (!tp->reason.empty()) {
    if (!s.empty()) s += "; ";
    s += "ineligible: " + tp->reason;
  }
  return s.empty() ? "cold" : s;
}

}  // namespace nfcast
