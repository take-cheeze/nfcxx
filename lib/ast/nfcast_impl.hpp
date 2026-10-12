// nfcast internals shared by the translation units (nfcast_core.cpp, nfcast_ops.cpp, nfcast_parse.cpp, nfcast_nodes.cpp,
// nfcast_lib.cpp). Not for users of the library.
#pragma once
#include <cmath>
#include <memory>
#include <utility>

#include "nfcast.hpp"

namespace nfcast {

// Metamethod events. The first group is cached as "absent" in Table::absent; the arithmetic group is ordered like the AR_*
// operators below (TM_ADD + (op - AR_ADD)).
enum TM {
  TM_INDEX,
  TM_NEWINDEX,
  TM_EQ,
  TM_LEN,
  TM_CALL,
  TM_LT,
  TM_LE,
  TM_CONCAT,
  TM_UNM,
  TM_BNOT,
  TM_ADD,
  TM_SUB,
  TM_MUL,
  TM_MOD,
  TM_POW,
  TM_DIV,
  TM_IDIV,
  TM_BAND,
  TM_BOR,
  TM_BXOR,
  TM_SHL,
  TM_SHR,
  TM_TOSTRING,
  TM_NAME,
  TM_METATABLE,
  TM_PAIRS,
  TM_N
};

enum Arith { AR_ADD, AR_SUB, AR_MUL, AR_MOD, AR_POW, AR_DIV, AR_IDIV, AR_BAND, AR_BOR, AR_BXOR, AR_SHL, AR_SHR, AR_UNM, AR_BNOT };

enum Ctl { C_NORMAL = 0, C_BREAK = 1, C_RETURN = 2 };

// Unary operators besides AR_UNM and AR_BNOT, and the comparison operators.
enum { OPX_NOT = 100, OPX_LEN = 101 };
enum Cmp { CMP_EQ, CMP_NE, CMP_LT, CMP_LE, CMP_GT, CMP_GE };

struct Node;
struct VarInfo;

// A function's static description: its AST and the way it captures variables. Shared by every closure made from it; the
// nodes rewrite themselves in it, so every closure sees the specialization.
struct UpvalDesc {
  bool from_local;  // a local of the enclosing function (its Cell), else an upvalue of the enclosing function
  std::uint32_t index;
  std::string name;
  bool is_const = false;  // declared <const> (an assignment is a compile-time error)
};

struct Proto {
  int refs = 1;
  std::string chunk;  // "snippet"
  std::string name;   // for tracebacks: "function 'twice'", "main chunk", "function <snippet:3>"
  int linedefined = 0;
  int nparams = 0;
  bool vararg = false;
  int nslots = 0;  // parameters and locals
  std::vector<UpvalDesc> upvals;
  std::vector<int> captured_params;  // parameter slots that are boxed in a Cell on entry
  Node* body = nullptr;
  std::vector<std::unique_ptr<Node>> arena;  // every node of this function, including the ones that were rewritten away
  std::vector<Node*> patchables;             // nodes to patch() when the function is complete (captured locals)
  std::vector<String*> consts;               // the strings the nodes refer to, marked by the collector
  std::vector<Proto*> children;
  std::uint32_t mark_epoch = 0;

  Proto();
  ~Proto();
  Proto(const Proto&) = delete;
  Proto& operator=(const Proto&) = delete;
  void retain() { ++refs; }
  void release() {
    if (--refs == 0) delete this;
  }
  template <class T, class... A>
  T* make(A&&... a) {
    T* n = new T(static_cast<A&&>(a)...);
    arena.emplace_back(n);
    return n;
  }
};

// A running Lua function.
struct Frame {
  State* S;
  Closure* cl;
  Value* base;  // the parameters and locals
  Value* va;    // the extra arguments of a vararg function
  int nva;
  Rets* rets;   // where `return` puts its values
  Frame* prev;
  bool native_below;  // a native function (pcall, say) sits between this frame and PREV
  int line;     // the line the function is at, for error messages and tracebacks
};

struct Node {
  int line = 0;
  Node** slot = nullptr;  // where the parent holds this node; a rewrite stores the replacement there
  virtual ~Node() {}
  virtual Value eval(Frame& f) = 0;                                   // an expression's value (the first, if it has several)
  virtual void evalMulti(Frame& f, Rets& out) { out.push(eval(f)); }  // all its values (a call, `...`)
  virtual int exec(Frame& f) {                                        // a statement
    eval(f);
    return C_NORMAL;
  }
  virtual bool is_multi() const { return false; }
  virtual bool is_simple() const { return false; }  // evaluating it runs no script code and allocates nothing collectable
  virtual int node_kind() const { return 0; }       // 1 constant, 2 field access, 3 indexing (for the assignment factory)
  virtual void describe(std::string&) const {}  // "local 'x'" for "attempt to index a nil value (local 'x')"
  virtual void patch() {}                       // called once the enclosing function is complete
  // What the parser needs to know about an expression it has built.
  virtual int target_kind() const { return 0; }          // assignable: 1 local, 2 upvalue, 3 global, 4 indexed
  virtual VarInfo* target_var() const { return nullptr; }  // kind 1: the variable
  virtual int upval_index() const { return -1; }           // kind 2: the upvalue
  virtual bool is_call() const { return false; }
  virtual bool const_number(Value*) const { return false; }
  // How Lua's compiler classifies the expression (its debug information depends on it): 1 a constant that is true, 2 nil or
  // false, 0 anything else. `a and b` and `a or b` have the kind of b.
  virtual int expkind() const { return 0; }
  virtual bool concat_parts(std::vector<Node*>*) { return false; }  // a concatenation hands over its operands
  void adopt(Node*& child) {
    if (child) child->slot = &child;
  }
  // Replace this node by NEU in its parent. The node keeps running to the end of the current evaluation.
  void rewire(Node* neu) {
    neu->line = line;
    neu->slot = slot;
    if (slot) *slot = neu;
  }
};

// A local variable at parse time; nodes copy `captured` when the function is complete.
struct VarInfo {
  std::string name;
  int slot = 0;
  bool captured = false;
  bool is_const = false;
};

// ---- helpers shared by the translation units --------------------------------------------------------------------------
bool raw_equal(const Value& a, const Value& b);
std::uint32_t hash_value(const Value& v);
inline bool is_long_string(const String* s) { return !s->interned; }
bool str_equal(const String* a, const String* b);

Closure* new_closure(State& S, Proto* p, std::uint32_t nup);
Cell* new_cell(State& S, const Value& v);
inline void safepoint(State& S) {
  if (S.bytes > S.gc_threshold || S.gc_stress) S.collect();
}

// Metatables and metamethods.
Table* get_metatable(State& S, const Value& v);
Value tm_value(State& S, const Value& v, TM ev);
Value tm_of_table(State& S, Table* t, TM ev);  // the metamethod of a table's metatable, nil if none (uses the absent cache)
const char* tm_name(TM ev);
String* tm_string(State& S, TM ev);

// Generic operations with metamethods. WHERE names the operand's variable in error messages; it may be null.
Value index_slow(State& S, const Value& obj, const Value& key, Node* where);
void setindex_slow(State& S, const Value& obj, const Value& key, const Value& val, Node* where);
Value arith_slow(State& S, int op, const Value& a, const Value& b, Node* na, Node* nb);
bool equals_slow(State& S, const Value& a, const Value& b);
bool less_slow(State& S, const Value& a, const Value& b);   // a < b
bool lesseq_slow(State& S, const Value& a, const Value& b);  // a <= b
Value len_slow(State& S, const Value& v, Node* where);
Value concat_slow(State& S, Value* vals, int n, Node** nodes);  // vals are on the stack
// Calls FN, which sits at ARGS[-1] (rooted); ARGS[0..n) are the arguments. Throws Thrown.
void call_value(State& S, const Value& fn, Value* args, int n, Rets& out, Node* where);
void call_closure(State& S, Closure* cl, Value* args, int n, Rets& out, bool from_native = false);

// Constant folding as Lua's compiler does it: false when the operation is not folded (a division by zero, a float that is
// not an integer used as one, a result that is NaN or a float zero).
bool fold_arith(int op, const Value& a, const Value& b, Value* out);
bool to_number(const Value& v, Value* out);               // a number or a string that reads as one
bool to_integer(const Value& v, std::int64_t* out);        // an integer, a float or string with an exact integer value
std::string var_info(Node* n);                             // " (local 'x')" or ""

// Lua's integer and float operators.
inline std::int64_t int_floordiv(State& S, std::int64_t a, std::int64_t b) {
  if (static_cast<std::uint64_t>(b) + 1u <= 1u) {  // b is 0 or -1
    if (b == 0) S.rt_error("attempt to divide by zero");
    return static_cast<std::int64_t>(0u - static_cast<std::uint64_t>(a));
  }
  std::int64_t q = a / b;
  if ((a ^ b) < 0 && a % b != 0) --q;
  return q;
}
inline std::int64_t int_mod(State& S, std::int64_t a, std::int64_t b) {
  if (static_cast<std::uint64_t>(b) + 1u <= 1u) {
    if (b == 0) S.rt_error("attempt to perform 'n%0'");
    return 0;
  }
  std::int64_t r = a % b;
  if (r != 0 && (r ^ b) < 0) r += b;
  return r;
}
inline double flt_mod(double a, double b) {
  double m = std::fmod(a, b);
  if ((m > 0) ? b < 0 : (m < 0 && b > 0)) m += b;
  return m;
}
inline double flt_pow(double a, double b) { return b == 2 ? a * a : std::pow(a, b); }
inline std::int64_t shift_left(std::int64_t x, std::int64_t y) {
  if (y <= -64 || y >= 64) return 0;
  if (y >= 0) return static_cast<std::int64_t>(static_cast<std::uint64_t>(x) << y);
  return static_cast<std::int64_t>(static_cast<std::uint64_t>(x) >> (-y));
}

// ---- the parser and the standard library --------------------------------------------------------------------------------
void open_base(State& S);
void open_string(State& S);
void open_table(State& S);
void open_math(State& S);
void register_function(State& S, Table* t, const char* prefix, const char* name, NativeFn fn);

// Node factories (nfcast_nodes.cpp). Each allocates in P's arena and adopts its children.
struct TableItem {
  Node* key;  // null: a positional item
  Node* val;
};
Node* n_const(Proto& P, int line, const Value& v);
Node* n_local(Proto& P, int line, VarInfo* vi);
Node* n_upval(Proto& P, int line, int idx, String* name);
Node* n_global(Proto& P, int line, String* name);
Node* n_index(Proto& P, int line, Node* obj, Node* key);
Node* n_call(Proto& P, int line, Node* fn, std::vector<Node*> args);
Node* n_method(Proto& P, int line, Node* obj, String* name, std::vector<Node*> args);
Node* n_function(Proto& P, int line, Proto* child);
Node* n_vararg(Proto& P, int line);
Node* n_table(Proto& P, int line, std::vector<TableItem> items);
Node* n_arith(Proto& P, int line, int op, Node* a, Node* b);
Node* n_unary(Proto& P, int line, int op, Node* a);  // op: AR_UNM, AR_BNOT, OPX_NOT, OPX_LEN
Node* n_compare(Proto& P, int line, int op, Node* a, Node* b);  // op: Cmp
Node* n_and(Proto& P, int line, Node* a, Node* b);
Node* n_or(Proto& P, int line, Node* a, Node* b);
Node* n_concat(Proto& P, int line, std::vector<Node*> parts);
Node* n_paren(Proto& P, int line, Node* e);

Node* n_block(Proto& P, int line, std::vector<Node*> stmts);
Node* n_localdecl(Proto& P, int line, std::vector<VarInfo*> vars, std::vector<Node*> exprs);
Node* n_assign(Proto& P, int line, std::vector<Node*> targets, std::vector<Node*> exprs);
Node* n_callstat(Proto& P, int line, Node* call);
Node* n_while(Proto& P, int line, Node* cond, Node* body);
Node* n_repeat(Proto& P, int line, Node* body, Node* cond);
Node* n_if(Proto& P, int line, std::vector<Node*> conds, std::vector<Node*> blocks, Node* els);
Node* n_fornum(Proto& P, int line, VarInfo* var, Node* start, Node* limit, Node* step, Node* body);
Node* n_forin(Proto& P, int line, std::vector<VarInfo*> vars, std::vector<Node*> exprs, int hidden_slot, Node* body);
Node* n_localfunc(Proto& P, int line, VarInfo* var, Node* fn);
Node* n_return(Proto& P, int line, std::vector<Node*> exprs);
Node* n_break(Proto& P, int line);

// Runs a native function. WHERE is the node that called it (null: another native called it).
inline void invoke_native(State& S, Native* nat, Value* args, int n, Rets& out, Node* where) {
  if (S.depth >= S.max_depth) S.rt_error("stack overflow");
  ++S.depth;
  Node* sw = S.call_where;
  Native* sn = S.cur_native;
  bool snf = S.nfn;
  S.call_where = where;
  S.cur_native = nat;
  S.nfn = where == nullptr;
  Args a;
  a.v = args;
  a.n = n;
  nat->fn(S, a, out, *nat);
  S.call_where = sw;
  S.cur_native = sn;
  S.nfn = snf;
  --S.depth;
}

// Parses CODE into a main-chunk Proto (retained once); null with ERR set on a syntax error.
Proto* parse_chunk(State& S, std::string_view code, const std::string& chunkname, std::string* err);

}  // namespace nfcast
